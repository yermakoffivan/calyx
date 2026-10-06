//
//  UsageStoreReconcileTests.swift
//  CalyxTests
//
//  Pins UsageStore.reconcile(session:) and unreportedRows(): the input is
//  assembled from the session's OWN stored state only (run log, points
//  summed over label groups per minute and model, active process starts,
//  the smallest first_heard_ns of its series, tracked_from); the session's
//  rows from `firstSequence` on are replaced and earlier rows are never
//  touched; a nil `firstSequence` changes nothing; resetTracking keeps the
//  rows and deleteAll removes them; a version-2 file lacking the table is
//  moved aside.
//
//  Every database lives in a per-test temporary directory removed in
//  tearDown after every opened store is closed. The clock is injected;
//  run logs are saved directly (no transcript is read here).
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageStoreReconcileTests: XCTestCase {

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreReconcileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
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

    // MARK: - Times and builders

    /// Minute `m` of these tests is minute `baseMinute + m` since the epoch.
    private static let baseMinute: Int64 = 29_853_100
    private static let sonnet = "claude-sonnet-5-5"
    private static let opus = "claude-opus-5-5[1m]"
    private static let sessionA = "session-a"
    private static let sessionB = "session-b"

    private func ns(_ minute: Int64, _ second: Int64 = 0) -> Int64 {
        (Self.baseMinute + minute) * 60_000_000_000 + second * 1_000_000_000
    }

    /// The start of test minute `minute` as a clock value (whole seconds, exact in a Double).
    private func date(minute: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval((Self.baseMinute + minute) * 60))
    }

    private func tt(_ input: Int64 = 0, _ output: Int64 = 0, _ cacheRead: Int64 = 0, _ cacheCreation: Int64 = 0)
        -> UsageTokenTotals {
        UsageTokenTotals(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private func storeDirectory() throws -> URL {
        try XCTUnwrap(tempDirectory).appendingPathComponent("store", isDirectory: true)
    }

    private func databaseURL() throws -> URL {
        try storeDirectory().appendingPathComponent("usage.sqlite")
    }

    /// Default clock: the epoch, so tracking starts at 0, before every time used here.
    private func openStore(clock: UsageTestClock = UsageTestClock(Date(timeIntervalSince1970: 0))) throws -> UsageStore {
        let store = try UsageStore(directory: try storeDirectory(), now: clock.now)
        openedStores.append(store)
        return store
    }

    private func seriesID(_ number: Int) -> String {
        String(format: "%064x", number)
    }

    private func sample(
        session: String = UsageStoreReconcileTests.sessionA, series: Int = 1, startNs: Int64 = 1_000,
        timeNs: Int64 = 2_000, kind: UsageTokenKind = .input, value: Int64,
        model: String = UsageStoreReconcileTests.sonnet, effort: String? = "medium"
    ) -> UsageSeriesSample {
        UsageSeriesSample(
            sessionID: session, seriesID: seriesID(series), startNs: startNs, timeNs: timeNs, kind: kind,
            value: value, model: model, effort: effort, thread: "main", agent: nil)
    }

    private func process(_ session: String, _ startNs: Int64, _ type: String?) -> UsageProcessStart {
        UsageProcessStart(sessionID: session, startNs: startNs, startType: type)
    }

    /// Applies one export received at `receivedAtNs`; fails the test if it was ignored.
    private func send(
        _ samples: [UsageSeriesSample], start: UsageProcessStart, at receivedAtNs: Int64, to store: UsageStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let outcome = try await store.apply(samples: samples, processStarts: [start], receivedAtNs: receivedAtNs)
        XCTAssertFalse(outcome.ignored, "Fixture error: the export was ignored", file: file, line: line)
    }

    private func saveRuns(_ runs: [UsageRun], session: String, to store: UsageStore) async throws {
        let file = UsageRunLogFile(
            path: "/fixture/project/\(session).jsonl", checkpoint: TranscriptCheckpoint(inode: 1, offset: 1))
        try await store.saveRunLog(UsageRunLog(runs: runs), file: file, forSession: session)
    }

    private func stored(_ session: String, _ sequence: Int, _ timeNs: Int64, _ totals: UsageTokenTotals,
                        model: String = UsageStoreReconcileTests.sonnet) -> UsageUnreportedStoredRow {
        UsageUnreportedStoredRow(sessionID: session, sequence: sequence, timeNs: timeNs, model: model, totals: totals)
    }

    private func row(_ sequence: Int, _ timeNs: Int64, _ totals: UsageTokenTotals,
                     model: String = UsageStoreReconcileTests.sonnet) -> UsageUnreportedRow {
        UsageUnreportedRow(sequence: sequence, timeNs: timeNs, model: model, totals: totals)
    }

    // MARK: - One run, input only
    //
    // Session A: one run, minutes 0-2, cumulative sonnet input 100. Its
    // fresh process started at minute -1; 90 input received in minute 1.

    private var oneRunEnd: Int64 { ns(2, 30) }

    private func storeWithOneRun(heardInput: Int64 = 90) async throws -> UsageStore {
        let store = try openStore()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(100)])],
                           session: Self.sessionA, to: store)
        try await send([sample(value: heardInput)], start: process(Self.sessionA, ns(-1), "fresh"), at: ns(1), to: store)
        return store
    }

    func test_reconcile_storesTheRows_withTheSessionAndTheRunsEnd() async throws {
        let store = try await storeWithOneRun()
        let outcome = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [row(1, oneRunEnd, tt(10))], surplus: [:]))
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [stored(Self.sessionA, 1, oneRunEnd, tt(10))])
    }

    func test_reconcile_allFourKindsAndABracketedModel_roundTrip() async throws {
        let store = try openStore()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd,
                                     totals: [Self.opus: tt(11, 22, 33, 44)])], session: Self.sessionA, to: store)
        try await send([sample(value: 1, model: Self.opus)], start: process(Self.sessionA, ns(-1), "fresh"),
                       at: ns(1), to: store)
        _ = try await store.reconcile(session: Self.sessionA)
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [stored(Self.sessionA, 1, oneRunEnd, tt(10, 22, 33, 44), model: Self.opus)])
    }

    // MARK: - Input assembly

    func test_inputAssembly_pointsOfAnotherSessionNeverLeakIn() async throws {
        let store = try await storeWithOneRun()
        // Session B: 50 sonnet input in the same minute, from its own process.
        try await send([sample(session: Self.sessionB, series: 2, value: 50)],
                       start: process(Self.sessionB, ns(-1), "fresh"), at: ns(1, 10), to: store)
        let outcome = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(outcome.rows, [row(1, oneRunEnd, tt(10))])
        XCTAssertEqual(outcome.surplus, [:])
    }

    func test_inputAssembly_processStartsOfAnotherSessionNeverLeakIn() async throws {
        let store = try await storeWithOneRun()
        // A `resume` start of session B before A's run ended: if it leaked
        // into A's input, A's only run would be dropped (rule 3).
        try await send([sample(session: Self.sessionB, series: 2, value: 5)],
                       start: process(Self.sessionB, ns(0), "resume"), at: ns(1, 10), to: store)
        let outcome = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(outcome.firstSequence, 1)
        XCTAssertEqual(outcome.rows, [row(1, oneRunEnd, tt(10))])
    }

    func test_inputAssembly_seriesAndStartsOfAnotherSessionGiveNoEvidence() async throws {
        let store = try openStore()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(100)])],
                           session: Self.sessionA, to: store)
        // Session B's process (fresh, before A's end) and its series, first
        // heard inside A's run. A itself is first heard at minute 5, after
        // its run ended, through B's process (a session born inside it).
        let processB = process(Self.sessionB, ns(-1), "fresh")
        try await send([sample(session: Self.sessionB, series: 2, value: 5)], start: processB, at: ns(1), to: store)
        try await send([sample(session: Self.sessionA, series: 1, value: 100)], start: processB, at: ns(5), to: store)

        let outcome = try await store.reconcile(session: Self.sessionA)

        XCTAssertNil(outcome.firstSequence, "A was never heard during its only run")
        XCTAssertEqual(outcome.rows, [])
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    func test_inputAssembly_firstHeardIsTheSmallestAmongTheSessionsSeries() async throws {
        let store = try openStore()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(100, 7)])],
                           session: Self.sessionA, to: store)
        // A has no process start of its own (born inside B's process): its
        // input series is first heard inside the run, its output series
        // only afterwards. The earlier one is the evidence.
        let processB = process(Self.sessionB, ns(-1), "fresh")
        try await send([sample(series: 1, value: 100)], start: processB, at: ns(1), to: store)
        try await send([sample(series: 2, kind: .output, value: 3)], start: processB, at: ns(5), to: store)

        let outcome = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [row(1, oneRunEnd, tt(0, 4))], surplus: [:]))
    }

    func test_inputAssembly_labelGroupsOfOneMinuteAndModel_areSummed() async throws {
        let store = try openStore()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(100)])],
                           session: Self.sessionA, to: store)
        // Two efforts, two point rows in the same minute: 40 + 50 = 90.
        try await send([sample(series: 1, value: 40, effort: "low"), sample(series: 2, value: 50, effort: "high")],
                       start: process(Self.sessionA, ns(-1), "fresh"), at: ns(1), to: store)
        let points = try await store.pointRows()
        XCTAssertEqual(points.count, 2, "Fixture error: two label groups expected")

        let outcome = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(outcome.rows, [row(1, oneRunEnd, tt(10))])
    }

    func test_inputAssembly_usesTrackedFrom() async throws {
        // Tracking starts after the run began: nothing is reconciled.
        let store = try openStore(clock: UsageTestClock(date(minute: 1)))
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(100)])],
                           session: Self.sessionA, to: store)
        try await send([sample(value: 90)], start: process(Self.sessionA, ns(1, 5), "fresh"), at: ns(1, 10), to: store)
        let outcome = try await store.reconcile(session: Self.sessionA)
        XCTAssertNil(outcome.firstSequence)
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    func test_reconcile_sessionWithoutARunLog_isEmpty_andChangesNothing() async throws {
        let store = try await storeWithOneRun()
        _ = try await store.reconcile(session: Self.sessionA)
        let before = try await store.unreportedRows()
        XCTAssertEqual(before, [stored(Self.sessionA, 1, oneRunEnd, tt(10))], "Fixture error")
        try await send([sample(session: Self.sessionB, series: 2, value: 5)],
                       start: process(Self.sessionB, ns(-1), "fresh"), at: ns(1), to: store)

        let outcome = try await store.reconcile(session: Self.sessionB)

        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: nil, rows: [], surplus: [:]))
        let after = try await store.unreportedRows()
        XCTAssertEqual(after, before)
    }

    // MARK: - Replace semantics
    //
    // Session A: three runs, cumulative sonnet input 100 / 300 / 600, in
    // minutes 0-2, 10-12 and 20-22. A fresh process (minute -1) delivered
    // 60 input in minute 1. U1 = 40, U2 = 240, U3 = 540: rows 40, 200, 300.

    private var threeRuns: [UsageRun] {
        [
            UsageRun(sequence: 1, beginNs: ns(0), endNs: ns(2, 30), totals: [Self.sonnet: tt(100)]),
            UsageRun(sequence: 2, beginNs: ns(10), endNs: ns(12, 30), totals: [Self.sonnet: tt(300)]),
            UsageRun(sequence: 3, beginNs: ns(20), endNs: ns(22, 30), totals: [Self.sonnet: tt(600)]),
        ]
    }

    private var threeRunRows: [UsageUnreportedStoredRow] {
        [
            stored(Self.sessionA, 1, ns(2, 30), tt(40)),
            stored(Self.sessionA, 2, ns(12, 30), tt(200)),
            stored(Self.sessionA, 3, ns(22, 30), tt(300)),
        ]
    }

    private func storeWithThreeRuns(clock: UsageTestClock) async throws -> UsageStore {
        let store = try openStore(clock: clock)
        try await saveRuns(threeRuns, session: Self.sessionA, to: store)
        try await send([sample(value: 60)], start: process(Self.sessionA, ns(-1), "fresh"), at: ns(1), to: store)
        let outcome = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(outcome.firstSequence, 1, "Fixture error")
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, threeRunRows, "Fixture error")
        return store
    }

    func test_replace_rowsFromFirstSequenceOnAreReplaced_earlierRowsStay() async throws {
        let clock = UsageTestClock(Date(timeIntervalSince1970: 0))
        let store = try await storeWithThreeRuns(clock: clock)
        // Tracking restarts between run 2's and run 3's begin; a new process
        // (started after that) delivers 250 of run 3 in minute 20.
        clock.set(date(minute: 15))
        try await store.resetTracking()
        try await send([sample(series: 2, startNs: ns(19, 50), value: 250)],
                       start: process(Self.sessionA, ns(19, 50), "resume"), at: ns(20, 10), to: store)

        let outcome = try await store.reconcile(session: Self.sessionA)

        // Run 3 alone; lower bound = minute 12, so the minute-1 point is out:
        // D3 = 300, H3 = 250, row 50.
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 3, rows: [row(3, ns(22, 30), tt(50))], surplus: [:]))
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [
            stored(Self.sessionA, 1, ns(2, 30), tt(40)),
            stored(Self.sessionA, 2, ns(12, 30), tt(200)),
            stored(Self.sessionA, 3, ns(22, 30), tt(50)),
        ])
    }

    func test_replace_aRowNoLongerDue_isDeleted() async throws {
        let store = try await storeWithOneRun()
        _ = try await store.reconcile(session: Self.sessionA)
        try await send([sample(timeNs: 3_000, value: 100)], start: process(Self.sessionA, ns(-1), "fresh"),
                       at: ns(2, 20), to: store)

        let outcome = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    func test_replace_nilFirstSequence_changesNothing() async throws {
        let clock = UsageTestClock(Date(timeIntervalSince1970: 0))
        let store = try await storeWithThreeRuns(clock: clock)
        // Tracking restarts after every run began: no run can be reconciled.
        clock.set(date(minute: 30))
        try await store.resetTracking()
        try await send([sample(series: 2, startNs: ns(30, 5), value: 1)],
                       start: process(Self.sessionA, ns(30, 5), "resume"), at: ns(30, 10), to: store)

        let outcome = try await store.reconcile(session: Self.sessionA)

        XCTAssertNil(outcome.firstSequence)
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, threeRunRows)
    }

    func test_replace_onlyTheReconciledSessionsRowsAreTouched() async throws {
        let store = try await storeWithOneRun()
        try await saveRuns([UsageRun(sequence: 1, beginNs: ns(0), endNs: oneRunEnd, totals: [Self.sonnet: tt(30)])],
                           session: Self.sessionB, to: store)
        try await send([sample(session: Self.sessionB, series: 2, value: 20)],
                       start: process(Self.sessionB, ns(-1), "fresh"), at: ns(1), to: store)
        _ = try await store.reconcile(session: Self.sessionB)
        _ = try await store.reconcile(session: Self.sessionA)
        // A's shortfall is made up; B's row must stay.
        try await send([sample(timeNs: 3_000, value: 100)], start: process(Self.sessionA, ns(-1), "fresh"),
                       at: ns(2, 20), to: store)

        _ = try await store.reconcile(session: Self.sessionA)

        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [stored(Self.sessionB, 1, oneRunEnd, tt(10))])
    }

    func test_secondCallWithUnchangedState_changesNothing() async throws {
        let store = try await storeWithOneRun()
        let first = try await store.reconcile(session: Self.sessionA)
        let rowsAfterFirst = try await store.unreportedRows()

        let second = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(second, first)
        let rowsAfterSecond = try await store.unreportedRows()
        XCTAssertEqual(rowsAfterSecond, rowsAfterFirst)
        XCTAssertEqual(rowsAfterSecond, [stored(Self.sessionA, 1, oneRunEnd, tt(10))])
    }

    private func fileBytes(_ name: String) throws -> Data? {
        let url = try storeDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func test_secondCallWithUnchangedState_rowsPresent_writesNoByte() async throws {
        let store = try await storeWithOneRun()
        let first = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(first.rows.count, 1, "Fixture error: a row must be present")
        let databaseBefore = try fileBytes("usage.sqlite")
        let walBefore = try fileBytes("usage.sqlite-wal")
        XCTAssertNotNil(walBefore, "Fixture error: the WAL must exist while the store is open")

        let second = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try fileBytes("usage.sqlite"), databaseBefore, "an unchanged result must not write the database")
        XCTAssertEqual(try fileBytes("usage.sqlite-wal"), walBefore, "an unchanged result must not write the WAL")
    }

    func test_secondCallWithUnchangedState_noRows_writesNoByte() async throws {
        let store = try await storeWithOneRun(heardInput: 100)
        let first = try await store.reconcile(session: Self.sessionA)
        XCTAssertEqual(first, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]), "Fixture error")
        let databaseBefore = try fileBytes("usage.sqlite")
        let walBefore = try fileBytes("usage.sqlite-wal")
        XCTAssertNotNil(walBefore, "Fixture error: the WAL must exist while the store is open")

        let second = try await store.reconcile(session: Self.sessionA)

        XCTAssertEqual(second, first)
        XCTAssertEqual(try fileBytes("usage.sqlite"), databaseBefore, "an unchanged result must not write the database")
        XCTAssertEqual(try fileBytes("usage.sqlite-wal"), walBefore, "an unchanged result must not write the WAL")
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    func test_unreportedRows_areOrderedBySessionSequenceAndModel() async throws {
        let store = try openStore()
        let zeta = "claude-zeta-1"
        let alpha = "claude-alpha-1"
        for (session, startNs) in [(Self.sessionB, ns(-1)), (Self.sessionA, ns(-1, 30))] {
            try await saveRuns([
                UsageRun(sequence: 1, beginNs: ns(0), endNs: ns(2), totals: [zeta: tt(1), alpha: tt(2)]),
                UsageRun(sequence: 2, beginNs: ns(10), endNs: ns(12), totals: [zeta: tt(3), alpha: tt(5)]),
            ], session: session, to: store)
            try await send([], start: process(session, startNs, "fresh"), at: ns(0, 10), to: store)
            _ = try await store.reconcile(session: session)
        }
        let rows = try await store.unreportedRows()
        var expected: [UsageUnreportedStoredRow] = []
        for session in [Self.sessionA, Self.sessionB] {
            expected += [
                stored(session, 1, ns(2), tt(2), model: alpha),
                stored(session, 1, ns(2), tt(1), model: zeta),
                stored(session, 2, ns(12), tt(3), model: alpha),
                stored(session, 2, ns(12), tt(2), model: zeta),
            ]
        }
        XCTAssertEqual(rows, expected)
    }

    // MARK: - Restarting tracking, deleting

    func test_resetTracking_keepsTheRows() async throws {
        let store = try await storeWithOneRun()
        _ = try await store.reconcile(session: Self.sessionA)
        try await store.resetTracking()
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [stored(Self.sessionA, 1, oneRunEnd, tt(10))])
    }

    func test_deleteAll_removesEveryRow() async throws {
        let store = try await storeWithOneRun()
        _ = try await store.reconcile(session: Self.sessionA)
        let before = try await store.unreportedRows()
        XCTAssertEqual(before.count, 1, "Fixture error")
        try await store.deleteAll()
        let rows = try await store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    // MARK: - Closed store, schema

    func test_closedStore_throwsClosed() async throws {
        let store = try openStore()
        await store.close()
        for (name, call) in [
            ("reconcile", { _ = try await store.reconcile(session: Self.sessionA) }),
            ("unreportedRows", { _ = try await store.unreportedRows() }),
        ] as [(String, () async throws -> Void)] {
            do {
                try await call()
                XCTFail("\(name) must throw after close")
            } catch {
                XCTAssertEqual(error as? UsageStoreError, .closed, name)
            }
        }
    }

    private func corruptSiblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try storeDirectory().path)
            .filter { $0.hasPrefix("usage.sqlite.corrupt-") }
    }

    func test_version2DatabaseWithoutTheUnreportedTable_isMovedAside_andAFreshOneOpens() async throws {
        let first = try await storeWithOneRun()
        _ = try await first.reconcile(session: Self.sessionA)
        await first.close()
        // An earlier slice's version-2 file: everything but this table.
        var database: OpaquePointer?
        guard sqlite3_open_v2(try databaseURL().path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return XCTFail("Fixture error: cannot open the database")
        }
        let dropped = sqlite3_exec(database, "DROP TABLE usage_unreported", nil, nil, nil)
        sqlite3_close(database)
        XCTAssertEqual(dropped, SQLITE_OK, "Fixture error: the table must exist before it is dropped")

        let second = try openStore()

        XCTAssertEqual(try corruptSiblings().count, 1)
        let rows = try await second.unreportedRows()
        XCTAssertEqual(rows, [])
        let points = try await second.pointRows()
        XCTAssertEqual(points, [], "a fresh database, not the old file")
    }
}
