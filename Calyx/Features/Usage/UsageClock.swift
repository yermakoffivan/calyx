// UsageClock.swift
// Calyx
//
// The one conversion from a `Date` to the nanosecond timestamps usage
// records carry.

import Foundation

enum UsageClock {

    /// 2^63, exactly representable as a Double: the first value above
    /// `Int64.max`. `Double(Int64.max)` would round up to this same value,
    /// so the bounds are written as powers of two rather than derived.
    private static let upperExclusive: Double = 9_223_372_036_854_775_808.0
    /// -2^63, exactly `Int64.min`.
    private static let lowerInclusive: Double = -9_223_372_036_854_775_808.0

    /// Whole nanoseconds since the epoch: truncated toward zero, saturated to `Int64.min ... Int64.max`;
    /// a non-finite date (NaN, +infinity, -infinity) reads as `Int64.max`. Never traps.
    ///
    /// Finiteness is checked on the seconds, before scaling, so a finite
    /// date whose product overflows to an infinity still saturates by its
    /// sign. Every bound is compared before `Int64(_:)` runs, since that
    /// initializer traps outside the representable range.
    static func nanoseconds(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return .max }
        let scaled = (seconds * 1_000_000_000).rounded(.towardZero)
        if scaled >= upperExclusive { return .max }
        if scaled < lowerInclusive { return .min }
        return Int64(scaled)
    }
}
