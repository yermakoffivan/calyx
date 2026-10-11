// WorktreeTaskArgumentMemory.swift
// Calyx
//
// The last "Arguments" text used per agent kind in the New Worktree Task
// sheet, kept in UserDefaults. Text containing a recognised secret is
// never kept.

import Foundation

struct WorktreeTaskArgumentMemory {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered text for `kind`; "" when none was remembered.
    func arguments(for kind: WorktreeTaskAgentKind) -> String {
        defaults.string(forKey: Self.key(for: kind)) ?? ""
    }

    /// Stores `text` for `kind`, unless it contains a secret that
    /// `SecretRedactor` (the Command Log's redaction) recognises: then
    /// nothing is stored and any earlier text for `kind` is removed, so a
    /// token never lands in UserDefaults.
    func remember(_ text: String, for kind: WorktreeTaskAgentKind) {
        guard SecretRedactor.redact(text) == text else {
            defaults.removeObject(forKey: Self.key(for: kind))
            return
        }
        defaults.set(text, forKey: Self.key(for: kind))
    }

    private static func key(for kind: WorktreeTaskAgentKind) -> String {
        "calyx.worktreeTask.arguments." + kind.rawValue
    }
}
