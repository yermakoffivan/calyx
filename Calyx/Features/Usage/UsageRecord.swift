// UsageRecord.swift
// Calyx
//
// One API response's token usage, as extracted from a Claude Code
// transcript line (see ClaudeTranscriptParser): numbers and short labels
// only, never conversation text. Several transcript lines can describe
// the same response (same `key`); `winner` folds them into one record.

import Foundation

struct UsageRecord: Sendable, Equatable {
    enum Thread: String, Sendable, Equatable {
        case main, subagent, advisor
    }

    /// `message.id`, or `<message.id>#adv<i>` for an advisor iteration.
    let key: String
    let sessionID: String
    /// UTC epoch milliseconds of the transcript line.
    let timestampMs: Int64
    let model: String
    let effort: String?
    let thread: Thread
    let agentID: String?
    let agentType: String?
    let gitBranch: String?
    let cwd: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let thinkingTokens: Int64
    let cacheReadTokens: Int64
    /// Total cache-creation tokens; `cacheCreation1hTokens` is the part of
    /// this total written with the 1-hour TTL, not an addition to it.
    let cacheCreationTokens: Int64
    let cacheCreation1hTokens: Int64
    /// Whether the line carried a `stop_reason`. A non-final line's
    /// output-side numbers are a snapshot taken mid-response.
    let isFinal: Bool

    /// Picks the record to keep when two records share a key. One response
    /// is written as several lines whose usage grows, and the same id can
    /// also appear in another file, so the larger record wins by priority
    /// isFinal > outputTokens > timestampMs > agentID (nil as "") >
    /// sessionID. A tie on all five falls through to every remaining field
    /// in declaration order, which makes this a total order: re-reading
    /// transcripts in any order folds to the same record, and
    /// `winner(a, b) == winner(b, a)`.
    static func winner(_ a: UsageRecord, _ b: UsageRecord) -> UsageRecord {
        isOrderedBefore(a, b) ? b : a
    }

    /// Whether `a` is strictly smaller than `b` in the total order
    /// `winner` documents. Each step returns as soon as one field differs.
    private static func isOrderedBefore(_ a: UsageRecord, _ b: UsageRecord) -> Bool {
        // Priority fields.
        if let decided = before(a.isFinal, b.isFinal) { return decided }
        if let decided = before(a.outputTokens, b.outputTokens) { return decided }
        if let decided = before(a.timestampMs, b.timestampMs) { return decided }
        if let decided = before(a.agentID ?? "", b.agentID ?? "") { return decided }
        if let decided = before(a.sessionID, b.sessionID) { return decided }
        // Remaining fields, in declaration order.
        if let decided = before(a.key, b.key) { return decided }
        if let decided = before(a.model, b.model) { return decided }
        if let decided = before(a.effort, b.effort) { return decided }
        if let decided = before(a.thread.rawValue, b.thread.rawValue) { return decided }
        // The priority step above treats a nil agentID and "" as equal;
        // telling them apart here keeps the order total for that pair too.
        if let decided = before(a.agentID, b.agentID) { return decided }
        if let decided = before(a.agentType, b.agentType) { return decided }
        if let decided = before(a.gitBranch, b.gitBranch) { return decided }
        if let decided = before(a.cwd, b.cwd) { return decided }
        if let decided = before(a.inputTokens, b.inputTokens) { return decided }
        if let decided = before(a.thinkingTokens, b.thinkingTokens) { return decided }
        if let decided = before(a.cacheReadTokens, b.cacheReadTokens) { return decided }
        if let decided = before(a.cacheCreationTokens, b.cacheCreationTokens) { return decided }
        if let decided = before(a.cacheCreation1hTokens, b.cacheCreation1hTokens) { return decided }
        return false
    }

    /// `nil` when the two values tie, otherwise whether `a` is the smaller.
    private static func before<Value: Comparable>(_ a: Value, _ b: Value) -> Bool? {
        a == b ? nil : a < b
    }

    /// `false` is below `true`.
    private static func before(_ a: Bool, _ b: Bool) -> Bool? {
        a == b ? nil : b
    }

    /// `nil` is below any value, including "".
    private static func before(_ a: String?, _ b: String?) -> Bool? {
        switch (a, b) {
        case (nil, nil): nil
        case (nil, _?): true
        case (_?, nil): false
        case let (a?, b?): before(a, b)
        }
    }
}
