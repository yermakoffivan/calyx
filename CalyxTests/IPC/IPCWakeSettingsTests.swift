//
//  IPCWakeSettingsTests.swift
//  CalyxTests
//
//  Pins IPCWakeSettings: the setting (`IPCWakeSettings.enabled`) that
//  gates `/ipc-wake`, same shape as CockpitSettings.autoApproveEnabled and
//  defaulting OFF.
//
//  Coverage:
//  - The UserDefaults key literal
//  - enabled defaults to false when the key has never been written
//  - Setting it persists and round-trips, in an isolated UserDefaults
//    suite (never touches the user's real defaults domain)
//  - Suite isolation: a fresh suite never leaks state from a
//    previously-used suite, and writes never reach .standard
//

import XCTest
@testable import Calyx

final class IPCWakeSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.IPCWakeSettingsTests"
    private var standardDefaultsTripwire: StandardDefaultsTripwire!

    override func setUp() {
        super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: "calyx.ipc.wakeEnabled")
        IPCWakeSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        IPCWakeSettings._testTeardownSuite(named: suiteName)
        standardDefaultsTripwire.assertUnchanged()
        super.tearDown()
    }

    func test_enabledKey_isTheSpecifiedLiteral() {
        XCTAssertEqual(IPCWakeSettings.enabledKey, "calyx.ipc.wakeEnabled")
    }

    func test_default_isOff() {
        XCTAssertFalse(IPCWakeSettings.enabled,
                       "enabled must default to false when the key has never been written")
    }

    func test_setAndRead_roundTrip() {
        IPCWakeSettings.enabled = true
        XCTAssertTrue(IPCWakeSettings.enabled, "Setting enabled to true must be readable back as true")

        // Verify the write actually reached the isolated test suite,
        // under the specified key -- otherwise the assertion above would
        // be indistinguishable from a getter backed by something else.
        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(rawSuite.object(forKey: "calyx.ipc.wakeEnabled") as? Bool, true,
                       "Setting enabled must persist the value into the isolated test suite")

        IPCWakeSettings.enabled = false
        XCTAssertFalse(IPCWakeSettings.enabled, "Setting enabled to false must be readable back as false")
        XCTAssertEqual(rawSuite.object(forKey: "calyx.ipc.wakeEnabled") as? Bool, false,
                       "Setting enabled to false must persist an explicit false, not remove the key")
    }

    func test_testStoreIsolation() {
        assertStandardDefaultsUntouched(key: "calyx.ipc.wakeEnabled") { before in
            IPCWakeSettings.enabled = !(before ?? false)
        }

        // Write the non-default value unconditionally so the assertion
        // below can never be satisfied by the suite above already
        // holding false.
        assertStandardDefaultsUntouched(key: "calyx.ipc.wakeEnabled") { _ in
            IPCWakeSettings.enabled = true
        }
        XCTAssertTrue(IPCWakeSettings.enabled,
                      "precondition: the isolated suite holds true, so the fresh suite below reading " +
                      "false proves isolation and not a setter that stores nothing")
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.object(forKey: "calyx.ipc.wakeEnabled") as? Bool, true,
                       "the write must have landed in the isolated suite")

        // A different, never-before-used suite must read the default
        // (off), not leak state from the suite above.
        let otherSuiteName = suiteName + ".other"
        IPCWakeSettings._testUseSuite(named: otherSuiteName)

        XCTAssertFalse(IPCWakeSettings.enabled,
                       "A fresh isolated suite must read the default (off), not leak state from a " +
                       "previously-used suite")

        IPCWakeSettings._testTeardownSuite(named: otherSuiteName)
    }
}
