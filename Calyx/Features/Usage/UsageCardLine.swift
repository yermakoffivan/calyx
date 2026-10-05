// UsageCardLine.swift
// Calyx
//
// The one-line token summary a Mission Map card shows for its Claude
// Code session, and the same summary as a spoken label. Pure formatting
// over a session's `UsageTokenTotals`; integer arithmetic only, so the
// digits and the decimal point are ASCII whatever the user's locale.

import Foundation

enum UsageCardLine {
    /// "<out> out · <in> in", e.g. "45.2k out · 1.2M in". `in` is
    /// everything sent to the model, cached or not.
    static func text(for totals: UsageTokenTotals) -> String {
        "\(compact(totals.output)) out \u{00B7} \(compact(sentTokens(totals))) in"
    }

    /// The spoken form of `text(for:)`: "Usage: <out> output tokens, <in>
    /// input tokens", with the same compact numbers.
    static func accessibilityLabel(for totals: UsageTokenTotals) -> String {
        "Usage: \(compact(totals.output)) output tokens, \(compact(sentTokens(totals))) input tokens"
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

    /// Input, cache read and cache creation tokens, saturating at
    /// `Int64.max` (or `.min`) instead of trapping.
    private static func sentTokens(_ totals: UsageTokenTotals) -> Int64 {
        [totals.cacheRead, totals.cacheCreation].reduce(totals.input) { sum, part in
            let (result, overflow) = sum.addingReportingOverflow(part)
            return overflow ? (part > 0 ? .max : .min) : result
        }
    }
}
