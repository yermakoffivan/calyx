// UsageReconciliation.swift
// Calyx
//
// Compares what the telemetry metric delivered for one session with Claude
// Code's own cumulative totals (the closed runs of its transcript) and
// computes the shortfall per run and model: the "unreported" amounts. A
// process that leaves while Calyx cannot be reached never delivers its last
// increments; the transcript still records them. The session's total
// unreported amount never exceeds what the received points leave
// unexplained, because an amount that is too large would count the same
// tokens twice; an earlier run's amount that a bound makes too large (rule
// 5's upper bound excludes the minute the next run begins) is capped by the
// suffix minimum (rule 7). Pure: the outcome depends only on the input.

import Foundation

// MARK: - Values

/// Recorded tokens of one session received in one minute for one model (all
/// efforts, threads and agents together).
struct UsageHeardBucket: Sendable, Equatable {
    /// Receive time, minutes since the epoch.
    let minute: Int64
    let model: String
    let totals: UsageTokenTotals
}

struct UsageReconcileInput: Sendable, Equatable {
    /// The session's closed runs, sequence 1...n.
    let runs: [UsageRun]
    let trackedFromNs: Int64
    /// The session's stored (active) process starts.
    let processStarts: [UsageProcessStart]
    /// The smallest `first_heard_ns` among the session's stored series; nil
    /// when none.
    let firstHeardNs: Int64?
    /// Every recorded point of the session.
    let heard: [UsageHeardBucket]
}

struct UsageUnreportedRow: Sendable, Equatable {
    /// The run the amount is attributed to.
    let sequence: Int
    /// That run's `endNs`.
    let timeNs: Int64
    let model: String
    /// At least one number is positive.
    let totals: UsageTokenTotals
}

struct UsageReconcileOutcome: Sendable, Equatable {
    /// The first run that was reconciled; nil when none could be.
    let firstSequence: Int?
    /// Unreported amounts of the runs from `firstSequence` on, ordered by
    /// (sequence, model).
    let rows: [UsageUnreportedRow]
    /// Recorded tokens beyond Claude Code's totals over the reconciled runs,
    /// per model (a diagnostic; positive numbers only).
    let surplus: [String: UsageTokenTotals]

    static let empty = UsageReconcileOutcome(firstSequence: nil, rows: [], surplus: [:])
}

// MARK: - Computation

enum UsageReconciliation {
    private static let kinds: [UsageTokenKind] = [.input, .output, .cacheRead, .cacheCreation]
    private static let nanosecondsPerMinute: Int64 = 60_000_000_000

    static func reconcile(_ input: UsageReconcileInput) -> UsageReconcileOutcome {
        // Rule 1: a session Calyx never heard since tracking began is not counted.
        guard !input.processStarts.isEmpty || input.firstHeardNs != nil else { return .empty }

        let runs = input.runs
        // Rule 2: the longest suffix of runs that all began at or after
        // tracking started (a run without a begin breaks the suffix).
        var first = runs.count
        while first > 0, let begin = runs[first - 1].beginNs, begin >= input.trackedFromNs {
            first -= 1
        }
        guard first < runs.count else { return .empty }

        // Rule 3: run 1 stays only with proof that it started from zero and
        // that Calyx heard the session while it ran.
        if first == 0 && !firstRunQualifies(runs[0], input: input) {
            first = 1
            guard first < runs.count else { return .empty }
        }

        // Rule 5's lower bound: the minute of the last line of the run before
        // the first reconciled one, inclusive.
        let lower: Int64? = first > 0 ? runs[first - 1].endNs.map(minute(ofNs:)) : nil

        var cumulative: [String: UsageTokenTotals] = [:]   // E_j
        var shortfalls: [[String: UsageTokenTotals]] = []  // U_j, per reconciled run
        var heardLast: [String: UsageTokenTotals] = [:]    // H_n
        for index in first..<runs.count {
            let previous = index > 0 ? runs[index - 1].totals : [:]
            for (model, totals) in usage(of: runs[index].totals, after: previous) {
                cumulative[model] = sum(cumulative[model] ?? UsageTokenTotals(), totals)
            }
            // Rule 5's upper bound excludes the minute in which the next run
            // begins; the last run has none. The suffix guarantees every run
            // after the first reconciled one has a begin.
            let upper: Int64? = index + 1 < runs.count ? runs[index + 1].beginNs.map(minute(ofNs:)) : nil
            let heard = heardTotals(input.heard, lower: lower, upper: upper)
            // Rule 6.
            var shortfall: [String: UsageTokenTotals] = [:]
            for (model, expected) in cumulative {
                shortfall[model] = positiveDifference(expected, heard[model] ?? UsageTokenTotals())
            }
            shortfalls.append(shortfall)
            if index + 1 == runs.count {
                heardLast = heard
            }
        }

        // Rule 7: suffix minima, so the rows add up to U_n and no row is
        // larger than what a later run confirms.
        var minima = shortfalls
        if minima.count > 1 {
            for position in stride(from: minima.count - 2, through: 0, by: -1) {
                let later = minima[position + 1]
                var current: [String: UsageTokenTotals] = [:]
                for (model, totals) in minima[position] {
                    current[model] = minimum(totals, later[model] ?? UsageTokenTotals())
                }
                minima[position] = current
            }
        }
        var rows: [UsageUnreportedRow] = []
        var previousMinimum: [String: UsageTokenTotals] = [:]
        for (position, minimumOfRun) in minima.enumerated() {
            let run = runs[first + position]
            for model in minimumOfRun.keys.sorted() {
                let amount = positiveDifference(
                    minimumOfRun[model] ?? UsageTokenTotals(), previousMinimum[model] ?? UsageTokenTotals())
                guard isPositive(amount), let endNs = run.endNs else { continue }
                rows.append(UsageUnreportedRow(sequence: run.sequence, timeNs: endNs, model: model, totals: amount))
            }
            previousMinimum = minimumOfRun
        }

        // Rule 8.
        var surplus: [String: UsageTokenTotals] = [:]
        for (model, heard) in heardLast {
            let excess = positiveDifference(heard, cumulative[model] ?? UsageTokenTotals())
            if isPositive(excess) {
                surplus[model] = excess
            }
        }

        return UsageReconcileOutcome(firstSequence: runs[first].sequence, rows: rows, surplus: surplus)
    }

    // MARK: - Rules

    /// Rule 3. No process that began with totals from elsewhere (any start
    /// type but `fresh`, nil included) started before run 1 ended, and Calyx
    /// heard the session by run 1's end. Both comparisons are inclusive of
    /// `endNs` and allow no delivery delay.
    private static func firstRunQualifies(_ run: UsageRun, input: UsageReconcileInput) -> Bool {
        guard let endNs = run.endNs else { return false }
        let startsByEnd = input.processStarts.filter { $0.startNs <= endNs }
        guard startsByEnd.allSatisfy({ $0.startType == "fresh" }) else { return false }
        if !startsByEnd.isEmpty { return true }
        guard let firstHeardNs = input.firstHeardNs else { return false }
        return firstHeardNs <= endNs
    }

    /// Rule 4: the usage of one run per model. When any model's kind is
    /// smaller than in the previous run (a missing model counts as zeros),
    /// the totals did not continue and the run's own totals are its usage.
    private static func usage(
        of totals: [String: UsageTokenTotals], after previous: [String: UsageTokenTotals]
    ) -> [String: UsageTokenTotals] {
        let models = Set(totals.keys).union(previous.keys)
        let continued = models.allSatisfy { model in
            let now = totals[model] ?? UsageTokenTotals()
            let before = previous[model] ?? UsageTokenTotals()
            return kinds.allSatisfy { now[$0] >= before[$0] }
        }
        guard continued else { return totals }
        var usage: [String: UsageTokenTotals] = [:]
        for (model, now) in totals {
            usage[model] = positiveDifference(now, previous[model] ?? UsageTokenTotals())
        }
        return usage
    }

    /// Rule 5: the buckets with `minute >= lower` and `minute < upper`, per
    /// model; a nil bound is no bound.
    private static func heardTotals(
        _ buckets: [UsageHeardBucket], lower: Int64?, upper: Int64?
    ) -> [String: UsageTokenTotals] {
        var heard: [String: UsageTokenTotals] = [:]
        for bucket in buckets {
            if let lower, bucket.minute < lower { continue }
            if let upper, bucket.minute >= upper { continue }
            heard[bucket.model] = sum(heard[bucket.model] ?? UsageTokenTotals(), bucket.totals)
        }
        return heard
    }

    // MARK: - Arithmetic (never traps)

    /// Floor division, so a time before the epoch falls in the minute that
    /// contains it. Cannot overflow: the divisor is a positive constant above 1.
    private static func minute(ofNs timeNs: Int64) -> Int64 {
        let quotient = timeNs / nanosecondsPerMinute
        return timeNs % nanosecondsPerMinute < 0 ? quotient - 1 : quotient
    }

    /// Per kind, clamped to Int64's range instead of overflowing.
    private static func sum(_ lhs: UsageTokenTotals, _ rhs: UsageTokenTotals) -> UsageTokenTotals {
        var result = UsageTokenTotals()
        for kind in kinds {
            let (value, overflow) = lhs[kind].addingReportingOverflow(rhs[kind])
            result[kind] = overflow ? (rhs[kind] > 0 ? Int64.max : Int64.min) : value
        }
        return result
    }

    /// Per kind, `max(0, lhs - rhs)`; the subtraction only runs when
    /// `lhs > rhs` and saturates at Int64.max (a negative stored value can
    /// make the difference exceed Int64's range).
    private static func positiveDifference(_ lhs: UsageTokenTotals, _ rhs: UsageTokenTotals) -> UsageTokenTotals {
        var result = UsageTokenTotals()
        for kind in kinds where lhs[kind] > rhs[kind] {
            let (value, overflow) = lhs[kind].subtractingReportingOverflow(rhs[kind])
            result[kind] = overflow ? Int64.max : value
        }
        return result
    }

    private static func minimum(_ lhs: UsageTokenTotals, _ rhs: UsageTokenTotals) -> UsageTokenTotals {
        var result = UsageTokenTotals()
        for kind in kinds {
            result[kind] = min(lhs[kind], rhs[kind])
        }
        return result
    }

    private static func isPositive(_ totals: UsageTokenTotals) -> Bool {
        kinds.contains { totals[$0] > 0 }
    }
}
