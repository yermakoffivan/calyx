// UsageWindowModel.swift
// Calyx
//
// The logic behind the Usage window (`UsageWindowView`): turns the
// window's three filters into ledger token queries (`tokenReports`),
// reads them in one call and keeps the newest result, plus the reception
// status line. Every dependency is injected, so the rules
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

    /// One table row: Claude Code's token counts of one model at one
    /// effort level, or the tokens of one model that Calyx did not
    /// receive (`isUnreported`, effort unknown).
    struct Row: Identifiable, Equatable, Sendable {
        /// Unique within one result and the same for the same
        /// (model, effort, unreported) in every result, so the table keeps
        /// its selection and scroll position across refreshes.
        let id: String
        /// Optional because the ledger's grouping key is `[String?]`; no
        /// stored row has a nil model (`usage_points.model` and
        /// `usage_unreported.model` are NOT NULL), but the key type allows it, and the view shows `—`
        /// rather than assuming it away.
        let model: String?
        /// nil: no effort was recorded (always nil for an unreported row).
        let effort: String?
        /// true: tokens Claude Code counted that Calyx did not receive.
        let isUnreported: Bool
        let tokens: UsageTokenTotals
    }

    /// Shown instead of reading anything when the selected period's
    /// start cannot be computed.
    static let periodUnavailableMessage = "The selected period could not be computed."

    var period: Period = .last7Days
    var project: ProjectChoice = .all
    /// nil: every thread; otherwise a thread label ("main", "subagent",
    /// "auxiliary").
    var thread: String? = nil

    private(set) var rows: [Row] = []
    /// The field-by-field saturating sum of the totals query's rows
    /// (recorded + unreported); nil: the totals query returned no row.
    private(set) var totals: UsageTokenTotals? = nil
    /// What the project picker offers besides `.all`: each project root
    /// in the ledger's order, then `.unattributed` when unattributed
    /// usage exists. Never filtered by the selection, so it does not
    /// shrink while a filter is active.
    private(set) var projects: [ProjectChoice] = []
    private(set) var isTrackingEnabled = false
    private(set) var isLoading = false
    /// The reception status line; empty: none is shown.
    private(set) var statusText = ""
    /// The most recent failure: a refresh's read, a period that cannot be
    /// computed, or a delete. A successful refresh clears it only if that
    /// refresh started after the failure; one already running when the
    /// failure happened still shows its data but leaves the message.
    private(set) var errorMessage: String? = nil

    private let isEnabled: () -> Bool
    private let reports: @Sendable ([UsageTokenQuery], Calendar) async throws -> [[UsageTokenRow]]
    private let deleteAll: @Sendable () async throws -> Void
    private let readStatusText: () -> String
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
        reports: @escaping @Sendable ([UsageTokenQuery], Calendar) async throws -> [[UsageTokenRow]],
        deleteAll: @escaping @Sendable () async throws -> Void,
        statusText: @escaping () -> String,
        now: @escaping () -> Date,
        calendar: @escaping () -> Calendar
    ) {
        self.isEnabled = isEnabled
        self.reports = reports
        self.deleteAll = deleteAll
        self.readStatusText = statusText
        self.now = now
        self.calendar = calendar
    }

    /// The ledger query for the given filters, or nil when the period's
    /// start cannot be computed (only for a `now` at the edge of what the
    /// calendar represents). A period starts at local midnight of the
    /// first of its 1, 7 or 30 calendar days, by `UsagePeriod.startMs`,
    /// the rule the MCP tool's `days` uses; All Time has no start.
    static func query(
        period: Period, project: ProjectChoice, thread: String?,
        groupBy: [UsageTokenQuery.Dimension], now: Date, calendar: Calendar
    ) -> UsageTokenQuery? {
        var sinceMs: Int64? = nil
        if let lastDays = period.lastDays {
            guard let start = UsagePeriod.startMs(lastDays: lastDays, now: now, calendar: calendar) else {
                return nil
            }
            sinceMs = start
        }
        let projectFilter: UsageTokenQuery.ProjectFilter?
        switch project {
        case .all: projectFilter = nil
        case .root(let path): projectFilter = .root(path)
        case .unattributed: projectFilter = .unattributed
        }
        return UsageTokenQuery(groupBy: groupBy, sinceMs: sinceMs, project: projectFilter, thread: thread)
    }

    /// Reads the table, its totals and the project list in exactly one
    /// `reports` call (one reconcile, one consistent read), with the
    /// clock and calendar read now.
    ///
    /// - `isTrackingEnabled` and `statusText` are updated before the first
    ///   suspension (also when the read fails or nothing is read), so the
    ///   tracking-off banner never shows while the read is pending.
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
        statusText = readStatusText()

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
        let queries = [rowsQuery, totalsQuery, UsageTokenQuery(groupBy: [.project])]

        runningRefreshes += 1
        isLoading = true
        defer {
            runningRefreshes -= 1
            isLoading = runningRefreshes > 0
        }

        let results: [[UsageTokenRow]]
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
        totals = Self.saturatingSum(results[1])
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

    /// Reads the reception status line again, and nothing else.
    func refreshStatus() {
        statusText = readStatusText()
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

    private static func row(_ source: UsageTokenRow) -> Row {
        let model = source.key.first.flatMap { $0 }
        let effort = source.key.dropFirst().first.flatMap { $0 }
        return Row(
            id: rowID(model: model, effort: effort, isUnreported: source.isUnreported),
            model: model, effort: effort, isUnreported: source.isUnreported, tokens: tokens(of: source))
    }

    private static func tokens(of row: UsageTokenRow) -> UsageTokenTotals {
        UsageTokenTotals(
            input: row.inputTokens, output: row.outputTokens,
            cacheRead: row.cacheReadTokens, cacheCreation: row.cacheCreationTokens)
    }

    /// Length-prefixed, so nil, "" and any string content give distinct
    /// ids; the unreported flag is a final element of its own.
    private static func rowID(model: String?, effort: String?, isUnreported: Bool) -> String {
        let elements = [model, effort]
            .map { element in element.map { "\($0.count):\($0)" } ?? "-" }
        return (elements + [isUnreported ? "u" : "r"]).joined(separator: ",")
    }

    /// Field by field, each saturating at `Int64.max` (and `Int64.min`);
    /// nil for no rows.
    private static func saturatingSum(_ rows: [UsageTokenRow]) -> UsageTokenTotals? {
        guard !rows.isEmpty else { return nil }
        return rows.map(tokens(of:)).reduce(into: UsageTokenTotals()) { sum, next in
            for kind in UsageTokenKind.allCases {
                sum[kind] = saturatingAdd(sum[kind], next[kind])
            }
        }
    }

    private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? Int64.max : Int64.min
    }

    /// Each root once, in the ledger's order (a root may come from a
    /// recorded and an unreported row), then `.unattributed`.
    private static func projectChoices(_ rows: [UsageTokenRow]) -> [ProjectChoice] {
        let keys = rows.map { $0.key.first.flatMap { $0 } }
        var seen = Set<String>()
        let roots: [ProjectChoice] = keys.compactMap { $0 }.filter { seen.insert($0).inserted }.map { .root($0) }
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
