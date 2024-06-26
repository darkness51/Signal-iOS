//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

open class SignalBaseTest: XCTestCase {

    public override func setUp() {
        super.setUp()

        SetCurrentAppContext(TestAppContext())
        MockSSKEnvironment.activate()
    }

    open override func tearDown() {
        MockSSKEnvironment.flushAndWait()
        super.tearDown()
    }

    func read<T>(block: (SDSAnyReadTransaction) throws -> T) rethrows -> T {
        return try databaseStorage.read(block: block)
    }

    func write<T>(block: (SDSAnyWriteTransaction) throws -> T) rethrows -> T {
        return try databaseStorage.write(block: block)
    }
}
