//
//  UsageWindowModelTests.swift
//  CalyxTests
//
//  Pins UsageWindowModel, the logic behind the Usage window (a model x
//  effort table over the usage ledger):
//
//  - `query`: the period's lower bound is `UsagePeriod.startMs` for 1 / 7
//    / 30 local days (the rule the MCP tool's `days` uses), nil for All
//    Time; the bound is computed by calendar days in the injected zone,
//    so it is exact east of UTC and across a DST change. A `now` the
//    calendar cannot step back from yields no query at all.
//  - `refresh`: exactly one `reports` call holding three queries in a
//    fixed order (rows, totals, project list), the project list with no
//    filter so the picker never shrinks while a filter is active; the
//    calendar passed is the injected one.
//  - Results: rows keep the ledger's order and split the key into model
//    and effort; totals are the single total row or nil; the project
//    picker lists roots in order, then Unattributed; a selected project
//    that disappeared stays selected.
//  - Concurrency: the tracking flag is read before the first suspension;
//    the latest refresh wins over an older one that ends later, whether
//    the older one succeeds or throws; `isLoading` spans every running
//    refresh.
//  - Errors keep the previous table; a failed delete does not refresh.
//
//  Every expected bound is a literal epoch-millisecond value computed
//  outside the app (the local and UTC instants are written next to it).
//  Stubs are gated by continuations, never by sleeping: a test releases
//  each held `reports` call explicitly.
//

import Foundation
import os
import XCTest
@testable import Calyx

// MARK: - Stubs

/// A `reports` stand-in that records every call and either answers at
/// once (`respond`) or, for the first `hold(_:)` calls, holds the call
/// until the test releases it. Calls beyond the held ones answer at
/// once, so an implementation that makes extra calls fails an assertion
/// instead of hanging the test.
private final class ReportsStub: Sendable {
    typealias Answer = Result<[[UsageRow]], any Error>

    private struct State {
        var calls: [(queries: [UsageQuery], calendar: Calendar)] = []
        var events: [String] = []
        var heldCallCount = 0
        var respond: @Sendable ([UsageQuery]) -> Answer = { queries in .success(queries.map { _ in [] }) }
        var held: [Int: CheckedContinuation<[[UsageRow]], any Error>] = [:]
        var waiters: [(index: Int, expectation: XCTestExpectation)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [(queries: [UsageQuery], calendar: Calendar)] { state.withLock { $0.calls } }
    var callCount: Int { state.withLock { $0.calls.count } }
    var events: [String] { state.withLock { $0.events } }

    /// Calls with an index below `count` are held until `release(_:with:)`.
    func hold(_ count: Int) { state.withLock { $0.heldCallCount = count } }

    /// Every later call answers at once with `respond(queries)`.
    func answer(_ respond: @escaping @Sendable ([UsageQuery]) -> Answer) {
        state.withLock {
            $0.respond = respond
        }
    }

    func noteDelete() { state.withLock { $0.events.append("deleteAll") } }

    func call(_ queries: [UsageQuery], _ calendar: Calendar) async throws -> [[UsageRow]] {
        let (index, holding, respond) = state.withLock { state in
            state.calls.append((queries, calendar))
            state.events.append("reports")
            let index = state.calls.count - 1
            return (index, index < state.heldCallCount, state.respond)
        }
        if holding {
            return try await withCheckedThrowingContinuation { continuation in
                let ready = state.withLock { state in
                    state.held[index] = continuation
                    return takeWaiters(for: index, in: &state)
                }
                ready.forEach { $0.fulfill() }
            }
        }
        let ready = state.withLock { takeWaiters(for: index, in: &$0) }
        ready.forEach { $0.fulfill() }
        return try respond(queries).get()
    }

    /// An expectation fulfilled once call `index` has arrived (and, when
    /// held, is waiting for its release).
    func expectCall(_ index: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "reports call \(index)")
        let arrived = state.withLock { state in
            let present = index < state.heldCallCount ? state.held[index] != nil : state.calls.count > index
            if !present { state.waiters.append((index, expectation)) }
            return present
        }
        if arrived { expectation.fulfill() }
        return expectation
    }

    func release(_ index: Int, with answer: Answer) {
        let continuation = state.withLock { $0.held.removeValue(forKey: index) }
        guard let continuation else {
            XCTFail("call \(index) is not held")
            return
        }
        continuation.resume(with: answer)
    }

    private func takeWaiters(for index: Int, in state: inout State) -> [XCTestExpectation] {
        let ready = state.waiters.filter { $0.index == index }.map(\.expectation)
        state.waiters.removeAll { $0.index == index }
        return ready
    }
}

/// Gates `deleteAll`: while armed, the next delete waits until the test
/// releases it; any other delete passes straight through.
private final class DeleteGate: Sendable {
    private struct State {
        var armed = false
        var held: CheckedContinuation<Void, any Error>?
        var arrival: XCTestExpectation?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Arms the gate and returns an expectation fulfilled once the next
    /// delete is waiting.
    func holdNext() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "deleteAll arrived")
        state.withLock {
            $0.armed = true
            $0.arrival = expectation
        }
        return expectation
    }

    func pass() async throws {
        let armed = state.withLock { state in
            let armed = state.armed
            state.armed = false
            return armed
        }
        guard armed else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let arrival = state.withLock { state in
                state.held = continuation
                let arrival = state.arrival
                state.arrival = nil
                return arrival
            }
            arrival?.fulfill()
        }
    }

    func release(throwing error: (any Error)?) {
        let continuation = state.withLock { state in
            let held = state.held
            state.held = nil
            return held
        }
        guard let continuation else {
            XCTFail("no delete is held")
            return
        }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The values the model reads through its injected closures; mutable so
/// a test can change them between refreshes.
@MainActor
private final class Environment {
    var isEnabled = true
    var now: Date
    var calendar: Calendar
    var deleteError: (any Error)?

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
    }
}

// MARK: - Tests

@MainActor
final class UsageWindowModelTests: XCTestCase {

    // MARK: Fixtures

    nonisolated private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Known zone identifiers; a missing one falls back to GMT and
        // every bound assertion below then fails loudly.
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    nonisolated private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
    }

    /// Asia/Tokyo (UTC+9, no DST): 2026-03-10 00:30 local, which is still
    /// 2026-03-09 in UTC, so a bound taken from the UTC day is a day off.
    private static let tokyoNowMs: Int64 = 1_773_070_200_000  // 2026-03-09T15:30:00Z
    /// 2026-03-10 00:00 JST = 2026-03-09T15:00:00Z
    private static let tokyoTodayMs: Int64 = 1_773_068_400_000
    /// 2026-03-04 00:00 JST = 2026-03-03T15:00:00Z
    private static let tokyoLast7Ms: Int64 = 1_772_550_000_000
    /// 2026-02-09 00:00 JST = 2026-02-08T15:00:00Z
    private static let tokyoLast30Ms: Int64 = 1_770_562_800_000

    /// Europe/Berlin: DST began 2026-03-29 (02:00 CET -> 03:00 CEST).
    /// `now` is 2026-04-01 12:00 CEST; the 7- and 30-day windows start in
    /// CET, so stepping back by 86,400-second days lands an hour late.
    private static let berlinNowMs: Int64 = 1_775_037_600_000  // 2026-04-01T10:00:00Z
    /// 2026-04-01 00:00 CEST = 2026-03-31T22:00:00Z
    private static let berlinTodayMs: Int64 = 1_774_994_400_000
    /// 2026-03-26 00:00 CET = 2026-03-25T23:00:00Z
    private static let berlinLast7Ms: Int64 = 1_774_479_600_000
    /// 2026-03-03 00:00 CET = 2026-03-02T23:00:00Z
    private static let berlinLast30Ms: Int64 = 1_772_492_400_000

    /// A `now` ten days after the earliest day the Gregorian calendar
    /// represents (it saturates at 4713 BC instead of returning nil): the
    /// start of today and of the last 7 days exist, the start of the last
    /// 30 days does not, so `UsagePeriod.startMs(lastDays: 30, …)` is nil.
    private static let calendarEdgeNow = Date(timeIntervalSince1970: -210_865_896_000)

    nonisolated private static func row(
        _ key: [String?], responses: Int64 = 1, input: Int64 = 0, lastMs: Int64 = 0
    ) -> UsageRow {
        UsageRow(
            key: key, responses: responses, finalResponses: responses, inputTokens: input,
            cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0,
            outputTokensFinal: 0, thinkingTokensFinal: 0, lastTimestampMs: lastMs)
    }

    /// The three results of one refresh, in the order the queries are sent.
    nonisolated private static func answer(
        rows: [UsageRow], totals: [UsageRow], projects: [UsageRow]
    ) -> ReportsStub.Answer {
        .success([rows, totals, projects])
    }

    private var stub: ReportsStub!
    private var env: Environment!
    private var deleteCalls: OSAllocatedUnfairLock<Int>!
    private var deleteGate: DeleteGate!

    override func setUp() async throws {
        try await super.setUp()
        stub = ReportsStub()
        env = Environment(now: Self.date(ms: Self.tokyoNowMs), calendar: Self.calendar("Asia/Tokyo"))
        deleteCalls = OSAllocatedUnfairLock(initialState: 0)
        deleteGate = DeleteGate()
    }

    override func tearDown() async throws {
        stub = nil
        env = nil
        deleteCalls = nil
        deleteGate = nil
        try await super.tearDown()
    }

    private func makeModel() -> UsageWindowModel {
        let stub = stub!
        let env = env!
        let deleteCalls = deleteCalls!
        let deleteGate = deleteGate!
        // Read on the main actor before the delete closure suspends.
        let deleteError: @Sendable () async -> (any Error)? = { await MainActor.run { env.deleteError } }
        return UsageWindowModel(
            isEnabled: { env.isEnabled },
            reports: { queries, calendar in try await stub.call(queries, calendar) },
            deleteAll: {
                deleteCalls.withLock { $0 += 1 }
                stub.noteDelete()
                try await deleteGate.pass()
                if let error = await deleteError() { throw error }
            },
            now: { env.now },
            calendar: { env.calendar }
        )
    }

    /// Waits (bounded, not by sleeping) until `reports` call `index` has arrived.
    private func waitForCall(_ index: Int) async {
        await fulfillment(of: [stub.expectCall(index)], timeout: 10)
    }

    private func expectedQueries(
        sinceMs: Int64?, project: UsageQuery.ProjectFilter? = nil, thread: UsageRecord.Thread? = nil
    ) -> [UsageQuery] {
        [
            UsageQuery(groupBy: [.model, .effort], sinceMs: sinceMs, project: project, thread: thread),
            UsageQuery(groupBy: [], sinceMs: sinceMs, project: project, thread: thread),
            UsageQuery(groupBy: [.project]),
        ]
    }

    private func modelEffortUsage(_ rows: [UsageWindowModel.Row]) -> [[String?]] {
        rows.map { [$0.model, $0.effort] }
    }

    // MARK: - query: period bounds

    func test_query_eastOfUTC_boundsAreLocalDayStarts() {
        let now = Self.date(ms: Self.tokyoNowMs)
        let calendar = Self.calendar("Asia/Tokyo")
        func since(_ period: UsageWindowModel.Period) -> Int64?? {
            UsageWindowModel.query(
                period: period, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar
            ).map(\.sinceMs)
        }

        XCTAssertEqual(since(.today), .some(Self.tokyoTodayMs))
        XCTAssertEqual(since(.last7Days), .some(Self.tokyoLast7Ms))
        XCTAssertEqual(since(.last30Days), .some(Self.tokyoLast30Ms))
        XCTAssertEqual(since(.all), .some(nil), "All Time has no lower bound")
    }

    func test_query_acrossADSTChange_boundsAreLocalMidnightNotFixedDaySteps() {
        let now = Self.date(ms: Self.berlinNowMs)
        let calendar = Self.calendar("Europe/Berlin")
        func since(_ period: UsageWindowModel.Period) -> Int64?? {
            UsageWindowModel.query(
                period: period, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar
            ).map(\.sinceMs)
        }

        XCTAssertEqual(since(.today), .some(Self.berlinTodayMs))
        XCTAssertEqual(since(.last7Days), .some(Self.berlinLast7Ms))
        XCTAssertEqual(since(.last30Days), .some(Self.berlinLast30Ms))
    }

    /// The window and the MCP tool's `days` mean the same instant.
    func test_query_boundsEqualUsagePeriodStartMs_for1_7_30Days() {
        let cases: [(UsageWindowModel.Period, Int)] = [(.today, 1), (.last7Days, 7), (.last30Days, 30)]
        for (nowMs, zone) in [(Self.tokyoNowMs, "Asia/Tokyo"), (Self.berlinNowMs, "Europe/Berlin")] {
            let now = Self.date(ms: nowMs)
            let calendar = Self.calendar(zone)
            for (period, days) in cases {
                let query = UsageWindowModel.query(
                    period: period, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar)
                XCTAssertNotNil(UsagePeriod.startMs(lastDays: days, now: now, calendar: calendar))
                XCTAssertEqual(
                    query?.sinceMs, UsagePeriod.startMs(lastDays: days, now: now, calendar: calendar),
                    "\(period) in \(zone)")
            }
        }
    }

    // MARK: - query: filters

    func test_query_mapsProjectThreadAndGroupBy_andNeverSetsUntilOrSession() {
        let now = Self.date(ms: Self.tokyoNowMs)
        let calendar = Self.calendar("Asia/Tokyo")

        let root = UsageWindowModel.query(
            period: .all, project: .root("/work/app"), thread: .subagent,
            groupBy: [.model, .effort], now: now, calendar: calendar)
        XCTAssertEqual(
            root, UsageQuery(groupBy: [.model, .effort], project: .root("/work/app"), thread: .subagent))

        let unattributed = UsageWindowModel.query(
            period: .today, project: .unattributed, thread: .advisor,
            groupBy: [.project], now: now, calendar: calendar)
        XCTAssertEqual(
            unattributed,
            UsageQuery(groupBy: [.project], sinceMs: Self.tokyoTodayMs, project: .unattributed, thread: .advisor))

        let all = UsageWindowModel.query(
            period: .last7Days, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar)
        XCTAssertEqual(all, UsageQuery(groupBy: [], sinceMs: Self.tokyoLast7Ms))
    }

    func test_query_aNowTheCalendarCannotStepBackFrom_isNil_forThatPeriodOnly() {
        let calendar = Self.calendar("Asia/Tokyo")
        let now = Self.calendarEdgeNow
        // Preconditions of the fixture itself: fail, never skip.
        XCTAssertNil(UsagePeriod.startMs(lastDays: 30, now: now, calendar: calendar))
        XCTAssertNotNil(UsagePeriod.startMs(lastDays: 1, now: now, calendar: calendar))

        XCTAssertNil(UsageWindowModel.query(
            period: .last30Days, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar))
        XCTAssertEqual(
            UsageWindowModel.query(
                period: .today, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar)?.sinceMs,
            UsagePeriod.startMs(lastDays: 1, now: now, calendar: calendar))
        XCTAssertEqual(
            UsageWindowModel.query(
                period: .all, project: .all, thread: nil, groupBy: [], now: now, calendar: calendar),
            UsageQuery(groupBy: []))
    }

    // MARK: - Defaults

    func test_initialState_isLast7DaysAllProjectsEveryThread_andEmpty() {
        let model = makeModel()

        XCTAssertEqual(model.period, .last7Days)
        XCTAssertEqual(model.project, .all)
        XCTAssertNil(model.thread)
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.totals)
        XCTAssertEqual(model.projects, [])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(stub.callCount, 0, "creating the model reads nothing")
    }

    // MARK: - refresh: the one reports call

    func test_refresh_makesOneReportsCall_withRowsTotalsAndUnfilteredProjectQueries_inOrder() async {
        let model = makeModel()

        await model.refresh()

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(stub.calls.first?.queries, expectedQueries(sinceMs: Self.tokyoLast7Ms))
        XCTAssertEqual(stub.calls.first?.calendar, Self.calendar("Asia/Tokyo"))
    }

    func test_refresh_withEveryFilterSet_filtersRowsAndTotals_butNotTheProjectList() async {
        let model = makeModel()
        model.period = .today
        model.project = .root("/work/app")
        model.thread = .subagent

        await model.refresh()

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(
            stub.calls.first?.queries,
            expectedQueries(sinceMs: Self.tokyoTodayMs, project: .root("/work/app"), thread: .subagent))
    }

    func test_refresh_allTimeAndUnattributed_sendNoLowerBound() async {
        let model = makeModel()
        model.period = .all
        model.project = .unattributed
        model.thread = .main

        await model.refresh()

        XCTAssertEqual(
            stub.calls.first?.queries, expectedQueries(sinceMs: nil, project: .unattributed, thread: .main))
    }

    func test_refresh_readsTheClockAndCalendarAtEachRefresh() async {
        let model = makeModel()
        model.period = .today
        await model.refresh()

        env.now = Self.date(ms: Self.berlinNowMs)
        env.calendar = Self.calendar("Europe/Berlin")
        await model.refresh()

        XCTAssertEqual(stub.callCount, 2)
        XCTAssertEqual(stub.calls.last?.queries, expectedQueries(sinceMs: Self.berlinTodayMs))
        XCTAssertEqual(stub.calls.last?.calendar, Self.calendar("Europe/Berlin"))
    }

    func test_changingTheFilters_doesNotRefreshByItself() async {
        let model = makeModel()

        model.period = .all
        model.project = .unattributed
        model.thread = .advisor
        XCTAssertEqual(stub.callCount, 0)

        // A refresh started by a filter change would be queued on the main
        // actor ahead of this one's completion and show up as a second call.
        await model.refresh()

        XCTAssertEqual(stub.callCount, 1)
    }

    // MARK: - refresh: results

    func test_refresh_rowsKeepTheLedgersOrder_andSplitTheKeyIntoModelAndEffort() async {
        let rows = [
            Self.row(["claude-opus", nil], responses: 3),
            Self.row(["claude-opus", "high"], responses: 2),
            Self.row(["claude-sonnet", "low"], responses: 1),
        ]
        stub.answer { _ in Self.answer(rows: rows, totals: [Self.row([], responses: 6)], projects: []) }
        let model = makeModel()

        await model.refresh()

        XCTAssertEqual(
            modelEffortUsage(model.rows),
            [["claude-opus", nil], ["claude-opus", "high"], ["claude-sonnet", "low"]])
        XCTAssertEqual(model.rows.map(\.usage), rows)
        XCTAssertEqual(model.totals, Self.row([], responses: 6))
    }

    func test_rowIDs_areUniqueWithinAResult_andStablePerModelAndEffort() async {
        // nil and "" are different groups and must not share an id.
        stub.answer { _ in
            Self.answer(
                rows: [Self.row(["m", nil]), Self.row(["m", ""]), Self.row(["m", "high"]), Self.row([nil, "high"])],
                totals: [Self.row([], responses: 4)], projects: [])
        }
        let model = makeModel()
        await model.refresh()
        let first = model.rows
        XCTAssertEqual(Set(first.map(\.id)).count, 4, "ids collide: \(first.map(\.id))")

        // Same (model, effort) at another position: same id.
        stub.answer { _ in
            Self.answer(rows: [Self.row(["m", "high"], responses: 9)], totals: [Self.row([], responses: 9)], projects: [])
        }
        await model.refresh()

        // Checked, not subscripted: a wrong first result must fail, not trap.
        let highID = first.first { $0.model == "m" && $0.effort == "high" }?.id
        XCTAssertNotNil(highID)
        XCTAssertEqual(model.rows.map(\.id), highID.map { [$0] })
    }

    func test_totals_isNilWhenTheTotalsQueryReturnedNoRow() async {
        stub.answer { _ in Self.answer(rows: [Self.row(["m", nil])], totals: [Self.row([])], projects: []) }
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.totals, Self.row([]))

        stub.answer { _ in Self.answer(rows: [], totals: [], projects: []) }
        await model.refresh()

        XCTAssertNil(model.totals)
        XCTAssertEqual(model.rows, [])
    }

    func test_projects_areRootsInTheLedgersOrder_thenUnattributedLast() async {
        // The ledger sorts the nil key first; the picker puts it last.
        stub.answer { _ in
            Self.answer(rows: [], totals: [], projects: [
                Self.row([nil]), Self.row(["/a/one"]), Self.row(["/b/two"]),
            ])
        }
        let model = makeModel()

        await model.refresh()

        XCTAssertEqual(model.projects, [.root("/a/one"), .root("/b/two"), .unattributed])
    }

    func test_projects_withoutANilKey_offerNoUnattributed() async {
        stub.answer { _ in
            Self.answer(rows: [], totals: [], projects: [Self.row(["/a/one"]), Self.row(["/b/two"])])
        }
        let model = makeModel()

        await model.refresh()

        XCTAssertEqual(model.projects, [.root("/a/one"), .root("/b/two")])
    }

    func test_aSelectedProjectNoLongerOffered_staysSelected_andKeepsFiltering() async {
        stub.answer { _ in Self.answer(rows: [], totals: [], projects: [Self.row(["/a/one"])]) }
        let model = makeModel()
        model.project = .root("/gone")

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(model.project, .root("/gone"))
        XCTAssertEqual(model.projects, [.root("/a/one")])
        XCTAssertEqual(stub.calls.last?.queries.first?.project, .root("/gone"))
    }

    // MARK: - Tracking flag

    func test_isTrackingEnabled_isSetBeforeTheFirstReportsCallReturns() async {
        stub.hold(1)
        let model = makeModel()
        XCTAssertFalse(model.isTrackingEnabled)

        let refresh = Task { await model.refresh() }
        await waitForCall(0)

        XCTAssertTrue(model.isTrackingEnabled, "the banner would flash while the first read is pending")
        XCTAssertTrue(model.isLoading)

        stub.release(0, with: Self.answer(rows: [], totals: [], projects: []))
        await refresh.value
        XCTAssertTrue(model.isTrackingEnabled)
    }

    func test_isTrackingEnabled_isReadAgainAtEachRefresh_andDataIsShownWhenOff() async {
        stub.answer { _ in
            Self.answer(rows: [Self.row(["m", nil])], totals: [Self.row([])], projects: [Self.row(["/a"])])
        }
        let model = makeModel()
        await model.refresh()
        XCTAssertTrue(model.isTrackingEnabled)

        env.isEnabled = false
        await model.refresh()

        XCTAssertFalse(model.isTrackingEnabled)
        XCTAssertEqual(stub.callCount, 2, "the stored data is still read while tracking is off")
        XCTAssertEqual(modelEffortUsage(model.rows), [["m", nil]])
        XCTAssertEqual(model.projects, [.root("/a")])
    }

    // MARK: - Latest wins

    private let olderData = (rows: [UsageWindowModelTests.row(["old", nil])],
                             totals: [UsageWindowModelTests.row([])],
                             projects: [UsageWindowModelTests.row(["/old"])])
    private let newerData = (rows: [UsageWindowModelTests.row(["new", "high"])],
                             totals: [UsageWindowModelTests.row([], responses: 2)],
                             projects: [UsageWindowModelTests.row(["/new"])])

    private func startTwoHeldRefreshes(_ model: UsageWindowModel) async -> (Task<Void, Never>, Task<Void, Never>) {
        stub.hold(2)
        let older = Task { await model.refresh() }
        await waitForCall(0)
        let newer = Task { await model.refresh() }
        await waitForCall(1)
        return (older, newer)
    }

    func test_anOlderRefreshFinishingLast_doesNotOverwriteTheNewerResult() async {
        let model = makeModel()
        let (older, newer) = await startTwoHeldRefreshes(model)

        stub.release(1, with: Self.answer(rows: newerData.rows, totals: newerData.totals, projects: newerData.projects))
        await newer.value
        XCTAssertEqual(modelEffortUsage(model.rows), [["new", "high"]])
        XCTAssertTrue(model.isLoading, "the older refresh is still running")

        stub.release(0, with: Self.answer(rows: olderData.rows, totals: olderData.totals, projects: olderData.projects))
        await older.value

        XCTAssertEqual(modelEffortUsage(model.rows), [["new", "high"]])
        XCTAssertEqual(model.totals, Self.row([], responses: 2))
        XCTAssertEqual(model.projects, [.root("/new")])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func test_anOlderRefreshThatThrowsLast_doesNotSetAnError() async {
        let model = makeModel()
        let (older, newer) = await startTwoHeldRefreshes(model)

        stub.release(1, with: Self.answer(rows: newerData.rows, totals: newerData.totals, projects: newerData.projects))
        await newer.value
        stub.release(0, with: .failure(StubError(message: "stale failure")))
        await older.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(modelEffortUsage(model.rows), [["new", "high"]])
        XCTAssertFalse(model.isLoading)
    }

    func test_anOlderRefreshFinishingFirst_isDiscarded_andLoadingContinuesUntilTheNewerEnds() async {
        let model = makeModel()
        let (older, newer) = await startTwoHeldRefreshes(model)

        stub.release(0, with: Self.answer(rows: olderData.rows, totals: olderData.totals, projects: olderData.projects))
        await older.value
        XCTAssertEqual(model.rows, [], "a superseded result is never shown")
        XCTAssertNil(model.totals)
        XCTAssertEqual(model.projects, [])
        XCTAssertTrue(model.isLoading, "the newer refresh is still running")

        stub.release(1, with: Self.answer(rows: newerData.rows, totals: newerData.totals, projects: newerData.projects))
        await newer.value

        XCTAssertEqual(modelEffortUsage(model.rows), [["new", "high"]])
        XCTAssertFalse(model.isLoading)
    }

    func test_anOlderRefreshThrowingFirst_isDiscarded_andTheNewerFailureIsShown() async {
        let model = makeModel()
        let (older, newer) = await startTwoHeldRefreshes(model)

        stub.release(0, with: .failure(StubError(message: "stale failure")))
        await older.value
        XCTAssertNil(model.errorMessage)

        stub.release(1, with: .failure(StubError(message: "current failure")))
        await newer.value

        XCTAssertEqual(model.errorMessage, "current failure")
        XCTAssertFalse(model.isLoading)
    }

    func test_isLoading_isTrueOnlyWhileARefreshRuns() async {
        stub.hold(1)
        let model = makeModel()
        XCTAssertFalse(model.isLoading)

        let refresh = Task { await model.refresh() }
        await waitForCall(0)
        XCTAssertTrue(model.isLoading)

        stub.release(0, with: .failure(StubError(message: "x")))
        await refresh.value
        XCTAssertFalse(model.isLoading, "a failed refresh also ends loading")
    }

    // MARK: - Errors

    func test_aFailedRefresh_showsTheErrorAndKeepsThePreviousData_untilTheNextSuccess() async {
        stub.answer { _ in
            Self.answer(rows: [Self.row(["m", "high"])], totals: [Self.row([], responses: 1)], projects: [Self.row(["/a"])])
        }
        let model = makeModel()
        await model.refresh()
        let rows = model.rows

        stub.answer { _ in .failure(StubError(message: "The database is locked.")) }
        await model.refresh()

        XCTAssertEqual(model.errorMessage, "The database is locked.")
        XCTAssertEqual(model.rows, rows)
        XCTAssertEqual(model.totals, Self.row([], responses: 1))
        XCTAssertEqual(model.projects, [.root("/a")])

        stub.answer { _ in Self.answer(rows: [], totals: [], projects: []) }
        await model.refresh()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.rows, [])
    }

    func test_aPeriodTheCalendarCannotCompute_readsNothing_andKeepsThePreviousData() async {
        env.now = Self.calendarEdgeNow
        XCTAssertNil(UsagePeriod.startMs(lastDays: 30, now: env.now, calendar: env.calendar), "fixture")
        stub.answer { _ in
            Self.answer(rows: [Self.row(["m", nil])], totals: [Self.row([])], projects: [Self.row(["/a"])])
        }
        let model = makeModel()
        model.period = .today
        await model.refresh()
        XCTAssertEqual(stub.callCount, 1)
        let rows = model.rows

        model.period = .last30Days
        await model.refresh()

        XCTAssertEqual(stub.callCount, 1, "no read, and in particular no all-time read in its place")
        XCTAssertEqual(model.errorMessage, "The selected period could not be computed.")
        XCTAssertEqual(model.rows, rows)
        XCTAssertEqual(model.totals, Self.row([]))
        XCTAssertEqual(model.projects, [.root("/a")])
        XCTAssertFalse(model.isLoading)
    }

    /// A refresh whose period cannot be computed is still the newest
    /// refresh: an older one (for another period) finishing after it is
    /// discarded, so it can neither show data for a period that is no
    /// longer selected nor replace the message.
    private func runOlderRefreshAcrossANilPeriodRefresh(releasing answer: ReportsStub.Answer) async {
        stub.answer { _ in
            Self.answer(rows: [Self.row(["before", nil])], totals: [Self.row([])], projects: [Self.row(["/before"])])
        }
        let model = makeModel()
        model.period = .today
        await model.refresh()
        let rowsBefore = model.rows
        XCTAssertEqual(modelEffortUsage(rowsBefore), [["before", nil]])

        // Call 0 has been answered; call 1 (the older refresh) is held.
        stub.hold(2)
        let older = Task { await model.refresh() }
        await waitForCall(1)

        env.now = Self.calendarEdgeNow
        XCTAssertNil(UsagePeriod.startMs(lastDays: 30, now: env.now, calendar: env.calendar), "fixture")
        model.period = .last30Days
        await model.refresh()
        XCTAssertEqual(stub.callCount, 2, "the nil period reads nothing")
        XCTAssertEqual(model.errorMessage, "The selected period could not be computed.")

        stub.release(1, with: answer)
        await older.value

        XCTAssertEqual(model.rows, rowsBefore)
        XCTAssertEqual(model.totals, Self.row([]))
        XCTAssertEqual(model.projects, [.root("/before")])
        XCTAssertEqual(model.errorMessage, "The selected period could not be computed.")
        XCTAssertFalse(model.isLoading)
    }

    func test_anOlderRefreshSucceedingAfterANilPeriodRefresh_isDiscarded() async {
        await runOlderRefreshAcrossANilPeriodRefresh(releasing: Self.answer(
            rows: [Self.row(["stale", "high"])], totals: [Self.row([], responses: 5)],
            projects: [Self.row(["/stale"])]))
    }

    func test_anOlderRefreshThrowingAfterANilPeriodRefresh_isDiscarded() async {
        await runOlderRefreshAcrossANilPeriodRefresh(releasing: .failure(StubError(message: "stale failure")))
    }

    // MARK: - The most recent failure stays until a later refresh succeeds

    private static let deleteFailure = "Could not delete the usage database."

    /// Shows rows A, then holds the next `reports` call (index 1).
    private func modelShowingRowsA() async -> UsageWindowModel {
        stub.answer { _ in
            Self.answer(rows: [Self.row(["a", nil])], totals: [Self.row([])], projects: [Self.row(["/a"])])
        }
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(modelEffortUsage(model.rows), [["a", nil]])
        stub.hold(2)
        return model
    }

    private let rowsB = Answer(rows: [UsageWindowModelTests.row(["b", "high"])],
                               totals: [UsageWindowModelTests.row([], responses: 2)],
                               projects: [UsageWindowModelTests.row(["/b"])])

    private struct Answer {
        let rows: [UsageRow]
        let totals: [UsageRow]
        let projects: [UsageRow]
        var success: ReportsStub.Answer { .success([rows, totals, projects]) }
    }

    /// A refresh after the failure, answered at once, clears the message.
    private func assertALaterRefreshClearsTheMessage(_ model: UsageWindowModel) async {
        stub.answer { _ in Self.answer(rows: [], totals: [], projects: []) }
        await model.refresh()
        XCTAssertNil(model.errorMessage, "a refresh started after the failure succeeded")
    }

    /// A refresh running when the delete fails is still the latest: its
    /// rows land, but it started before the failure, so the message stays.
    func test_aRefreshRunningWhenADeleteFails_appliesItsRows_butKeepsTheDeleteError() async {
        let model = await modelShowingRowsA()
        let refresh = Task { await model.refresh() }
        await waitForCall(1)

        env.deleteError = StubError(message: Self.deleteFailure)
        await model.deleteAllData()
        XCTAssertEqual(model.errorMessage, Self.deleteFailure)

        stub.release(1, with: rowsB.success)
        await refresh.value

        XCTAssertEqual(modelEffortUsage(model.rows), [["b", "high"]])
        XCTAssertEqual(model.totals, Self.row([], responses: 2))
        XCTAssertEqual(model.projects, [.root("/b")])
        XCTAssertEqual(model.errorMessage, Self.deleteFailure)
        XCTAssertFalse(model.isLoading)

        env.deleteError = nil
        await assertALaterRefreshClearsTheMessage(model)
    }

    /// A refresh started while the delete runs (the user changed a filter)
    /// is not superseded by the failed delete: its rows are valid, since a
    /// failed delete changed nothing, and land; the message stays.
    func test_aRefreshStartedDuringADeleteThatFails_appliesItsRows_butKeepsTheDeleteError() async {
        let model = await modelShowingRowsA()
        let deleteArrived = deleteGate.holdNext()
        let delete = Task { await model.deleteAllData() }
        await fulfillment(of: [deleteArrived], timeout: 10)

        model.period = .all
        let refresh = Task { await model.refresh() }
        await waitForCall(1)

        deleteGate.release(throwing: StubError(message: Self.deleteFailure))
        await delete.value
        XCTAssertEqual(model.errorMessage, Self.deleteFailure)

        stub.release(1, with: rowsB.success)
        await refresh.value

        XCTAssertEqual(modelEffortUsage(model.rows), [["b", "high"]], "the new selection's rows must land")
        XCTAssertEqual(model.projects, [.root("/b")])
        XCTAssertEqual(model.errorMessage, Self.deleteFailure)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(stub.events, ["reports", "deleteAll", "reports"], "a failed delete does not refresh")

        await assertALaterRefreshClearsTheMessage(model)
    }

    /// The most recent failure wins: a refresh that started before the
    /// delete failed, and then fails itself, shows its own message.
    func test_aRefreshRunningWhenADeleteFails_thatThenThrows_replacesTheMessage() async {
        let model = await modelShowingRowsA()
        let refresh = Task { await model.refresh() }
        await waitForCall(1)

        env.deleteError = StubError(message: Self.deleteFailure)
        await model.deleteAllData()
        XCTAssertEqual(model.errorMessage, Self.deleteFailure)

        stub.release(1, with: .failure(StubError(message: "The database is locked.")))
        await refresh.value

        XCTAssertEqual(model.errorMessage, "The database is locked.")
        XCTAssertEqual(modelEffortUsage(model.rows), [["a", nil]])
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Delete

    func test_deleteAllData_deletesThenRefreshes() async {
        stub.answer { _ in Self.answer(rows: [Self.row(["m", nil])], totals: [Self.row([])], projects: []) }
        let model = makeModel()
        await model.refresh()

        stub.answer { _ in Self.answer(rows: [], totals: [], projects: []) }
        await model.deleteAllData()

        XCTAssertEqual(deleteCalls.withLock { $0 }, 1)
        XCTAssertEqual(stub.events, ["reports", "deleteAll", "reports"])
        XCTAssertEqual(stub.calls.last?.queries, expectedQueries(sinceMs: Self.tokyoLast7Ms))
        XCTAssertEqual(model.rows, [])
        XCTAssertNil(model.totals)
    }

    func test_aFailedDelete_showsTheError_doesNotRefresh_andKeepsTheTable() async {
        stub.answer { _ in
            Self.answer(rows: [Self.row(["m", nil])], totals: [Self.row([])], projects: [Self.row(["/a"])])
        }
        let model = makeModel()
        await model.refresh()
        let rows = model.rows
        env.deleteError = StubError(message: "Could not delete the usage database.")

        await model.deleteAllData()

        XCTAssertEqual(deleteCalls.withLock { $0 }, 1)
        XCTAssertEqual(stub.events, ["reports", "deleteAll"])
        XCTAssertEqual(model.errorMessage, "Could not delete the usage database.")
        XCTAssertEqual(model.rows, rows)
        XCTAssertEqual(model.totals, Self.row([]))
        XCTAssertEqual(model.projects, [.root("/a")])
    }
}
