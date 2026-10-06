//
//  UsageTokenGoldTests.swift
//  CalyxTests
//
//  Pins UsageStore.tokenReport(_:calendar:) / tokenReports(_:calendar:),
//  the aggregate query over recorded telemetry points (`usage_points`) and
//  unreported amounts (`usage_unreported`): grouping by one or several
//  dimensions, the four token sums and the latest time per group, recorded
//  and unreported kept as separate flagged rows, the time rule (a point is
//  dated at the START of its receive minute, an unreported row at its
//  nanosecond time floored to milliseconds; [since, until)), the filters
//  (a thread filter drops unreported rows), "no match, no row", the order,
//  local days from the calendar's time zone only, and the errors.
//
//  How data gets into a test store (only contracted APIs, no test-only
//  production code):
//  - points: `apply(samples:processStarts:receivedAtNs:)` with one fresh
//    process start per session and new series ids per call, so every
//    sample counts in full and lands in the minute of `receivedAtNs`;
//  - unreported rows: a fresh process start makes the session "heard",
//    `saveRunLog` stores ONE closed run whose totals are what the test
//    itself recorded for the session plus the wanted shortfall, ending at
//    the wanted time, and `reconcile(session:)` writes the rows the way
//    production does. Every such setup is checked against
//    `unreportedRows()` and fails as "Fixture error" if it differs.
//  - project roots: `setProjectRootIfUnset`; a session row with a NULL
//    root with raw SQL (the store's API cannot make one).
//
//  Token amounts follow one pattern, `n` → input n, output 10n, cache read
//  100n, cache creation 1000n, with n a distinct power of two per source
//  row, so every expected sum is computed by hand and a swapped column or
//  a wrongly included row changes the numbers.
//
//  Epoch-millisecond literals were computed outside the code under test
//  (Python zoneinfo). Everything is synthetic except the run2 fixture
//  tests, whose numbers come from the sanitized captures.
//

import Darwin
import SQLite3
import XCTest
@testable import Calyx

// MARK: - Shared support

class UsageTokenGoldTestSupport: XCTestCase {

    typealias Dimension = UsageTokenQuery.Dimension

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []
    private var seriesCounter = 0

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageTokenGoldTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        seriesCounter = 0
    }

    override func tearDown() async throws {
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: Stores

    func temporaryDirectory() throws -> URL {
        try XCTUnwrap(tempDirectory, "Fixture error: no temporary directory")
    }

    /// A store whose clock (and so `tracked_from_ns`) is `date`; the epoch
    /// by default, so every synthetic time counts.
    func openStore(at date: Date = Date(timeIntervalSince1970: 0)) throws -> UsageStore {
        let store = try UsageStore(
            directory: try temporaryDirectory().appendingPathComponent("store", isDirectory: true),
            now: UsageTestClock(date).now)
        openedStores.append(store)
        return store
    }

    // MARK: Amounts and rows

    /// input n, output 10n, cache read 100n, cache creation 1000n.
    /// Never traps: an out-of-range n (a test bug) yields -1 everywhere,
    /// which no stored amount equals.
    func amounts(_ n: Int64) -> UsageTokenTotals {
        let (output, o1) = n.multipliedReportingOverflow(by: 10)
        let (cacheRead, o2) = n.multipliedReportingOverflow(by: 100)
        let (cacheCreation, o3) = n.multipliedReportingOverflow(by: 1_000)
        guard !(o1 || o2 || o3) else {
            XCTFail("Fixture error: amounts(\(n)) overflows")
            return UsageTokenTotals(input: -1, output: -1, cacheRead: -1, cacheCreation: -1)
        }
        return UsageTokenTotals(input: n, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    /// Milliseconds to nanoseconds, never trapping (test times are far
    /// from the limits; an overflow is a test bug and fails).
    func ns(_ ms: Int64) -> Int64 {
        let (value, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
        if overflow { XCTFail("Fixture error: \(ms) ms overflows as ns") }
        return overflow ? 0 : value
    }

    func row(_ key: [String?], unreported: Bool = false, _ n: Int64, last: Int64) -> UsageTokenRow {
        row(key, unreported: unreported, amounts(n), last: last)
    }

    func row(_ key: [String?], unreported: Bool = false, _ totals: UsageTokenTotals, last: Int64) -> UsageTokenRow {
        UsageTokenRow(
            key: key,
            isUnreported: unreported,
            inputTokens: totals.input,
            cacheReadTokens: totals.cacheRead,
            cacheCreationTokens: totals.cacheCreation,
            outputTokens: totals.output,
            lastTimestampMs: last)
    }

    func query(
        _ groupBy: [Dimension] = [], _ configure: (inout UsageTokenQuery) -> Void = { _ in }
    ) -> UsageTokenQuery {
        var query = UsageTokenQuery()
        query.groupBy = groupBy
        configure(&query)
        return query
    }

    func calendar(_ identifier: String, system: Calendar.Identifier = .gregorian) throws -> Calendar {
        var calendar = Calendar(identifier: system)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier), "Fixture error: unknown time zone")
        return calendar
    }

    func utc() throws -> Calendar { try calendar("UTC") }

    func report(
        _ store: UsageStore, _ query: UsageTokenQuery, calendar: Calendar? = nil
    ) async throws -> [UsageTokenRow] {
        let calendar = try calendar ?? utc()
        return try await store.tokenReport(query, calendar: calendar)
    }

    /// Adds the four token columns of every row, failing (never trapping)
    /// on overflow.
    func sum(_ rows: [UsageTokenRow]) -> UsageTokenTotals? {
        var total = UsageTokenTotals()
        for row in rows {
            guard let input = adding(total.input, row.inputTokens),
                  let output = adding(total.output, row.outputTokens),
                  let cacheRead = adding(total.cacheRead, row.cacheReadTokens),
                  let cacheCreation = adding(total.cacheCreation, row.cacheCreationTokens) else {
                XCTFail("Sum of rows overflows")
                return nil
            }
            total = UsageTokenTotals(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
        }
        return total
    }

    private func adding(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    func element<T>(_ items: [T], at index: Int) throws -> T {
        try XCTUnwrap(items.indices.contains(index) ? items[index] : nil, "No element \(index) in \(items)")
    }

    // MARK: Seeding

    /// The one process start every synthetic session is sent from: fresh,
    /// after tracking started (clock at the epoch), before every run end.
    func processStart(_ sessionID: String) -> UsageProcessStart {
        UsageProcessStart(sessionID: sessionID, startNs: 1_000, startType: "fresh")
    }

    /// Records `totals` for one label group, received at `receivedAtNs`
    /// (so dated at the start of that minute). New series ids every call:
    /// each sample counts in full.
    func record(
        _ store: UsageStore,
        session: String,
        model: String,
        effort: String? = nil,
        thread: String? = nil,
        agent: String? = nil,
        _ totals: UsageTokenTotals,
        receivedAtNs: Int64
    ) async throws {
        seriesCounter += 1
        let samples = UsageTokenKind.allCases.map { kind in
            UsageSeriesSample(
                sessionID: session,
                seriesID: "series-\(seriesCounter)-\(kind.rawValue)",
                startNs: 1_000,
                timeNs: receivedAtNs,
                kind: kind,
                value: totals[kind],
                model: model,
                effort: effort,
                thread: thread,
                agent: agent)
        }
        let outcome = try await store.apply(
            samples: samples, processStarts: [processStart(session)], receivedAtNs: receivedAtNs)
        XCTAssertFalse(outcome.ignored, "Fixture error: points for \(session) were ignored")
        XCTAssertEqual(outcome.newSeries, samples.count, "Fixture error: points for \(session) did not count in full")
    }

    /// `record` with the n pattern at a millisecond time.
    func record(
        _ store: UsageStore,
        session: String,
        model: String,
        effort: String? = nil,
        thread: String? = nil,
        agent: String? = nil,
        _ n: Int64,
        atMs: Int64
    ) async throws {
        try await record(
            store, session: session, model: model, effort: effort, thread: thread, agent: agent,
            amounts(n), receivedAtNs: ns(atMs))
    }

    /// Makes the store hold exactly `shortfall` as unreported rows of
    /// `session` (one per model, all dated `atNs`), through a stored run
    /// log and `reconcile(session:)`. `recorded` must be what the test
    /// itself recorded for this session, per model (it is what the run's
    /// totals hold besides the shortfall).
    func addUnreported(
        _ store: UsageStore,
        session: String,
        recorded: [String: UsageTokenTotals] = [:],
        shortfall: [String: UsageTokenTotals],
        atNs: Int64
    ) async throws {
        // Makes the session heard by a fresh process (no samples).
        let outcome = try await store.apply(samples: [], processStarts: [processStart(session)], receivedAtNs: 1_000)
        XCTAssertFalse(outcome.ignored, "Fixture error: process start for \(session) ignored")

        var runTotals = recorded
        for (model, extra) in shortfall {
            let base = runTotals[model] ?? UsageTokenTotals()
            var combined = UsageTokenTotals()
            for kind in UsageTokenKind.allCases {
                let (value, overflow) = base[kind].addingReportingOverflow(extra[kind])
                guard !overflow else { return XCTFail("Fixture error: run totals overflow") }
                combined[kind] = value
            }
            runTotals[model] = combined
        }
        let log = UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: 1, endNs: atNs, totals: runTotals)])
        try await store.saveRunLog(
            log,
            file: UsageRunLogFile(
                path: "/nonexistent/project/\(session).jsonl", checkpoint: TranscriptCheckpoint(inode: 1, offset: 0)),
            forSession: session)
        _ = try await store.reconcile(session: session)

        let expected = shortfall.keys.sorted().compactMap { model -> UsageUnreportedStoredRow? in
            guard let totals = shortfall[model] else { return nil }
            return UsageUnreportedStoredRow(sessionID: session, sequence: 1, timeNs: atNs, model: model, totals: totals)
        }
        let stored = try await store.unreportedRows().filter { $0.sessionID == session }
        XCTAssertEqual(stored, expected, "Fixture error: the reconciliation did not store the intended unreported rows")
    }

    func setRoot(_ store: UsageStore, _ root: String, session: String) async throws {
        try await store.setProjectRootIfUnset(root, forSession: session)
    }

    /// A session row whose project root is NULL. The store's API cannot
    /// make one (`setProjectRootIfUnset` takes a root), so it is written
    /// with raw SQL into the open store's database (WAL: the store sees
    /// it on its next read). `session` must be a plain identifier.
    func addSessionWithoutRoot(_ store: UsageStore, session: String) async throws {
        let path = try temporaryDirectory().appendingPathComponent("store", isDirectory: true)
            .appendingPathComponent("usage.sqlite").path
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: cannot open the database")
        }
        let sql = "INSERT INTO usage_sessions (session_id, project_root) VALUES ('\(session)', NULL)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: cannot insert the session row")
        }
    }
}

// MARK: - Synthetic rules

final class UsageTokenGoldTests: UsageTokenGoldTestSupport {

    // MARK: Times of the standard data set

    /// 2026-10-02T10:00:00.000Z, a minute start.
    private let baseMs: Int64 = 1_790_935_200_000
    /// 2026-10-03T10:00:00.000Z.
    private let nextDayMs: Int64 = 1_791_021_600_000
    /// U1: 2026-10-02T10:01:30.123456789Z → dated 10:01:30.123 (floor).
    private let u1Ns: Int64 = 1_790_935_290_123_456_789
    private let u1Ms: Int64 = 1_790_935_290_123
    /// U2: 2026-10-03T10:00:00.005999999Z → dated …00.005 (floor).
    private let u2Ns: Int64 = 1_791_021_600_005_999_999
    private let u2Ms: Int64 = 1_791_021_600_005

    /// The standard data set:
    ///
    ///     P1 s1 opus   high main      -       n=1   base
    ///     P2 s1 opus   low  subagent  Explore n=2   base+60s
    ///     P3 s2 sonnet -    main      -       n=4   base+120s
    ///     P4 s3 sonnet high auxiliary -       n=8   base+180s
    ///     P5 s2 opus   high main      -       n=16  next day
    ///     U1 s1 opus   unreported             n=32  u1 (2026-10-02)
    ///     U2 s3 sonnet unreported             n=64  u2 (2026-10-03)
    ///
    /// s1 has root /p/a, s2 root /p/b, s3 no session row.
    private func standardStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(store, session: "s1", model: "opus", effort: "high", thread: "main", 1, atMs: baseMs)
        try await record(
            store, session: "s1", model: "opus", effort: "low", thread: "subagent", agent: "Explore", 2,
            atMs: baseMs + 60_000)
        try await record(store, session: "s2", model: "sonnet", thread: "main", 4, atMs: baseMs + 120_000)
        try await record(
            store, session: "s3", model: "sonnet", effort: "high", thread: "auxiliary", 8, atMs: baseMs + 180_000)
        try await record(store, session: "s2", model: "opus", effort: "high", thread: "main", 16, atMs: nextDayMs)
        try await addUnreported(
            store, session: "s1", recorded: ["opus": amounts(3)], shortfall: ["opus": amounts(32)], atNs: u1Ns)
        try await addUnreported(
            store, session: "s3", recorded: ["sonnet": amounts(8)], shortfall: ["sonnet": amounts(64)], atNs: u2Ns)
        try await setRoot(store, "/p/a", session: "s1")
        try await setRoot(store, "/p/b", session: "s2")
        return store
    }

    // MARK: Each dimension alone

    func testGroupByModelSumsEachColumnPerSourceWithLatestTime() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.model]))
        XCTAssertEqual(rows, [
            row(["opus"], 19, last: nextDayMs),
            row(["opus"], unreported: true, 32, last: u1Ms),
            row(["sonnet"], 12, last: baseMs + 180_000),
            row(["sonnet"], unreported: true, 64, last: u2Ms),
        ])
    }

    func testGroupByEffortGivesUnreportedRowsANilEffort() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.effort]))
        XCTAssertEqual(rows, [
            row([nil], 4, last: baseMs + 120_000),
            row([nil], unreported: true, 96, last: u2Ms),
            row(["high"], 25, last: nextDayMs),
            row(["low"], 2, last: baseMs + 60_000),
        ])
    }

    func testGroupByThreadGivesUnreportedRowsANilThread() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.thread]))
        XCTAssertEqual(rows, [
            row([nil], unreported: true, 96, last: u2Ms),
            row(["auxiliary"], 8, last: baseMs + 180_000),
            row(["main"], 21, last: nextDayMs),
            row(["subagent"], 2, last: baseMs + 60_000),
        ])
    }

    func testGroupByAgentTypeGivesUnreportedRowsANilAgent() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.agentType]))
        XCTAssertEqual(rows, [
            row([nil], 29, last: nextDayMs),
            row([nil], unreported: true, 96, last: u2Ms),
            row(["Explore"], 2, last: baseMs + 60_000),
        ])
    }

    func testGroupByDayLabelsBothSourcesByTheirOwnTimes() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.day]))
        XCTAssertEqual(rows, [
            row(["2026-10-02"], 15, last: baseMs + 180_000),
            row(["2026-10-02"], unreported: true, 32, last: u1Ms),
            row(["2026-10-03"], 16, last: nextDayMs),
            row(["2026-10-03"], unreported: true, 64, last: u2Ms),
        ])
    }

    func testGroupByProjectUsesStoredRootsAndNilForUnattributed() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.project]))
        XCTAssertEqual(rows, [
            row([nil], 8, last: baseMs + 180_000),
            row([nil], unreported: true, 64, last: u2Ms),
            row(["/p/a"], 3, last: baseMs + 60_000),
            row(["/p/a"], unreported: true, 32, last: u1Ms),
            row(["/p/b"], 20, last: nextDayMs),
        ])
    }

    func testGroupBySessionKeepsEachSessionsSourcesApart() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.session]))
        XCTAssertEqual(rows, [
            row(["s1"], 3, last: baseMs + 60_000),
            row(["s1"], unreported: true, 32, last: u1Ms),
            row(["s2"], 20, last: nextDayMs),
            row(["s3"], 8, last: baseMs + 180_000),
            row(["s3"], unreported: true, 64, last: u2Ms),
        ])
    }

    func testEmptyGroupByGivesOneRecordedAndOneUnreportedTotal() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query())
        XCTAssertEqual(rows, [
            row([], 31, last: nextDayMs),
            row([], unreported: true, 96, last: u2Ms),
        ])
    }

    // MARK: Several dimensions

    func testGroupByModelAndEffort() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.model, .effort]))
        XCTAssertEqual(rows, [
            row(["opus", nil], unreported: true, 32, last: u1Ms),
            row(["opus", "high"], 17, last: nextDayMs),
            row(["opus", "low"], 2, last: baseMs + 60_000),
            row(["sonnet", nil], 4, last: baseMs + 120_000),
            row(["sonnet", nil], unreported: true, 64, last: u2Ms),
            row(["sonnet", "high"], 8, last: baseMs + 180_000),
        ])
    }

    func testGroupByProjectAndDay() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.project, .day]))
        XCTAssertEqual(rows, [
            row([nil, "2026-10-02"], 8, last: baseMs + 180_000),
            row([nil, "2026-10-03"], unreported: true, 64, last: u2Ms),
            row(["/p/a", "2026-10-02"], 3, last: baseMs + 60_000),
            row(["/p/a", "2026-10-02"], unreported: true, 32, last: u1Ms),
            row(["/p/b", "2026-10-02"], 4, last: baseMs + 120_000),
            row(["/p/b", "2026-10-03"], 16, last: nextDayMs),
        ])
    }

    func testGroupBySessionThreadAndAgentType() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.session, .thread, .agentType]))
        XCTAssertEqual(rows, [
            row(["s1", nil, nil], unreported: true, 32, last: u1Ms),
            row(["s1", "main", nil], 1, last: baseMs),
            row(["s1", "subagent", "Explore"], 2, last: baseMs + 60_000),
            row(["s2", "main", nil], 20, last: nextDayMs),
            row(["s3", nil, nil], unreported: true, 64, last: u2Ms),
            row(["s3", "auxiliary", nil], 8, last: baseMs + 180_000),
        ])
    }

    func testKeyElementsFollowTheOrderOfGroupBy() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.effort, .model]) { $0.sessionID = "s1" })
        XCTAssertEqual(rows, [
            row([nil, "opus"], unreported: true, 32, last: u1Ms),
            row(["high", "opus"], 1, last: baseMs),
            row(["low", "opus"], 2, last: baseMs + 60_000),
        ])
    }

    // MARK: Rule 2: time

    /// 2026-10-02T10:00:00.000Z: the minute start M the bounds are set around.
    private let minuteMs: Int64 = 1_790_935_200_000

    /// Point A received at 09:59:59.999 (dated 09:59:00.000), n=1;
    /// point B received at 10:00:00.000 (dated 10:00:00.000), n=2.
    private func minuteEdgeStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(
            store, session: "a", model: "m", amounts(1), receivedAtNs: ns(minuteMs - 1))
        try await record(store, session: "b", model: "m", amounts(2), receivedAtNs: ns(minuteMs))
        return store
    }

    func testPointIsDatedAtTheStartOfItsReceiveMinute() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query([.session]))
        XCTAssertEqual(rows, [
            row(["a"], 1, last: minuteMs - 60_000),
            row(["b"], 2, last: minuteMs),
        ])
    }

    func testSinceAtTheMinuteStartIncludesThatMinuteOnly() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.sinceMs = minuteMs })
        XCTAssertEqual(rows, [row([], 2, last: minuteMs)])
    }

    func testSinceOneMillisecondBeforeTheMinuteStartExcludesThePointReceivedThen() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.sinceMs = minuteMs - 1 })
        XCTAssertEqual(rows, [row([], 2, last: minuteMs)])
    }

    func testSinceOneMillisecondAfterTheMinuteStartExcludesThatMinute() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.sinceMs = minuteMs + 1 })
        XCTAssertEqual(rows, [])
    }

    func testUntilAtTheMinuteStartIsExclusive() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.untilMs = minuteMs })
        XCTAssertEqual(rows, [row([], 1, last: minuteMs - 60_000)])
    }

    func testUntilOneMillisecondBeforeTheMinuteStartStillIncludesTheEarlierMinute() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.untilMs = minuteMs - 1 })
        XCTAssertEqual(rows, [row([], 1, last: minuteMs - 60_000)])
    }

    func testUntilOneMillisecondAfterTheMinuteStartIncludesThatMinute() async throws {
        let store = try await minuteEdgeStore()
        let rows = try await report(store, query { $0.untilMs = minuteMs + 1 })
        XCTAssertEqual(rows, [row([], 3, last: minuteMs)])
    }

    /// Unreported row at 2026-10-02T10:00:12.345678901Z: dated
    /// 10:00:12.345 (floor; rounding would give .346).
    private let oddNs: Int64 = 1_790_935_212_345_678_901
    private let oddMs: Int64 = 1_790_935_212_345

    private func unreportedAtOddTimeStore() async throws -> UsageStore {
        let store = try openStore()
        try await addUnreported(store, session: "u", shortfall: ["m": amounts(4)], atNs: oddNs)
        return store
    }

    func testUnreportedRowIsDatedAtItsTimeFlooredToMilliseconds() async throws {
        let store = try await unreportedAtOddTimeStore()
        let rows = try await report(store, query())
        XCTAssertEqual(rows, [row([], unreported: true, 4, last: oddMs)])
    }

    func testUnreportedRowAgainstSinceBounds() async throws {
        let store = try await unreportedAtOddTimeStore()
        let atTime = try await report(store, query { $0.sinceMs = oddMs })
        XCTAssertEqual(atTime, [row([], unreported: true, 4, last: oddMs)], "since == time includes")
        let before = try await report(store, query { $0.sinceMs = oddMs - 1 })
        XCTAssertEqual(before, [row([], unreported: true, 4, last: oddMs)], "since before time includes")
        let after = try await report(store, query { $0.sinceMs = oddMs + 1 })
        XCTAssertEqual(after, [], "since after time excludes")
    }

    func testUnreportedRowAgainstUntilBounds() async throws {
        let store = try await unreportedAtOddTimeStore()
        let atTime = try await report(store, query { $0.untilMs = oddMs })
        XCTAssertEqual(atTime, [], "until == time excludes")
        let before = try await report(store, query { $0.untilMs = oddMs - 1 })
        XCTAssertEqual(before, [], "until before time excludes")
        let after = try await report(store, query { $0.untilMs = oddMs + 1 })
        XCTAssertEqual(after, [row([], unreported: true, 4, last: oddMs)], "until after time includes")
    }

    func testSinceEqualToUntilGivesNothing() async throws {
        let store = try await minuteEdgeStore()
        try await addUnreported(store, session: "u", shortfall: ["m": amounts(4)], atNs: ns(minuteMs))
        let rows = try await report(store, query([.session]) {
            $0.sinceMs = minuteMs
            $0.untilMs = minuteMs
        })
        XCTAssertEqual(rows, [])
    }

    func testSinceAfterUntilGivesNothing() async throws {
        let store = try await minuteEdgeStore()
        try await addUnreported(store, session: "u", shortfall: ["m": amounts(4)], atNs: ns(minuteMs))
        let rows = try await report(store, query([.session]) {
            $0.sinceMs = minuteMs + 60_000
            $0.untilMs = minuteMs - 60_000
        })
        XCTAssertEqual(rows, [])
    }

    // MARK: Rule 3: filters

    func testSessionFilterKeepsThatSessionsRecordedAndUnreportedRows() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query { $0.sessionID = "s1" })
        XCTAssertEqual(rows, [
            row([], 3, last: baseMs + 60_000),
            row([], unreported: true, 32, last: u1Ms),
        ])
    }

    func testProjectRootFilterMatchesExactlyThatRoot() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.session]) { $0.project = .root("/p/a") })
        XCTAssertEqual(rows, [
            row(["s1"], 3, last: baseMs + 60_000),
            row(["s1"], unreported: true, 32, last: u1Ms),
        ])
        let prefix = try await report(store, query { $0.project = .root("/p") })
        XCTAssertEqual(prefix, [], "a root is matched exactly, not as a prefix")
    }

    func testUnattributedFilterMatchesASessionWithoutRowAndOneWithNullRoot() async throws {
        let store = try openStore()
        try await record(store, session: "noRow", model: "m", 1, atMs: baseMs)
        try await addSessionWithoutRoot(store, session: "nullRoot")
        try await record(store, session: "nullRoot", model: "m", 4, atMs: baseMs + 60_000)
        try await addUnreported(
            store, session: "nullRoot", recorded: ["m": amounts(4)], shortfall: ["m": amounts(2)], atNs: u1Ns)
        try await record(store, session: "rooted", model: "m", 8, atMs: baseMs + 120_000)
        try await addUnreported(store, session: "rooted", recorded: ["m": amounts(8)], shortfall: ["m": amounts(16)], atNs: u2Ns)
        try await setRoot(store, "/p/x", session: "rooted")

        let noRowMeta = try await store.session("noRow")
        XCTAssertNil(noRowMeta, "Fixture error: \"noRow\" must have no session row")
        let nullRootMeta = try await store.session("nullRoot")
        XCTAssertNotNil(nullRootMeta, "Fixture error: \"nullRoot\" must have a session row")
        XCTAssertNil(nullRootMeta?.projectRoot, "Fixture error: \"nullRoot\" must have a NULL root")

        let rows = try await report(store, query([.session]) { $0.project = .unattributed })
        XCTAssertEqual(rows, [
            row(["noRow"], 1, last: baseMs),
            row(["nullRoot"], 4, last: baseMs + 60_000),
            row(["nullRoot"], unreported: true, 2, last: u1Ms),
        ])
    }

    func testThreadFilterKeepsMatchingRecordedRowsAndDropsAllUnreportedRows() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.session]) { $0.thread = "main" })
        XCTAssertEqual(rows, [
            row(["s1"], 1, last: baseMs),
            row(["s2"], 20, last: nextDayMs),
        ])
    }

    func testThreadFilterDropsUnreportedRowsEvenWithASessionFilter() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query {
            $0.sessionID = "s3"
            $0.thread = "auxiliary"
        })
        XCTAssertEqual(rows, [row([], 8, last: baseMs + 180_000)])
    }

    func testThreadLabelNobodyHasGivesNothing() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.model]) { $0.thread = "nobody" })
        XCTAssertEqual(rows, [])
    }

    func testTimeFilterKeepsUnreportedRowsInRange() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.session]) { $0.sinceMs = nextDayMs })
        XCTAssertEqual(rows, [
            row(["s2"], 16, last: nextDayMs),
            row(["s3"], unreported: true, 64, last: u2Ms),
        ])
    }

    func testAllFiltersTogetherWithoutThread() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.model]) {
            $0.sessionID = "s1"
            $0.project = .root("/p/a")
            $0.sinceMs = baseMs + 60_000
            $0.untilMs = nextDayMs
        })
        XCTAssertEqual(rows, [
            row(["opus"], 2, last: baseMs + 60_000),
            row(["opus"], unreported: true, 32, last: u1Ms),
        ])
    }

    func testAllFiltersTogetherWithThread() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query([.model]) {
            $0.sessionID = "s1"
            $0.project = .root("/p/a")
            $0.thread = "main"
            $0.sinceMs = baseMs
            $0.untilMs = nextDayMs
        })
        XCTAssertEqual(rows, [row(["opus"], 1, last: baseMs)])
    }

    func testFiltersThatContradictEachOtherGiveNothing() async throws {
        let store = try await standardStore()
        let rows = try await report(store, query {
            $0.sessionID = "s2"
            $0.project = .root("/p/a")
        })
        XCTAssertEqual(rows, [])
    }

    func testFilterValuesAreMatchedLiterallyNotAsSQL() async throws {
        let store = try await standardStore()
        let injected = try await report(store, query { $0.sessionID = "s1' OR '1'='1" })
        XCTAssertEqual(injected, [])
        let wildcard = try await report(store, query { $0.thread = "%" })
        XCTAssertEqual(wildcard, [])
        let rootWildcard = try await report(store, query { $0.project = .root("/p/%") })
        XCTAssertEqual(rootWildcard, [])
    }

    // MARK: Rules 1 and 4: sources and keys

    /// Model "opus": recorded under effort high (n=1), effort low (n=2)
    /// and without effort (n=4); unreported n=8.
    private func mixedSourcesStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(store, session: "r", model: "opus", effort: "high", thread: "main", 1, atMs: baseMs)
        try await record(store, session: "r", model: "opus", effort: "low", thread: "main", 2, atMs: baseMs + 60_000)
        try await record(store, session: "r", model: "opus", thread: "main", 4, atMs: baseMs + 120_000)
        try await addUnreported(store, session: "u", shortfall: ["opus": amounts(8)], atNs: u1Ns)
        return store
    }

    func testUnreportedRowStaysApartFromARecordedRowWithTheSameNilEffort() async throws {
        let store = try await mixedSourcesStore()
        let rows = try await report(store, query([.model, .effort]))
        XCTAssertEqual(rows, [
            row(["opus", nil], 4, last: baseMs + 120_000),
            row(["opus", nil], unreported: true, 8, last: u1Ms),
            row(["opus", "high"], 1, last: baseMs),
            row(["opus", "low"], 2, last: baseMs + 60_000),
        ])
    }

    func testGroupByModelGivesOneRecordedAndOneUnreportedRow() async throws {
        let store = try await mixedSourcesStore()
        let rows = try await report(store, query([.model]))
        XCTAssertEqual(rows, [
            row(["opus"], 7, last: baseMs + 120_000),
            row(["opus"], unreported: true, 8, last: u1Ms),
        ])
    }

    func testEmptyGroupByOverMixedSourcesGivesTwoRows() async throws {
        let store = try await mixedSourcesStore()
        let rows = try await report(store, query())
        XCTAssertEqual(rows, [
            row([], 7, last: baseMs + 120_000),
            row([], unreported: true, 8, last: u1Ms),
        ])
    }

    func testEveryGroupingAddsUpToTheSameTotal() async throws {
        let store = try await mixedSourcesStore()
        let groupings: [[Dimension]] = [
            [], [.model], [.model, .effort], [.effort, .thread, .agentType], [.day], [.project], [.session],
        ]
        for groupBy in groupings {
            let rows = try await report(store, query(groupBy))
            XCTAssertEqual(sum(rows), amounts(15), "rows of \(groupBy) add up to everything stored")
            XCTAssertEqual(sum(rows.filter(\.isUnreported)), amounts(8), "unreported part of \(groupBy)")
        }
    }

    // MARK: Rule 5: no match, no row

    func testEmptyStoreGivesNoRowForAnyGrouping() async throws {
        let store = try openStore()
        for groupBy in [[], [.model], [.day], [.project, .session]] as [[Dimension]] {
            let rows = try await report(store, query(groupBy))
            XCTAssertEqual(rows, [], "grouping \(groupBy)")
        }
    }

    func testFiltersMatchingNothingGiveNoRow() async throws {
        let store = try await standardStore()
        let unknownSession = try await report(store, query { $0.sessionID = "nobody" })
        XCTAssertEqual(unknownSession, [])
        let unknownRoot = try await report(store, query([.model]) { $0.project = .root("/nowhere") })
        XCTAssertEqual(unknownRoot, [])
        let future = try await report(store, query([.day]) { $0.sinceMs = nextDayMs + 86_400_000 })
        XCTAssertEqual(future, [])
    }

    func testSessionWithOnlyUnreportedRowsGivesOneFlaggedRow() async throws {
        let store = try await standardStore()
        try await addUnreported(store, session: "only", shortfall: ["haiku": amounts(128)], atNs: u1Ns)
        let rows = try await report(store, query([.model]) { $0.sessionID = "only" })
        XCTAssertEqual(rows, [row(["haiku"], unreported: true, 128, last: u1Ms)])
        let total = try await report(store, query { $0.sessionID = "only" })
        XCTAssertEqual(total, [row([], unreported: true, 128, last: u1Ms)])
    }

    func testRecordedOnlyDataGivesNoUnreportedRow() async throws {
        let store = try openStore()
        try await record(store, session: "r", model: "m", 1, atMs: baseMs)
        let rows = try await report(store, query())
        XCTAssertEqual(rows, [row([], 1, last: baseMs)])
    }

    // MARK: Rule 6: order

    func testNilSortsBeforeStringsAtEveryKeyPosition() async throws {
        let store = try openStore()
        try await record(store, session: "s", model: "m", thread: "main", 1, atMs: baseMs)
        try await record(store, session: "s", model: "m", effort: "high", 2, atMs: baseMs)
        try await record(store, session: "s", model: "m", effort: "high", thread: "main", 4, atMs: baseMs)
        try await record(store, session: "s", model: "m", effort: "high", thread: "main", agent: "Explore", 8, atMs: baseMs)
        try await record(store, session: "s", model: "m", effort: "high", agent: "Explore", 16, atMs: baseMs)
        try await addUnreported(
            store, session: "s", recorded: ["m": amounts(31)], shortfall: ["m": amounts(32)], atNs: u1Ns)

        let rows = try await report(store, query([.effort, .thread, .agentType]))
        XCTAssertEqual(rows, [
            row([nil, nil, nil], unreported: true, 32, last: u1Ms),
            row([nil, "main", nil], 1, last: baseMs),
            row(["high", nil, nil], 2, last: baseMs),
            row(["high", nil, "Explore"], 16, last: baseMs),
            row(["high", "main", nil], 4, last: baseMs),
            row(["high", "main", "Explore"], 8, last: baseMs),
        ])
    }

    func testStringsSortByteWiseAscending() async throws {
        let store = try openStore()
        try await record(store, session: "s", model: "b", 1, atMs: baseMs)
        try await record(store, session: "s", model: "a", 2, atMs: baseMs)
        try await record(store, session: "s", model: "B", 4, atMs: baseMs)
        try await record(store, session: "s", model: "a2", 8, atMs: baseMs)
        let rows = try await report(store, query([.model]))
        XCTAssertEqual(rows.map(\.key), [["B"], ["a"], ["a2"], ["b"]])
    }

    func testRecordedRowComesBeforeTheUnreportedRowOfTheSameKey() async throws {
        let store = try openStore()
        // Inserted so that neither source order nor model order gives the answer by accident.
        try await addUnreported(store, session: "u", shortfall: ["b": amounts(1), "a": amounts(2)], atNs: u1Ns)
        try await record(store, session: "r", model: "b", 4, atMs: baseMs)
        try await record(store, session: "r", model: "a", 8, atMs: baseMs)
        let rows = try await report(store, query([.model]))
        XCTAssertEqual(rows, [
            row(["a"], 8, last: baseMs),
            row(["a"], unreported: true, 2, last: u1Ms),
            row(["b"], 4, last: baseMs),
            row(["b"], unreported: true, 1, last: u1Ms),
        ])
    }

    // MARK: Rule 7: days

    // America/New_York, 2026-03-08 is 23 hours long (EST -05:00 → EDT -04:00)
    // and 2026-11-01 is 25 hours long (EDT → EST).
    /// 2026-03-07 23:59 EST = 2026-03-08T04:59:00Z
    private let ny0307End: Int64 = 1_772_945_940_000
    /// 2026-03-08 00:00 EST = 2026-03-08T05:00:00Z
    private let ny0308Start: Int64 = 1_772_946_000_000
    /// 2026-03-08 23:59 EDT = 2026-03-09T03:59:00Z
    private let ny0308End: Int64 = 1_773_028_740_000
    /// 2026-03-09 00:00 EDT = 2026-03-09T04:00:00Z
    private let ny0309Start: Int64 = 1_773_028_800_000
    /// 2026-10-31 23:59 EDT = 2026-11-01T03:59:00Z
    private let ny1031End: Int64 = 1_793_505_540_000
    /// 2026-11-01 00:00 EDT = 2026-11-01T04:00:00Z
    private let ny1101Start: Int64 = 1_793_505_600_000
    /// 2026-11-01 23:59 EST = 2026-11-02T04:59:00Z
    private let ny1101End: Int64 = 1_793_595_540_000
    /// 2026-11-02 00:00 EST = 2026-11-02T05:00:00Z
    private let ny1102Start: Int64 = 1_793_595_600_000
    /// 2026-03-08 23:59:59.999999999 EDT: the last nanosecond of the
    /// 23-hour day; floored to …59.999 it stays on 03-08 (rounded it
    /// would be 2026-03-09 00:00).
    private let ny0308LastNs: Int64 = 1_773_028_799_999_999_999
    private let ny0308LastMs: Int64 = 1_773_028_799_999

    private func dstStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(store, session: "s", model: "m", 2, atMs: ny0307End)
        try await record(store, session: "s", model: "m", 1, atMs: ny0308Start)
        try await record(store, session: "s", model: "m", 4, atMs: ny0308End)
        try await record(store, session: "s", model: "m", 8, atMs: ny0309Start)
        try await record(store, session: "s", model: "m", 32, atMs: ny1031End)
        try await record(store, session: "s", model: "m", 16, atMs: ny1101Start)
        try await record(store, session: "s", model: "m", 64, atMs: ny1101End)
        try await record(store, session: "s", model: "m", 128, atMs: ny1102Start)
        try await addUnreported(store, session: "u", shortfall: ["m": amounts(256)], atNs: ny0308LastNs)
        return store
    }

    private var dstExpected: [UsageTokenRow] {
        [
            row(["2026-03-07"], 2, last: ny0307End),
            row(["2026-03-08"], 5, last: ny0308End),
            row(["2026-03-08"], unreported: true, 256, last: ny0308LastMs),
            row(["2026-03-09"], 8, last: ny0309Start),
            row(["2026-10-31"], 32, last: ny1031End),
            row(["2026-11-01"], 80, last: ny1101End),
            row(["2026-11-02"], 128, last: ny1102Start),
        ]
    }

    func testDaysAroundDSTTransitionsAreExactLocalDays() async throws {
        let store = try await dstStore()
        let rows = try await report(store, query([.day]), calendar: try calendar("America/New_York"))
        XCTAssertEqual(rows, dstExpected)
    }

    func testTwentyThreeHourDayIntervalAsFilterSelectsExactlyThatDay() async throws {
        let store = try await dstStore()
        let rows = try await report(store, query([.day]) {
            $0.sinceMs = ny0308Start
            $0.untilMs = ny0309Start
        }, calendar: try calendar("America/New_York"))
        XCTAssertEqual(rows, [
            row(["2026-03-08"], 5, last: ny0308End),
            row(["2026-03-08"], unreported: true, 256, last: ny0308LastMs),
        ])
    }

    func testTwentyFiveHourDayIntervalAsFilterSelectsExactlyThatDay() async throws {
        let store = try await dstStore()
        let rows = try await report(store, query([.day]) {
            $0.sinceMs = ny1101Start
            $0.untilMs = ny1102Start
        }, calendar: try calendar("America/New_York"))
        XCTAssertEqual(rows, [row(["2026-11-01"], 80, last: ny1101End)])
    }

    func testOnlyTheCalendarsTimeZoneMattersForDayLabels() async throws {
        let store = try await dstStore()
        for system in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura] {
            let rows = try await report(
                store, query([.day]), calendar: try calendar("America/New_York", system: system))
            XCTAssertEqual(rows, dstExpected, "calendar \(system)")
        }
    }

    func testThirtyMinuteOffsetZone() async throws {
        let store = try openStore()
        // Asia/Kolkata (+05:30): 2026-10-01 23:59 = 2026-10-01T18:29:00Z,
        // 2026-10-02 00:00 = 2026-10-01T18:30:00Z.
        try await record(store, session: "s", model: "m", 2, atMs: 1_790_879_340_000)
        try await record(store, session: "s", model: "m", 1, atMs: 1_790_879_400_000)
        let rows = try await report(store, query([.day]), calendar: try calendar("Asia/Kolkata"))
        XCTAssertEqual(rows, [
            row(["2026-10-01"], 2, last: 1_790_879_340_000),
            row(["2026-10-02"], 1, last: 1_790_879_400_000),
        ])
    }

    func testFortyFiveMinuteOffsetZone() async throws {
        let store = try openStore()
        // Asia/Kathmandu (+05:45): 2026-10-01 23:59 = 2026-10-01T18:14:00Z,
        // 2026-10-02 00:00 = 2026-10-01T18:15:00Z.
        try await record(store, session: "s", model: "m", 2, atMs: 1_790_878_440_000)
        try await record(store, session: "s", model: "m", 1, atMs: 1_790_878_500_000)
        let rows = try await report(store, query([.day]), calendar: try calendar("Asia/Kathmandu"))
        XCTAssertEqual(rows, [
            row(["2026-10-01"], 2, last: 1_790_878_440_000),
            row(["2026-10-02"], 1, last: 1_790_878_500_000),
        ])
    }

    func testDayFilterSplitsOneSessionAcrossTwoDays() async throws {
        let store = try openStore()
        // America/New_York (EDT -04:00): 2026-10-02 23:59 = 2026-10-03T03:59:00Z,
        // 2026-10-03 00:00 = 2026-10-03T04:00:00Z, 2026-10-04 00:00 = 2026-10-04T04:00:00Z.
        let lateMs: Int64 = 1_790_999_940_000
        let dayStartMs: Int64 = 1_791_000_000_000
        let nextDayStartMs: Int64 = 1_791_086_400_000
        try await record(store, session: "s", model: "m", 1, atMs: lateMs)
        try await record(store, session: "s", model: "m", 2, atMs: dayStartMs)
        try await addUnreported(
            store, session: "s", recorded: ["m": amounts(3)], shortfall: ["m": amounts(4)],
            atNs: ns(dayStartMs + 30_000))
        let newYork = try calendar("America/New_York")

        let all = try await report(store, query([.session, .day]), calendar: newYork)
        XCTAssertEqual(all, [
            row(["s", "2026-10-02"], 1, last: lateMs),
            row(["s", "2026-10-03"], 2, last: dayStartMs),
            row(["s", "2026-10-03"], unreported: true, 4, last: dayStartMs + 30_000),
        ])
        let secondDay = try await report(store, query([.session, .day]) {
            $0.sinceMs = dayStartMs
            $0.untilMs = nextDayStartMs
        }, calendar: newYork)
        XCTAssertEqual(secondDay, [
            row(["s", "2026-10-03"], 2, last: dayStartMs),
            row(["s", "2026-10-03"], unreported: true, 4, last: dayStartMs + 30_000),
        ])
        let firstDayOnly = try await report(store, query([.session]) { $0.untilMs = dayStartMs }, calendar: newYork)
        XCTAssertEqual(firstDayOnly, [row(["s"], 1, last: lateMs)])
    }

    func testDayGroupingWithBoundsInsideADayClipsToTheBounds() async throws {
        let store = try await dstStore()
        // 03-08 from 00:01 EST on: excludes the point at 00:00 EST (n=1).
        let rows = try await report(store, query([.day]) {
            $0.sinceMs = ny0308Start + 60_000
            $0.untilMs = ny0309Start
        }, calendar: try calendar("America/New_York"))
        XCTAssertEqual(rows, [
            row(["2026-03-08"], 4, last: ny0308End),
            row(["2026-03-08"], unreported: true, 256, last: ny0308LastMs),
        ])
    }

    // MARK: Rule 8: errors

    func testRepeatedDimensionThrowsInvalidQuery() async throws {
        let store = try await standardStore()
        for groupBy in [[.model, .model], [.day, .session, .day]] as [[Dimension]] {
            do {
                _ = try await report(store, query(groupBy))
                XCTFail("\(groupBy) must throw")
            } catch let error as UsageStoreError {
                XCTAssertEqual(error, .invalidQuery)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRepeatedDimensionThrowsEvenOnAnEmptyStore() async throws {
        let store = try openStore()
        do {
            _ = try await report(store, query([.thread, .thread]))
            XCTFail("must throw")
        } catch let error as UsageStoreError {
            XCTAssertEqual(error, .invalidQuery)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRecordedSumBeyondInt64ThrowsInsteadOfWrapping() async throws {
        let store = try openStore()
        let huge = UsageTokenTotals(input: Int64.max, output: 0, cacheRead: 0, cacheCreation: 0)
        try await record(store, session: "a", model: "m", huge, receivedAtNs: ns(baseMs))
        try await record(store, session: "b", model: "m", huge, receivedAtNs: ns(baseMs))
        let points = try await store.pointRows()
        XCTAssertEqual(points.map(\.inputTokens), [Int64.max, Int64.max], "Fixture error: two saturated points")

        do {
            let rows = try await report(store, query([.model]))
            XCTFail("must throw, got \(rows)")
        } catch {}
        do {
            let rows = try await report(store, query())
            XCTFail("must throw, got \(rows)")
        } catch {}
        // One of them alone is representable.
        let single = try await report(store, query { $0.sessionID = "a" })
        XCTAssertEqual(single.map(\.inputTokens), [Int64.max])
    }

    func testUnreportedSumBeyondInt64ThrowsInsteadOfWrapping() async throws {
        let store = try openStore()
        let huge = UsageTokenTotals(input: 0, output: Int64.max, cacheRead: 0, cacheCreation: 0)
        try await addUnreported(store, session: "a", shortfall: ["m": huge], atNs: u1Ns)
        try await addUnreported(store, session: "b", shortfall: ["m": huge], atNs: u2Ns)
        do {
            let rows = try await report(store, query([.model]))
            XCTFail("must throw, got \(rows)")
        } catch {}
    }
}

// MARK: - Store entry points

final class UsageStoreTokenReportTests: UsageTokenGoldTestSupport {

    /// 2026-10-02T10:00:00.000Z
    private let baseMs: Int64 = 1_790_935_200_000
    /// 2026-10-02T10:01:30.123456789Z
    private let unreportedNs: Int64 = 1_790_935_290_123_456_789

    private func seededStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(store, session: "s1", model: "opus", effort: "high", thread: "main", 1, atMs: baseMs)
        try await record(store, session: "s2", model: "sonnet", thread: "auxiliary", 2, atMs: baseMs + 60_000)
        try await addUnreported(store, session: "s3", shortfall: ["opus": amounts(4)], atNs: unreportedNs)
        try await setRoot(store, "/p/a", session: "s1")
        return store
    }

    func testTokenReportsAnswersInQueryOrderEqualToSingleReports() async throws {
        let store = try await seededStore()
        let utc = try utc()
        let queries = [
            query([.session]),
            query([.model]) { $0.thread = "main" },
            query(),
            query([.project, .day]),
            query { $0.sessionID = "nobody" },
        ]
        let batch = try await store.tokenReports(queries, calendar: utc)
        var singles: [[UsageTokenRow]] = []
        for query in queries {
            singles.append(try await store.tokenReport(query, calendar: utc))
        }
        XCTAssertEqual(batch, singles)
        XCTAssertEqual(batch.count, 5)
        XCTAssertEqual(try element(batch, at: 2), [
            row([], 3, last: baseMs + 60_000),
            row([], unreported: true, 4, last: 1_790_935_290_123),
        ])
        XCTAssertEqual(try element(batch, at: 4), [])
    }

    func testTokenReportsWithNoQueriesGivesNoAnswers() async throws {
        let store = try await seededStore()
        let batch = try await store.tokenReports([], calendar: try utc())
        XCTAssertEqual(batch, [])
    }

    func testTokenReportsFailsWhollyWhenOneQueryIsInvalid() async throws {
        let store = try await seededStore()
        do {
            _ = try await store.tokenReports([query([.model]), query([.model, .model])], calendar: try utc())
            XCTFail("must throw")
        } catch let error as UsageStoreError {
            XCTAssertEqual(error, .invalidQuery)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testClosedStoreThrowsClosedFromTokenReport() async throws {
        let store = try await seededStore()
        await store.close()
        do {
            _ = try await store.tokenReport(query([.model]), calendar: try utc())
            XCTFail("must throw")
        } catch let error as UsageStoreError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testClosedStoreThrowsClosedFromTokenReports() async throws {
        let store = try await seededStore()
        await store.close()
        do {
            _ = try await store.tokenReports([query([.model])], calendar: try utc())
            XCTFail("must throw")
        } catch let error as UsageStoreError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

// MARK: - Real data (fixture run2)

final class UsageTokenGoldFixtureTests: UsageTokenGoldTestSupport {

    private typealias Fixtures = UsageTelemetryFixtures

    /// Before run2's process start (1_791_183_586.797 s): tracking covers the capture.
    private static let beforeCaptures = Date(timeIntervalSince1970: 1_791_183_400)
    private static let sessionID = "22222222-2222-4222-8222-222222222222"
    private static let sonnet = "claude-sonnet-5-5"
    private static let fable = "claude-fable-5-1"
    private static let haiku = "claude-haiku-4-5-20251001"

    private struct StubResolver: ProjectRootResolving {
        func projectRoot(forCWD cwd: String) async throws -> String? { nil }
    }

    /// Applies the first `count` of run2's exports (all when nil), each
    /// received at its own collection time; returns those times.
    @discardableResult
    private func applyRun2(_ store: UsageStore, count: Int? = nil) async throws -> [Int64] {
        let bodies = try Fixtures.exports(run: "run2")
        XCTAssertEqual(bodies.count, 14, "Fixture error: run2 has 14 exports")
        var times: [Int64] = []
        for body in bodies.prefix(count ?? bodies.count) {
            let batch = try OTLPTokenUsageDecoder.decode(body)
            let receivedAtNs = try Fixtures.collectionTimeNs(of: body)
            let outcome = try await store.apply(
                samples: batch.samples, processStarts: batch.processStarts, receivedAtNs: receivedAtNs)
            XCTAssertFalse(outcome.ignored, "Fixture error: a run2 export was ignored")
            times.append(receivedAtNs)
        }
        return times
    }

    private func totals(_ row: UsageTokenRow) -> UsageTokenTotals {
        UsageTokenTotals(
            input: row.inputTokens, output: row.outputTokens,
            cacheRead: row.cacheReadTokens, cacheCreation: row.cacheCreationTokens)
    }

    private func expectedCostState() throws -> [String: UsageTokenTotals] {
        let expected = try Fixtures.expectedTotals(run: "run2")
        var result: [String: UsageTokenTotals] = [:]
        for (model, kinds) in expected {
            result[model] = UsageTokenTotals(
                input: kinds["input"] ?? -1, output: kinds["output"] ?? -1,
                cacheRead: kinds["cacheRead"] ?? -1, cacheCreation: kinds["cacheCreation"] ?? -1)
        }
        return result
    }

    /// Every row's time is a minute start between the first and the last
    /// export's receive minute (points are dated at minute starts).
    private func assertMinuteDated(_ rows: [UsageTokenRow], receivedAtNs times: [Int64]) throws {
        let first = try XCTUnwrap(times.min()) / 60_000_000_000 * 60_000 // ns → minute start in ms; bounded by real times
        let last = try XCTUnwrap(times.max()) / 60_000_000_000 * 60_000
        for row in rows where !row.isUnreported {
            XCTAssertEqual(row.lastTimestampMs % 60_000, 0, "\(row.key) is dated at a minute start")
            XCTAssertTrue((first...last).contains(row.lastTimestampMs), "\(row.key) within the capture's minutes")
        }
    }

    func testRun2ByModelEqualsCostStateForAllFourColumns() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let times = try await applyRun2(store)
        let rows = try await report(store, query([.model]))

        XCTAssertEqual(rows.map(\.key), [[Self.fable], [Self.haiku], [Self.sonnet]])
        XCTAssertFalse(rows.contains(where: \.isUnreported))
        var byModel: [String: UsageTokenTotals] = [:]
        for row in rows {
            byModel[row.key.first.flatMap { $0 } ?? "?"] = totals(row)
        }
        XCTAssertEqual(byModel, try expectedCostState())
        try assertMinuteDated(rows, receivedAtNs: times)
    }

    func testRun2ByAllLabelDimensionsShowsAdvisorAuxiliaryAndSubagentRows() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let times = try await applyRun2(store)
        let rows = try await report(store, query([.model, .effort, .thread, .agentType]))

        // Last cumulative value per series of the capture, summed per label
        // group (computed from the export files with a separate script).
        let expected: [([String?], UsageTokenTotals)] = [
            ([Self.fable, nil, "main", nil],
             UsageTokenTotals(input: 41_788, output: 1_085, cacheRead: 0, cacheCreation: 0)),
            ([Self.haiku, nil, "auxiliary", nil],
             UsageTokenTotals(input: 944, output: 11, cacheRead: 0, cacheCreation: 0)),
            ([Self.sonnet, "medium", "auxiliary", nil],
             UsageTokenTotals(input: 1_554, output: 29, cacheRead: 142_696, cacheCreation: 55)),
            ([Self.sonnet, "medium", "main", nil],
             UsageTokenTotals(input: 14, output: 546, cacheRead: 174_561, cacheCreation: 49_130)),
            ([Self.sonnet, "medium", "subagent", "Explore"],
             UsageTokenTotals(input: 10, output: 1_289, cacheRead: 57_207, cacheCreation: 42_192)),
        ]
        XCTAssertEqual(rows.map(\.key), expected.map(\.0))
        XCTAssertEqual(rows.map { totals($0) }, expected.map(\.1))
        XCTAssertFalse(rows.contains(where: \.isUnreported))

        let all = try XCTUnwrap(sum(rows))
        let costState = try expectedCostState()
        var costTotal = UsageTokenTotals()
        for model in costState.values {
            for kind in UsageTokenKind.allCases {
                let (value, overflow) = costTotal[kind].addingReportingOverflow(model[kind])
                XCTAssertFalse(overflow)
                costTotal[kind] = overflow ? 0 : value
            }
        }
        XCTAssertEqual(all, costTotal, "the label rows add up to the cost-state totals")
        try assertMinuteDated(rows, receivedAtNs: times)
    }

    func testRun2FirstSevenExportsReconciledSplitsSonnetIntoRecordedAndUnreported() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let times = try await applyRun2(store, count: 7)

        // The skeleton as the session's transcript under a canonical projects root.
        let rootURL = try temporaryDirectory().appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = rootURL.appendingPathComponent("-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        guard let resolved = realpath(rootURL.path, nil) else { return XCTFail("Fixture error: realpath") }
        let root = String(cString: resolved)
        free(resolved)
        let skeleton = Fixtures.directory
            .appendingPathComponent("run2", isDirectory: true)
            .appendingPathComponent("transcript-skeleton.jsonl")
        try Data(contentsOf: skeleton).write(
            to: URL(fileURLWithPath: root)
                .appendingPathComponent("-fixture-project", isDirectory: true)
                .appendingPathComponent("\(Self.sessionID).jsonl"))

        let reader = UsageRunLogReader(
            store: store, resolver: StubResolver(), projectsRoot: { root }, directoryState: { _ in .present })
        let read = try await reader.read(sessionID: Self.sessionID, resolveProjectRoot: false)
        XCTAssertEqual(read.status, .read, "Fixture error: the skeleton was not read")
        let outcome = try await store.reconcile(session: Self.sessionID)
        XCTAssertEqual(outcome.firstSequence, 1, "Fixture error: run 1 was not reconciled")

        let rows = try await report(store, query([.model]))
        XCTAssertEqual(rows.map(\.key), [[Self.fable], [Self.haiku], [Self.sonnet], [Self.sonnet]])
        XCTAssertEqual(rows.map(\.isUnreported), [false, false, false, true])
        XCTAssertEqual(rows.map { totals($0) }, [
            UsageTokenTotals(input: 41_788, output: 1_085, cacheRead: 0, cacheCreation: 0),
            UsageTokenTotals(input: 944, output: 11, cacheRead: 0, cacheCreation: 0),
            UsageTokenTotals(input: 1_056, output: 1_844, cacheRead: 278_420, cacheCreation: 90_220),
            UsageTokenTotals(input: 522, output: 20, cacheRead: 96_044, cacheCreation: 1_157),
        ])
        // The run's end: the latest timestamp among the skeleton's activity
        // lines, 2026-10-05T07:00:22.229Z.
        XCTAssertEqual(try element(rows, at: 3).lastTimestampMs, 1_791_183_622_229)
        try assertMinuteDated(rows, receivedAtNs: times)

        let sonnetRows = rows.filter { $0.key == [Self.sonnet] }
        XCTAssertEqual(sum(sonnetRows), try expectedCostState()[Self.sonnet], "recorded + unreported = cost-state")
        var byModel: [String: UsageTokenTotals] = [:]
        for row in rows {
            let model = row.key.first.flatMap { $0 } ?? "?"
            let existing = byModel[model] ?? UsageTokenTotals()
            byModel[model] = sum([
                self.row([], existing, last: 0), self.row([], totals(row), last: 0),
            ])
        }
        XCTAssertEqual(byModel, try expectedCostState(), "both sources together equal cost-state per model")
    }
}

// MARK: - Review round 1: extreme bounds, missing indexes, byte order

final class UsageTokenGoldEdgeTests: UsageTokenGoldTestSupport {

    /// 2026-10-02T10:00:00.000Z
    private let baseMs: Int64 = 1_790_935_200_000
    /// 2026-10-02T10:01:30.123456789Z → 10:01:30.123
    private let lowUnreportedNs: Int64 = 1_790_935_290_123_456_789
    private let lowUnreportedMs: Int64 = 1_790_935_290_123
    /// Int64.max / 1_000_000 = 9_223_372_036_854: the millisecond time of
    /// an unreported row stored at time_ns = Int64.max (floor).
    private let k: Int64 = 9_223_372_036_854
    /// A point received at Int64.max ns: minute 153_722_867 (floor of
    /// 9_223_372_036_854_775_807 / 60_000_000_000), dated
    /// 153_722_867 × 60_000 = 9_223_372_020_000 ms.
    private let highPointMs: Int64 = 9_223_372_020_000

    /// "lo": a point (n=1) at base and an unreported row (n=32) at
    /// lowUnreported; "hiR": a point (n=2) received at Int64.max ns;
    /// "hiU": an unreported row (n=4) at Int64.max ns.
    private func extremeStore() async throws -> UsageStore {
        let store = try openStore()
        try await record(store, session: "lo", model: "m", 1, atMs: baseMs)
        try await addUnreported(
            store, session: "lo", recorded: ["m": amounts(1)], shortfall: ["m": amounts(32)], atNs: lowUnreportedNs)
        try await record(store, session: "hiR", model: "m", amounts(2), receivedAtNs: Int64.max)
        try await addUnreported(store, session: "hiU", shortfall: ["m": amounts(4)], atNs: Int64.max)
        return store
    }

    private var loR: UsageTokenRow { row(["lo"], 1, last: baseMs) }
    private var loU: UsageTokenRow { row(["lo"], unreported: true, 32, last: lowUnreportedMs) }
    private var hiR: UsageTokenRow { row(["hiR"], 2, last: highPointMs) }
    private var hiU: UsageTokenRow { row(["hiU"], unreported: true, 4, last: k) }

    func testExtremeRowsAreDatedPerRuleTwo() async throws {
        let store = try await extremeStore()
        let rows = try await report(store, query([.session]))
        XCTAssertEqual(rows, [hiR, hiU, loR, loU])
    }

    func testSinceAtInt64Extremes() async throws {
        let store = try await extremeStore()
        let cases: [(Int64, [UsageTokenRow])] = [
            (Int64.min, [hiR, hiU, loR, loU]),
            (Int64.min + 1, [hiR, hiU, loR, loU]),
            (k - 1, [hiU]),
            (k, [hiU]),
            (k + 1, []),
            (Int64.max, []),
        ]
        for (since, expected) in cases {
            let rows = try await report(store, query([.session]) { $0.sinceMs = since })
            XCTAssertEqual(rows, expected, "sinceMs = \(since)")
        }
    }

    func testUntilAtInt64Extremes() async throws {
        let store = try await extremeStore()
        let cases: [(Int64, [UsageTokenRow])] = [
            (Int64.min, []),
            (Int64.min + 1, []),
            (k - 1, [hiR, loR, loU]),
            (k, [hiR, loR, loU]),
            (k + 1, [hiR, hiU, loR, loU]),
            (Int64.max, [hiR, hiU, loR, loU]),
        ]
        for (until, expected) in cases {
            let rows = try await report(store, query([.session]) { $0.untilMs = until })
            XCTAssertEqual(rows, expected, "untilMs = \(until)")
        }
    }

    func testBothBoundsAtTheExtremesSelectEverything() async throws {
        let store = try await extremeStore()
        let rows = try await report(store, query([.session]) {
            $0.sinceMs = Int64.min
            $0.untilMs = Int64.max
        })
        XCTAssertEqual(rows, [hiR, hiU, loR, loU])
    }

    func testDayGroupingWithSinceAtInt64Min() async throws {
        let store = try await extremeStore()
        let rows = try await report(store, query([.day]) {
            $0.sinceMs = Int64.min
            $0.sessionID = "lo"
        })
        XCTAssertEqual(rows, [
            row(["2026-10-02"], 1, last: baseMs),
            row(["2026-10-02"], unreported: true, 32, last: lowUnreportedMs),
        ])
    }

    // MARK: Rule 10

    private func execute(_ sql: String, at url: URL) -> Bool {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    func testMissingIndexesDoNotMoveTheDatabaseAside() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("store", isDirectory: true)
        let database = directory.appendingPathComponent("usage.sqlite")
        let first = try openStore()
        try await record(first, session: "s", model: "m", 1, atMs: baseMs)
        try await addUnreported(
            first, session: "s", recorded: ["m": amounts(1)], shortfall: ["m": amounts(2)], atNs: lowUnreportedNs)
        await first.close()

        XCTAssertTrue(
            execute("DROP INDEX usage_points_minute; DROP INDEX usage_unreported_time;", at: database),
            "Fixture error: the two indexes must exist and be droppable")

        let reopened = try openStore()
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("usage.sqlite.corrupt-") }
        XCTAssertEqual(siblings, [], "a missing index must not move the database aside")
        let rows = try await report(reopened, query([.session]))
        XCTAssertEqual(rows, [
            row(["s"], 1, last: baseMs),
            row(["s"], unreported: true, 2, last: lowUnreportedMs),
        ])
        let stored = try await reopened.unreportedRows()
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: Rule 6: strings by UTF-8 bytes

    /// U+00E9 (bytes C3 A9) and "e" + U+0301 (bytes 65 CC 81): the same
    /// text in NFC and NFD, two different byte strings.
    private let nfc = "caf\u{E9}"
    private let nfd = "cafe\u{301}"

    func testCanonicallyEquivalentKeysAreTwoRowsInByteOrderOnEveryCall() async throws {
        let store = try openStore()
        try await record(store, session: nfc, model: "m", 1, atMs: baseMs)
        try await record(store, session: nfd, model: "m", 2, atMs: baseMs)
        for attempt in 0..<20 {
            let rows = try await report(store, query([.session]))
            XCTAssertEqual(rows.count, 2, "attempt \(attempt)")
            // Compared by bytes: Swift's == treats the two keys as equal.
            XCTAssertEqual(
                rows.map { $0.key.map { Array(($0 ?? "").utf8) } },
                [[Array(nfd.utf8)], [Array(nfc.utf8)]],
                "attempt \(attempt): NFD (65 …) before NFC (C3 …)")
            XCTAssertEqual(rows.map(\.inputTokens), [2, 1], "attempt \(attempt)")
        }
    }

    func testStringsAreOrderedByBytesWhereSwiftOrderDiffers() async throws {
        // "e" + U+0301 (65 CC 81) vs "f" (66): bytes put the first one first,
        // Swift's `<` (which compares the NFC form, U+00E9 > "f") the other way.
        let store = try openStore()
        try await record(store, session: "f", model: "m", 1, atMs: baseMs)
        try await record(store, session: "e\u{301}", model: "m", 2, atMs: baseMs)
        let rows = try await report(store, query([.session]))
        XCTAssertEqual(
            rows.map { $0.key.map { Array(($0 ?? "").utf8) } },
            [[Array("e\u{301}".utf8)], [Array("f".utf8)]])
        XCTAssertEqual(rows.map(\.inputTokens), [2, 1])
    }
}
