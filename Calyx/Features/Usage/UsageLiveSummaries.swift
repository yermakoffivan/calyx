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

    /// Stores the session's row; nil removes the entry.
    func set(_ row: UsageRow?, forSession sessionID: String) {
        bySession[sessionID] = row
    }

    func removeAll() {
        bySession.removeAll()
    }
}
