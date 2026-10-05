// UsageWindowModel.swift
// Calyx
//
// The logic behind the Usage window (`UsageWindowView`): turns the
// window's three filters into ledger queries, reads them in one call and
// keeps the newest result. Every dependency is injected, so the rules
// below are tested without a database, a clock or a time zone of the
// machine running the tests.

import Foundation
import Observation

@MainActor @Observable
final class UsageWindowModel {

    enum Period: String, CaseIterable, Sendable {
        case today, last7Days, last30Days, all
    }

    enum ProjectChoice: Hashable, Sendable {
        case all
        case root(String)
        case unattributed
    }

    /// One table row: the usage of one model at one effort level.
    struct Row: Identifiable, Equatable, Sendable {
        /// Unique within one result and the same for the same
        /// (model, effort) in every result, so the table keeps its
        /// selection and scroll position across refreshes.
        let id: String
        /// Optional because the ledger's grouping key is `[String?]`; no
        /// stored record has a nil model (`UsageRecord.model` is not
        /// optional), but the key type allows it, and the view shows `—`
        /// rather than assuming it away.
        let model: String?
        /// nil: the response had no effort.
        let effort: String?
        let usage: UsageRow
    }

    /// Shown instead of reading anything when the selected period's
    /// start cannot be computed.
    static let periodUnavailableMessage = "The selected period could not be computed."

    var period: Period = .last7Days
    var project: ProjectChoice = .all
    /// nil: every thread.
    var thread: UsageRecord.Thread? = nil

    private(set) var rows: [Row] = []
    /// nil: nothing matched.
    private(set) var totals: UsageRow? = nil
    /// What the project picker offers besides `.all`: each project root
    /// in the ledger's order, then `.unattributed` when unattributed
    /// usage exists. Never filtered by the selection, so it does not
    /// shrink while a filter is active.
    private(set) var projects: [ProjectChoice] = []
    private(set) var isTrackingEnabled = false
    private(set) var isLoading = false
    /// The most recent failure: a refresh's read, a period that cannot be
    /// computed, or a delete. A successful refresh clears it only if that
    /// refresh started after the failure; one already running when the
    /// failure happened still shows its data but leaves the message.
    private(set) var errorMessage: String? = nil

    private let isEnabled: () -> Bool
    private let reports: @Sendable ([UsageQuery], Calendar) async throws -> [[UsageRow]]
    private let deleteAll: @Sendable () async throws -> Void
    private let now: () -> Date
    private let calendar: () -> Calendar

    /// Incremented by every `refresh`; a refresh applies its outcome only
    /// while it is still the newest one.
    private var latestRefresh = 0
    /// Refreshes currently waiting on `reports`; `isLoading` is true
    /// while any is.
    private var runningRefreshes = 0
    /// `latestRefresh` when `errorMessage` was last set: only a refresh
    /// numbered above it started after that failure and may clear it.
    private var failureRecordedAtRefresh = 0

    init(
        isEnabled: @escaping () -> Bool,
        reports: @escaping @Sendable ([UsageQuery], Calendar) async throws -> [[UsageRow]],
        deleteAll: @escaping @Sendable () async throws -> Void,
        now: @escaping () -> Date,
        calendar: @escaping () -> Calendar
    ) {
        self.isEnabled = isEnabled
        self.reports = reports
        self.deleteAll = deleteAll
        self.now = now
        self.calendar = calendar
    }

    /// The ledger query for the given filters, or nil when the period's
    /// start cannot be computed (only for a `now` at the edge of what the
    /// calendar represents). A period starts at local midnight of the
    /// first of its 1, 7 or 30 calendar days, by `UsagePeriod.startMs`,
    /// the rule the MCP tool's `days` uses; All Time has no start.
    static func query(
        period: Period, project: ProjectChoice, thread: UsageRecord.Thread?,
        groupBy: [UsageQuery.Dimension], now: Date, calendar: Calendar
    ) -> UsageQuery? {
        var sinceMs: Int64? = nil
        if let lastDays = period.lastDays {
            guard let start = UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: calendar) else {
                return nil
            }
            sinceMs = start
        }
        let projectFilter: UsageQuery.ProjectFilter?
        switch project {
        case .all: projectFilter = nil
        case .root(let path): projectFilter = .root(path)
        case .unattributed: projectFilter = .unattributed
        }
        return UsageQuery(groupBy: groupBy, sinceMs: sinceMs, project: projectFilter, thread: thread)
    }

    /// Reads the table, its totals and the project list in exactly one
    /// `reports` call (one reconcile, one consistent read), with the
    /// clock and calendar read now.
    ///
    /// - `isTrackingEnabled` is updated before the first suspension, so
    ///   the tracking-off banner never shows while the read is pending.
    ///   Stored data is read whether tracking is on or off.
    /// - Latest wins: every call supersedes the ones started before it,
    ///   including a call that reads nothing; a superseded call discards
    ///   its result and its error when it finishes.
    /// - A failed read sets `errorMessage` and keeps the previous rows,
    ///   totals and projects; a later successful read that started after
    ///   the failure clears it (see `errorMessage`).
    /// - When the selected period cannot be computed, nothing is read:
    ///   `errorMessage` says so and the previous data stays.
    func refresh() async {
        latestRefresh += 1
        let generation = latestRefresh
        isTrackingEnabled = isEnabled()

        let now = now()
        let calendar = calendar()
        guard
            let rowsQuery = Self.query(
                period: period, project: project, thread: thread,
                groupBy: [.model, .effort], now: now, calendar: calendar),
            let totalsQuery = Self.query(
                period: period, project: project, thread: thread,
                groupBy: [], now: now, calendar: calendar)
        else {
            recordFailure(Self.periodUnavailableMessage)
            return
        }
        let queries = [rowsQuery, totalsQuery, UsageQuery(groupBy: [.project])]

        runningRefreshes += 1
        isLoading = true
        defer {
            runningRefreshes -= 1
            isLoading = runningRefreshes > 0
        }

        let results: [[UsageRow]]
        do {
            results = try await reports(queries, calendar)
        } catch {
            guard generation == latestRefresh else { return }
            recordFailure(error.localizedDescription)
            return
        }
        guard generation == latestRefresh else { return }

        // `reports` answers one result per query, in order.
        guard results.count == queries.count else {
            recordFailure(UnexpectedResultCount(expected: queries.count, actual: results.count).localizedDescription)
            return
        }
        rows = results[0].map(Self.row)
        totals = results[1].first
        projects = Self.projectChoices(results[2])
        if generation > failureRecordedAtRefresh {
            errorMessage = nil
        }
    }

    /// Deletes every stored record, then refreshes. A failed delete sets
    /// `errorMessage`, does not refresh and leaves the table as it was.
    /// It does not supersede refreshes already running: a failed delete
    /// changed nothing, so their data is still valid and lands, but only
    /// a refresh started after the failure clears its message.
    func deleteAllData() async {
        do {
            try await deleteAll()
        } catch {
            recordFailure(error.localizedDescription)
            return
        }
        await refresh()
    }

    /// The Final column: the share of responses whose final transcript
    /// line was written, truncated to a whole percent, so `100%` appears
    /// only when every response is final; `—` with no responses.
    /// Computed in integers (a `Double` ratio rounds 10^18 - 1 of 10^18
    /// up to 100%) over a full-width product, so no `Int64` pair
    /// overflows; out-of-range counts clamp to 0% and 100%.
    nonisolated static func finalPercentText(final: Int64, responses: Int64) -> String {
        guard responses > 0 else { return "\u{2014}" }
        let clamped = min(max(final, 0), responses)
        // clamped * 100 fits in 128 bits, and the quotient is at most
        // 100 because clamped <= responses, so neither step overflows.
        let product = clamped.multipliedFullWidth(by: 100)
        let (quotient, _) = responses.dividingFullWidth(product)
        return "\(quotient)%"
    }

    /// The project picker's label for `root`: the full path with `home`
    /// written "~" (`HomeTildePath.abbreviate`), so two different roots
    /// never share a label.
    nonisolated static func projectLabel(root: String, home: String) -> String {
        HomeTildePath.abbreviate(root, home: home)
    }

    private func recordFailure(_ message: String) {
        errorMessage = message
        failureRecordedAtRefresh = latestRefresh
    }

    private static func row(_ usage: UsageRow) -> Row {
        let model = usage.key.first.flatMap { $0 }
        let effort = usage.key.dropFirst().first.flatMap { $0 }
        return Row(id: rowID(model: model, effort: effort), model: model, effort: effort, usage: usage)
    }

    /// Length-prefixed, so nil, "" and any string content give distinct ids.
    private static func rowID(model: String?, effort: String?) -> String {
        [model, effort]
            .map { element in element.map { "\($0.count):\($0)" } ?? "-" }
            .joined(separator: ",")
    }

    private static func projectChoices(_ rows: [UsageRow]) -> [ProjectChoice] {
        let keys = rows.map { $0.key.first.flatMap { $0 } }
        let roots: [ProjectChoice] = keys.compactMap { $0 }.map { .root($0) }
        return keys.contains(nil) ? roots + [.unattributed] : roots
    }

    /// `reports` broke its one-result-per-query contract.
    private struct UnexpectedResultCount: LocalizedError {
        let expected: Int
        let actual: Int
        var errorDescription: String? {
            "The usage ledger returned \(actual) results for \(expected) queries."
        }
    }
}

extension UsageWindowModel.Period {
    /// The number of local calendar days the period covers; nil for All
    /// Time, which has no start.
    fileprivate var lastDays: Int? {
        switch self {
        case .today: 1
        case .last7Days: 7
        case .last30Days: 30
        case .all: nil
        }
    }
}
