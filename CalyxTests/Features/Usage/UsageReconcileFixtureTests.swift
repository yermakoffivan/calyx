//
//  UsageReconcileFixtureTests.swift
//  CalyxTests
//
//  The acceptance criteria of the reconciliation on the real captures
//  (runs 1-9 in `CalyxTests/Fixtures/UsageTelemetry/`): a store whose
//  tracking started before the capture receives the capture's exports in
//  order (each at its own collection time), the transcript skeleton is
//  read with UsageRunLogReader from a temporary projects root, and
//  `reconcile(session:)` runs. Totals are compared per model for all four
//  token kinds; models whose four numbers are all zero are left out on
//  both sides.
//
//  1. Every export received: no unreported row, and the points equal the
//     session's `cost-state` totals.
//  2. Every prefix of the exports: points + unreported never exceed the
//     `cost-state` totals and equal them whenever run 1 is reconciled;
//     after the withheld exports arrive no row is left.
//  3. A fork never reports its parent's totals.
//  Plus the pinned numbers, computed independently from the captures.
//
//  Nothing here reads ~/.claude, Application Support or UserDefaults.
//

import XCTest
@testable import Calyx

final class UsageReconcileFixtureTests: XCTestCase {

    private typealias Fixtures = UsageTelemetryFixtures

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []
    private var directoryCounter = 0

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageReconcileFixtureTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Sessions of the captures

    private static let sonnet = "claude-sonnet-5-5"
    private static let fable = "claude-fable-5-1"

    private static let run1Session = "11111111-1111-4111-8111-111111111111"
    private static let run2Session = "22222222-2222-4222-8222-222222222222"
    private static let run4Session = "44444444-4444-4444-8444-444444444444"
    private static let run5Session1 = "55555555-5555-4555-8555-555555555551"
    private static let run5Session2 = "55555555-5555-4555-8555-555555555552"
    private static let run6Session = "66666666-6666-4666-8666-666666666661"
    private static let run7Session1 = "77777777-7777-4777-8777-777777777771"
    private static let run7Session2 = "77777777-7777-4777-8777-777777777772"
    private static let run8Session1 = "88888888-8888-4888-8888-888888888881"
    private static let run9Session1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
    private static let run9Session2 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
    private static let run9Session3 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"

    /// Before every process start of the captures (the earliest, run1's, is 1_791_183_405.041 s).
    private static let beforeCaptures = Date(timeIntervalSince1970: 1_791_183_400)

    /// The end (latest activity) of the runs the pinned rows are attributed
    /// to, read from the skeletons' timestamps.
    private static let run1End: Int64 = 1_791_183_438_061_000_000          // 06:57:18.061Z
    private static let run2End: Int64 = 1_791_183_622_229_000_000          // 07:00:22.229Z
    private static let run3SecondRunEnd: Int64 = 1_791_183_686_877_000_000 // 07:01:26.877Z
    private static let run8SecondRunEnd: Int64 = 1_791_187_574_703_000_000 // 08:06:14.703Z
    private static let run9Session2End: Int64 = 1_791_188_838_505_000_000  // 08:27:18.505Z
    private static let run9Session3End: Int64 = 1_791_188_894_259_000_000  // 08:28:14.259Z

    /// One session of a capture: the runs whose exports it receives (in
    /// order), its skeleton, and its expected `cost-state` file.
    private struct Case {
        let name: String
        let exportRuns: [String]
        let skeletonRun: String
        let skeletonFile: String
        let expectedFile: String
        let session: String
        /// `firstSequence` with every export applied.
        let firstSequence: Int?
    }

    private static let cases: [Case] = [
        Case(name: "run1", exportRuns: ["run1"], skeletonRun: "run1", skeletonFile: "transcript-skeleton.jsonl",
             expectedFile: "expected-cost-state.json", session: run1Session, firstSequence: 1),
        Case(name: "run2", exportRuns: ["run2"], skeletonRun: "run2", skeletonFile: "transcript-skeleton.jsonl",
             expectedFile: "expected-cost-state.json", session: run2Session, firstSequence: 1),
        Case(name: "run3", exportRuns: ["run2", "run3"], skeletonRun: "run3", skeletonFile: "transcript-skeleton.jsonl",
             expectedFile: "expected-cost-state.json", session: run2Session, firstSequence: 1),
        Case(name: "run4", exportRuns: ["run4"], skeletonRun: "run4", skeletonFile: "transcript-skeleton.jsonl",
             expectedFile: "expected-cost-state.json", session: run4Session, firstSequence: 1),
        Case(name: "run5-1", exportRuns: ["run5"], skeletonRun: "run5", skeletonFile: "transcript-skeleton-1.jsonl",
             expectedFile: "expected-cost-state-1.json", session: run5Session1, firstSequence: 1),
        Case(name: "run5-2", exportRuns: ["run5"], skeletonRun: "run5", skeletonFile: "transcript-skeleton-2.jsonl",
             expectedFile: "expected-cost-state-2.json", session: run5Session2, firstSequence: nil),
        Case(name: "run6", exportRuns: ["run6"], skeletonRun: "run6", skeletonFile: "transcript-skeleton.jsonl",
             expectedFile: "expected-cost-state.json", session: run6Session, firstSequence: nil),
        Case(name: "run7-1", exportRuns: ["run7"], skeletonRun: "run7", skeletonFile: "transcript-skeleton-1.jsonl",
             expectedFile: "expected-cost-state-1.json", session: run7Session1, firstSequence: 1),
        Case(name: "run7-2", exportRuns: ["run7"], skeletonRun: "run7", skeletonFile: "transcript-skeleton-2.jsonl",
             expectedFile: "expected-cost-state-2.json", session: run7Session2, firstSequence: nil),
        Case(name: "run8-1", exportRuns: ["run8"], skeletonRun: "run8", skeletonFile: "transcript-skeleton-1.jsonl",
             expectedFile: "expected-cost-state-1.json", session: run8Session1, firstSequence: 1),
        Case(name: "run8-2", exportRuns: ["run7", "run8"], skeletonRun: "run8", skeletonFile: "transcript-skeleton-2.jsonl",
             expectedFile: "expected-cost-state-2.json", session: run7Session1, firstSequence: 1),
        Case(name: "run9-1", exportRuns: ["run9"], skeletonRun: "run9", skeletonFile: "transcript-skeleton-1.jsonl",
             expectedFile: "expected-cost-state-1.json", session: run9Session1, firstSequence: 1),
        Case(name: "run9-2", exportRuns: ["run9"], skeletonRun: "run9", skeletonFile: "transcript-skeleton-2.jsonl",
             expectedFile: "expected-cost-state-2.json", session: run9Session2, firstSequence: 1),
        Case(name: "run9-3", exportRuns: ["run9"], skeletonRun: "run9", skeletonFile: "transcript-skeleton-3.jsonl",
             expectedFile: "expected-cost-state-3.json", session: run9Session3, firstSequence: 1),
    ]

    private func fixtureCase(_ name: String) throws -> Case {
        try XCTUnwrap(Self.cases.first { $0.name == name }, "Fixture error: no case \(name)")
    }

    // MARK: - Helpers

    private struct ReceivedExport {
        let batch: OTLPTokenUsageBatch
        let receivedAtNs: Int64
    }

    private func receivedExports(runs: [String]) throws -> [ReceivedExport] {
        try runs.flatMap { run in
            try Fixtures.exports(run: run).map {
                ReceivedExport(batch: try OTLPTokenUsageDecoder.decode($0),
                               receivedAtNs: try Fixtures.collectionTimeNs(of: $0))
            }
        }
    }

    private func apply(_ exports: ArraySlice<ReceivedExport>, to store: UsageStore) async throws {
        for export in exports {
            _ = try await store.apply(
                samples: export.batch.samples, processStarts: export.batch.processStarts,
                receivedAtNs: export.receivedAtNs)
        }
    }

    private func nextDirectory(_ prefix: String) throws -> URL {
        directoryCounter += 1
        let url = try XCTUnwrap(tempDirectory).appendingPathComponent("\(prefix)-\(directoryCounter)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openStore(trackingFrom date: Date = UsageReconcileFixtureTests.beforeCaptures) throws -> UsageStore {
        let store = try UsageStore(directory: try nextDirectory("store"), now: UsageTestClock(date).now)
        openedStores.append(store)
        return store
    }

    /// A projects root (canonical: the reader accepts only a file exactly
    /// two levels under the canonical root) holding `contents` as the
    /// session's main transcript.
    private func projectsRoot(holding contents: Data, session: String) throws -> String {
        let root = try nextDirectory("projects")
        guard let resolved = realpath(root.path, nil) else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: realpath failed")
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        let project = URL(fileURLWithPath: canonical).appendingPathComponent("-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try contents.write(to: project.appendingPathComponent("\(session).jsonl"))
        return canonical
    }

    private func skeleton(_ fixture: Case) throws -> Data {
        try Data(contentsOf: Fixtures.directory.appendingPathComponent(fixture.skeletonRun, isDirectory: true)
            .appendingPathComponent(fixture.skeletonFile))
    }

    private func readTranscript(session: String, root: String, into store: UsageStore,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let reader = UsageRunLogReader(
            store: store, resolver: UsageFixtureNoRepositoryResolver(), projectsRoot: { root },
            directoryState: { _ in .gone })
        let result = try await reader.read(sessionID: session, resolveProjectRoot: false)
        XCTAssertEqual(result.status, .read, "Fixture error: the skeleton was not read", file: file, line: line)
    }

    /// Store tracking from `trackingFrom`, the first `count` exports
    /// applied (all when nil), the transcript read, then reconciled.
    private struct Prepared {
        let store: UsageStore
        let outcome: UsageReconcileOutcome
        let exports: [ReceivedExport]
    }

    private func prepare(
        exports: [ReceivedExport], applied range: Range<Int>? = nil, transcript: Data, session: String,
        trackingFrom date: Date = UsageReconcileFixtureTests.beforeCaptures
    ) async throws -> Prepared {
        let store = try openStore(trackingFrom: date)
        try await apply(exports[range ?? exports.indices], to: store)
        let root = try projectsRoot(holding: transcript, session: session)
        try await readTranscript(session: session, root: root, into: store)
        let outcome = try await store.reconcile(session: session)
        return Prepared(store: store, outcome: outcome, exports: exports)
    }

    private func prepare(_ fixture: Case, appliedPrefix count: Int? = nil) async throws -> Prepared {
        let exports = try receivedExports(runs: fixture.exportRuns)
        let range = count.map { 0..<min($0, exports.count) }
        return try await prepare(exports: exports, applied: range, transcript: try skeleton(fixture), session: fixture.session)
    }

    /// Totals of `model -> kind -> tokens` without all-zero models.
    private func nonZero(_ totals: UsageTotalsByModel) -> UsageTotalsByModel {
        totals.filter { $0.value.values.contains { $0 != 0 } }
    }

    private func points(of session: String, in store: UsageStore) async throws -> UsageTotalsByModel {
        let rows = try await store.pointRows().filter { $0.sessionID == session }
        return nonZero(Fixtures.totals(of: rows))
    }

    private func unreported(of session: String, in store: UsageStore) async throws -> [UsageUnreportedStoredRow] {
        try await store.unreportedRows().filter { $0.sessionID == session }
    }

    private func pointsPlusUnreported(of session: String, in store: UsageStore) async throws -> UsageTotalsByModel {
        let pointRows = try await store.pointRows().filter { $0.sessionID == session }
        var entries: [(String, String, Int64)] = pointRows.flatMap { row in
            [(row.model, "input", row.inputTokens), (row.model, "output", row.outputTokens),
             (row.model, "cacheRead", row.cacheReadTokens), (row.model, "cacheCreation", row.cacheCreationTokens)]
        }
        for row in try await unreported(of: session, in: store) {
            entries += [(row.model, "input", row.totals.input), (row.model, "output", row.totals.output),
                        (row.model, "cacheRead", row.totals.cacheRead), (row.model, "cacheCreation", row.totals.cacheCreation)]
        }
        return nonZero(Fixtures.sumByModel(entries))
    }

    /// An expected-cost-state file restricted to the four kinds.
    private func expectedCostState(_ fixture: Case) throws -> UsageTotalsByModel {
        let url = Fixtures.directory.appendingPathComponent(fixture.skeletonRun, isDirectory: true)
            .appendingPathComponent(fixture.expectedFile)
        guard let models = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape(url.path)
        }
        return nonZero(try kindTotals(models, path: url.path))
    }

    /// `expected-metric-sums.json` of `run` for one session.
    private func expectedMetricSums(run: String, session: String) throws -> UsageTotalsByModel {
        let url = Fixtures.directory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("expected-metric-sums.json")
        guard let sessions = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any],
              let models = sessions[session] as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape("\(url.path): \(session)")
        }
        return nonZero(try kindTotals(models, path: url.path))
    }

    private func kindTotals(_ models: [String: Any], path: String) throws -> UsageTotalsByModel {
        var totals: UsageTotalsByModel = [:]
        for (model, entry) in models {
            guard let kinds = entry as? [String: Any] else {
                throw UsageTelemetryFixtureError.unexpectedShape("\(path): \(model)")
            }
            var row: [String: Int64] = [:]
            for kind in usageTelemetryKindNames {
                guard let number = kinds[kind] as? NSNumber else {
                    throw UsageTelemetryFixtureError.unexpectedShape("\(path): \(model).\(kind)")
                }
                row[kind] = number.int64Value
            }
            totals[model] = row
        }
        return totals
    }

    private func kinds(_ input: Int64, _ output: Int64, _ cacheRead: Int64, _ cacheCreation: Int64) -> [String: Int64] {
        ["input": input, "output": output, "cacheRead": cacheRead, "cacheCreation": cacheCreation]
    }

    private func tt(_ input: Int64, _ output: Int64, _ cacheRead: Int64, _ cacheCreation: Int64) -> UsageTokenTotals {
        UsageTokenTotals(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private func stored(_ session: String, _ sequence: Int, _ timeNs: Int64, _ totals: UsageTokenTotals,
                        model: String = UsageReconcileFixtureTests.sonnet) -> UsageUnreportedStoredRow {
        UsageUnreportedStoredRow(sessionID: session, sequence: sequence, timeNs: timeNs, model: model, totals: totals)
    }

    /// Every model's kind in `actual` that is above `limit`'s (empty when none is).
    private func exceeding(_ actual: UsageTotalsByModel, _ limit: UsageTotalsByModel) -> [String] {
        var found: [String] = []
        for (model, row) in actual {
            for (kind, value) in row where value > (limit[model]?[kind] ?? 0) {
                found.append("\(model).\(kind) \(value) > \(limit[model]?[kind] ?? 0)")
            }
        }
        return found.sorted()
    }

    // MARK: - Criterion 1: every export received

    private func assertEverythingReceived(_ name: String, file: StaticString = #filePath, line: UInt = #line)
        async throws {
        let fixture = try fixtureCase(name)
        let prepared = try await prepare(fixture)

        XCTAssertEqual(prepared.outcome.firstSequence, fixture.firstSequence, "firstSequence", file: file, line: line)
        XCTAssertEqual(prepared.outcome.rows, [], "outcome rows", file: file, line: line)
        let rows = try await prepared.store.unreportedRows()
        XCTAssertEqual(rows, [], "stored rows", file: file, line: line)
        let points = try await points(of: fixture.session, in: prepared.store)
        if fixture.name == "run6" {
            XCTAssertEqual(points, try expectedMetricSums(run: "run6", session: fixture.session),
                           "the fork's points are its own metric sums", file: file, line: line)
        } else {
            XCTAssertEqual(points, try expectedCostState(fixture), "points equal cost-state", file: file, line: line)
        }
    }

    func test_criterion1_run1_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run1")
    }

    func test_criterion1_run2_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run2")
    }

    func test_criterion1_run3_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run3")
    }

    func test_criterion1_run4_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run4")
    }

    func test_criterion1_run5Session1_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run5-1")
    }

    func test_criterion1_run5Session2_everyExportReceived_notReconciled_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run5-2")
    }

    func test_criterion1_run6_everyExportReceived_notReconciled_noRow_pointsEqualMetricSums() async throws {
        try await assertEverythingReceived("run6")
    }

    func test_criterion1_run7Session1_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run7-1")
    }

    func test_criterion1_run7Session2_everyExportReceived_notReconciled_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run7-2")
    }

    func test_criterion1_run8Session1_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run8-1")
    }

    func test_criterion1_run8Session2_run7AndRun8Exports_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run8-2")
    }

    func test_criterion1_run9Session1_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run9-1")
    }

    func test_criterion1_run9Session2_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run9-2")
    }

    func test_criterion1_run9Session3_everyExportReceived_noRow_pointsEqualCostState() async throws {
        try await assertEverythingReceived("run9-3")
    }

    // MARK: - Criterion 2: every prefix

    private func assertEveryPrefix(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try fixtureCase(name)
        let exports = try receivedExports(runs: fixture.exportRuns)
        let transcript = try skeleton(fixture)
        let costState = try expectedCostState(fixture)
        XCTAssertFalse(costState.isEmpty, "Fixture error: no cost-state totals", file: file, line: line)

        for count in 0...exports.count {
            let prepared = try await prepare(
                exports: exports, applied: 0..<count, transcript: transcript, session: fixture.session)
            let total = try await pointsPlusUnreported(of: fixture.session, in: prepared.store)
            let label = "\(name), \(count) of \(exports.count) exports"

            XCTAssertEqual(exceeding(total, costState), [], "\(label): points + unreported exceed cost-state",
                           file: file, line: line)
            if prepared.outcome.firstSequence == 1 {
                XCTAssertEqual(total, costState, "\(label): run 1 reconciled, so points + unreported equal cost-state",
                               file: file, line: line)
            }

            try await apply(exports[count...], to: prepared.store)
            _ = try await prepared.store.reconcile(session: fixture.session)
            let left = try await unreported(of: fixture.session, in: prepared.store)
            XCTAssertEqual(left, [], "\(label), then the rest: no row may be left", file: file, line: line)

            await prepared.store.close()
        }
    }

    func test_criterion2_run1_everyPrefix() async throws { try await assertEveryPrefix("run1") }
    func test_criterion2_run2_everyPrefix() async throws { try await assertEveryPrefix("run2") }
    func test_criterion2_run3_everyPrefix() async throws { try await assertEveryPrefix("run3") }
    func test_criterion2_run4_everyPrefix() async throws { try await assertEveryPrefix("run4") }
    func test_criterion2_run5Session1_everyPrefix() async throws { try await assertEveryPrefix("run5-1") }
    func test_criterion2_run5Session2_everyPrefix() async throws { try await assertEveryPrefix("run5-2") }
    func test_criterion2_run6_everyPrefix() async throws { try await assertEveryPrefix("run6") }
    func test_criterion2_run7Session1_everyPrefix() async throws { try await assertEveryPrefix("run7-1") }
    func test_criterion2_run7Session2_everyPrefix() async throws { try await assertEveryPrefix("run7-2") }
    func test_criterion2_run8Session1_everyPrefix() async throws { try await assertEveryPrefix("run8-1") }
    func test_criterion2_run8Session2_everyPrefix() async throws { try await assertEveryPrefix("run8-2") }
    func test_criterion2_run9Session1_everyPrefix() async throws { try await assertEveryPrefix("run9-1") }
    func test_criterion2_run9Session2_everyPrefix() async throws { try await assertEveryPrefix("run9-2") }
    func test_criterion2_run9Session3_everyPrefix() async throws { try await assertEveryPrefix("run9-3") }

    // MARK: - Pinned numbers

    private func pinnedRows(_ name: String, prefix: Int) async throws -> (Prepared, [UsageUnreportedStoredRow]) {
        let fixture = try fixtureCase(name)
        let prepared = try await prepare(fixture, appliedPrefix: prefix)
        let rows = try await prepared.store.unreportedRows()
        return (prepared, rows)
    }

    func test_pinned_run1_sixOfSeven() async throws {
        let (prepared, rows) = try await pinnedRows("run1", prefix: 6)
        XCTAssertEqual(prepared.outcome.firstSequence, 1)
        XCTAssertEqual(rows, [stored(Self.run1Session, 1, Self.run1End, tt(6, 534, 49_589, 1_220))])
    }

    func test_pinned_run1_onlyTheFirstExport_theWholeIsUnreported() async throws {
        let (prepared, rows) = try await pinnedRows("run1", prefix: 1)
        XCTAssertEqual(prepared.outcome.firstSequence, 1)
        let points = try await points(of: Self.run1Session, in: prepared.store)
        XCTAssertEqual(points, [:], "Fixture error: the first export carries no token series")
        XCTAssertEqual(rows, [stored(Self.run1Session, 1, Self.run1End, tt(24, 2_114, 176_467, 51_986))])
    }

    func test_pinned_run2_sevenOfFourteen() async throws {
        let (_, rows) = try await pinnedRows("run2", prefix: 7)
        XCTAssertEqual(rows, [stored(Self.run2Session, 1, Self.run2End, tt(522, 20, 96_044, 1_157))])
    }

    func test_pinned_run2_fourOfFourteen_sonnetAndFable_haikuNothing() async throws {
        let (_, rows) = try await pinnedRows("run2", prefix: 4)
        XCTAssertEqual(rows, [
            stored(Self.run2Session, 1, Self.run2End, tt(41_788, 1_085, 0, 0), model: Self.fable),
            stored(Self.run2Session, 1, Self.run2End, tt(1_578, 1_864, 374_464, 91_377)),
        ])
    }

    /// run3's case with run2's first `fromRun2` exports and run3's first `fromRun3`.
    private func run3Rows(fromRun2: Int, fromRun3: Int) async throws -> (Prepared, [UsageUnreportedStoredRow]) {
        let fixture = try fixtureCase("run3")
        let run2 = try receivedExports(runs: ["run2"])
        let run3 = try receivedExports(runs: ["run3"])
        XCTAssertEqual(run2.count, 14, "Fixture error")
        XCTAssertEqual(run3.count, 2, "Fixture error")
        let exports = Array(run2.prefix(fromRun2)) + Array(run3.prefix(fromRun3))
        let prepared = try await prepare(exports: exports, transcript: try skeleton(fixture), session: fixture.session)
        return (prepared, try await prepared.store.unreportedRows())
    }

    func test_pinned_run3_allOfRun2_noneOfRun3_rowOnSequence2() async throws {
        let (prepared, rows) = try await run3Rows(fromRun2: 14, fromRun3: 0)
        XCTAssertEqual(prepared.outcome.firstSequence, 1)
        XCTAssertEqual(rows, [stored(Self.run2Session, 2, Self.run3SecondRunEnd, tt(4, 204, 99_145, 2_235))])
    }

    func test_pinned_run3_allOfRun2_oneOfRun3_rowOnSequence2() async throws {
        let (_, rows) = try await run3Rows(fromRun2: 14, fromRun3: 1)
        XCTAssertEqual(rows, [stored(Self.run2Session, 2, Self.run3SecondRunEnd, tt(2, 33, 50_543, 294))])
    }

    func test_pinned_run3_sevenOfRun2_bothOfRun3_onlyTheFirstProcessesTail() async throws {
        let (_, rows) = try await run3Rows(fromRun2: 7, fromRun3: 2)
        XCTAssertEqual(rows, [stored(Self.run2Session, 1, Self.run2End, tt(522, 20, 96_044, 1_157))])
    }

    func test_pinned_run3_sevenOfRun2_noneOfRun3_aRowOnEachRun() async throws {
        let (_, rows) = try await run3Rows(fromRun2: 7, fromRun3: 0)
        XCTAssertEqual(rows, [
            stored(Self.run2Session, 1, Self.run2End, tt(522, 20, 96_044, 1_157)),
            stored(Self.run2Session, 2, Self.run3SecondRunEnd, tt(4, 204, 99_145, 2_235)),
        ])
    }

    func test_pinned_run8Session2_run7sElevenAndSevenOfRun8() async throws {
        let (prepared, rows) = try await pinnedRows("run8-2", prefix: 18)
        XCTAssertEqual(prepared.exports.count, 22, "Fixture error: run7's 11 then run8's 11")
        XCTAssertEqual(rows, [stored(Self.run7Session1, 2, Self.run8SecondRunEnd, tt(2, 4, 27_340, 17_320))])
    }

    func test_pinned_run9Session2_eightOfTwentySix() async throws {
        let (prepared, rows) = try await pinnedRows("run9-2", prefix: 8)
        XCTAssertEqual(prepared.outcome.firstSequence, 1)
        XCTAssertEqual(rows, [stored(Self.run9Session2, 1, Self.run9Session2End, tt(520, 14, 71_799, 17_198))])
    }

    func test_pinned_run9Session3_nineteenOfTwentySix() async throws {
        let (prepared, rows) = try await pinnedRows("run9-3", prefix: 19)
        XCTAssertEqual(prepared.outcome.firstSequence, 1)
        XCTAssertEqual(rows, [stored(Self.run9Session3, 1, Self.run9Session3End, tt(520, 14, 89_924, 77))])
    }

    // MARK: - A first run Calyx never heard is not counted

    func test_run3_noneOfRun2_bothOfRun3_firstSequence2_pointsAreRun3sOwn_noRow() async throws {
        let (prepared, rows) = try await run3Rows(fromRun2: 0, fromRun3: 2)
        XCTAssertEqual(prepared.outcome.firstSequence, 2)
        XCTAssertEqual(rows, [])
        let points = try await points(of: Self.run2Session, in: prepared.store)
        XCTAssertEqual(points, [Self.sonnet: kinds(4, 204, 99_145, 2_235)])
    }

    func test_run8Session2_noneOfRun7_allOfRun8_firstSequence2_noRow() async throws {
        let fixture = try fixtureCase("run8-2")
        let exports = try receivedExports(runs: ["run8"])
        let prepared = try await prepare(exports: exports, transcript: try skeleton(fixture), session: fixture.session)
        XCTAssertEqual(prepared.outcome.firstSequence, 2)
        let rows = try await prepared.store.unreportedRows()
        XCTAssertEqual(rows, [])
        let points = try await points(of: Self.run7Session1, in: prepared.store)
        XCTAssertEqual(points, try expectedMetricSums(run: "run8", session: Self.run7Session1))
    }

    // MARK: - Criterion 3: a fork

    func test_criterion3_run6_withItsExport_noRow() async throws {
        let (prepared, rows) = try await pinnedRows("run6", prefix: 1)
        XCTAssertNil(prepared.outcome.firstSequence)
        XCTAssertEqual(rows, [])
    }

    func test_criterion3_run6_withNothingApplied_noRow() async throws {
        let (prepared, rows) = try await pinnedRows("run6", prefix: 0)
        XCTAssertNil(prepared.outcome.firstSequence)
        XCTAssertEqual(rows, [])
    }

    /// The fork's file with a synthetic second run appended: one activity
    /// line two minutes after run 1's last line, then a `cost-state` whose
    /// sonnet totals grew by (1000, 2000, 300000, 4000).
    private static let run6SecondRunActivity = "2026-10-05T07:13:40.369Z"
    private static let run6SecondRunEnd: Int64 = 1_791_184_420_369_000_000

    private func run6WithASecondRun() throws -> Data {
        let fixture = try fixtureCase("run6")
        guard let text = String(data: try skeleton(fixture), encoding: .utf8) else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: run6 skeleton is not UTF-8")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var lastCostState: [String: Any]?
        for line in lines {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["type"] as? String == "cost-state" { lastCostState = object }
        }
        guard var costState = lastCostState,
              var modelUsage = costState["modelUsage"] as? [String: Any],
              var sonnet = modelUsage[Self.sonnet] as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: run6 has no sonnet cost-state")
        }
        for (field, delta) in [("inputTokens", Int64(1_000)), ("outputTokens", 2_000),
                               ("cacheReadInputTokens", 300_000), ("cacheCreationInputTokens", 4_000)] {
            guard let value = (sonnet[field] as? NSNumber)?.int64Value else {
                throw UsageTelemetryFixtureError.unexpectedShape("Fixture error: run6 sonnet \(field)")
            }
            sonnet[field] = NSNumber(value: value + delta)
        }
        modelUsage[Self.sonnet] = sonnet
        costState["modelUsage"] = modelUsage
        let activity: [String: Any] = [
            "type": "user", "timestamp": Self.run6SecondRunActivity, "sessionId": Self.run6Session,
            "cwd": "/fixture/project",
        ]
        var appended = lines
        appended.append(String(decoding: try JSONSerialization.data(withJSONObject: activity), as: UTF8.self))
        appended.append(String(decoding: try JSONSerialization.data(withJSONObject: costState), as: UTF8.self))
        return Data((appended.joined(separator: "\n") + "\n").utf8)
    }

    func test_criterion3_run6_syntheticSecondRun_withTheForksExport_reportsOnlyTheSecondRunsShortfall() async throws {
        let exports = try receivedExports(runs: ["run6"])
        let prepared = try await prepare(exports: exports, transcript: try run6WithASecondRun(), session: Self.run6Session)
        let log = try await prepared.store.runLog(forSession: Self.run6Session)
        XCTAssertEqual(log?.log.runs.count, 2, "Fixture error: the appended run must be read")

        XCTAssertEqual(prepared.outcome.firstSequence, 2)
        let rows = try await prepared.store.unreportedRows()
        // (1000, 2000, 300000, 4000) minus the fork's own points
        // (2, 3, 50837, 70), received in the minute of run 1's last line.
        XCTAssertEqual(rows, [stored(Self.run6Session, 2, Self.run6SecondRunEnd, tt(998, 1_997, 249_163, 3_930))])
    }

    func test_criterion3_run6_syntheticSecondRun_withNothingApplied_staysEmpty() async throws {
        let prepared = try await prepare(exports: [], transcript: try run6WithASecondRun(), session: Self.run6Session)
        XCTAssertNil(prepared.outcome.firstSequence)
        let rows = try await prepared.store.unreportedRows()
        XCTAssertEqual(rows, [])
    }

    // MARK: - Tracking that starts between two processes

    /// Between run2's last line (1_791_183_622.229 s) and run3's process
    /// start (1_791_183_681.268 s).
    private static let betweenRun2AndRun3 = Date(timeIntervalSince1970: 1_791_183_650)

    private func run3TrackedBetween(fromRun3: Int) async throws -> (Prepared, [UsageUnreportedStoredRow]) {
        let fixture = try fixtureCase("run3")
        let run2 = try receivedExports(runs: ["run2"])
        let run3 = try receivedExports(runs: ["run3"])
        let prepared = try await prepare(
            exports: run2 + Array(run3.prefix(fromRun3)), transcript: try skeleton(fixture), session: fixture.session,
            trackingFrom: Self.betweenRun2AndRun3)
        return (prepared, try await prepared.store.unreportedRows())
    }

    func test_trackingBetweenProcesses_run2sExportsIgnored_bothOfRun3_noRow() async throws {
        let (prepared, rows) = try await run3TrackedBetween(fromRun3: 2)
        XCTAssertEqual(prepared.outcome.firstSequence, 2)
        XCTAssertEqual(rows, [])
        let points = try await points(of: Self.run2Session, in: prepared.store)
        XCTAssertEqual(points, [Self.sonnet: kinds(4, 204, 99_145, 2_235)], "only run3's own usage is recorded")
    }

    func test_trackingBetweenProcesses_oneOfRun3_rowOnSequence2() async throws {
        let (prepared, rows) = try await run3TrackedBetween(fromRun3: 1)
        XCTAssertEqual(prepared.outcome.firstSequence, 2)
        XCTAssertEqual(rows, [stored(Self.run2Session, 2, Self.run3SecondRunEnd, tt(2, 33, 50_543, 294))])
    }
}
