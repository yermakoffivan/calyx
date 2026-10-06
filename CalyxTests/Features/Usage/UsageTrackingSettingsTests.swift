//
//  UsageTrackingSettingsTests.swift
//  CalyxTests
//
//  Pins UsageTrackingSettings, the switch of the Claude Code usage
//  ledger: the exact key, default OFF when the key was never written
//  (nothing is read from transcripts without the user's consent), and a
//  round trip through an isolated UserDefaults suite that never reaches
//  the real .standard domain. Same shape as IPCSettingsTests.
//

import XCTest
@testable import Calyx

final class UsageTrackingSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.UsageTrackingSettingsTests"
    private var standardDefaultsTripwire: StandardDefaultsTripwire!

    override func setUp() {
        super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: UsageTrackingSettings.enabledKey)
        UsageTrackingSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        UsageTrackingSettings._testTeardownSuite(named: suiteName)
        standardDefaultsTripwire.assertUnchanged()
        super.tearDown()
    }

    func test_enabledKey_isExactLiteral() {
        XCTAssertEqual(UsageTrackingSettings.enabledKey, "calyx.usage.trackingEnabled")
    }

    func test_default_isOff() {
        XCTAssertFalse(UsageTrackingSettings.enabled,
                       "enabled must be false when the key has never been written")
    }

    func test_setAndRead_roundTrip() {
        UsageTrackingSettings.enabled = true
        XCTAssertTrue(UsageTrackingSettings.enabled)

        UsageTrackingSettings.enabled = false
        XCTAssertFalse(UsageTrackingSettings.enabled)

        // The write must land in the isolated suite under the exact key;
        // otherwise a getter ignoring every set would pass the above.
        UsageTrackingSettings.enabled = true
        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(rawSuite.object(forKey: "calyx.usage.trackingEnabled") as? Bool, true)
    }

    func test_testStoreIsolation() {
        assertStandardDefaultsUntouched(key: UsageTrackingSettings.enabledKey) { before in
            UsageTrackingSettings.enabled = !(before ?? false)
        }

        UsageTrackingSettings.enabled = true

        let otherSuiteName = suiteName + ".other"
        UsageTrackingSettings._testUseSuite(named: otherSuiteName)
        defer { UsageTrackingSettings._testTeardownSuite(named: otherSuiteName) }

        XCTAssertFalse(UsageTrackingSettings.enabled,
                       "A fresh isolated suite must read the default (off)")
    }

    func test_doesNotShareItsStoreWithIPCSettings() {
        // Each settings type owns its own store: switching this type to a
        // suite and writing must not change what IPCSettings reads.
        let ipcSuite = suiteName + ".ipc"
        IPCSettings._testUseSuite(named: ipcSuite)
        defer { IPCSettings._testTeardownSuite(named: ipcSuite) }

        UsageTrackingSettings.enabled = true

        XCTAssertFalse(IPCSettings.enabled)
        XCTAssertNil(UserDefaults(suiteName: ipcSuite)!.object(forKey: UsageTrackingSettings.enabledKey))
    }
}
