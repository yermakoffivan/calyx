// IPCWakeSettings.swift
// Calyx
//
// UserDefaults-backed store for the IPC wake toggle. Same shared
// `SettingsStore` resolution as CockpitSettings (see
// `Calyx/Helpers/SettingsStore.swift`'s header comment for the full
// rationale): `_testStore` (in-process unit-test isolation) then
// `uiTestSuite` (separate --uitesting process isolation) then
// `.standard` in production. Always compiled, not `#if DEBUG`-gated,
// for the same reason as CockpitSettings. Defaults OFF -- a pane is
// never woken for a waiting message unless explicitly opted in.

import Foundation

struct IPCWakeSettings: Sendable {

    static let enabledKey = "calyx.ipc.wakeEnabled"

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

    /// Whether a Claude Code pane whose bound peer has messages it has
    /// not been told about yet is woken. Read in two places:
    /// `CalyxMCPServer`'s `POST /ipc-wake` route answers 204 before
    /// registering a waiter while this is `false`, and
    /// `IPCWakeCoordinator`'s default `isEnabled` reads it at the start
    /// of every check, which does nothing while it is `false`. Nothing
    /// observes a change of this value: a waiter registered before it
    /// turned `false` stays until it times out or is released.
    /// Documented default: `false` when the key has never been written.
    static var enabled: Bool {
        get {
            // Default OFF matches UserDefaults.bool(forKey:)'s native
            // absent-key behavior, so no explicit object(forKey:) == nil
            // check is needed here (same as CockpitSettings).
            store.bool(forKey: enabledKey)
        }
        set {
            store.set(newValue, forKey: enabledKey)
        }
    }
}
