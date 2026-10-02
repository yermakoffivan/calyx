// UsageLiveSummaries.swift
// Calyx
//
// The latest total usage row of each session the ledger has ingested in
// this process, for views that show a session's usage while it runs.
// Holds no logic of its own: the ledger decides what is published.

import Foundation
import Observation

@MainActor @Observable
final class UsageLiveSummaries {
    /// Keyed by session id. Each value is that session's total row:
    /// `UsageQuery(sessionID:)` with an empty `groupBy`, so `key == []`.
    private(set) var bySession: [String: UsageRow] = [:]

    /// The summaries the app's ledger publishes into. Nonisolated so the
    /// ledger's own shared instance, which is built on whichever thread
    /// uses it first, can hold it; everything it stores is still read and
    /// written on the main actor only.
    nonisolated static let shared = UsageLiveSummaries()

    /// Nonisolated because nothing is read here: a new instance is empty,
    /// so it can be created on any thread.
    nonisolated init() {}

    /// Stores the session's row; nil removes the entry. Leaves
    /// `bySession` untouched when the stored value already equals `row`
    /// (nil for an absent entry included): every reconcile publishes each
    /// session's row again, and writing an equal value would still
    /// invalidate every observer once per session.
    func set(_ row: UsageRow?, forSession sessionID: String) {
        guard bySession[sessionID] != row else { return }
        bySession[sessionID] = row
    }

    func removeAll() {
        bySession.removeAll()
    }
}
