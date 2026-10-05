// UsageLiveSummaries.swift
// Calyx
//
// The latest totals of each session the ledger has published in this
// process, for views that show a session's usage while it runs.
// Holds no logic of its own: the ledger decides what is published.

import Foundation
import Observation

@MainActor @Observable
final class UsageLiveSummaries {
    /// Keyed by session id. Each value is that session's totals: what
    /// Calyx received plus what it knows was not received.
    private(set) var bySession: [String: UsageTokenTotals] = [:]

    /// The summaries the app's ledger publishes into. Nonisolated so the
    /// ledger's own shared instance, which is built on whichever thread
    /// uses it first, can hold it; everything it stores is still read and
    /// written on the main actor only.
    nonisolated static let shared = UsageLiveSummaries()

    /// Nonisolated because nothing is read here: a new instance is empty,
    /// so it can be created on any thread.
    nonisolated init() {}

    /// Stores the session's totals; nil removes the entry. Leaves
    /// `bySession` untouched when the stored value already equals
    /// `totals` (nil for an absent entry included): writing an equal value
    /// would still invalidate every observer.
    func set(_ totals: UsageTokenTotals?, forSession sessionID: String) {
        guard bySession[sessionID] != totals else { return }
        bySession[sessionID] = totals
    }

    func removeAll() {
        bySession.removeAll()
    }
}
