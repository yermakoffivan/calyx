//
//  UsageStoreSeriesTests.swift
//  CalyxTests
//
//  Pins UsageStore's token-series storage. Each telemetry series' last
//  cumulative value is kept as a baseline; only increments since that
//  baseline are added to per-minute point rows grouped by session, model,
//  effort, thread and agent, dated by the time Calyx RECEIVED the export
//  (never by the sender's timestamps).
//
//  Pinned here: totals of the captured real exports in any arrival order
//  and with duplicates; dating by receive time; which calls are ignored
//  (received before tracking, or an already-running process inside the
//  settling window after tracking (re)started) and that an ignored call
//  stores nothing; which first samples count in full (decided by the
//  export's process, else by the series' own start); restarting tracking
//  (resetTracking / deleteAll) never before anything already heard, even
//  with a clock set back; saturating sums; the clock conversion; the
//  per-series rows and process starts; label groups and row order; the
//  version-1 to version-2 migration; and that no personal value of an
//  export ever reaches a file of the store.
//
//  Every database lives in a per-test temporary directory removed in
//  tearDown after every opened store is closed. The clock is injected.
//

import CryptoKit
import SQLite3
import XCTest
@testable import Calyx

final class UsageStoreSeriesTests: XCTestCase {

    private typealias Fixtures = UsageTelemetryFixtures

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreSeriesTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Times

    /// Before every process start of the captures (the earliest, run1's,
    /// is 1_791_183_405.041 s).
    private static let beforeCaptures = Date(timeIntervalSince1970: 1_791_183_400)
    private static let beforeCapturesNs: Int64 = 1_791_183_400_000_000_000

    /// A tracking start used by the synthetic cases.
    private static let trackedNs: Int64 = 1_791_183_413_000_000_000
    private static let tracked = Date(timeIntervalSince1970: 1_791_183_413)
    private static let settleNs: Int64 = 15_000_000_000

    /// The start of minute 29_853_057 since the epoch; the default receive
    /// time of the synthetic calls.
    private static let minuteStartNs: Int64 = 1_791_183_420_000_000_000
    private static let minute: Int64 = 29_853_057
    private static let oneMinuteNs: Int64 = 60_000_000_000

    // MARK: - Helpers

    private func storeDirectory() throws -> URL {
        try XCTUnwrap(tempDirectory).appendingPathComponent("store", isDirectory: true)
    }

    private func databaseURL() throws -> URL {
        try storeDirectory().appendingPathComponent("usage.sqlite")
    }

    private func openStore(clock: UsageTestClock) throws -> UsageStore {
        let store = try UsageStore(directory: try storeDirectory(), now: clock.now)
        openedStores.append(store)
        return store
    }

    /// Default clock: the epoch, so tracking starts at 0.
    private func openStore(at date: Date = Date(timeIntervalSince1970: 0)) throws -> UsageStore {
        try openStore(clock: UsageTestClock(date))
    }

    private func closeAllStoresAndRemoveDirectory() async throws {
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        let directory = try storeDirectory()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// The element at `index`, or a test failure (never a trap).
    private func element<T>(_ items: [T], at index: Int) throws -> T {
        try XCTUnwrap(items.indices.contains(index) ? items[index] : nil, "Fixture error: no element \(index)")
    }

    private func reordered<T>(_ items: [T], by order: [Int]) throws -> [T] {
        XCTAssertEqual(order.sorted(), Array(items.indices), "Fixture error: not a permutation")
        return try order.map { try element(items, at: $0) }
    }

    /// One decoded export and its receive time (its collection time).
    private struct ReceivedExport {
        let batch: OTLPTokenUsageBatch
        let receivedAtNs: Int64
    }

    private func receivedExports(run: String) throws -> [ReceivedExport] {
        try Fixtures.exports(run: run).map {
            ReceivedExport(batch: try OTLPTokenUsageDecoder.decode($0), receivedAtNs: try Fixtures.collectionTimeNs(of: $0))
        }
    }

    @discardableResult
    private func apply(_ export: ReceivedExport, to store: UsageStore) async throws -> UsageSeriesApplyOutcome {
        try await store.apply(
            samples: export.batch.samples, processStarts: export.batch.processStarts, receivedAtNs: export.receivedAtNs)
    }

    @discardableResult
    private func apply(_ exports: [ReceivedExport], to store: UsageStore) async throws -> [UsageSeriesApplyOutcome] {
        var outcomes: [UsageSeriesApplyOutcome] = []
        for export in exports {
            outcomes.append(try await apply(export, to: store))
        }
        return outcomes
    }

    /// The test's own reading of each export of a run, keyed by series.
    private func rawExports(run: String) throws -> [[String: UsageRawTokenPoint]] {
        try Fixtures.exports(run: run).map { body in
            var bySeries: [String: UsageRawTokenPoint] = [:]
            for point in try Fixtures.rawTokenPoints(in: body) {
                bySeries[point.seriesKey] = point
            }
            return bySeries
        }
    }

    /// Per series of the LAST export: `value(last) - value(baseline)`
    /// plus `value(kept)` when given, summed by model and kind.
    private func expectedIncrements(
        _ raw: [[String: UsageRawTokenPoint]], kept: Int?, baseline: Int
    ) throws -> UsageTotalsByModel {
        let last = try XCTUnwrap(raw.last)
        let baselineExport = try element(raw, at: baseline)
        let keptExport = try kept.map { try element(raw, at: $0) }
        var entries: [(String, String, Int64)] = []
        for (key, point) in last {
            var tokens = point.value - (try XCTUnwrap(baselineExport[key], key).value)
            if let keptExport { tokens += try XCTUnwrap(keptExport[key], key).value }
            entries.append((point.model, point.kind, tokens))
        }
        return Fixtures.sumByModel(entries)
    }

    private func totals(of store: UsageStore) async throws -> UsageTotalsByModel {
        Fixtures.totals(of: try await store.pointRows())
    }

    private func seriesID(_ number: Int) -> String {
        String(format: "%064x", number)
    }

    private func sample(
        series: Int = 1,
        session: String = "session-a",
        startNs: Int64 = 1_000,
        timeNs: Int64,
        kind: UsageTokenKind = .input,
        value: Int64,
        model: String = "claude-sonnet-5-5",
        effort: String? = "medium",
        thread: String? = "main",
        agent: String? = nil
    ) -> UsageSeriesSample {
        UsageSeriesSample(
            sessionID: session, seriesID: seriesID(series), startNs: startNs, timeNs: timeNs, kind: kind,
            value: value, model: model, effort: effort, thread: thread, agent: agent)
    }

    /// The process of the synthetic calls by default: started at 0, so it
    /// does not predate a tracking start of 0 (the default clock).
    private static let defaultProcess = UsageProcessStart(sessionID: "session-a", startNs: 0, startType: "fresh")

    private func fresh(_ startNs: Int64, session: String = "session-a") -> UsageProcessStart {
        UsageProcessStart(sessionID: session, startNs: startNs, startType: "fresh")
    }

    /// A synthetic call received at `receivedAtNs` (default: the start of
    /// `minute`), carrying one process start (by default `defaultProcess`).
    @discardableResult
    private func send(
        _ samples: [UsageSeriesSample], starts: [UsageProcessStart] = [UsageStoreSeriesTests.defaultProcess],
        to store: UsageStore,
        at receivedAtNs: Int64 = UsageStoreSeriesTests.minuteStartNs
    ) async throws -> UsageSeriesApplyOutcome {
        try await store.apply(samples: samples, processStarts: starts, receivedAtNs: receivedAtNs)
    }

    private func row(
        session: String = "session-a",
        minute: Int64 = UsageStoreSeriesTests.minute,
        model: String = "claude-sonnet-5-5",
        effort: String? = "medium",
        thread: String? = "main",
        agent: String? = nil,
        input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheCreation: Int64 = 0
    ) -> UsagePointRow {
        UsagePointRow(
            sessionID: session, minute: minute, model: model, effort: effort, thread: thread, agent: agent,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheCreationTokens: cacheCreation)
    }

    private func outcome(
        ignored: Bool = false, newSeries: Int = 0, baselineOnly: Int = 0, advancedSeries: Int = 0,
        unchangedSamples: Int = 0, staleSamples: Int = 0, regressions: Int = 0, added: [UsageTokenKind: Int64] = [:],
        changedSessions: Set<String> = []
    ) -> UsageSeriesApplyOutcome {
        var outcome = UsageSeriesApplyOutcome()
        outcome.changedSessions = changedSessions
        outcome.ignored = ignored
        outcome.newSeries = newSeries
        outcome.baselineOnly = baselineOnly
        outcome.advancedSeries = advancedSeries
        outcome.unchangedSamples = unchangedSamples
        outcome.staleSamples = staleSamples
        outcome.regressions = regressions
        outcome.added = added
        return outcome
    }

    /// Asserts the store holds no series, no active process start, no
    /// point, and exactly `retired` retired digests.
    private func assertNothingStored(
        _ store: UsageStore, _ message: String = "", retired: Int = 0, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let series = try await store.seriesRows()
        let starts = try await store.processStarts()
        let points = try await store.pointRows()
        let retiredCount = try await store.retiredProcessCount()
        XCTAssertEqual(series, [], message, file: file, line: line)
        XCTAssertEqual(starts, [], message, file: file, line: line)
        XCTAssertEqual(points, [], message, file: file, line: line)
        XCTAssertEqual(retiredCount, retired, message, file: file, line: line)
    }

    func test_trackingSettleNs_is15Seconds() {
        XCTAssertEqual(UsageStore.trackingSettleNs, 15_000_000_000)
    }

    // MARK: - Captured runs

    func test_run1_appliedInOrder_totalsEqualExpectedCostState() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run1"), to: store)
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run1"))
    }

    func test_run2_appliedInOrder_totalsEqualExpectedCostState() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run2"), to: store)
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run2"))
    }

    func test_run2ThenRun3_resumedSession_totalsEqualRun3ExpectedCostState() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run2") + receivedExports(run: "run3"), to: store)
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run3"))
    }

    func test_run4_appliedInOrder_totalsEqualExpectedCostState() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run4"), to: store)
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run4"))
    }

    func test_run1_eachExportAppliedTwice_totalsUnchanged() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        for export in try receivedExports(run: "run1") {
            try await apply(export, to: store)
            let seriesBefore = try await store.seriesRows()
            let resent = try await apply(export, to: store)
            // A series whose value grew in this export is stale (same time);
            // one whose value did not change was stored earlier: unchanged.
            XCTAssertEqual(resent.staleSamples + resent.unchangedSamples, export.batch.samples.count,
                           "A resent export must change nothing")
            XCTAssertEqual(resent.newSeries + resent.baselineOnly + resent.advancedSeries + resent.regressions, 0)
            XCTAssertEqual(resent.added, [:])
            let seriesAfter = try await store.seriesRows()
            XCTAssertEqual(seriesAfter, seriesBefore)
        }
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run1"))
    }

    func test_run2AndRun3_wholeSequenceAppliedTwice_totalsUnchanged() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run2") + receivedExports(run: "run3")
        try await apply(exports, to: store)
        let rowsOnce = try await store.pointRows()
        try await apply(exports, to: store)
        let rowsTwice = try await store.pointRows()
        XCTAssertEqual(rowsTwice, rowsOnce)
        XCTAssertEqual(Fixtures.totals(of: rowsTwice), try Fixtures.expectedTotals(run: "run3"))
    }

    func test_everyRun_appliedInReverseOrder_totalsEqualExpectedCostState() async throws {
        let cases: [([String], String)] = [(["run1"], "run1"), (["run2"], "run2"), (["run2", "run3"], "run3"), (["run4"], "run4")]
        for (runs, expectedRun) in cases {
            try await closeAllStoresAndRemoveDirectory()
            let store = try openStore(at: Self.beforeCaptures)
            var exports: [ReceivedExport] = []
            for run in runs { exports += try receivedExports(run: run) }
            try await apply(exports.reversed(), to: store)
            let actual = try await totals(of: store)
            XCTAssertEqual(actual, try Fixtures.expectedTotals(run: expectedRun), "\(runs) reversed")
        }
    }

    func test_run2AndRun3_fixedShuffles_totalsEqualRun3ExpectedCostState() async throws {
        let exports = try receivedExports(run: "run2") + receivedExports(run: "run3")
        XCTAssertEqual(exports.count, 16, "Fixture error")
        let shuffles: [[Int]] = [
            [7, 2, 15, 0, 11, 4, 13, 9, 1, 14, 6, 3, 12, 8, 5, 10],
            [15, 14, 0, 1, 8, 9, 2, 3, 10, 11, 4, 5, 12, 13, 6, 7],
            [3, 13, 5, 11, 0, 9, 15, 1, 7, 2, 12, 6, 14, 4, 10, 8],
            [1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14],
        ]
        for order in shuffles {
            try await closeAllStoresAndRemoveDirectory()
            let store = try openStore(at: Self.beforeCaptures)
            try await apply(try reordered(exports, by: order), to: store)
            let actual = try await totals(of: store)
            XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run3"), "order \(order)")
        }
    }

    func test_run1_allSamplesInOneCallInReverse_areAppliedByAscendingTime() async throws {
        let exports = try receivedExports(run: "run1")
        let last = try XCTUnwrap(exports.last)
        let all = exports.flatMap(\.batch.samples)
        XCTAssertEqual(all.count, 48, "Fixture error")
        let store = try openStore(at: Self.beforeCaptures)

        let result = try await store.apply(
            samples: all.reversed(), processStarts: last.batch.processStarts, receivedAtNs: last.receivedAtNs)

        // Of the 40 later samples, those whose value grew over the previous
        // export's are advanced; those with the same value are unchanged.
        let raw = try rawExports(run: "run1")
        var grew = 0, same = 0
        for index in 2..<raw.count {
            let previous = try element(raw, at: index - 1)
            for (key, point) in try element(raw, at: index) {
                let before = try XCTUnwrap(previous[key], key).value
                if point.value > before { grew += 1 } else if point.value == before { same += 1 }
            }
        }
        XCTAssertEqual(grew + same, 40, "Fixture error")
        XCTAssertGreaterThan(same, 0, "Fixture error: run1 has idle exports")
        XCTAssertEqual(result.newSeries, 8)
        XCTAssertEqual(result.advancedSeries, grew)
        XCTAssertEqual(result.unchangedSamples, same)
        XCTAssertEqual(result.staleSamples, 0)
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run1"))
    }

    func test_run1_eachExportsIncrementsLandInTheMinuteItWasReceived() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run1")
        try await apply(exports, to: store)
        let raw = try rawExports(run: "run1")
        // Exports 1 and 2 were received before …420 s, the rest after; the
        // first token values arrive in export 2.
        XCTAssertLessThan(try element(exports, at: 1).receivedAtNs, Self.minuteStartNs, "Fixture error")
        XCTAssertGreaterThan(try element(exports, at: 2).receivedAtNs, Self.minuteStartNs, "Fixture error")
        let firstMinute = Fixtures.sumByModel(try element(raw, at: 1).values.map { ($0.model, $0.kind, $0.value) })
        let rows = try await store.pointRows()
        XCTAssertEqual(Set(rows.map(\.minute)), [Self.minute - 1, Self.minute])
        XCTAssertEqual(Fixtures.totals(of: rows.filter { $0.minute == Self.minute - 1 }), firstMinute)
    }

    // MARK: - Series identity

    func test_seriesDifferingOnlyInOneExtraAttribute_countSeparately() async throws {
        let base = Fixtures.attributes([
            "session.id": "11111111-1111-4111-8111-111111111111",
            "model": "claude-sonnet-5-5",
            "query_source": "main",
            "type": "output",
        ])
        let body = try Fixtures.body(metrics: [Fixtures.metric(points: [
            Fixtures.point(attributes: base, asDouble: 100),
            Fixtures.point(attributes: base + [Fixtures.stringAttribute("speed", "fast")], asDouble: 50),
        ])])
        let samples = try OTLPTokenUsageDecoder.decode(body).samples
        let store = try openStore(at: Self.beforeCaptures)

        let result = try await send(samples, starts: [fresh(Self.beforeCapturesNs)], to: store)

        XCTAssertEqual(result, outcome(newSeries: 2, added: [.output: 150], changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows.map(\.outputTokens), [150])
    }

    func test_sameSeriesIDInTwoSessions_areTwoSeries() async throws {
        let store = try openStore()
        let result = try await send([
            sample(session: "session-a", timeNs: 10, value: 10),
            sample(session: "session-b", timeNs: 10, value: 20),
        ], to: store)
        XCTAssertEqual(result, outcome(newSeries: 2, added: [.input: 30], changedSessions: ["session-a", "session-b"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(session: "session-a", input: 10), row(session: "session-b", input: 20)])
    }

    func test_sameSeriesWithANewStart_isANewSeries() async throws {
        let store = try openStore()
        try await send([sample(startNs: 1_000, timeNs: 10, value: 500)], to: store)
        let result = try await send([sample(startNs: 2_000, timeNs: 11, value: 7)], to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 7], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 507)])
    }

    // MARK: - Dating by receive time

    func test_dating_samplesFarInThePastOrFuture_landInTheMinuteOfReceipt() async throws {
        let store = try openStore()
        try await send([
            sample(series: 1, startNs: 0, timeNs: 0, value: 1),
            sample(series: 2, startNs: 1_000, timeNs: Int64.max - 1, value: 20),
        ], to: store, at: Self.minuteStartNs + 30_000_000_000)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(minute: Self.minute, input: 21)])
    }

    func test_dating_twoCallsInDifferentMinutes_giveTwoRows() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store, at: Self.minuteStartNs)
        try await send([sample(timeNs: 11, value: 25)], to: store, at: Self.minuteStartNs + Self.oneMinuteNs)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(minute: Self.minute, input: 10), row(minute: Self.minute + 1, input: 15)])
    }

    func test_dating_exactMinuteBoundary() async throws {
        let store = try openStore()
        try await send([sample(series: 1, timeNs: 5, value: 1)], to: store, at: Self.minuteStartNs - 1)
        try await send([sample(series: 2, timeNs: 5, value: 20)], to: store, at: Self.minuteStartNs)
        try await send([sample(series: 3, timeNs: 5, value: 300)], to: store, at: Self.minuteStartNs + 59_999_999_999)
        try await send([sample(series: 4, timeNs: 5, value: 4_000)], to: store, at: Self.minuteStartNs + Self.oneMinuteNs)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [
            row(minute: Self.minute - 1, input: 1),
            row(minute: Self.minute, input: 320),
            row(minute: Self.minute + 1, input: 4_000),
        ])
    }

    func test_dating_negativeReceiveTimes_areFloorDivided() async throws {
        let store = try openStore(at: Date.distantPast)
        try await send([sample(series: 1, startNs: 0, timeNs: 1, value: 1)], to: store, at: -1)
        try await send([sample(series: 2, startNs: 0, timeNs: 1, value: 20)], to: store, at: -60_000_000_000)
        try await send([sample(series: 3, startNs: 0, timeNs: 1, value: 300)], to: store, at: -60_000_000_001)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(minute: -2, input: 300), row(minute: -1, input: 21)])
    }

    func test_dating_receivedAtZero_isMinuteZero() async throws {
        let store = try openStore()
        try await send([sample(startNs: 0, timeNs: 99, value: 5)], to: store, at: 0)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(minute: 0, input: 5)])
    }

    // MARK: - Ignored calls

    func test_ignored_callWithoutProcessStart_storesNothing() async throws {
        let store = try openStore()
        let result = try await send([sample(timeNs: 10, value: 9)], starts: [], to: store)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_ignored_callWithTwoProcessStarts_withSamples_storesNothing_notEvenTheStarts() async throws {
        let store = try openStore()
        let result = try await send(
            [sample(timeNs: 10, value: 9)], starts: [fresh(500), fresh(600, session: "session-b")], to: store)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_ignored_callWithTwoProcessStarts_withoutSamples_storesNothing() async throws {
        let store = try openStore()
        let result = try await send([], starts: [fresh(500), fresh(500)], to: store)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_ignored_twoStartsReceivedBeforeTracking_isIgnored() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send(
            [sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs), fresh(Self.trackedNs + 1)], to: store,
            at: Self.trackedNs - 1)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_ignored_receivedBeforeTracking_withAProcessThatPredatesTracking_storesNoDigest() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send(
            [sample(timeNs: 10, value: 9)], starts: [oldProcess], to: store, at: Self.trackedNs - 1)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_ignored_receivedBeforeTracking_storesNothing() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send(
            [sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs)], to: store, at: Self.trackedNs - 1)
        XCTAssertEqual(result, outcome(ignored: true))
        try await assertNothingStored(store)
    }

    func test_receivedExactlyAtTracking_isNotIgnored() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send([sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs)], to: store,
                                    at: Self.trackedNs)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 9], changedSessions: ["session-a"]))
    }

    private var oldProcess: UsageProcessStart {
        UsageProcessStart(sessionID: "session-a", startNs: Self.trackedNs - 100_000_000_000, startType: "fresh")
    }

    func test_ignored_oldProcessInsideTheSettlingWindow_storesOnlyItsDigest_thenItsNextExportSetsBaselines() async throws {
        let store = try openStore(at: Self.tracked)
        let inside = try await send(
            [sample(startNs: oldProcess.startNs + 1, timeNs: 10, value: 100)], starts: [oldProcess], to: store,
            at: Self.trackedNs + Self.settleNs - 1)
        XCTAssertEqual(inside, outcome(ignored: true))
        try await assertNothingStored(store, retired: 1)
        let again = try await send(
            [sample(startNs: oldProcess.startNs + 1, timeNs: 15, value: 110)], starts: [oldProcess], to: store,
            at: Self.trackedNs + 1)
        XCTAssertEqual(again, outcome(ignored: true))
        try await assertNothingStored(store, "the same process ignored again adds no digest", retired: 1)

        let after = try await send(
            [sample(startNs: oldProcess.startNs + 1, timeNs: 20, value: 130)], starts: [oldProcess], to: store,
            at: Self.trackedNs + Self.settleNs)
        XCTAssertEqual(after, outcome(baselineOnly: 1, changedSessions: ["session-a"]))
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [oldProcess])
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [])
    }

    func test_newProcessInsideTheSettlingWindow_countsWhole() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send(
            [sample(startNs: Self.trackedNs + 1, timeNs: 10, value: 40)], starts: [fresh(Self.trackedNs)], to: store,
            at: Self.trackedNs + 1_000_000_000)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 40], changedSessions: ["session-a"]))
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [fresh(Self.trackedNs)])
    }

    // MARK: - Which first samples count in full

    func test_oldProcessFirstHeardAfterTheWindow_baselineOnlyForAllItsSeries_thenIncrementsAndNewSeriesCount() async throws {
        let store = try openStore(at: Self.tracked)
        let first = try await send([
            sample(series: 1, startNs: Self.trackedNs - 90_000_000_000, timeNs: 10, value: 100),
            // A series start after tracking decides nothing.
            sample(series: 2, startNs: Self.trackedNs + 1, timeNs: 10, value: 7),
        ], starts: [oldProcess], to: store, at: Self.trackedNs + Self.settleNs)
        XCTAssertEqual(first, outcome(baselineOnly: 2, changedSessions: ["session-a"]))
        let rowsAfterFirst = try await store.pointRows()
        XCTAssertEqual(rowsAfterFirst, [])

        let second = try await send([
            sample(series: 1, startNs: Self.trackedNs - 90_000_000_000, timeNs: 20, value: 130),
            sample(series: 2, startNs: Self.trackedNs + 1, timeNs: 20, value: 7),
            // First seen in a later export of an active process: whole, even
            // though its own start is far before tracking.
            sample(series: 3, startNs: 1, timeNs: 20, value: 40),
        ], starts: [oldProcess], to: store, at: Self.trackedNs + Self.settleNs + 5_000_000_000)
        XCTAssertEqual(second, outcome(newSeries: 1, advancedSeries: 1, unchangedSamples: 1, added: [.input: 70], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows.map(\.inputTokens), [70])
    }

    func test_processStartingExactlyAtTracking_countsWhole() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send([
            sample(series: 1, startNs: Self.trackedNs - 1, timeNs: 10, value: 3),
            sample(series: 2, startNs: Self.trackedNs + 5, timeNs: 10, value: 4),
        ], starts: [fresh(Self.trackedNs)], to: store, at: Self.trackedNs + Self.settleNs + 1)
        XCTAssertEqual(result, outcome(newSeries: 2, added: [.input: 7], changedSessions: ["session-a"]))
    }

    func test_neverHeardProcessStartedAfterTracking_seriesStartingBeforeTracking_countsWhole() async throws {
        let store = try openStore(at: Self.tracked)
        let result = try await send(
            [sample(startNs: 1, timeNs: 10, value: 25)], starts: [fresh(Self.trackedNs + 1)], to: store,
            at: Self.trackedNs + Self.settleNs + 1)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 25], changedSessions: ["session-a"]))
    }

    func test_freshStore_trackedFromIsTheClockAtCreation() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.beforeCapturesNs)
    }

    func test_reopen_keepsTrackedFromAndBaselines() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let first = try openStore(clock: clock)
        let exports = try receivedExports(run: "run4")
        try await apply(exports, to: first)
        await first.close()

        clock.set(Date(timeIntervalSince1970: 1_791_183_900))
        let second = try openStore(clock: clock)
        let trackedFrom = try await second.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.beforeCapturesNs, "Opening an existing database must not move tracked_from")
        let resent = try await apply(try XCTUnwrap(exports.first), to: second)
        XCTAssertEqual(resent, outcome(staleSamples: 4), "Baselines must survive a reopen")
        let actual = try await totals(of: second)
        XCTAssertEqual(actual, try Fixtures.expectedTotals(run: "run4"))
    }

    // MARK: - Known series: stale, advance, regression

    func test_regression_addsNothing_writesNothing_andLaterGrowthCountsOnlyBeyondTheLargestValue() async throws {
        let store = try openStore()
        let first = try await send([sample(timeNs: 10, value: 100)], to: store)
        XCTAssertEqual(first, outcome(newSeries: 1, added: [.input: 100], changedSessions: ["session-a"]))
        let seriesBefore = try await store.seriesRows()

        let regression = try await send([sample(timeNs: 20, value: 50)], to: store)
        XCTAssertEqual(regression, outcome(regressions: 1))
        let seriesAfterRegression = try await store.seriesRows()
        XCTAssertEqual(seriesAfterRegression, seriesBefore, "a regression writes nothing")
        let rowsAfterRegression = try await store.pointRows()
        XCTAssertEqual(rowsAfterRegression, [row(input: 100)])

        let growth = try await send([sample(timeNs: 30, value: 120)], to: store)
        XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 20], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 120)])
    }

    /// Review round 4: stored (100, t=10); (100, t=30) unchanged; a late
    /// (50, t=20) is a regression; (100, t=35) must add nothing.
    func test_nonMonotonicSender_roundFourSequence_addsTheLargestValueOnce() async throws {
        let store = try openStore()
        var total: Int64 = 0
        var regressions = 0
        for (time, value) in [(Int64(10), Int64(100)), (30, 100), (20, 50), (35, 100)] {
            let result = try await send([sample(timeNs: time, value: value)], to: store)
            let (sum, overflow) = total.addingReportingOverflow(result.added[.input] ?? 0)
            XCTAssertFalse(overflow)
            total = sum
            regressions += result.regressions
        }
        XCTAssertEqual(total, 100)
        XCTAssertEqual(regressions, 1)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 100)])
    }

    /// Every arrival order of one series' samples (some non-monotonic),
    /// each order as its own series: what is counted never exceeds the
    /// largest value, and equals the value stored for the series.
    func test_nonMonotonicSender_everyArrivalOrder_neverAddsMoreThanTheLargestValue() async throws {
        let points: [(Int64, Int64)] = [(10, 100), (20, 50), (30, 100), (35, 120), (15, 70), (40, 120)]
        var orders: [[Int]] = [[]]
        for _ in points.indices {
            var next: [[Int]] = []
            for order in orders {
                for index in points.indices where !order.contains(index) { next.append(order + [index]) }
            }
            orders = next
        }
        XCTAssertEqual(orders.count, 720, "Fixture error")
        let store = try openStore()
        var counted: [Int: Int64] = [:]
        for (number, order) in orders.enumerated() {
            for index in order {
                let (time, value) = try element(points, at: index)
                let result = try await send([sample(series: number + 1, timeNs: time, value: value)], to: store)
                let (sum, overflow) = (counted[number + 1] ?? 0).addingReportingOverflow(result.added[.input] ?? 0)
                XCTAssertFalse(overflow)
                counted[number + 1] = sum
            }
        }
        let series = try await store.seriesRows()
        XCTAssertEqual(series.count, 720)
        for row in series {
            let number = Int(row.seriesID, radix: 16) ?? -1
            let total = counted[number] ?? -1
            XCTAssertLessThanOrEqual(total, 120, "order \(number)")
            XCTAssertEqual(total, row.lastValue, "order \(number)")
        }
    }

    func test_staleSamples_atOrBeforeTheLastTime_areIgnored() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 20, value: 100)], to: store)
        let result = try await send([
            sample(timeNs: 20, value: 500),
            sample(timeNs: 19, value: 900),
            sample(timeNs: 1, value: 1),
        ], to: store)
        XCTAssertEqual(result, outcome(staleSamples: 3))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 100)])
    }

    /// A regression does not move the stored time: a later-arriving
    /// sample between the stored time and the regression's is judged
    /// against the stored (largest) value.
    func test_regression_leavesTheStoredTime_soASampleBeforeItIsStillCompared() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 100)], to: store)
        try await send([sample(timeNs: 20, value: 40)], to: store)
        let result = try await send([sample(timeNs: 15, value: 300)], to: store)
        XCTAssertEqual(result, outcome(advancedSeries: 1, added: [.input: 200], changedSessions: ["session-a"]))
        let stale = try await send([sample(timeNs: 15, value: 400)], to: store)
        XCTAssertEqual(stale, outcome(staleSamples: 1))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 300)])
    }

    func test_samplesWithEqualTime_keepInputOrder_firstWins() async throws {
        let store = try openStore()
        let result = try await send([sample(timeNs: 10, value: 10), sample(timeNs: 10, value: 20)], to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, staleSamples: 1, added: [.input: 10], changedSessions: ["session-a"]))

        try await closeAllStoresAndRemoveDirectory()
        let other = try openStore()
        let swapped = try await send([sample(timeNs: 10, value: 20), sample(timeNs: 10, value: 10)], to: other)
        XCTAssertEqual(swapped, outcome(newSeries: 1, staleSamples: 1, added: [.input: 20], changedSessions: ["session-a"]))
    }

    func test_oneCall_outOfOrderSamples_areAppliedInAscendingTime() async throws {
        let store = try openStore()
        let result = try await send([
            sample(timeNs: 30, value: 90),
            sample(timeNs: 9, value: 10),
            sample(timeNs: 20, value: 60),
        ], to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, advancedSeries: 2, added: [.input: 90], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 90)])
    }

    func test_outcome_countsEveryCaseInOneCall_andAddedOmitsZeroKinds() async throws {
        let store = try openStore(at: Date(timeIntervalSince1970: 1))
        let process = fresh(2_000_000_000)
        try await send([
            sample(series: 1, timeNs: 10, kind: .output, value: 50),
            sample(series: 2, timeNs: 10, kind: .cacheRead, value: 50),
            sample(series: 3, timeNs: 10, kind: .input, value: 50),
        ], starts: [process], to: store)
        let result = try await send([
            sample(series: 1, timeNs: 11, kind: .output, value: 57),
            sample(series: 2, timeNs: 11, kind: .cacheRead, value: 50),
            sample(series: 2, timeNs: 9, kind: .cacheRead, value: 1),
            sample(series: 3, timeNs: 11, kind: .input, value: 20),
            sample(series: 3, timeNs: 11, kind: .input, value: 49),
            sample(series: 4, timeNs: 11, kind: .cacheCreation, value: 0),
            sample(series: 5, startNs: 0, timeNs: 11, kind: .cacheCreation, value: 800),
        ], starts: [process], to: store)
        // Series 3: 20 is a regression (nothing written), 49 at the same
        // time is still compared with the stored 50 at t=10: a regression.
        XCTAssertEqual(result, outcome(
            newSeries: 2, advancedSeries: 1, unchangedSamples: 1, staleSamples: 1, regressions: 2,
            added: [.output: 7, .cacheCreation: 800], changedSessions: ["session-a"]))
    }

    func test_zeroAmount_createsNoRow() async throws {
        let store = try openStore()
        let first = try await send([sample(timeNs: 10, value: 0)], to: store)
        XCTAssertEqual(first, outcome(newSeries: 1, changedSessions: ["session-a"]))
        let unchanged = try await send([sample(timeNs: 20, value: 0)], to: store, at: Self.minuteStartNs + Self.oneMinuteNs)
        XCTAssertEqual(unchanged, outcome(unchangedSamples: 1))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [])
    }

    func test_emptyCall_isANoOp_notIgnored() async throws {
        let store = try openStore()
        let result = try await send([], starts: [], to: store)
        XCTAssertEqual(result, UsageSeriesApplyOutcome())
        try await assertNothingStored(store)
    }

    func test_eachKind_landsInItsOwnColumn() async throws {
        let store = try openStore()
        try await send([
            sample(series: 1, timeNs: 10, kind: .input, value: 1),
            sample(series: 2, timeNs: 10, kind: .output, value: 20),
            sample(series: 3, timeNs: 10, kind: .cacheRead, value: 300),
            sample(series: 4, timeNs: 10, kind: .cacheCreation, value: 4_000),
        ], to: store)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 1, output: 20, cacheRead: 300, cacheCreation: 4_000)])
    }

    // MARK: - Restarting tracking

    // run1, received at (collection times): export 1 …410.039 s, 2 …415.040,
    // 3 …420.041, 4 …425.041, 5 …430.041, 6 …435.042, 7 …438.327. Its
    // process started at …405.041 s; its series at …410.362 and …412.584.

    /// 1_791_183_416 s: after exports 1–2 were received. The settling
    /// window then lasts until …431 s: exports 3, 4 and 5 fall inside it.
    private static let afterRun1Export2 = Date(timeIntervalSince1970: 1_791_183_416)
    private static let afterRun1Export2Ns: Int64 = 1_791_183_416_000_000_000

    /// Restarting tracking with the clock set back to …300 s, before run1's
    /// process start: the window ends at …315 s, before every later export.
    private static let setBack = Date(timeIntervalSince1970: 1_791_183_300)
    private static let setBackNs: Int64 = 1_791_183_300_000_000_000

    private func restart(_ store: UsageStore, deleting: Bool) async throws {
        if deleting {
            try await store.deleteAll()
        } else {
            try await store.resetTracking()
        }
    }

    func test_resetTracking_afterTwoExports_keepsPoints_ignoresTheWindow_thenBaselineThenIncrements() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let store = try openStore(clock: clock)
        let exports = try receivedExports(run: "run1")
        let raw = try rawExports(run: "run1")
        XCTAssertEqual(exports.count, 7, "Fixture error")
        try await apply(Array(exports.prefix(2)), to: store)
        let rowsBeforeReset = try await store.pointRows()

        clock.set(Self.afterRun1Export2)
        try await store.resetTracking()

        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.afterRun1Export2Ns)
        let rowsAfterReset = try await store.pointRows()
        XCTAssertEqual(rowsAfterReset, rowsBeforeReset, "resetTracking must keep the points")
        let seriesAfterReset = try await store.seriesRows()
        let startsAfterReset = try await store.processStarts()
        let retired = try await store.retiredProcessCount()
        XCTAssertEqual(seriesAfterReset, [])
        XCTAssertEqual(startsAfterReset, [])
        XCTAssertEqual(retired, 1)

        for index in 2...4 {
            let result = try await apply(try element(exports, at: index), to: store)
            XCTAssertEqual(result, outcome(ignored: true), "export \(index + 1) is inside the settling window")
            let series = try await store.seriesRows()
            let starts = try await store.processStarts()
            XCTAssertEqual(series, [], "export \(index + 1)")
            XCTAssertEqual(starts, [], "export \(index + 1)")
        }
        let firstAfterWindow = try await apply(try element(exports, at: 5), to: store)
        XCTAssertEqual(firstAfterWindow, outcome(baselineOnly: 8, changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let rowsAfterBaseline = try await store.pointRows()
        XCTAssertEqual(rowsAfterBaseline, rowsBeforeReset)
        try await apply(try element(exports, at: 6), to: store)

        // Per series: export 2's value (added before the reset) plus the
        // growth from export 6 to export 7.
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try expectedIncrements(raw, kept: 1, baseline: 5))
    }

    func test_deleteAll_runningProcess_ignoresTheWindow_thenOnlyLaterIncrementsCount() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let store = try openStore(clock: clock)
        let exports = try receivedExports(run: "run1")
        let raw = try rawExports(run: "run1")
        try await apply(Array(exports.prefix(2)), to: store)

        clock.set(Self.afterRun1Export2)
        try await store.deleteAll()

        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.afterRun1Export2Ns)
        try await assertNothingStored(store, retired: 1)
        let outcomes = try await apply(Array(exports.dropFirst(2)), to: store)
        XCTAssertEqual(outcomes.map(\.ignored), [true, true, true, false, false])
        XCTAssertEqual(try element(outcomes, at: 3), outcome(baselineOnly: 8, changedSessions: ["11111111-1111-4111-8111-111111111111"]), "Deleted usage must not come back")
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try expectedIncrements(raw, kept: nil, baseline: 5))
    }

    /// The clock is set back before run1's process start; the process is
    /// still recognized as heard before the restart (by identity), so its
    /// next export only sets baselines.
    func test_resetTracking_clockSetBack_retiredProcessStillPredates_andPointsDoNotDouble() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let store = try openStore(clock: clock)
        let exports = try receivedExports(run: "run1")
        let raw = try rawExports(run: "run1")
        try await apply(Array(exports.prefix(3)), to: store)

        clock.set(Self.setBack)
        try await store.resetTracking()

        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.setBackNs, "tracked_from is the clock, even when earlier than before")
        let outcomes = try await apply(Array(exports.dropFirst(3)), to: store)
        XCTAssertEqual(outcomes.map(\.ignored), [false, false, false, false])
        XCTAssertEqual(try element(outcomes, at: 0), outcome(baselineOnly: 8, changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try expectedIncrements(raw, kept: 2, baseline: 3))
        XCTAssertNotEqual(actual, try Fixtures.expectedTotals(run: "run1"), "Fixture error: the reset must leave out some tokens")
    }

    func test_deleteAll_clockSetBack_retiredProcessStillPredates_andNothingComesBack() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let store = try openStore(clock: clock)
        let exports = try receivedExports(run: "run1")
        let raw = try rawExports(run: "run1")
        try await apply(Array(exports.prefix(3)), to: store)

        clock.set(Self.setBack)
        try await store.deleteAll()

        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.setBackNs)
        try await assertNothingStored(store, retired: 1)
        let outcomes = try await apply(Array(exports.dropFirst(3)), to: store)
        XCTAssertEqual(try element(outcomes, at: 0), outcome(baselineOnly: 8, changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try expectedIncrements(raw, kept: nil, baseline: 3))
    }

    /// A process heard before a restart whose own start is LATER than the
    /// new tracked_from predates tracking anyway: ignored inside the window,
    /// baseline only after it.
    func test_retiredProcessStartingAfterTheNewTrackedFrom_stillPredates() async throws {
        for deleting in [false, true] {
            try await closeAllStoresAndRemoveDirectory()
            let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
            let store = try openStore(clock: clock)
            let process = fresh(2_000_000_000_000)
            let first = try await send([sample(timeNs: 10, value: 10)], starts: [process], to: store, at: 2_100_000_000_000)
            XCTAssertEqual(first, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]))

            clock.set(Date(timeIntervalSince1970: 1_500))
            try await restart(store, deleting: deleting)
            let trackedFrom = try await store.trackedFromNs()
            XCTAssertEqual(trackedFrom, 1_500_000_000_000)

            let inside = try await send([sample(timeNs: 20, value: 30)], starts: [process], to: store,
                                        at: 1_500_000_000_000 + Self.settleNs - 1)
            XCTAssertEqual(inside, outcome(ignored: true), "deleting: \(deleting)")
            let retiredAfterInside = try await store.retiredProcessCount()
            XCTAssertEqual(retiredAfterInside, 1, "an already retired process adds no digest; deleting: \(deleting)")
            let edge = try await send([sample(timeNs: 30, value: 50)], starts: [process], to: store,
                                      at: 1_500_000_000_000 + Self.settleNs)
            XCTAssertEqual(edge, outcome(baselineOnly: 1, changedSessions: ["session-a"]), "deleting: \(deleting)")
            let growth = try await send([sample(timeNs: 40, value: 54)], starts: [process], to: store,
                                        at: 2_200_000_000_000)
            XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 4], changedSessions: ["session-a"]), "deleting: \(deleting)")
            let rows = try await store.pointRows()
            XCTAssertEqual(rows.map(\.inputTokens).reduce(0, +), deleting ? 4 : 14, "deleting: \(deleting)")
        }
    }

    func test_restart_setsTrackedFromToTheClock_evenWhenEarlier() async throws {
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try openStore(clock: clock)
        clock.set(Date(timeIntervalSince1970: 500))
        try await store.resetTracking()
        let afterReset = try await store.trackedFromNs()
        XCTAssertEqual(afterReset, 500_000_000_000)
        clock.set(Date(timeIntervalSince1970: 400))
        try await store.deleteAll()
        let afterDelete = try await store.trackedFromNs()
        XCTAssertEqual(afterDelete, 400_000_000_000)
    }

    /// A sender's start time far in the future must not move Calyx's own
    /// threshold: after a restart tracked_from is the clock and a new
    /// ordinary process counts.
    func test_restart_afterAProcessStartFarInTheFuture_trackedFromIsTheClock_andNewProcessesCount() async throws {
        for deleting in [false, true] {
            try await closeAllStoresAndRemoveDirectory()
            let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
            let store = try openStore(clock: clock)
            let future = fresh(4_000_000_000_000_000_000)
            let accepted = try await send(
                [sample(startNs: 4_000_000_000_000_000_000, timeNs: 10, value: 5)], starts: [future], to: store)
            XCTAssertEqual(accepted, outcome(newSeries: 1, added: [.input: 5], changedSessions: ["session-a"]))

            clock.set(Date(timeIntervalSince1970: 2_000))
            try await restart(store, deleting: deleting)
            let trackedFrom = try await store.trackedFromNs()
            XCTAssertEqual(trackedFrom, 2_000_000_000_000, "deleting: \(deleting)")
            let ordinary = try await send(
                [sample(series: 2, timeNs: 10, value: 8)], starts: [fresh(3_000_000_000_000, session: "session-b")],
                to: store)
            XCTAssertEqual(ordinary, outcome(newSeries: 1, added: [.input: 8], changedSessions: ["session-a"]), "deleting: \(deleting)")
        }
    }

    func test_restart_recoversFromADistantFutureCreationClock() async throws {
        for deleting in [false, true] {
            try await closeAllStoresAndRemoveDirectory()
            let clock = UsageTestClock(Date.distantFuture)
            let store = try openStore(clock: clock)
            let ignored = try await sendRealisticExport(to: store)
            XCTAssertEqual(ignored, outcome(ignored: true))

            clock.set(Self.tracked)
            try await restart(store, deleting: deleting)
            let trackedFrom = try await store.trackedFromNs()
            XCTAssertEqual(trackedFrom, Self.trackedNs, "deleting: \(deleting)")
            let counted = try await sendRealisticExport(to: store)
            XCTAssertEqual(counted, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]), "deleting: \(deleting)")
        }
    }

    // MARK: - Retirement

    func test_restart_retiresEveryActiveProcess_deletesSeries_resetKeepsPoints() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 5)], starts: [fresh(500)], to: store)
        try await send([sample(series: 2, session: "session-b", timeNs: 10, value: 6)],
                       starts: [fresh(600, session: "session-b")], to: store)
        // Two processes of ONE session are two processes.
        try await send([sample(series: 3, startNs: 700, timeNs: 10, value: 7)], starts: [fresh(700)], to: store)
        let before = try await store.retiredProcessCount()
        XCTAssertEqual(before, 0)

        try await store.resetTracking()

        let retired = try await store.retiredProcessCount()
        let starts = try await store.processStarts()
        let series = try await store.seriesRows()
        let rows = try await store.pointRows()
        XCTAssertEqual(retired, 3)
        XCTAssertEqual(starts, [])
        XCTAssertEqual(series, [])
        XCTAssertEqual(rows.map(\.inputTokens).reduce(0, +), 18, "resetTracking keeps the points")
    }

    func test_retiringTheSameProcessTwice_keepsOneDigest_andDigestsSurviveDeleteAll() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 5)], starts: [fresh(500)], to: store)
        try await store.resetTracking()
        // Heard again after the restart (outside the window): active again.
        try await send([sample(timeNs: 20, value: 6)], starts: [fresh(500)], to: store)
        let active = try await store.processStarts()
        XCTAssertEqual(active, [fresh(500)])
        try await store.deleteAll()
        let afterDelete = try await store.retiredProcessCount()
        XCTAssertEqual(afterDelete, 1, "The same process is one digest")

        try await send([sample(timeNs: 30, value: 7)], starts: [fresh(900, session: "session-c")], to: store)
        try await store.deleteAll()
        let afterSecondDelete = try await store.retiredProcessCount()
        XCTAssertEqual(afterSecondDelete, 2, "deleteAll never deletes digests")
    }

    func test_ignoredCalls_onlyTheSettlingWindowCaseRecordsADigest() async throws {
        let store = try openStore(at: Self.tracked)
        try await send([sample(timeNs: 10, value: 9)], starts: [], to: store)
        try await send([sample(timeNs: 10, value: 9)], starts: [oldProcess, fresh(Self.trackedNs)], to: store)
        try await send([sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs)], to: store, at: Self.trackedNs - 1)
        try await send([sample(timeNs: 10, value: 9)], starts: [oldProcess], to: store, at: Self.trackedNs - 1)
        let afterOtherReasons = try await store.retiredProcessCount()
        XCTAssertEqual(afterOtherReasons, 0)
        try await send([sample(timeNs: 10, value: 9)], starts: [oldProcess], to: store, at: Self.trackedNs + 1)
        let afterWindow = try await store.retiredProcessCount()
        XCTAssertEqual(afterWindow, 1)
        try await store.resetTracking()
        let afterReset = try await store.retiredProcessCount()
        XCTAssertEqual(afterReset, 1, "nothing was active")
    }

    /// A process that predates tracking and was heard ONLY inside the
    /// settling window is remembered: after a restart with the clock set
    /// back below its start it still predates tracking.
    func test_processHeardOnlyInsideTheWindow_isRememberedAcrossARestartWithTheClockSetBack() async throws {
        for deleting in [false, true] {
            try await closeAllStoresAndRemoveDirectory()
            let clock = UsageTestClock(Self.tracked)
            let store = try openStore(clock: clock)
            let inside = try await send([sample(timeNs: 10, value: 100)], starts: [oldProcess], to: store,
                                        at: Self.trackedNs + 1_000_000_000)
            XCTAssertEqual(inside, outcome(ignored: true))

            let setBackNs = oldProcess.startNs - 100_000_000_000
            clock.set(Date(timeIntervalSince1970: Double(setBackNs / 1_000_000_000)))
            try await restart(store, deleting: deleting)
            let trackedFrom = try await store.trackedFromNs()
            XCTAssertEqual(trackedFrom, setBackNs)
            XCTAssertLessThan(trackedFrom, oldProcess.startNs, "Fixture error")

            let insideNew = try await send([sample(timeNs: 20, value: 150)], starts: [oldProcess], to: store,
                                           at: setBackNs + Self.settleNs - 1)
            XCTAssertEqual(insideNew, outcome(ignored: true), "deleting: \(deleting)")
            let baseline = try await send([sample(timeNs: 30, value: 200)], starts: [oldProcess], to: store,
                                          at: setBackNs + Self.settleNs)
            XCTAssertEqual(baseline, outcome(baselineOnly: 1, changedSessions: ["session-a"]), "deleting: \(deleting)")
            let growth = try await send([sample(timeNs: 40, value: 206)], starts: [oldProcess], to: store,
                                        at: setBackNs + Self.settleNs + 5_000_000_000)
            XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 6], changedSessions: ["session-a"]), "deleting: \(deleting)")
            let rows = try await store.pointRows()
            XCTAssertEqual(rows.map(\.inputTokens), [6], "deleting: \(deleting)")
        }
    }

    /// The digest of `(sessionID, startNs)` as the contract defines it.
    private func expectedDigest(_ sessionID: String, _ startNs: Int64) -> String {
        let bytes = Data(sessionID.utf8) + Data([0]) + Data(String(startNs).utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Every stored cell of `usage_retired_processes`, as text.
    private func retiredDigestCells() throws -> [String] {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(try databaseURL().path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: cannot open the database")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT * FROM usage_retired_processes", -1, &statement, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: no usage_retired_processes table")
        }
        var cells: [String] = []
        let columns = sqlite3_column_count(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0..<columns {
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { continue }
                cells.append(String(decoding: Data(bytes: bytes, count: count), as: UTF8.self))
            }
        }
        return cells
    }

    func test_retiredDigest_isSHA256OfSessionNULAndDecimalStart() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let process = UsageProcessStart(
            sessionID: "11111111-1111-4111-8111-111111111111", startNs: 1_791_183_405_041_000_000, startType: "fresh")
        try await send([sample(timeNs: 10, value: 1)], starts: [process], to: store)
        try await store.resetTracking()
        await store.close()
        XCTAssertEqual(try retiredDigestCells(), [expectedDigest(process.sessionID, process.startNs)])
    }

    func test_retiredDigest_ofANegativeStart_usesItsDecimalForm() async throws {
        let store = try openStore(at: Date.distantPast)
        let process = UsageProcessStart(sessionID: "session-n", startNs: -42, startType: nil)
        try await send([sample(timeNs: 10, value: 1)], starts: [process], to: store)
        try await store.resetTracking()
        await store.close()
        XCTAssertEqual(try retiredDigestCells(), [expectedDigest("session-n", -42)])
    }

    /// "s1" + "23" and "s12" + "3" concatenate alike; with the separator
    /// they are two processes, and retiring one does not make the other
    /// predate tracking.
    func test_retiredDigest_separatorTellsApartProcessesThatConcatenateAlike() async throws {
        XCTAssertNotEqual(expectedDigest("s1", 23), expectedDigest("s12", 3), "Fixture error")
        let store = try openStore()
        try await send([sample(session: "s1", timeNs: 10, value: 1)], starts: [fresh(23, session: "s1")], to: store)
        try await store.resetTracking()
        let retired = try await store.retiredProcessCount()
        XCTAssertEqual(retired, 1)

        // Inside the window after the restart (tracking from 0): the
        // retired "s1" process is ignored, the never-heard "s12" one counts.
        let retiredOne = try await send([sample(session: "s1", timeNs: 20, value: 5)], starts: [fresh(23, session: "s1")],
                                        to: store, at: 1_000)
        XCTAssertEqual(retiredOne, outcome(ignored: true))
        let other = try await send([sample(session: "s12", timeNs: 20, value: 7)], starts: [fresh(3, session: "s12")],
                                   to: store, at: 1_000)
        XCTAssertEqual(other, outcome(newSeries: 1, added: [.input: 7], changedSessions: ["s12"]))
    }

    // MARK: - An unchanged value writes nothing

    private func movedLater(_ samples: [UsageSeriesSample], by ns: Int64, valueDelta: (UsageSeriesSample) -> Int64 = { _ in 0 })
        -> [UsageSeriesSample] {
        samples.map {
            UsageSeriesSample(
                sessionID: $0.sessionID, seriesID: $0.seriesID, startNs: $0.startNs, timeNs: $0.timeNs + ns, kind: $0.kind,
                value: $0.value + valueDelta($0), model: $0.model, effort: $0.effort, thread: $0.thread, agent: $0.agent)
        }
    }

    private func fileBytes(_ name: String) throws -> Data? {
        let url = try storeDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func test_unchangedValues_writeNothing_thenGrowthCountsOnce_andAnEarlierExportIsStale() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run1")
        try await apply(exports, to: store)
        let last = try XCTUnwrap(exports.last)
        let fiveSeconds: Int64 = 5_000_000_000
        let seriesBefore = try await store.seriesRows()
        let databaseBefore = try fileBytes("usage.sqlite")
        let walBefore = try fileBytes("usage.sqlite-wal")
        XCTAssertNotNil(walBefore, "Fixture error: the WAL must exist while the store is open")

        let idle = try await store.apply(
            samples: movedLater(last.batch.samples, by: fiveSeconds), processStarts: last.batch.processStarts,
            receivedAtNs: last.receivedAtNs + fiveSeconds)

        XCTAssertEqual(idle, outcome(unchangedSamples: 8))
        let seriesAfter = try await store.seriesRows()
        XCTAssertEqual(seriesAfter, seriesBefore, "lastTimeNs must not move on an unchanged value")
        XCTAssertEqual(try fileBytes("usage.sqlite"), databaseBefore, "an idle export must not write the database")
        XCTAssertEqual(try fileBytes("usage.sqlite-wal"), walBefore, "an idle export must not write the WAL")

        let regressing = last.batch.samples.filter { $0.value > 0 }.count
        XCTAssertGreaterThan(regressing, 0, "Fixture error")
        let regression = try await store.apply(
            samples: movedLater(last.batch.samples, by: fiveSeconds + 1) { $0.value > 0 ? -1 : 0 },
            processStarts: last.batch.processStarts, receivedAtNs: last.receivedAtNs + fiveSeconds + 1)
        XCTAssertEqual(regression, outcome(unchangedSamples: 8 - regressing, regressions: regressing))
        let seriesAfterRegression = try await store.seriesRows()
        XCTAssertEqual(seriesAfterRegression, seriesBefore, "a regression must not write")
        XCTAssertEqual(try fileBytes("usage.sqlite"), databaseBefore, "a regression must not write the database")
        XCTAssertEqual(try fileBytes("usage.sqlite-wal"), walBefore, "a regression must not write the WAL")

        let idleAgain = try await store.apply(
            samples: movedLater(last.batch.samples, by: 2 * fiveSeconds), processStarts: last.batch.processStarts,
            receivedAtNs: last.receivedAtNs + 2 * fiveSeconds)
        XCTAssertEqual(idleAgain, outcome(unchangedSamples: 8))

        let growing = try XCTUnwrap(last.batch.samples.first { $0.kind == .output })
        let grow = try await store.apply(
            samples: movedLater(last.batch.samples, by: 3 * fiveSeconds) { $0 == growing ? 7 : 0 },
            processStarts: last.batch.processStarts, receivedAtNs: last.receivedAtNs + 3 * fiveSeconds)
        XCTAssertEqual(grow, outcome(advancedSeries: 1, unchangedSamples: 7, added: [.output: 7], changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let repeated = try await store.apply(
            samples: movedLater(last.batch.samples, by: 4 * fiveSeconds) { $0 == growing ? 7 : 0 },
            processStarts: last.batch.processStarts, receivedAtNs: last.receivedAtNs + 4 * fiveSeconds)
        XCTAssertEqual(repeated, outcome(unchangedSamples: 8))

        // Every export of the run sent again changes nothing: each sample
        // is stale or unchanged. Export 2 is the first export of every
        // series, so each series' stored time is at or after it: all stale.
        let pointsBeforeResend = try await store.pointRows()
        let seriesBeforeResend = try await store.seriesRows()
        for (index, export) in exports.enumerated() {
            let resent = try await apply(export, to: store)
            XCTAssertFalse(resent.ignored, "export \(index + 1)")
            XCTAssertEqual(resent.staleSamples + resent.unchangedSamples, export.batch.samples.count, "export \(index + 1)")
            XCTAssertEqual(resent.newSeries + resent.baselineOnly + resent.advancedSeries + resent.regressions, 0,
                           "export \(index + 1)")
            XCTAssertEqual(resent.added, [:], "export \(index + 1)")
        }
        let pointsAfterResend = try await store.pointRows()
        let seriesAfterResend = try await store.seriesRows()
        XCTAssertEqual(pointsAfterResend, pointsBeforeResend)
        XCTAssertEqual(seriesAfterResend, seriesBeforeResend)
        let firstExport = try await apply(try element(exports, at: 1), to: store)
        XCTAssertEqual(firstExport, outcome(staleSamples: 8))

        var expected = try Fixtures.expectedTotals(run: "run1")
        expected["claude-sonnet-5-5"]?["output"] = 2_114 + 7
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, expected, "the growth is added exactly once")
    }

    func test_deleteAll_keepsNoRowWithTheSessionIDOfARetiredProcess() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run2"), to: store)
        try await store.deleteAll()
        let retired = try await store.retiredProcessCount()
        XCTAssertEqual(retired, 1)
        await store.close()
        XCTAssertEqual(try textValues(containing: "22222222-2222-4222-8222-222222222222"), [])
    }

    /// An export received before a delete but applied after it (it was
    /// waiting for the store) must not set a baseline from before the
    /// delete; the exports that follow count exactly their growth.
    func test_exportReceivedBeforeDeleteAll_appliedAfterIt_isIgnored() async throws {
        let base: Int64 = 1_791_183_000_000_000_000
        let second: Int64 = 1_000_000_000
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_791_183_100))
        let store = try openStore(clock: clock)
        let process = UsageProcessStart(sessionID: "session-a", startNs: base + 150 * second, startType: "fresh")
        func export(_ value: Int64, time: Int64) -> [UsageSeriesSample] {
            [sample(startNs: base + 160 * second, timeNs: base + time * second, value: value)]
        }
        let first = try await send(export(10, time: 199), starts: [process], to: store, at: base + 200 * second)
        XCTAssertEqual(first, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]))

        clock.set(Date(timeIntervalSince1970: 1_791_183_300))
        try await store.deleteAll()
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, base + 300 * second)

        let late = try await send(export(30, time: 259), starts: [process], to: store, at: base + 260 * second)
        XCTAssertEqual(late, outcome(ignored: true))
        try await assertNothingStored(store, retired: 1)

        let baseline = try await send(export(50, time: 319), starts: [process], to: store, at: base + 320 * second)
        XCTAssertEqual(baseline, outcome(baselineOnly: 1, changedSessions: ["session-a"]))
        let growth = try await send(export(55, time: 329), starts: [process], to: store, at: base + 330 * second)
        XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 5], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows.map(\.inputTokens), [5])
    }

    func test_exportReceivedBeforeResetTracking_appliedAfterIt_isIgnored() async throws {
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try openStore(clock: clock)
        let process = fresh(1_000_000_000_000)
        try await send([sample(timeNs: 10, value: 10)], starts: [process], to: store, at: 1_100_000_000_000)
        clock.set(Date(timeIntervalSince1970: 1_300))
        try await store.resetTracking()
        let late = try await send([sample(timeNs: 20, value: 30)], starts: [process], to: store, at: 1_200_000_000_000)
        XCTAssertEqual(late, outcome(ignored: true))
        let series = try await store.seriesRows()
        XCTAssertEqual(series, [])
        let next = try await send([sample(timeNs: 30, value: 45)], starts: [process], to: store, at: 1_400_000_000_000)
        XCTAssertEqual(next, outcome(baselineOnly: 1, changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows.map(\.inputTokens), [10])
    }

    func test_deleteAll_alsoRemovesVersion1Records() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 3)], to: store)
        try await store.apply(UsageBatch(
            records: [], session: UsageSessionMeta(sessionID: "s", transcriptPath: nil, projectRoot: nil), fileCheckpoint: nil))
        try await store.deleteAll()
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [])
        try await assertNothingStored(store, retired: 1)
    }

    // MARK: - seriesRows

    func test_seriesRows_afterRun2AndRun3_holdFinalValue_kindModel_andFirstReceiveTime() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run2") + receivedExports(run: "run3")
        try await apply(exports, to: store)
        let rows = try await store.seriesRows()

        // lastTimeNs: the time at which the series' final value was first
        // seen (an unchanged value does not move it).
        var lastSamples: [String: UsageSeriesSample] = [:]
        var firstHeard: [String: Int64] = [:]
        for export in exports {
            for sample in export.batch.samples {
                let key = "\(sample.sessionID)|\(sample.seriesID)|\(sample.startNs)"
                if lastSamples[key]?.value != sample.value { lastSamples[key] = sample }
                if firstHeard[key] == nil { firstHeard[key] = export.receivedAtNs }
            }
        }
        var expected: [UsageSeriesRow] = []
        for (key, last) in lastSamples {
            expected.append(UsageSeriesRow(
                sessionID: last.sessionID, seriesID: last.seriesID, startNs: last.startNs, kind: last.kind,
                model: last.model, lastValue: last.value, lastTimeNs: last.timeNs,
                firstHeardNs: try XCTUnwrap(firstHeard[key])))
        }
        expected.sort { ($0.sessionID, $0.startNs, $0.seriesID) < ($1.sessionID, $1.startNs, $1.seriesID) }
        XCTAssertEqual(expected.count, 24, "Fixture error: run2 has 20 series, run3 has 4")
        XCTAssertEqual(Set(expected.map(\.firstHeardNs)).count > 1, true, "Fixture error: series appear in several exports")
        XCTAssertEqual(rows, expected)
        XCTAssertEqual(Fixtures.sumByModel(rows.map { ($0.model, $0.kind.rawValue, $0.lastValue) }),
                       try Fixtures.expectedTotals(run: "run3"))
    }

    func test_seriesRows_baselineOnlySeries_storesItsFullValue() async throws {
        // run4's process started at …710.265 s, before tracking at …800 s;
        // its export is received after the settling window.
        let store = try openStore(at: Date(timeIntervalSince1970: 1_791_183_800))
        let export = try XCTUnwrap(try receivedExports(run: "run4").first)
        let result = try await store.apply(
            samples: export.batch.samples, processStarts: export.batch.processStarts,
            receivedAtNs: 1_791_183_900_000_000_000)
        XCTAssertEqual(result, outcome(baselineOnly: 4, changedSessions: ["44444444-4444-4444-8444-444444444444"]))
        let points = try await store.pointRows()
        XCTAssertEqual(points, [])
        let rows = try await store.seriesRows()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.firstHeardNs)), [1_791_183_900_000_000_000])
        XCTAssertEqual(Fixtures.sumByModel(rows.map { ($0.model, $0.kind.rawValue, $0.lastValue) }),
                       try Fixtures.expectedTotals(run: "run4"))
    }

    func test_seriesRows_keepTheLargestValueThroughRegressions_theFirstModel_andTheFirstReceiveTime() async throws {
        let store = try openStore()
        try await send([sample(series: 1, timeNs: 10, kind: .output, value: 100, model: "m-first")], to: store, at: 5_000)
        try await send([sample(series: 1, timeNs: 20, kind: .output, value: 40, model: "m-first")], to: store, at: 9_000)
        try await send([sample(series: 1, timeNs: 30, kind: .output, value: 60, model: "m-first")], to: store, at: 12_000)
        let rows = try await store.seriesRows()
        XCTAssertEqual(rows, [UsageSeriesRow(
            sessionID: "session-a", seriesID: seriesID(1), startNs: 1_000, kind: .output, model: "m-first",
            lastValue: 100, lastTimeNs: 10, firstHeardNs: 5_000)])
    }

    func test_seriesRows_areOrderedBySessionStartAndSeriesID() async throws {
        let store = try openStore()
        try await send([
            sample(series: 2, session: "b", startNs: 5, timeNs: 100, value: 1),
            sample(series: 3, session: "a", startNs: 9, timeNs: 100, value: 1),
            sample(series: 2, session: "a", startNs: 7, timeNs: 100, value: 1),
            sample(series: 1, session: "a", startNs: 9, timeNs: 100, value: 1),
        ], to: store)
        let rows = try await store.seriesRows()
        XCTAssertEqual(rows.map { "\($0.sessionID)/\($0.startNs)/\($0.seriesID.suffix(1))" },
                       ["a/7/2", "a/9/1", "a/9/3", "b/5/2"])
    }

    // MARK: - processStarts

    private let startA = UsageProcessStart(sessionID: "session-a", startNs: 500, startType: "fresh")

    func test_processStarts_fromEveryExportOfARun_areStoredOnce() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run2") + receivedExports(run: "run3")
        try await apply(exports, to: store)
        try await apply(exports, to: store)
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [
            UsageProcessStart(sessionID: "22222222-2222-4222-8222-222222222222", startNs: 1_791_183_586_797_000_000, startType: "fresh"),
            UsageProcessStart(sessionID: "22222222-2222-4222-8222-222222222222", startNs: 1_791_183_681_268_000_000, startType: "resume"),
        ])
    }

    func test_processStarts_firstStoredStartTypeWins() async throws {
        let store = try openStore()
        try await send([], starts: [startA], to: store)
        try await send([], starts: [UsageProcessStart(sessionID: "session-a", startNs: 500, startType: "resume")], to: store)
        try await send([], starts: [UsageProcessStart(sessionID: "session-a", startNs: 500, startType: nil)], to: store)
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [startA])

        let nilFirst = UsageProcessStart(sessionID: "session-b", startNs: 1, startType: nil)
        try await send([], starts: [nilFirst], to: store)
        try await send([], starts: [UsageProcessStart(sessionID: "session-b", startNs: 1, startType: "fresh")], to: store)
        let both = try await store.processStarts()
        XCTAssertEqual(both, [startA, nilFirst])
    }

    func test_processStarts_areOrderedBySessionAndStart() async throws {
        let store = try openStore()
        try await send([], starts: [UsageProcessStart(sessionID: "b", startNs: 1, startType: "fresh")], to: store)
        try await send([], starts: [UsageProcessStart(sessionID: "a", startNs: 30, startType: "resume")], to: store)
        try await send([], starts: [UsageProcessStart(sessionID: "a", startNs: 4, startType: nil)], to: store)
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [
            UsageProcessStart(sessionID: "a", startNs: 4, startType: nil),
            UsageProcessStart(sessionID: "a", startNs: 30, startType: "resume"),
            UsageProcessStart(sessionID: "b", startNs: 1, startType: "fresh"),
        ])
    }

    func test_processStarts_onlyStarts_isNotANoOp_andAddsNoTokens() async throws {
        let store = try openStore()
        let result = try await send([], starts: [startA], to: store)
        XCTAssertEqual(result, UsageSeriesApplyOutcome())
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [startA])
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [])
    }

    func test_processStarts_resetTrackingAndDeleteAll_removeThem_andALaterExportStoresThemAgain() async throws {
        let store = try openStore()
        try await send([sample(startNs: 500, timeNs: 10, value: 1)], starts: [startA], to: store)
        try await store.resetTracking()
        let afterReset = try await store.processStarts()
        XCTAssertEqual(afterReset, [])
        try await send([sample(startNs: 500, timeNs: 20, value: 2)], starts: [startA], to: store)
        let again = try await store.processStarts()
        XCTAssertEqual(again, [startA])

        try await store.deleteAll()
        let afterDelete = try await store.processStarts()
        XCTAssertEqual(afterDelete, [])
        try await send([sample(startNs: 500, timeNs: 30, value: 3)], starts: [startA], to: store)
        let stored = try await store.processStarts()
        XCTAssertEqual(stored, [startA])
    }

    func test_processStarts_failingCall_storesNoStart_andNoSeries() async throws {
        let store = try openStore()
        try await send([sample(series: 9, session: "other", timeNs: 10, value: 1)], to: store)
        // Makes the points insert of the session "poison" fail inside the
        // call's transaction, after its process start and series were written.
        try execute("""
            CREATE TRIGGER fail_poison_points BEFORE INSERT ON usage_points WHEN NEW.session_id = 'poison'
            BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
            """, at: try databaseURL())
        let poison = UsageProcessStart(sessionID: "poison", startNs: 500, startType: "fresh")
        do {
            try await send([sample(session: "poison", startNs: 600, timeNs: 10, value: 5)], starts: [poison], to: store)
            XCTFail("The call must fail")
        } catch {}
        let starts = try await store.processStarts()
        XCTAssertEqual(starts, [Self.defaultProcess], "Process starts must share the samples' transaction")
        let series = try await store.seriesRows()
        XCTAssertEqual(series.map(\.sessionID), ["other"])
    }

    // MARK: - Label groups and order

    func test_pointRows_groupsNilLabelsSeparately_andOrdersNilBeforeStrings() async throws {
        let store = try openStore()
        try await send([sample(series: 1, session: "session-b", timeNs: 1, value: 1, effort: nil, thread: nil)],
                       to: store, at: Self.minuteStartNs - Self.oneMinuteNs)
        try await send([sample(series: 2, timeNs: 1, value: 2, effort: nil, thread: nil)],
                       to: store, at: Self.minuteStartNs + Self.oneMinuteNs)
        try await send([
            sample(series: 3, timeNs: 1, value: 3, model: "m2", effort: nil, thread: nil),
            sample(series: 4, timeNs: 1, value: 4, model: "m1", effort: "low", thread: "main", agent: "Explore"),
            sample(series: 5, timeNs: 1, value: 5, model: "m1", effort: "high", thread: "main", agent: "Explore"),
            sample(series: 6, timeNs: 1, value: 6, model: "m1", effort: "high", thread: "main", agent: nil),
            sample(series: 7, timeNs: 1, value: 7, model: "m1", effort: "high", thread: nil, agent: nil),
            sample(series: 8, timeNs: 1, value: 8, model: "m1", effort: nil, thread: "main", agent: nil),
            sample(series: 9, timeNs: 1, value: 9, model: "m1", effort: nil, thread: nil, agent: nil),
            sample(series: 10, timeNs: 1, value: 10, model: "m1", effort: nil, thread: nil, agent: "Explore"),
            sample(series: 11, timeNs: 1, value: 11, model: "m1", effort: nil, thread: nil, agent: nil),
        ], to: store)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [
            row(minute: Self.minute, model: "m1", effort: nil, thread: nil, agent: nil, input: 20),
            row(minute: Self.minute, model: "m1", effort: nil, thread: nil, agent: "Explore", input: 10),
            row(minute: Self.minute, model: "m1", effort: nil, thread: "main", agent: nil, input: 8),
            row(minute: Self.minute, model: "m1", effort: "high", thread: nil, agent: nil, input: 7),
            row(minute: Self.minute, model: "m1", effort: "high", thread: "main", agent: nil, input: 6),
            row(minute: Self.minute, model: "m1", effort: "high", thread: "main", agent: "Explore", input: 5),
            row(minute: Self.minute, model: "m1", effort: "low", thread: "main", agent: "Explore", input: 4),
            row(minute: Self.minute, model: "m2", effort: nil, thread: nil, agent: nil, input: 3),
            row(minute: Self.minute + 1, model: "claude-sonnet-5-5", effort: nil, thread: nil, agent: nil, input: 2),
            row(session: "session-b", minute: Self.minute - 1, model: "claude-sonnet-5-5", effort: nil, thread: nil,
                agent: nil, input: 1),
        ])
    }

    // MARK: - Saturation

    func test_saturation_acrossCalls_pointSumStopsAtInt64Max_andOtherSeriesStillApply() async throws {
        let store = try openStore()
        let nearMax = Int64.max - 10
        try await send([sample(series: 1, timeNs: 10, value: nearMax)], to: store)
        let result = try await send([
            sample(series: 2, timeNs: 11, value: 11),
            sample(series: 3, timeNs: 11, kind: .output, value: 4),
        ], to: store)
        XCTAssertEqual(result, outcome(newSeries: 2, added: [.input: 11, .output: 4], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: Int64.max, output: 4)])
        let series = try await store.seriesRows()
        XCTAssertEqual(series.count, 3)
    }

    func test_saturation_withinOneCall_addedAndPointStopAtInt64Max() async throws {
        let store = try openStore()
        let result = try await send([
            sample(series: 1, timeNs: 10, kind: .output, value: 7),
            sample(series: 2, timeNs: 10, value: Int64.max),
            sample(series: 3, timeNs: 11, value: 1),
            sample(series: 4, timeNs: 12, value: Int64.max),
        ], to: store)
        XCTAssertEqual(result, outcome(newSeries: 4, added: [.input: Int64.max, .output: 7], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: Int64.max, output: 7)])
    }

    func test_int64MaxInOneRow_isStoredExactly() async throws {
        let store = try openStore()
        try await send([
            sample(series: 1, timeNs: 10, value: Int64.max - 1),
            sample(series: 2, timeNs: 10, value: 1),
        ], to: store)
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: Int64.max)])
    }

    // MARK: - Closed store

    func test_afterClose_newMethodsThrowClosed() async throws {
        let store = try openStore()
        await store.close()
        for (name, call) in [
            ("apply", { _ = try await store.apply(samples: [], receivedAtNs: 0) }),
            ("pointRows", { _ = try await store.pointRows() }),
            ("trackedFromNs", { _ = try await store.trackedFromNs() }),
            ("seriesRows", { _ = try await store.seriesRows() }),
            ("processStarts", { _ = try await store.processStarts() }),
            ("resetTracking", { try await store.resetTracking() }),
        ] as [(String, () async throws -> Void)] {
            do {
                try await call()
                XCTFail("\(name) must throw after close")
            } catch {
                XCTAssertEqual(error as? UsageStoreError, .closed, name)
            }
        }
    }

    // MARK: - Clock conversion
    //
    // The clock becomes whole nanoseconds since the epoch, truncated toward
    // zero and saturated to Int64; a non-finite clock reads as Int64.max,
    // and with tracked_from at Int64.max every call is ignored (a clock
    // that cannot be trusted records nothing). Reading the clock never
    // throws, so the calls below are wrapped and a thrown error is
    // reported, never propagated.

    private func openOrFail(
        _ clock: UsageTestClock, file: StaticString = #filePath, line: UInt = #line
    ) -> UsageStore? {
        do {
            return try openStore(clock: clock)
        } catch {
            XCTFail("Opening must not throw for this clock; got \(error)", file: file, line: line)
            return nil
        }
    }

    private func trackedFromOrFail(
        _ store: UsageStore, file: StaticString = #filePath, line: UInt = #line
    ) async -> Int64? {
        do {
            return try await store.trackedFromNs()
        } catch {
            XCTFail("trackedFromNs threw \(error)", file: file, line: line)
            return nil
        }
    }

    /// A realistic export of a process that started shortly before it.
    private func sendRealisticExport(to store: UsageStore) async throws -> UsageSeriesApplyOutcome {
        let start = UsageProcessStart(sessionID: "session-a", startNs: Self.minuteStartNs - 5_000_000_000, startType: "fresh")
        return try await send(
            [sample(startNs: Self.minuteStartNs - 4_000_000_000, timeNs: Self.minuteStartNs, value: 10)],
            starts: [start], to: store)
    }

    private func assertEveryCallIgnored(
        _ store: UsageStore, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let withProcess = try await sendRealisticExport(to: store)
            XCTAssertEqual(withProcess, outcome(ignored: true), file: file, line: line)
            let later = try await send(
                [sample(series: 2, timeNs: Self.minuteStartNs, value: 3)],
                starts: [fresh(Self.minuteStartNs + 1, session: "session-b")], to: store,
                at: Self.minuteStartNs + Self.oneMinuteNs)
            XCTAssertEqual(later, outcome(ignored: true), file: file, line: line)
            try await assertNothingStored(store, "", file: file, line: line)
        } catch {
            XCTFail("apply must not throw; got \(error)", file: file, line: line)
        }
    }

    func test_clock_distantFuture_tracksFromInt64Max_andEveryCallIsIgnored() async {
        guard let store = openOrFail(UsageTestClock(Date.distantFuture)) else { return }
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.max)
        await assertEveryCallIgnored(store)
    }

    func test_clock_distantPast_tracksFromInt64Min_andExportsCount() async throws {
        guard let store = openOrFail(UsageTestClock(Date.distantPast)) else { return }
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.min)
        let result = try await sendRealisticExport(to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]))
    }

    private func assertNonFiniteClockIgnoresEverything(
        _ seconds: Double, file: StaticString = #filePath, line: UInt = #line
    ) async {
        guard let store = openOrFail(UsageTestClock(Date(timeIntervalSince1970: seconds)), file: file, line: line) else {
            return
        }
        let trackedFrom = await trackedFromOrFail(store, file: file, line: line)
        XCTAssertEqual(trackedFrom, Int64.max, file: file, line: line)
        await assertEveryCallIgnored(store, file: file, line: line)
    }

    func test_clock_nan_tracksFromInt64Max_andEveryCallIsIgnored() async {
        await assertNonFiniteClockIgnoresEverything(.nan)
    }

    func test_clock_plusInfinity_tracksFromInt64Max_andEveryCallIsIgnored() async {
        await assertNonFiniteClockIgnoresEverything(.infinity)
    }

    func test_clock_minusInfinity_tracksFromInt64Max_andEveryCallIsIgnored() async {
        await assertNonFiniteClockIgnoresEverything(-.infinity)
    }

    /// Opens with an ordinary clock (1_000 s), moves the clock, deletes.
    private func storeAfterDeleteAll(
        clockMovedTo date: Date, file: StaticString = #filePath, line: UInt = #line
    ) async -> UsageStore? {
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
        guard let store = openOrFail(clock, file: file, line: line) else { return nil }
        clock.set(date)
        do {
            try await store.deleteAll()
        } catch {
            XCTFail("deleteAll must not throw for this clock; got \(error)", file: file, line: line)
            return nil
        }
        return store
    }

    func test_deleteAll_clockMovedToDistantFuture_tracksFromInt64Max_andIgnoresEverything() async {
        guard let store = await storeAfterDeleteAll(clockMovedTo: Date.distantFuture) else { return }
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.max)
        await assertEveryCallIgnored(store)
    }

    func test_deleteAll_clockMovedToNaN_tracksFromInt64Max_andIgnoresEverything() async {
        guard let store = await storeAfterDeleteAll(clockMovedTo: Date(timeIntervalSince1970: .nan)) else { return }
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.max)
        await assertEveryCallIgnored(store)
    }

    func test_deleteAll_clockMovedToDistantPast_withNothingStored_tracksFromInt64Min_andExportsCount() async throws {
        guard let store = await storeAfterDeleteAll(clockMovedTo: Date.distantPast) else { return }
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.min)
        let result = try await sendRealisticExport(to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]))
    }

    func test_clock_ordinaryDates_truncateTowardZero() async throws {
        let cases: [(Double, Int64)] = [
            (1_700_000_000.5, 1_700_000_000_500_000_000),
            (-0.5, -500_000_000),
            (0, 0),
        ]
        for (seconds, expected) in cases {
            try await closeAllStoresAndRemoveDirectory()
            guard let store = openOrFail(UsageTestClock(Date(timeIntervalSince1970: seconds))) else { continue }
            let trackedFrom = await trackedFromOrFail(store)
            XCTAssertEqual(trackedFrom, expected, "\(seconds) s")
        }
    }

    // MARK: - Schema and migration

    /// The version-1 schema exactly as the first release of the store
    /// created it; frozen here so the migration is tested against the
    /// real thing, not against whatever the current source says.
    private static let version1Schema = """
        CREATE TABLE usage_records (
            key TEXT NOT NULL PRIMARY KEY CHECK (length(key) > 0),
            session_id TEXT NOT NULL,
            timestamp_ms INTEGER NOT NULL,
            model TEXT NOT NULL,
            effort TEXT,
            thread TEXT NOT NULL,
            agent_id TEXT,
            agent_type TEXT,
            git_branch TEXT,
            cwd TEXT,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            thinking_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_creation_tokens INTEGER NOT NULL,
            cache_creation_1h_tokens INTEGER NOT NULL,
            is_final INTEGER NOT NULL CHECK (is_final IN (0, 1))
        ) WITHOUT ROWID;
        CREATE INDEX usage_records_session ON usage_records (session_id);
        CREATE INDEX usage_records_timestamp ON usage_records (timestamp_ms);
        CREATE TABLE usage_sessions (
            session_id TEXT NOT NULL PRIMARY KEY,
            transcript_path TEXT,
            project_root TEXT
        ) WITHOUT ROWID;
        CREATE TABLE usage_files (
            path TEXT NOT NULL PRIMARY KEY,
            inode INTEGER NOT NULL,
            offset INTEGER NOT NULL
        ) WITHOUT ROWID;
        """

    /// Runs `sql` on a new connection to the database file, creating it.
    private func execute(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: sqlite3_open failed")
        }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: sqlite3_exec failed")
        }
    }

    /// One integer from `sql`, or nil. READWRITE for the same reason as in
    /// UsageStoreTests: a closed WAL database cannot be opened read-only.
    private func integer(_ sql: String, at url: URL) -> Int64? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func corruptSiblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try storeDirectory().path)
            .filter { $0.hasPrefix("usage.sqlite.corrupt-") }
    }

    private var version1Record: UsageRecord {
        UsageRecord(
            key: "msg_v1", sessionID: "session-v1", timestampMs: 1_790_935_200_000, model: "claude-opus-5-5",
            effort: "high", thread: .subagent, agentID: "agent-1", agentType: "Explore", gitBranch: "main",
            cwd: "/tmp/project", inputTokens: 3, outputTokens: 100, thinkingTokens: 10, cacheReadTokens: 9_000,
            cacheCreationTokens: 120, cacheCreation1hTokens: 100, isFinal: true)
    }

    private static let version1Rows = """
        INSERT INTO usage_records VALUES ('msg_v1', 'session-v1', 1790935200000, 'claude-opus-5-5', 'high', \
        'subagent', 'agent-1', 'Explore', 'main', '/tmp/project', 3, 100, 10, 9000, 120, 100, 1);
        INSERT INTO usage_sessions VALUES ('session-v1', '/t/v1.jsonl', '/r/v1');
        INSERT INTO usage_files VALUES ('/t/v1.jsonl', 7, 99);
        PRAGMA user_version = 1;
        """

    private func tableCount(_ table: String, at url: URL) -> Int64? {
        integer("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'", at: url)
    }

    func test_migration_version1Database_keepsItsRows_setsTrackedFromToTheClock_andAcceptsSamples() async throws {
        let url = try databaseURL()
        try execute(Self.version1Schema + Self.version1Rows, at: url)
        XCTAssertEqual(integer("PRAGMA user_version", at: url), 1, "Fixture error")

        let store = try openStore(at: Self.tracked)

        XCTAssertEqual(try corruptSiblings(), [], "A version-1 database must be migrated, not moved aside")
        let records = try await store.records(forSession: "session-v1")
        XCTAssertEqual(records, [version1Record])
        let session = try await store.session("session-v1")
        XCTAssertEqual(session, UsageSessionMeta(sessionID: "session-v1", transcriptPath: "/t/v1.jsonl", projectRoot: "/r/v1"))
        let checkpoint = try await store.checkpoint(forPath: "/t/v1.jsonl")
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 7, offset: 99))
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.trackedNs)

        let result = try await send([sample(timeNs: 10, value: 12)], starts: [fresh(Self.trackedNs)], to: store)
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 12], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows, [row(input: 12)])

        await store.close()
        XCTAssertEqual(integer("PRAGMA user_version", at: url), 2)
        for table in ["usage_series", "usage_points", "usage_meta", "usage_process_starts"] {
            XCTAssertEqual(tableCount(table, at: url), 1, table)
        }
        XCTAssertEqual(integer("SELECT count(*) FROM usage_records", at: url), 1)
    }

    func test_migration_version1Database_withDistantFutureClock_opens_andTracksFromInt64Max() async throws {
        let url = try databaseURL()
        try execute(Self.version1Schema + Self.version1Rows, at: url)
        guard let store = openOrFail(UsageTestClock(Date.distantFuture)) else { return }
        let records = try await store.records(forSession: "session-v1")
        XCTAssertEqual(records, [version1Record])
        let trackedFrom = await trackedFromOrFail(store)
        XCTAssertEqual(trackedFrom, Int64.max)
    }

    func test_freshDatabase_isVersion2_withTheNewTables() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.beforeCapturesNs)
        await store.close()
        let url = try databaseURL()
        XCTAssertEqual(integer("PRAGMA user_version", at: url), 2)
        for table in ["usage_series", "usage_points", "usage_meta", "usage_process_starts"] {
            XCTAssertEqual(tableCount(table, at: url), 1, table)
        }
    }

    func test_version2Database_reopens_withoutBeingMovedAside() async throws {
        let first = try openStore()
        try await send([sample(timeNs: 10, value: 8)], to: first)
        await first.close()

        let second = try openStore(at: Self.tracked)
        XCTAssertEqual(try corruptSiblings(), [])
        let rows = try await second.pointRows()
        XCTAssertEqual(rows, [row(input: 8)])
    }

    func test_databaseClaimingVersion3_isMovedAside_andAFreshOneStarts() async throws {
        let url = try databaseURL()
        try execute("PRAGMA user_version = 3; CREATE TABLE fixture(x);", at: url)

        let store = try openStore(at: Self.tracked)

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(integer("PRAGMA user_version", at: try storeDirectory().appendingPathComponent(sibling)), 3)
        }
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.trackedNs)
        try await assertNothingStored(store)
    }

    func test_initWithoutClock_stillOpens_andTracksFromAboutNow() async throws {
        let before = Date()
        let store = try UsageStore(directory: try storeDirectory())
        openedStores.append(store)
        let after = Date()
        let trackedFrom = try await store.trackedFromNs()
        let seconds = Double(trackedFrom) / 1e9
        XCTAssertGreaterThanOrEqual(seconds, before.timeIntervalSince1970 - 1)
        XCTAssertLessThanOrEqual(seconds, after.timeIntervalSince1970 + 1)
    }

    /// Every table and column whose stored text contains `needle`, read
    /// with the SQLite C API from the closed database file.
    private func textValues(containing needle: String) throws -> [String] {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(try databaseURL().path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: cannot open the database")
        }
        var tables: [String] = []
        var listing: OpaquePointer?
        if sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &listing, nil) == SQLITE_OK {
            while sqlite3_step(listing) == SQLITE_ROW {
                if let text = sqlite3_column_text(listing, 0) { tables.append(String(cString: text)) }
            }
        }
        sqlite3_finalize(listing)
        XCTAssertTrue(tables.contains("usage_retired_processes"), "Fixture error: \(tables)")
        var found: [String] = []
        for table in tables {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "SELECT * FROM \"\(table)\"", -1, &statement, nil) == SQLITE_OK else { continue }
            let columns = sqlite3_column_count(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                for column in 0..<columns {
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { continue }
                    let data = Data(bytes: bytes, count: count)
                    if data.range(of: Data(needle.utf8)) != nil { found.append("\(table).\(column)") }
                }
            }
        }
        return found
    }

    // MARK: - Privacy

    func test_run2Applied_noFileOfTheStoreContainsAPersonalValue() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        try await apply(try receivedExports(run: "run2"), to: store)
        let directory = try storeDirectory()

        func assertNoSentinel(_ moment: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(names.contains("usage.sqlite"), "Fixture error: \(names)")
            for name in names {
                let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
                for sentinel in usageTelemetrySentinels {
                    XCTAssertNil(bytes.range(of: Data(sentinel.utf8)), "\(moment): \(sentinel) found in \(name)")
                    XCTAssertNil(bytes.range(of: Data(sentinel.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })),
                                 "\(moment): \(sentinel) (UTF-16) found in \(name)")
                }
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains("usage.sqlite-wal"), "Fixture error: the WAL must be checked while open: \(names)")
        let points = try await store.pointRows()
        XCTAssertFalse(points.isEmpty, "Fixture error: run2 must have been recorded")
        try assertNoSentinel("open")
        await store.close()
        try assertNoSentinel("closed")
    }

    // MARK: - changedSessions (R3b, section A)

    // The sessions a call stored a new series for or added tokens to; the
    // ledger settles exactly these after an export.

    func test_changedSessions_newSeries_isItsSession() async throws {
        let store = try openStore()
        let result = try await send([sample(timeNs: 10, value: 10)], to: store)
        XCTAssertEqual(result.changedSessions, ["session-a"])
        XCTAssertEqual(result, outcome(newSeries: 1, added: [.input: 10], changedSessions: ["session-a"]))
    }

    func test_changedSessions_increment_isItsSession() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let result = try await send([sample(timeNs: 20, value: 15)], to: store)
        XCTAssertEqual(result, outcome(advancedSeries: 1, added: [.input: 5], changedSessions: ["session-a"]))
    }

    func test_changedSessions_staleSample_isEmpty() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 20, value: 10)], to: store)
        let result = try await send([sample(timeNs: 20, value: 99)], to: store)
        XCTAssertEqual(result, outcome(staleSamples: 1))
        XCTAssertEqual(result.changedSessions, [])
    }

    func test_changedSessions_zeroIncrement_isEmpty() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let result = try await send([sample(timeNs: 20, value: 10)], to: store)
        XCTAssertEqual(result, outcome(unchangedSamples: 1))
        XCTAssertEqual(result.changedSessions, [])
    }

    func test_changedSessions_regression_isEmpty() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let result = try await send([sample(timeNs: 20, value: 4)], to: store)
        XCTAssertEqual(result, outcome(regressions: 1))
        XCTAssertEqual(result.changedSessions, [])
    }

    func test_changedSessions_ignoredCall_isEmpty() async throws {
        let store = try openStore(at: Self.tracked)
        let beforeTracking = try await send(
            [sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs)], to: store, at: Self.trackedNs - 1)
        let twoStarts = try await send(
            [sample(timeNs: 10, value: 9)], starts: [fresh(Self.trackedNs), fresh(Self.trackedNs + 1)], to: store,
            at: Self.trackedNs + 1)
        let insideTheWindow = try await send(
            [sample(timeNs: 10, value: 9)], starts: [oldProcess], to: store, at: Self.trackedNs + 1)
        for (name, result) in [("before tracking", beforeTracking), ("two starts", twoStarts),
                               ("inside the window", insideTheWindow)] {
            XCTAssertTrue(result.ignored, "Fixture error: \(name)")
            XCTAssertEqual(result.changedSessions, [], name)
        }
    }

    // One call of a process that has several sessions: two sessions gain
    // something, a third only has stale samples, a fourth only an
    // unchanged one.
    func test_changedSessions_severalSessionsInOneCall_areExactlyTheChangedOnes() async throws {
        let store = try openStore()
        try await send([
            sample(series: 3, session: "session-c", timeNs: 50, value: 30),
            sample(series: 4, session: "session-d", timeNs: 50, value: 40),
        ], to: store)
        let result = try await send([
            sample(series: 1, session: "session-a", timeNs: 60, value: 10),
            sample(series: 2, session: "session-b", timeNs: 60, kind: .output, value: 20),
            sample(series: 3, session: "session-c", timeNs: 40, value: 99),
            sample(series: 4, session: "session-d", timeNs: 60, value: 40),
        ], to: store)
        XCTAssertEqual(result, outcome(
            newSeries: 2, unchangedSamples: 1, staleSamples: 1, added: [.input: 10, .output: 20],
            changedSessions: ["session-a", "session-b"]))
    }

    func test_changedSessions_captureExports_nameTheCapturesSession() async throws {
        let store = try openStore(at: Self.beforeCaptures)
        let exports = try receivedExports(run: "run1")
        let outcomes = try await apply(exports, to: store)
        let changed = outcomes.filter { !$0.added.isEmpty }
        XCTAssertFalse(changed.isEmpty, "Fixture error: run1 adds tokens")
        for result in changed {
            XCTAssertEqual(result.changedSessions, ["11111111-1111-4111-8111-111111111111"])
        }
        XCTAssertEqual(try element(outcomes, at: 0).changedSessions, [],
                       "run1's first export carries only its process start")
    }

    // MARK: - The tracking flag (R3b, section A2)

    func test_trackingFlag_newDatabase_isActive() async throws {
        let store = try openStore()
        let active = try await store.isTrackingActive()
        XCTAssertTrue(active)
    }

    /// Bytes of the database and its WAL, after a write made the WAL exist.
    private func storeFileBytes() throws -> (database: Data?, wal: Data?) {
        (try fileBytes("usage.sqlite"), try fileBytes("usage.sqlite-wal"))
    }

    func test_trackingFlag_activeToActive_changesNothing_andWritesNothing() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let before = try storeFileBytes()
        XCTAssertNotNil(before.wal, "Fixture error: the WAL must exist while the store is open")
        let trackedBefore = try await store.trackedFromNs()

        let restarted = try await store.setTrackingActive(true)

        XCTAssertFalse(restarted)
        let after = try storeFileBytes()
        XCTAssertEqual(after.database, before.database, "active -> active must not write the database")
        XCTAssertEqual(after.wal, before.wal, "active -> active must not write the WAL")
        let active = try await store.isTrackingActive()
        let trackedAfter = try await store.trackedFromNs()
        let series = try await store.seriesRows()
        XCTAssertTrue(active)
        XCTAssertEqual(trackedAfter, trackedBefore)
        XCTAssertEqual(series.count, 1)
    }

    func test_trackingFlag_pausedToPaused_changesNothing_andWritesNothing() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let paused = try await store.setTrackingActive(false)
        XCTAssertFalse(paused, "active -> paused restarts nothing")
        let before = try storeFileBytes()
        XCTAssertNotNil(before.wal, "Fixture error: the WAL must exist while the store is open")

        let again = try await store.setTrackingActive(false)

        XCTAssertFalse(again)
        let after = try storeFileBytes()
        XCTAssertEqual(after.database, before.database, "paused -> paused must not write the database")
        XCTAssertEqual(after.wal, before.wal, "paused -> paused must not write the WAL")
        let active = try await store.isTrackingActive()
        XCTAssertFalse(active)
    }

    func test_trackingFlag_pausing_keepsEverythingStored_andApplyIsUnchanged() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        let trackedBefore = try await store.trackedFromNs()
        try await store.setTrackingActive(false)
        let trackedAfter = try await store.trackedFromNs()
        let starts = try await store.processStarts()
        XCTAssertEqual(trackedAfter, trackedBefore, "pausing does not restart tracking")
        XCTAssertEqual(starts, [Self.defaultProcess])
        // `apply` does not look at the flag.
        let growth = try await send([sample(timeNs: 20, value: 13)], to: store)
        XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 3], changedSessions: ["session-a"]))
    }

    // run1: exports 1-2 heard, tracking paused, then switched on again at
    // …416 s. The switch restarts tracking, so run1's process (heard before
    // the pause) is ignored inside the settling window and then only sets
    // baselines: the usage it counted while tracking was off is never added.
    func test_trackingFlag_pausedToActive_returnsTrue_andRestartsTracking() async throws {
        let clock = UsageTestClock(Self.beforeCaptures)
        let store = try openStore(clock: clock)
        let exports = try receivedExports(run: "run1")
        let raw = try rawExports(run: "run1")
        try await apply(Array(exports.prefix(2)), to: store)
        let rowsBefore = try await store.pointRows()
        try await store.setTrackingActive(false)

        clock.set(Self.afterRun1Export2)
        let restarted = try await store.setTrackingActive(true)

        XCTAssertTrue(restarted)
        let active = try await store.isTrackingActive()
        let trackedFrom = try await store.trackedFromNs()
        let retired = try await store.retiredProcessCount()
        let series = try await store.seriesRows()
        let starts = try await store.processStarts()
        let rowsAfterSwitch = try await store.pointRows()
        XCTAssertTrue(active)
        XCTAssertEqual(trackedFrom, Self.afterRun1Export2Ns)
        XCTAssertEqual(retired, 1)
        XCTAssertEqual(series, [])
        XCTAssertEqual(starts, [])
        XCTAssertEqual(rowsAfterSwitch, rowsBefore, "the switch keeps the points")

        let outcomes = try await apply(Array(exports.dropFirst(2)), to: store)
        XCTAssertEqual(outcomes.map(\.ignored), [true, true, true, false, false])
        XCTAssertEqual(try element(outcomes, at: 3), outcome(baselineOnly: 8, changedSessions: ["11111111-1111-4111-8111-111111111111"]))
        let actual = try await totals(of: store)
        XCTAssertEqual(actual, try expectedIncrements(raw, kept: 1, baseline: 5))
    }

    func test_trackingFlag_survivesClosingAndReopening() async throws {
        let clock = UsageTestClock(Self.tracked)
        let first = try openStore(clock: clock)
        try await first.setTrackingActive(false)
        await first.close()

        let second = try openStore(clock: clock)
        let pausedAfterReopen = try await second.isTrackingActive()
        XCTAssertFalse(pausedAfterReopen)
        let restarted = try await second.setTrackingActive(true)
        XCTAssertTrue(restarted, "a paused flag read back from disk still restarts tracking")
        await second.close()

        let third = try openStore(clock: clock)
        let activeAfterReopen = try await third.isTrackingActive()
        XCTAssertTrue(activeAfterReopen)
    }

    func test_trackingFlag_deleteAllWhileActive_staysActive() async throws {
        let store = try openStore()
        try await send([sample(timeNs: 10, value: 10)], to: store)
        try await store.deleteAll()
        let active = try await store.isTrackingActive()
        XCTAssertTrue(active)
        let restarted = try await store.setTrackingActive(true)
        XCTAssertFalse(restarted)
    }

    // Tracking off (paused at 1_000 s), data deleted at 2_000 s, a process
    // starts at 2_100 s (unheard: the ledger drops exports while off),
    // tracking on at 3_000 s. The flag is still paused after the delete, so
    // the switch restarts tracking at 3_000 s and the process predates it:
    // its first export (after the settling window) adds nothing, its second
    // only the growth. Had the delete marked tracking active, the process
    // would not predate tracking (2_100 s > 2_000 s) and its first export
    // would count in full.
    func test_trackingFlag_deleteAllWhilePaused_staysPaused_andALaterProcessOnlyAddsItsGrowth() async throws {
        let second: Int64 = 1_000_000_000
        let clock = UsageTestClock(Date(timeIntervalSince1970: 1_000))
        let store = try openStore(clock: clock)
        try await store.setTrackingActive(false)

        clock.set(Date(timeIntervalSince1970: 2_000))
        try await store.deleteAll()
        let pausedAfterDelete = try await store.isTrackingActive()
        let trackedAfterDelete = try await store.trackedFromNs()
        XCTAssertFalse(pausedAfterDelete, "deleteAll keeps the flag as it is")
        XCTAssertEqual(trackedAfterDelete, 2_000 * second)

        clock.set(Date(timeIntervalSince1970: 3_000))
        let restarted = try await store.setTrackingActive(true)
        XCTAssertTrue(restarted)
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, 3_000 * second)

        let process = fresh(2_100 * second)
        let first = try await send(
            [sample(startNs: 2_100 * second, timeNs: 3_100 * second, value: 500)], starts: [process], to: store,
            at: 3_100 * second)
        XCTAssertEqual(first, outcome(baselineOnly: 1, changedSessions: ["session-a"]))
        let growth = try await send(
            [sample(startNs: 2_100 * second, timeNs: 3_105 * second, value: 700)], starts: [process], to: store,
            at: 3_105 * second)
        XCTAssertEqual(growth, outcome(advancedSeries: 1, added: [.input: 200], changedSessions: ["session-a"]))
        let rows = try await store.pointRows()
        XCTAssertEqual(rows.map(\.inputTokens), [200])
    }

    func test_trackingFlag_afterClose_throwsClosed() async throws {
        let store = try openStore()
        await store.close()
        do {
            _ = try await store.isTrackingActive()
            XCTFail("isTrackingActive must throw after close")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .closed)
        }
        do {
            try await store.setTrackingActive(false)
            XCTFail("setTrackingActive must throw after close")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .closed)
        }
    }
}
