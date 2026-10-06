// UsageRunLog.swift
// Calyx
//
// Turns a session's transcript events, in file order, into "runs": the
// stretches of transcript that one group of `cost-state` lines ends. Each
// closed run carries Claude Code's cumulative totals at its end, so the
// difference between consecutive runs is what one process used. Pure: the
// log depends only on the sequence of events, so re-applying a whole file
// to a fresh log reproduces it.

import Foundation

/// One closed run of a session: the stretch of transcript that one
/// `cost-state` group ends.
struct UsageRun: Sendable, Equatable {
    /// 1, 2, 3 ... in file order.
    let sequence: Int
    /// The time of the run's FIRST activity line in file order; nil when
    /// the group had no activity before it.
    let beginNs: Int64?
    /// The LATEST time among the run's activity lines; nil exactly when
    /// `beginNs` is nil.
    let endNs: Int64?
    /// Claude Code's cumulative totals per model label at the run's end.
    let totals: [String: UsageTokenTotals]
}

/// What has been read of one session's transcript so far.
struct UsageRunLog: Sendable, Equatable {
    var runs: [UsageRun] = []
    /// The first activity (file order) after the last closed run: a run is
    /// open while this is non-nil.
    var openBeginNs: Int64? = nil
    /// The latest time among the open run's activity lines.
    var openEndNs: Int64? = nil
    /// The first non-nil cwd seen.
    var cwd: String? = nil

    /// Applies the next event in file order.
    ///
    /// - Activity opens a run when none is open; the open run's end
    ///   becomes the later of itself and the event's time. The begin is
    ///   file order on purpose and is never moved to a smaller time:
    ///   timestamps are not monotonic in a transcript, and in a forked
    ///   file the smallest time belongs to the parent's copied history.
    /// - A cost state closes the open run with its totals. With no run
    ///   open it is the second `cost-state` line of one exit (Claude Code
    ///   often writes two with identical totals), so it replaces the last
    ///   closed run's totals and keeps its times; with no run at all it
    ///   becomes a run without times, still the baseline for the next run.
    mutating func apply(_ event: ClaudeTranscriptRunEvent) {
        switch event {
        case .activity(let timeNs, let eventCWD):
            if openBeginNs == nil {
                openBeginNs = timeNs
            }
            openEndNs = max(openEndNs ?? timeNs, timeNs)
            if cwd == nil {
                cwd = eventCWD
            }
        case .costState(let totals):
            if openBeginNs != nil {
                runs.append(UsageRun(sequence: runs.count + 1, beginNs: openBeginNs, endNs: openEndNs, totals: totals))
                openBeginNs = nil
                openEndNs = nil
            } else if let index = runs.indices.last {
                let last = runs[index]
                runs[index] = UsageRun(
                    sequence: last.sequence, beginNs: last.beginNs, endNs: last.endNs, totals: totals)
            } else {
                runs.append(UsageRun(sequence: 1, beginNs: nil, endNs: nil, totals: totals))
            }
        }
    }
}
