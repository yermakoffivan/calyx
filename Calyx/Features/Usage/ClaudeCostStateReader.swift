// ClaudeCostStateReader.swift
// Calyx
//
// What ONE line of a session's main transcript means for its run log.
// Claude Code appends a `cost-state` line holding the session's cumulative
// token totals per model whenever a process leaves the session (exit,
// /clear, /branch, /resume elsewhere); every other line of the session's
// own that carries a timestamp is activity. Pure: no I/O, nothing throws,
// and nothing of the line is logged.

import Foundation

// MARK: - Totals

/// Token totals of one model, per kind.
struct UsageTokenTotals: Sendable, Equatable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cacheRead: Int64 = 0
    var cacheCreation: Int64 = 0

    subscript(kind: UsageTokenKind) -> Int64 {
        get {
            switch kind {
            case .input: return input
            case .output: return output
            case .cacheRead: return cacheRead
            case .cacheCreation: return cacheCreation
            }
        }
        set {
            switch kind {
            case .input: input = newValue
            case .output: output = newValue
            case .cacheRead: cacheRead = newValue
            case .cacheCreation: cacheCreation = newValue
            }
        }
    }
}

// MARK: - Event

enum ClaudeTranscriptRunEvent: Sendable, Equatable {
    /// A line of the session's own with a usable `timestamp`. `cwd` is the
    /// line's `cwd` when it is a valid cwd label and an absolute path
    /// (starts with `/`).
    case activity(timeNs: Int64, cwd: String?)
    /// A `cost-state` line: Claude Code's cumulative totals per model label.
    case costState(totals: [String: UsageTokenTotals])
}

// MARK: - Reader

enum ClaudeCostStateReader {
    /// The event `line` stands for, or nil. Rules, in this order:
    ///
    /// 1. A line that is not a JSON object is nil.
    /// 2. A `cost-state` line is that session's totals, unless it names
    ///    another session: a PRESENT `sessionId` that is not exactly
    ///    `sessionID` (a non-string included) makes it nil, a missing one
    ///    is accepted. `modelUsage` must be an object; each entry whose
    ///    value is an object adds its four token fields under
    ///    `UsageLabel.model(key)`, so two keys with the same label (two
    ///    invalid names, both `unknown`) are summed, saturating.
    /// 3. A line with a `forkedFrom` key (any value) is nil: history that
    ///    `/branch` copied from another session, not this session's
    ///    activity. Checked after rule 2, so a `cost-state` line is never
    ///    lost to it.
    /// 4. A line whose `timestamp` `TranscriptTimestamp` accepts is
    ///    activity at that time in nanoseconds (nil when the product does
    ///    not fit Int64), with its `cwd` when `TranscriptLabel.isCWD`
    ///    accepts it verbatim and it is an absolute path (starts with
    ///    `/`).
    /// 5. Everything else is nil.
    ///
    /// Every line is parsed as JSON, with no byte-level shortcut: a
    /// shortcut would have to re-implement JSON's rules for nested keys (a
    /// nested `"type":"cost-state"` is not the line's type).
    static func event(fromLine line: Data, sessionID: String) -> ClaudeTranscriptRunEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }

        if object["type"] as? String == costStateType {
            return costState(in: object, sessionID: sessionID)
        }
        guard object["forkedFrom"] == nil,
              let text = object["timestamp"] as? String,
              let milliseconds = TranscriptTimestamp.epochMilliseconds(fromISO8601: text) else {
            return nil
        }
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(by: nanosecondsPerMillisecond)
        guard !overflow else { return nil }
        // Only an absolute path: a relative one would later be checked with
        // `stat` and git relative to Calyx's own working directory.
        let cwd = (object["cwd"] as? String).flatMap { TranscriptLabel.isCWD($0) && $0.hasPrefix("/") ? $0 : nil }
        return .activity(timeNs: nanoseconds, cwd: cwd)
    }

    // MARK: - Cost state

    private static let costStateType = "cost-state"
    private static let nanosecondsPerMillisecond: Int64 = 1_000_000

    /// The JSON field of each token kind in a `modelUsage` entry.
    private static let fields: [(kind: UsageTokenKind, name: String)] = [
        (.input, "inputTokens"),
        (.output, "outputTokens"),
        (.cacheRead, "cacheReadInputTokens"),
        (.cacheCreation, "cacheCreationInputTokens"),
    ]

    private static func costState(in object: [String: Any], sessionID: String) -> ClaudeTranscriptRunEvent? {
        if let value = object["sessionId"] {
            guard let lineSessionID = value as? String,
                  lineSessionID.unicodeScalars.elementsEqual(sessionID.unicodeScalars) else { return nil }
        }
        guard let modelUsage = object["modelUsage"] as? [String: Any] else { return nil }
        var totals: [String: UsageTokenTotals] = [:]
        for (key, value) in modelUsage {
            guard let entry = value as? [String: Any] else { continue }
            let label = UsageLabel.model(key)
            var sum = totals[label] ?? UsageTokenTotals()
            for field in fields {
                sum[field.kind] = saturatingSum(sum[field.kind], tokenCount(entry[field.name]))
            }
            totals[label] = sum
        }
        return .costState(totals: totals)
    }

    // MARK: - Numbers

    /// A token count is a JSON number that is whole, non-negative and at
    /// most Int64.max (12 and 12.0 count); anything else (a fraction, a
    /// negative or larger number, a boolean, a string, null, a missing
    /// field) counts as 0, so one odd field does not lose the others.
    ///
    /// JSONSerialization may hand a number back as an integer, a double or
    /// an NSDecimalNumber depending on how it is written and how large it
    /// is, so each representation is checked exactly: `Int64(exactly:)` is
    /// not used, because it compares through Double, where Int64.max and
    /// 2^63 are the same value.
    private static func tokenCount(_ value: Any?) -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        if let decimal = number as? NSDecimalNumber {
            return count(fromDecimal: decimal.decimalValue)
        }
        if CFNumberIsFloatType(number as CFNumber) {
            return count(fromDouble: number.doubleValue)
        }
        var integer: Int64 = 0
        // false when the value does not fit Int64 exactly.
        guard CFNumberGetValue(number as CFNumber, .sInt64Type, &integer), integer >= 0 else { return 0 }
        return integer
    }

    /// 2^63, the first Double above Int64.max (`Double(Int64.max)` rounds
    /// up to it), so every Double below it converts without trapping.
    private static let int64Bound = 9_223_372_036_854_775_808.0

    private static func count(fromDouble value: Double) -> Int64 {
        guard value.isFinite, value >= 0, value < int64Bound, value.rounded(.towardZero) == value else { return 0 }
        return Int64(value)
    }

    private static func count(fromDecimal value: Decimal) -> Int64 {
        guard !value.isNaN, value >= 0, value <= Decimal(Int64.max) else { return 0 }
        var source = value
        var whole = Decimal()
        NSDecimalRound(&whole, &source, 0, .down)
        guard whole == value else { return 0 }
        // A whole Decimal in range prints as plain digits.
        return Int64(NSDecimalNumber(decimal: whole).stringValue) ?? 0
    }

    /// `lhs + rhs` for non-negative counts, clamped at Int64.max.
    private static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
