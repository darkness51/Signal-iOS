//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalRingRTC
import SignalServiceKit
import SignalUI

/// Represents an observer who will receive updates about a call happening on
/// this device. See ``SignalCall``.
protocol CallObserver: AnyObject {
    func individualCallStateDidChange(_ call: SignalCall, state: CallState)
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool)
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool)
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool)
    func individualCallRemoteSharingScreenDidChange(_ call: SignalCall, isRemoteSharingScreen: Bool)
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool)

    func groupCallLocalDeviceStateChanged(_ call: SignalCall)
    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall)
    func groupCallPeekChanged(_ call: SignalCall)
    func groupCallRequestMembershipProof(_ call: SignalCall)
    func groupCallRequestGroupMembers(_ call: SignalCall)
    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason)
    func groupCallReceivedReactions(_ call: SignalCall, reactions: [SignalRingRTC.Reaction])
    func groupCallReceivedRaisedHands(_ call: SignalRingRTC.GroupCall, raisedHands: [UInt32])

    /// Invoked if a call message failed to send because of a safety number change
    /// UI observing call state may choose to alert the user (e.g. presenting a SafetyNumberConfirmationSheet)
    func callMessageSendFailedUntrustedIdentity(_ call: SignalCall)
}

extension CallObserver {
    func individualCallStateDidChange(_ call: SignalCall, state: CallState) {}
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool) {}
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallRemoteSharingScreenDidChange(_ call: SignalCall, isRemoteSharingScreen: Bool) {}
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool) {}

    func groupCallLocalDeviceStateChanged(_ call: SignalCall) {}
    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {}
    func groupCallPeekChanged(_ call: SignalCall) {}
    func groupCallRequestMembershipProof(_ call: SignalCall) {}
    func groupCallRequestGroupMembers(_ call: SignalCall) {}
    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {}
    func groupCallReceivedReactions(_ call: SignalCall, reactions: [SignalRingRTC.Reaction]) {}
    func groupCallReceivedRaisedHands(_ call: SignalRingRTC.GroupCall, raisedHands: [UInt32]) {}

    func callMessageSendFailedUntrustedIdentity(_ call: SignalCall) {}
}

/// Represents a call happening on this device.
class SignalCall: CallManagerCallReference {
    private var audioSession: AudioSession { NSObject.audioSession }
    private var databaseStorage: SDSDatabaseStorage { NSObject.databaseStorage }
    private var tsAccountManager: any TSAccountManager { DependenciesBridge.shared.tsAccountManager }

    private(set) var raisedHands: [RemoteDeviceState] = []

    let mode: Mode
    enum Mode {
        case individual(IndividualCall)
        case groupThread(GroupThreadCall)
    }

    public let audioActivity: AudioActivity

    private(set) var systemState: SystemState = .notReported
    enum SystemState {
        case notReported
        case pending
        case reported
        case removed
    }

    public var hasTerminated: Bool {
        switch mode {
        case .groupThread:
            if case .incomingRingCancelled = groupCallRingState {
                return true
            }
            return false
        case .individual(let call):
            return call.hasTerminated
        }
    }

    public var isOutgoingAudioMuted: Bool {
        switch mode {
        case .individual(let call): return call.isMuted
        case .groupThread(let call): return call.ringRtcCall.isOutgoingAudioMuted
        }
    }

    public var isOutgoingVideoMuted: Bool {
        switch mode {
        case .individual(let call): return !call.hasLocalVideo
        case .groupThread(let call): return call.ringRtcCall.isOutgoingVideoMuted
        }
    }

    public var joinState: JoinState {
        switch mode {
        case .individual(let call):
            /// `JoinState` is a group call concept, but we want to bridge
            /// between the two call types.
            /// TODO: Continue to tweak this as we unify the individual and
            /// group call UIs.
            switch call.state {
            case .idle,
                 .remoteHangup,
                 .remoteHangupNeedPermission,
                 .localHangup,
                 .remoteRinging,
                 .localRinging_Anticipatory,
                 .localRinging_ReadyToAnswer,
                 .remoteBusy,
                 .localFailure,
                 .busyElsewhere,
                 .answeredElsewhere,
                 .declinedElsewhere:
                return .notJoined
            case .connected,
                 .accepting,
                 .answering,
                 .reconnecting,
                 .dialing:
                return .joined
            }
        case .groupThread(let call): return call.ringRtcCall.localDeviceState.joinState
        }
    }

    public var canJoin: Bool {
        switch mode {
        case .individual(_): return true
        case .groupThread(let call): return !call.ringRtcCall.isFull
        }
    }

    /// Returns the remote party for an incoming 1:1 call, or the ringer for a group call ring.
    ///
    /// Returns `nil` for an outgoing 1:1 call, a manually-entered group call,
    /// or a group call that has already been joined.
    public var caller: SignalServiceAddress? {
        switch mode {
        case .individual(let call):
            guard call.direction == .incoming else {
                return nil
            }
            return call.remoteAddress
        case .groupThread:
            guard case .incomingRing(let caller, _) = groupCallRingState else {
                return nil
            }
            return caller
        }
    }

    private(set) lazy var videoCaptureController = VideoCaptureController()

    // Should be used only on the main thread
    public var connectedDate: Date? {
        didSet { AssertIsOnMainThread() }
    }

    // Distinguishes between calls locally, e.g. in CallKit
    public let localId: UUID = UUID()

    internal struct RingRestrictions: OptionSet {
        var rawValue: UInt8

        /// The user does not get to choose whether this kind of call rings.
        static let notApplicable = Self(rawValue: 1 << 0)
        /// The user cannot ring because there is already a call in progress.
        static let callInProgress = Self(rawValue: 1 << 1)
        /// This group is too large to allow ringing.
        static let groupTooLarge = Self(rawValue: 1 << 2)
    }

    internal var ringRestrictions: RingRestrictions {
        didSet {
            AssertIsOnMainThread()
            switch mode {
            case .individual:
                break
            case .groupThread(let call):
                if ringRestrictions != oldValue, joinState == .notJoined {
                    // Use a fake local state change to refresh the call controls.
                    //
                    // If we ever introduce ringing restrictions for 1:1 calls,
                    // a similar affordance will be needed to refresh the call
                    // controls.
                    self.groupCall(onLocalDeviceStateChanged: call.ringRtcCall)
                }
            }
        }
    }

    internal enum GroupCallRingState {
        case doNotRing
        case shouldRing
        case ringing
        case ringingEnded
        case incomingRing(caller: SignalServiceAddress, ringId: Int64)
        case incomingRingCancelled

        var isIncomingRing: Bool {
            switch self {
            case .incomingRing, .incomingRingCancelled:
                return true
            default:
                return false
            }
        }
    }

    internal var groupCallRingState: GroupCallRingState = .shouldRing {
        didSet {
            AssertIsOnMainThread()
            switch mode {
            case .individual:
                // If we ever support non-ringing 1:1 calls, we might want to reuse this.
                owsFailDebug("must be group call")
            case .groupThread:
                break
            }
        }
    }

    public var error: CallError?
    public enum CallError: Error {
        case providerReset
        case disconnected
        case externalError(underlyingError: Error)
        case timeout(description: String)
        case signaling
        case doNotDisturbEnabled
        case contactIsBlocked

        func shouldSilentlyDropCall() -> Bool {
            switch self {
            case .providerReset, .disconnected, .externalError, .timeout, .signaling:
                return false
            case .doNotDisturbEnabled, .contactIsBlocked:
                return true
            }
        }
    }

    var participantAddresses: [SignalServiceAddress] {
        switch mode {
        case .groupThread(let call):
            return call.ringRtcCall.remoteDeviceStates.values.map { $0.address }
        case .individual(let call):
            return [call.remoteAddress]
        }
    }

    init(groupCall: GroupCall, groupThread: TSGroupThread, videoCaptureController: VideoCaptureController) {
        self.mode = .groupThread(GroupThreadCall(ringRtcCall: groupCall, groupThread: groupThread))
        self.audioActivity = AudioActivity(
            audioDescription: "[SignalCall] with group \(groupThread.groupModel.groupId)",
            behavior: .call
        )
        self.ringRestrictions = []
        self.videoCaptureController = videoCaptureController

        if groupThread.groupModel.groupMembers.count > RemoteConfig.maxGroupCallRingSize {
            self.ringRestrictions.insert(.groupTooLarge)
        }

        // Track the callInProgress restriction regardless; we use that for purposes other than rings.
        let hasActiveCallMessage = NSObject.databaseStorage.read { transaction -> Bool in
            !GroupCallInteractionFinder().unendedCallsForGroupThread(groupThread, transaction: transaction).isEmpty
        }
        if hasActiveCallMessage {
            // This info may be out of date, but the first peek will update it.
            self.ringRestrictions.insert(.callInProgress)
        }

        groupCall.delegate = self
        // Watch group membership changes.
        // The object is the group thread ID, which is a string.
        // NotificationCenter dispatches by object identity rather than equality,
        // so we watch all changes and filter later.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(groupMembershipDidChange),
            name: TSGroupThread.membershipDidChange,
            object: nil
        )
    }

    init(individualCall: IndividualCall) {
        self.mode = .individual(individualCall)
        self.audioActivity = AudioActivity(
            audioDescription: "[SignalCall] with individual \(individualCall.remoteAddress)",
            behavior: .call
        )
        self.ringRestrictions = .notApplicable
        individualCall.delegate = self
    }

    deinit {
        owsAssertDebug(systemState != .reported, "call \(localId) was reported to system but never removed")
    }

    public class func outgoingIndividualCall(thread: TSContactThread) -> IndividualCall {
        return IndividualCall(
            direction: .outgoing,
            state: .dialing,
            thread: thread,
            sentAtTimestamp: Date.ows_millisecondTimestamp(),
            callAdapterType: .default
        )
    }

    public class func incomingIndividualCall(
        thread: TSContactThread,
        sentAtTimestamp: UInt64,
        offerMediaType: TSRecentCallOfferType
    ) -> SignalCall {
        let callAdapterType: CallAdapterType = .default
        let individualCall = IndividualCall(
            direction: .incoming,
            state: .answering,
            thread: thread,
            sentAtTimestamp: sentAtTimestamp,
            callAdapterType: callAdapterType
        )
        individualCall.offerMediaType = offerMediaType
        return SignalCall(individualCall: individualCall)
    }

    @objc
    private func groupMembershipDidChange(_ notification: Notification) {
        // NotificationCenter dispatches by object identity rather than equality,
        // so we filter based on the thread ID here.
        if ringRestrictions.contains(.notApplicable) {
            return
        }
        let call: GroupThreadCall
        switch self.mode {
        case .individual:
            return
        case .groupThread(let groupThreadCall):
            call = groupThreadCall
        }
        guard call.groupThread.uniqueId == notification.object as? String else {
            return
        }
        self.databaseStorage.read { transaction in
            call.groupThread.anyReload(transaction: transaction)
        }
        let groupModel = call.groupThread.groupModel
        let isGroupTooLarge = groupModel.groupMembers.count > RemoteConfig.maxGroupCallRingSize
        ringRestrictions.update(.groupTooLarge, present: isGroupTooLarge)
    }

    // MARK: -

    private var observers: WeakArray<CallObserver> = []

    public func addObserverAndSyncState(observer: CallObserver) {
        AssertIsOnMainThread()

        observers.append(observer)

        // Synchronize observer with current call state
        switch mode {
        case .individual(let individualCall):
            observer.individualCallStateDidChange(self, state: individualCall.state)
        case .groupThread:
            observer.groupCallLocalDeviceStateChanged(self)
            observer.groupCallRemoteDeviceStatesChanged(self)
        }
    }

    public func removeObserver(_ observer: CallObserver) {
        AssertIsOnMainThread()

        observers.removeAll { $0 === observer }
    }

    public func publishSendFailureUntrustedParticipantIdentity() {
        observers.elements.forEach { $0.callMessageSendFailedUntrustedIdentity(self) }
    }

    // MARK: -

    // This method should only be called when the call state is "connected".
    public func connectionDuration() -> TimeInterval {
        guard let connectedDate = connectedDate else {
            owsFailDebug("Called connectionDuration before connected.")
            return 0
        }
        return -connectedDate.timeIntervalSinceNow
    }

    func markPendingReportToSystem() {
        owsAssertDebug(systemState == .notReported, "call \(localId) had unexpected system state: \(systemState)")
        systemState = .pending
    }

    func markReportedToSystem() {
        owsAssertDebug(systemState == .notReported || systemState == .pending,
                       "call \(localId) had unexpected system state: \(systemState)")
        systemState = .reported
    }

    func markRemovedFromSystem() {
        // This was an assert that was firing when coming back online after missing
        // a call while offline. See IOS-3416
        if systemState != .reported {
            Logger.warn("call \(localId) had unexpected system state: \(systemState)")
        }
        systemState = .removed
    }
}

extension SignalCall: GroupCallDelegate {
    public func groupCall(onLocalDeviceStateChanged groupCall: GroupCall) {
        if groupCall.localDeviceState.joinState == .joined, connectedDate == nil {
            connectedDate = Date()
            if groupCallRingState.isIncomingRing {
                groupCallRingState = .ringingEnded
            }

            // make sure we don't terminate audio session during call
            audioSession.isRTCAudioEnabled = true
            owsAssertDebug(audioSession.startAudioActivity(audioActivity))
        }

        observers.elements.forEach { $0.groupCallLocalDeviceStateChanged(self) }
    }

    public func groupCall(onRemoteDeviceStatesChanged groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRemoteDeviceStatesChanged(self) }
        // Change this after notifying observers so that they can see when the ring has concluded.
        if case .ringing = groupCallRingState, !groupCall.remoteDeviceStates.isEmpty {
            groupCallRingState = .ringingEnded
            // Treat the end of ringing as a "local state change" for listeners that normally ignore remote changes.
            self.groupCall(onLocalDeviceStateChanged: groupCall)
        }
    }

    public func groupCall(onAudioLevels groupCall: GroupCall) {
        // TODO: Implement audio level handling for group calls.
    }

    public func groupCall(onLowBandwidthForVideo groupCall: SignalRingRTC.GroupCall, recovered: Bool) {
        // TODO: Implement handling of the "low outgoing bandwidth for video" notification.
    }

    public func groupCall(onReactions groupCall: SignalRingRTC.GroupCall, reactions: [SignalRingRTC.Reaction]) {
        observers.elements.forEach {
            $0.groupCallReceivedReactions(
                self,
                reactions: reactions
            )
        }
    }

    public func groupCall(onRaisedHands groupCall: SignalRingRTC.GroupCall, raisedHands: [UInt32]) {
        guard
            FeatureFlags.callRaiseHandReceiveSupport,
            FeatureFlags.useCallMemberComposableViewsForRemoteUsersInGroupCalls
        else { return }

        self.raisedHands = raisedHands.compactMap { groupCall.remoteDeviceStates[$0] }

        observers.elements.forEach {
            $0.groupCallReceivedRaisedHands(
                groupCall,
                raisedHands: raisedHands
            )
        }
    }

    public func groupCall(onPeekChanged groupCall: GroupCall) {
        guard let localAci = self.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci else {
            owsFailDebug("Peek changed for a group call, but we're not registered?")
            return
        }

        if let peekInfo = groupCall.peekInfo {
            // Note that we track this regardless of whether ringing is available.
            // There are other places that use this.

            let minDevicesToConsiderCallInProgress: UInt32 = {
                if peekInfo.joinedMembers.contains(localAci.rawUUID) {
                    // If we're joined, require us + someone else.
                    return 2
                } else {
                    // Otherwise, anyone else in the call counts.
                    return 1
                }
            }()

            ringRestrictions.update(
                .callInProgress,
                present: peekInfo.deviceCountExcludingPendingDevices >= minDevicesToConsiderCallInProgress
            )
        }
        observers.elements.forEach { $0.groupCallPeekChanged(self) }
    }

    public func groupCall(requestMembershipProof groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRequestMembershipProof(self) }
    }

    public func groupCall(requestGroupMembers groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRequestGroupMembers(self) }
    }

    public func groupCall(onEnded groupCall: GroupCall, reason: GroupCallEndReason) {
        observers.elements.forEach { $0.groupCallEnded(self, reason: reason) }
    }
}

extension SignalCall: IndividualCallDelegate {
    public func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        if case .connected = state, connectedDate == nil {
            connectedDate = Date()
        }

        observers.elements.forEach { $0.individualCallStateDidChange(self, state: state) }
    }

    public func individualCallLocalVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        observers.elements.forEach { $0.individualCallLocalVideoMuteDidChange(self, isVideoMuted: isVideoMuted) }
    }

    public func individualCallLocalAudioMuteDidChange(_ call: IndividualCall, isAudioMuted: Bool) {
        observers.elements.forEach { $0.individualCallLocalAudioMuteDidChange(self, isAudioMuted: isAudioMuted) }
    }

    public func individualCallHoldDidChange(_ call: IndividualCall, isOnHold: Bool) {
        observers.elements.forEach { $0.individualCallHoldDidChange(self, isOnHold: isOnHold) }
    }

    public func individualCallRemoteVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        observers.elements.forEach { $0.individualCallRemoteVideoMuteDidChange(self, isVideoMuted: isVideoMuted) }
    }

    public func individualCallRemoteSharingScreenDidChange(_ call: IndividualCall, isRemoteSharingScreen: Bool) {
        observers.elements.forEach { $0.individualCallRemoteSharingScreenDidChange(self, isRemoteSharingScreen: isRemoteSharingScreen) }
    }
}

extension SignalCall: CallNotificationInfo {
    var thread: TSThread {
        switch mode {
        case .individual(let call): return call.thread
        case .groupThread(let call): return call.groupThread
        }
    }

    var offerMediaType: TSRecentCallOfferType {
        switch mode {
        case .individual(let call): return call.offerMediaType
        case .groupThread: return .video
        }
    }
}

extension GroupCall {
    public var isFull: Bool {
        guard let peekInfo = peekInfo, let maxDevices = peekInfo.maxDevices else { return false }
        return peekInfo.deviceCountExcludingPendingDevices >= maxDevices
    }
    public var maxDevices: UInt32? {
        guard let peekInfo = peekInfo, let maxDevices = peekInfo.maxDevices else { return nil }
        return maxDevices
    }
}
