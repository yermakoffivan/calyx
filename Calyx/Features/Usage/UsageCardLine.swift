// UsageCardLine.swift
// Calyx
//
// The one-line token summary a Mission Map card shows for its Claude
// Code session, and the same summary as a spoken label. Pure formatting
// over a session's total `UsageRow`; integer arithmetic only, so the
// digits and the decimal point are ASCII whatever the user's locale.

import Foundation

enum UsageCardLine {
    /// "<out> out · <in> in", e.g. "≥45.2k out · 1.2M in". `out` is the
    /// output summed over final responses; it carries "≥" while some
    /// responses have no final line yet, because their real output is not
    /// counted, so the true total is at least the number shown. `in` is
    /// everything sent to the model, cached or not.
    static func text(for row: UsageRow) -> String {
        let prefix = isLowerBound(row) ? "\u{2265}" : ""
        return "\(prefix)\(compact(row.outputTokensFinal)) out \u{00B7} \(compact(sentTokens(row))) in"
    }

    /// The spoken form of `text(for:)`: "Usage: [at least ]<out> output
    /// tokens, <in> input tokens", with "at least " exactly when `text`
    /// shows "≥", and the same compact numbers.
    static func accessibilityLabel(for row: UsageRow) -> String {
        let prefix = isLowerBound(row) ? "at least " : ""
        return "Usage: \(prefix)\(compact(row.outputTokensFinal)) output tokens, "
            + "\(compact(sentTokens(row))) input tokens"
    }

    /// A short token count: the number itself below 1,000, then one
    /// decimal below 100 of a unit ("1.0k" ... "99.9k") and whole units
    /// up to 999 ("100k" ... "999k"), with k, M and B; whole billions have
    /// no upper limit. Digits are truncated, never rounded up, so a card
    /// never overstates usage. A negative value reads "0".
    static func compact(_ value: Int64) -> String {
        switch value {
        case ..<1_000: return String(max(value, 0))
        case ..<1_000_000: return scaled(value, unit: 1_000, suffix: "k")
        case ..<1_000_000_000: return scaled(value, unit: 1_000_000, suffix: "M")
        default: return scaled(value, unit: 1_000_000_000, suffix: "B")
        }
    }

    /// `value` in `unit`s: one truncated decimal below 100 units, whole
    /// units from 100 up.
    private static func scaled(_ value: Int64, unit: Int64, suffix: String) -> String {
        let whole = value / unit
        guard whole < 100 else { return "\(whole)\(suffix)" }
        let tenth = value % unit / (unit / 10)
        return "\(whole).\(tenth)\(suffix)"
    }

    /// Fewer final responses than responses: the output sum is short of
    /// the real output.
    private static func isLowerBound(_ row: UsageRow) -> Bool {
        row.finalResponses < row.responses
    }

    /// Input, cache read and cache creation tokens (the 1-hour cache
    /// creation count is already part of `cacheCreationTokens`),
    /// saturating at `Int64.max` (or `.min`) instead of trapping.
    private static func sentTokens(_ row: UsageRow) -> Int64 {
        [row.cacheReadTokens, row.cacheCreationTokens].reduce(row.inputTokens) { sum, part in
            let (result, overflow) = sum.addingReportingOverflow(part)
            return overflow ? (part > 0 ? .max : .min) : result
        }
    }
}
