//
//  LSPSettings.swift
//  Calyx
//
//  UserDefaults-backed store for the two user-facing LSP installer knobs
//  surfaced in the Settings UI:
//
//    1. `autoInstallEnabled`         — try to install missing servers at all?
//    2. `requireInstallConfirmation` — prompt before each install step?
//
//  The two booleans collapse into the `ConfirmationMode` already used by
//  `LSPInstaller.install(...)` through `confirmationMode(confirmationHandler:)`:
//
//    autoInstallEnabled  requireConfirmation   confirmationMode(handler:)
//    ------------------  -------------------   ---------------------------------
//          false               (ignored)       .prompt with a handler that
//                                              UNCONDITIONALLY returns `false`
//                                              (fail-safe only: the installer's
//                                              own guard reports "auto-install
//                                              disabled" first)
//          true                  true          .prompt with the caller-supplied
//                                              handler (UI surfaces the prompt)
//          true                  false         .silent
//
//  Both knobs default to `true` on first launch: Calyx attempts auto-install
//  by default, but asks the user before running `brew` / `npm` / etc.
//
//  The type is a `Sendable` namespace struct — all access is through static
//  members. `resetToDefaults()` strips the persisted keys so callers (tests,
//  Settings UI "Restore Defaults") observe the initial defaults again.
//

import Foundation

// MARK: - LSPSettingsResolution

/// Explicit three-state resolution of the two user-facing LSP install knobs,
/// designed to be routed on by callers (the MCP bridge, `LSPInstaller`, etc.).
///
/// Why a separate enum from `ConfirmationMode`?
///   - `ConfirmationMode` (in `LSPInstaller.swift`) only has `.silent` and
///     `.prompt(handler:)`. When `autoInstallEnabled == false` we previously
///     collapsed that state onto `.prompt(handler: { _ in false })`, which
///     causes `LSPInstaller` to report `failed(reason: "user declined: ...")`
///     even though no real user ever saw a prompt.
///   - `LSPSettingsResolution.disabled` lets the caller distinguish "the
///     master switch is off — surface a clear error to the MCP caller" from
///     "the user actually saw the prompt and declined".
///
/// Truth table:
///
///    autoInstallEnabled  requireConfirmation   resolve(handler:)
///    ------------------  -------------------   ------------------------------
///          false               (ignored)       .disabled
///          true                  true          .prompt(handler:)
///          true                  false         .silent
///
enum LSPSettingsResolution: Sendable {
    /// Master switch is off — installer must not run, caller surfaces an
    /// explicit "auto-install disabled in Settings" error.
    case disabled
    /// Run install steps without prompting.
    case silent
    /// Gate each install step on `handler`.
    case prompt(handler: @Sendable (String) async -> Bool)
}

struct LSPSettings: Sendable {

    // MARK: - UserDefaults keys

    static let autoInstallEnabledKey = "calyx.lsp.autoInstallEnabled"
    static let requireInstallConfirmationKey = "calyx.lsp.requireInstallConfirmation"

    // MARK: - Knobs

    /// Master switch: when `false`, the installer must never run a command
    /// regardless of the confirmation handler the caller supplies.
    static var autoInstallEnabled: Bool {
        get {
            // `object(forKey:)` distinguishes "never written" from "written false".
            // We treat unset as the documented default (true).
            if UserDefaults.standard.object(forKey: autoInstallEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoInstallEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoInstallEnabledKey)
        }
    }

    /// When `true`, each install step is gated on a user prompt; when
    /// `false`, the installer runs straight through (silent mode).
    /// Ignored when `autoInstallEnabled == false`.
    static var requireInstallConfirmation: Bool {
        get {
            if UserDefaults.standard.object(forKey: requireInstallConfirmationKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: requireInstallConfirmationKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: requireInstallConfirmationKey)
        }
    }

    // MARK: - Resolution

    /// Collapse the two knobs into an explicit three-state resolution.
    ///
    /// This is the lower-level primitive `confirmationMode(confirmationHandler:)`
    /// builds on; use it directly when the caller needs to route on
    /// `.disabled` itself.
    ///
    /// Mapping:
    ///   - `autoInstallEnabled == false`                              → `.disabled`
    ///   - `autoInstallEnabled == true && requireInstallConfirmation` → `.prompt(handler:)`
    ///   - `autoInstallEnabled == true && !requireInstallConfirmation`→ `.silent`
    static func resolve(
        confirmationHandler: @Sendable @escaping (String) async -> Bool
    ) -> LSPSettingsResolution {
        if !autoInstallEnabled {
            return .disabled
        }
        if requireInstallConfirmation {
            return .prompt(handler: confirmationHandler)
        }
        return .silent
    }

    // MARK: - Mapping into ConfirmationMode

    /// Maps `resolve(confirmationHandler:)` into the `ConfirmationMode`
    /// that `LSPInstaller.install(...)` takes. `.silent` and
    /// `.prompt(handler:)` map to themselves; `.disabled` becomes a prompt
    /// whose handler refuses every step.
    ///
    /// Callers still call `install(...)` when auto-install is disabled:
    /// the installer's own `autoInstallEnabled` guard is the source of
    /// truth — it returns the explicit "auto-install disabled" failure
    /// (`LSPInstaller.autoInstallDisabledReason`) without running any step
    /// and records it for `lsp_install_status`. The refusing prompt only
    /// guards the window in which the master switch flips on between this
    /// read and the hop onto the installer actor: the install then fails
    /// closed instead of running without confirmation.
    static func confirmationMode(
        confirmationHandler: @Sendable @escaping (String) async -> Bool
    ) -> ConfirmationMode {
        switch resolve(confirmationHandler: confirmationHandler) {
        case .disabled:
            return .prompt(handler: { @Sendable _ in false })
        case .silent:
            return .silent
        case .prompt(let handler):
            return .prompt(handler: handler)
        }
    }

    // MARK: - Reset

    /// Strip both persisted keys so subsequent reads return the documented
    /// defaults. Used by tests for isolation, and intended for a future
    /// Settings UI "Restore Defaults" action.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: autoInstallEnabledKey)
        UserDefaults.standard.removeObject(forKey: requireInstallConfirmationKey)
    }
}
