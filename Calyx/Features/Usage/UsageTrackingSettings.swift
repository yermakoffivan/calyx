// UsageTrackingSettings.swift
// Calyx
//
// UserDefaults-backed store for the Claude Code usage tracking switch.
// Same shape as IPCSettings (see CockpitSettings' header comment for the
// full rationale): `_testStore` (in-process unit-test isolation) then
// `uiTestSuite` (separate --uitesting process isolation) then `.standard`
// in production.
//
// Default OFF is load-bearing: ON by default would point Claude Code's
// telemetry at Calyx, read its transcripts and create a database of the
// user's usage without their consent.

import Foundation

struct UsageTrackingSettings: Sendable {

    static let enabledKey = "calyx.usage.trackingEnabled"

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    /// Whether usage is tracked. Documented default: `false` when the key
    /// has never been written.
    static var enabled: Bool {
        get {
            // Default OFF matches UserDefaults.bool(forKey:)'s native
            // absent-key behavior.
            store.bool(forKey: enabledKey)
        }
        set {
            store.set(newValue, forKey: enabledKey)
        }
    }
}
