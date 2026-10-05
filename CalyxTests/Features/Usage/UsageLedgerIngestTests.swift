//
//  UsageLedgerIngestTests.swift
//  CalyxTests
//
//  Pins the version-2 side of UsageLedger (R3b): `ingestExport` takes one
//  export handed over by the usage route and answers once it is committed
//  (or refused), then settles every session the export changed (reads its
//  transcript's run log, then reconciles it) without being waited for;
//  `catchUp` settles every session heard since tracking (re)started;
//  `tokenReports` catches up first, then answers in one store call;
//  `syncTracking` keeps the store's durable tracking flag in line with
//  the setting, so an export is never applied before a switch back on has
//  restarted tracking. One settle per session at a time; requests during
//  a settle cost one more. A failed project root is not retried until a
//  new line was read; a missing transcript is not looked for by
//  `catchUp` for 10 minutes (the ledger's injected clock).
//
//  The `readRunLog` seam is a scripted actor (`RunLogScript`) that records
//  every call, can hold a call until the test releases it, and either
//  answers a fixed status, throws, or runs the REAL UsageRunLogReader
//  (with a counting resolver) over a temporary projects root. The store is
//  a real UsageStore in a per-test temporary directory. Its database is
//  created by the test with a pinned clock BEFORE the ledger opens it
//  (the ledger opens the store with the system clock, and the captures'
//  times are fixed), so `tracked_from` is known. Nothing here reads
//  ~/.claude, Application Support or UserDefaults, and nothing sleeps to
//  synchronise: ordering comes from the gates, `waitUntilIdle()`, and
//  bounded expectations.
//

import os
import XCTest
@testable import Calyx

// MARK: - Test doubles

private struct InjectedRunLogFailure: Error {}

private struct InjectedResolverFailure: Error {}

/// A resolver that counts its calls and answers nil ("not a repository")
/// or throws.
private final class CountingResolver: ProjectRootResolving {
    private let state = OSAllocatedUnfairLock(initialState: (calls: 0, fails: false))

    var calls: Int { state.withLock { $0.calls } }

    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }

    func projectRoot(forCWD cwd: String) async throws -> String? {
        let fails = state.withLock { state -> Bool in
            state.calls += 1
            return state.fails
        }
        if fails { throw InjectedResolverFailure() }
        return nil
    }
}

/// The `readRunLog` seam.
private actor RunLogScript {
    enum Outcome: Sendable {
        /// Runs the real UsageRunLogReader.
        case real
        /// Returns this status, having read nothing.
        case status(UsageRunLogReadResult.Status)
        case fails
    }

    struct Call: Equatable, Sendable {
        let sessionID: String
        let resolveProjectRoot: Bool
    }

    private let root: String
    private let resolver: CountingResolver
    private let directoryState: UsageDirectoryState

    /// Every call, in call order. Call indices are 1-based.
    private(set) var calls: [Call] = []
    private(set) var finished = 0
    private(set) var maxConcurrent = 0
    private(set) var maxConcurrentPerSession = 0

    private var defaultOutcome: Outcome = .real
    private var outcomes: [Int: Outcome] = [:]
    private var gated: Set<Int> = []
    private var released: Set<Int> = []
    private var gatesOpen = false
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var running = 0
    private var runningBySession: [String: Int] = [:]

    init(root: String, resolver: CountingResolver, directoryState: UsageDirectoryState) {
        self.root = root
        self.resolver = resolver
        self.directoryState = directoryState
    }

    func setDefault(_ outcome: Outcome) { defaultOutcome = outcome }
    func setOutcome(_ outcome: Outcome, forCall index: Int) { outcomes[index] = outcome }

    /// Forgets the concurrency maxima seen so far.
    func resetStatistics() {
        maxConcurrent = running
        maxConcurrentPerSession = runningBySession.values.max() ?? 0
    }

    func count(forSession sessionID: String) -> Int {
        calls.filter { $0.sessionID == sessionID }.count
    }

    /// Call `index` suspends inside the seam until `release(index)`.
    func gate(_ index: Int) { gated.insert(index) }

    func release(_ index: Int) {
        released.insert(index)
        releaseWaiters.removeValue(forKey: index)?.resume()
    }

    /// Opens every gate, present and future, and resumes every waiter
    /// (tearDown).
    func releaseEverything() {
        gatesOpen = true
        let waiters = releaseWaiters.values
        releaseWaiters = [:]
        for waiter in waiters { waiter.resume() }
        let starts = startWaiters
        startWaiters = []
        for waiter in starts { waiter.continuation.resume() }
    }

    /// Returns once at least `count` calls have entered the seam (or
    /// `releaseEverything` ran).
    func waitForStart(_ count: Int) async {
        if calls.count >= count || gatesOpen { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func run(_ sessionID: String, store: UsageStore, resolveProjectRoot: Bool) async throws -> UsageRunLogReadResult {
        calls.append(Call(sessionID: sessionID, resolveProjectRoot: resolveProjectRoot))
        let index = calls.count
        running += 1
        runningBySession[sessionID, default: 0] += 1
        maxConcurrent = max(maxConcurrent, running)
        maxConcurrentPerSession = max(maxConcurrentPerSession, runningBySession[sessionID] ?? 0)
        let ready = startWaiters.filter { $0.count <= index }
        startWaiters.removeAll { $0.count <= index }
        for waiter in ready { waiter.continuation.resume() }
        defer {
            running -= 1
            runningBySession[sessionID, default: 1] -= 1
            finished += 1
        }

        if gated.contains(index), !released.contains(index), !gatesOpen {
            await withCheckedContinuation { releaseWaiters[index] = $0 }
        }
        switch outcomes[index] ?? defaultOutcome {
        case .real:
            let root = self.root
            let state = directoryState
            return try await UsageRunLogReader(
                store: store, resolver: resolver, projectsRoot: { root }, directoryState: { _ in state }
            ).read(sessionID: sessionID, resolveProjectRoot: resolveProjectRoot)
        case .status(let status):
            return UsageRunLogReadResult(
                status: status, linesRead: 0, runsClosed: 0, restarted: false, projectRootResolutionFailed: false)
        case .fails:
            throw InjectedRunLogFailure()
        }
    }
}

/// The `afterApply` seam. Passes through unless armed; once armed, holds
/// the next apply (after it committed, before it returns to the ledger)
/// until `open()`.
private actor ApplyGate {
    private var armed = false
    private var held = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func passOrWait() async {
        guard armed, !held, !opened else { return }
        held = true
        let ready = heldWaiters
        heldWaiters = []
        for waiter in ready { waiter.resume() }
        await withCheckedContinuation { waiter = $0 }
    }

    /// Returns once an apply is held (or the gate was opened).
    func waitUntilHeld() async {
        if held || opened { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    var isHeld: Bool { held }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
        let ready = heldWaiters
        heldWaiters = []
        for waiter in ready { waiter.resume() }
    }
}

/// The `onDiagnostic` seam (a synchronous closure).
private final class DiagnosticLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UsageLedgerDiagnostic]())

    func append(_ diagnostic: UsageLedgerDiagnostic) { state.withLock { $0.append(diagnostic) } }
    var all: [UsageLedgerDiagnostic] { state.withLock { $0 } }
}

/// Holds a value set from another task.
private final class Box<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value?> = OSAllocatedUnfairLock(initialState: nil)

    func set(_ value: Value) { state.withLock { $0 = value } }
    var value: Value? { state.withLock { $0 } }
}

// MARK: - Tests

final class UsageLedgerIngestTests: XCTestCase {

    private typealias Fixtures = UsageTelemetryFixtures

    /// How long a test waits for something that must happen. Reached only
    /// when it does not happen, and the test then fails.
    private static let waitSeconds: TimeInterval = 30

    private static let sonnet = "claude-sonnet-5-5"
    private static let run1Session = "11111111-1111-4111-8111-111111111111"
    private static let sessionA = "aaaaaaaa-0000-4000-8000-00000000000a"
    private static let sessionB = "bbbbbbbb-0000-4000-8000-00000000000b"

    /// Before every process start of the captures (run1's is …405.041 s).
    private static let beforeCaptures = Date(timeIntervalSince1970: 1_791_183_400)
    /// run1's last activity (its run's end): 06:57:18.061Z.
    private static let run1End: Int64 = 1_791_183_438_061_000_000

    /// Synthetic exports of a process that started after `beforeCaptures`:
    /// its start, and the start of its one series.
    private static let syntheticStartNs: Int64 = 1_791_183_500_000_000_000
    /// Synthetic exports after a delete or a switch, which restart
    /// tracking at the store's (system) clock: far in the future (2096).
    private static let futureStartNs: Int64 = 4_000_000_000_000_000_000
    private static let secondNs: Int64 = 1_000_000_000

    private let resolver = CountingResolver()
    private let applyGate = ApplyGate()
    private let diagnostics = DiagnosticLog()
    private let tracking = UsageFixtureSwitch()
    private let clock = UsageTestClock(Date(timeIntervalSince1970: 1_791_200_000))

    /// realpath(3) of the per-test temporary directory; "" until setUp.
    private var tempPath = ""
    private var script: RunLogScript?
    private var ledgers: [UsageLedger] = []
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLedgerIngestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw InjectedRunLogFailure() }
        tempPath = String(cString: resolved)
        free(resolved)
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
        script = RunLogScript(root: root, resolver: resolver, directoryState: .gone)
    }

    override func tearDown() async throws {
        // A failed test may leave a settle held at its gate; let it go so
        // closing the ledgers cannot wait forever. Tracking off first, so
        // anything still on its way creates nothing.
        await script?.releaseEverything()
        await applyGate.open()
        tracking.set(false)
        for ledger in ledgers {
            await ledger.close()
        }
        ledgers = []
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        if !tempPath.isEmpty {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = ""
        script = nil
        try await super.tearDown()
    }

    // MARK: - Paths

    private var root: String { tempPath + "/projects" }
    private var projectDirectory: String { root + "/-fixture-project" }
    private var storePath: String { tempPath + "/store" }
    private var storeURL: URL { URL(fileURLWithPath: storePath, isDirectory: true) }
    private var databasePath: String { storePath + "/" + UsageStore.databaseFileName }

    private func transcriptPath(_ sessionID: String) -> String {
        projectDirectory + "/" + sessionID + ".jsonl"
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Ledger, script and store

    private func runLogScript() throws -> RunLogScript {
        try XCTUnwrap(script, "Fixture error: no script")
    }

    /// A ledger over this test's roots whose `readRunLog` is the script.
    /// The v1 `ingest` seam is never expected to run.
    private func makeLedger() throws -> UsageLedger {
        let script = try runLogScript()
        let diagnostics = self.diagnostics
        let tracking = self.tracking
        let root = self.root
        let applyGate = self.applyGate
        let ledger = UsageLedger(
            isEnabled: { tracking.isOn },
            projectsRoot: { root },
            storeDirectory: storeURL,
            ingest: { _, _ in throw InjectedRunLogFailure() },
            publish: { _, _ in },
            onDiagnostic: { diagnostics.append($0) },
            readRunLog: { sessionID, store, resolveProjectRoot in
                try await script.run(sessionID, store: store, resolveProjectRoot: resolveProjectRoot)
            },
            now: clock.now,
            afterApply: { await applyGate.passOrWait() })
        ledgers.append(ledger)
        return ledger
    }

    /// Creates the database with tracking starting at `date`, and closes
    /// it, before any ledger opens it.
    private func seedStore(trackingFrom date: Date = UsageLedgerIngestTests.beforeCaptures) async throws {
        let store = try UsageStore(directory: storeURL, now: UsageTestClock(date).now)
        await store.close()
    }

    /// Closes `ledger` (it stays usable: the next need reopens the store)
    /// and reads the store with a connection of its own.
    private func inspect<Value: Sendable>(
        _ ledger: UsageLedger, _ body: @Sendable (UsageStore) async throws -> Value
    ) async throws -> Value {
        await ledger.close()
        let store = try UsageStore(directory: storeURL)
        do {
            let value = try await body(store)
            await store.close()
            return value
        } catch {
            await store.close()
            throw error
        }
    }

    private func assertDiagnostics(
        _ expected: [UsageLedgerDiagnostic], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            diagnostics.all.map { "\($0)" }.sorted(), expected.map { "\($0)" }.sorted(), file: file, line: line)
    }

    private var storeUnavailableCount: Int {
        diagnostics.all.filter { if case .storeUnavailable = $0 { return true } else { return false } }.count
    }

    // MARK: - Waiting (bounded)

    /// Waits until the script has seen `count` calls; fails the test after
    /// `waitSeconds`.
    private func waitForRunLogCalls(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let script = try runLogScript()
        let started = expectation(description: "\(count) readRunLog call(s) started")
        Task {
            await script.waitForStart(count)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: Self.waitSeconds)
    }

    /// Runs `ingestExport` in a task of its own and waits for its answer
    /// (bounded): an implementation that waited for the settle it started
    /// would never answer while that settle is held.
    private func ingestWithoutWaitingForTheSettle(
        _ ledger: UsageLedger, _ body: Data, receivedAtNs: Int64
    ) async -> UsageIngestOutcome? {
        let box = Box<UsageIngestOutcome>()
        let answered = expectation(description: "ingestExport answered while its settle is held")
        Task {
            box.set(await ledger.ingestExport(body, receivedAtNs: receivedAtNs))
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: Self.waitSeconds)
        return box.value
    }

    /// Polls (with `Task.yield`, bounded) until `deleteAll` has begun.
    private func waitUntilDeleting(
        _ ledger: UsageLedger, maxPolls: Int = 1_000_000, file: StaticString = #filePath, line: UInt = #line
    ) async {
        var polls = 0
        while !(await ledger.isDeleting) {
            guard polls < maxPolls else {
                XCTFail("deleteAll never began", file: file, line: line)
                return
            }
            polls += 1
            await Task.yield()
        }
    }

    // MARK: - Exports

    private struct Export {
        let body: Data
        let receivedAtNs: Int64
    }

    /// The captured exports of a run, each received at its collection time.
    private func captured(run: String) throws -> [Export] {
        try Fixtures.exports(run: run).map { Export(body: $0, receivedAtNs: try Fixtures.collectionTimeNs(of: $0)) }
    }

    private func element<T>(_ items: [T], at index: Int) throws -> T {
        try XCTUnwrap(items.indices.contains(index) ? items[index] : nil, "Fixture error: no element \(index)")
    }

    /// One export of a synthetic process of `session` (started at
    /// `startNs`): its process start and one cumulative input series of
    /// `value`, sampled and received at `startNs + seconds`.
    private func synthetic(
        _ session: String, value: Double, seconds: Int64, startNs: Int64 = UsageLedgerIngestTests.syntheticStartNs
    ) throws -> Export {
        let timeNs = startNs + seconds * Self.secondNs
        let tokens = Fixtures.point(
            attributes: Fixtures.attributes([
                "session.id": session, "model": Self.sonnet, "query_source": "main", "type": "input",
            ]),
            startNs: startNs, timeNs: timeNs, asDouble: value)
        let start: [String: Any] = [
            "attributes": Fixtures.attributes(["session.id": session, "start_type": "fresh"]),
            "startTimeUnixNano": String(startNs), "timeUnixNano": String(timeNs), "asDouble": 1.0,
        ]
        let body = try Fixtures.body(metrics: [
            Fixtures.metric(points: [tokens]),
            Fixtures.metric(name: "claude_code.session.count", points: [start]),
        ])
        return Export(body: body, receivedAtNs: timeNs)
    }

    @discardableResult
    private func ingest(_ export: Export, into ledger: UsageLedger) async -> UsageIngestOutcome {
        await ledger.ingestExport(export.body, receivedAtNs: export.receivedAtNs)
    }

    private func ingestAll(_ exports: [Export], into ledger: UsageLedger,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for (index, export) in exports.enumerated() {
            let outcome = await ingest(export, into: ledger)
            XCTAssertEqual(outcome, .stored, "export \(index + 1)", file: file, line: line)
        }
    }

    // MARK: - Transcripts

    /// run1's skeleton split before its `cost-state` line: the transcript
    /// as it is while the session runs, and the lines its exit appends.
    private func run1SkeletonSplit() throws -> (beforeExit: [Data], exit: [Data]) {
        let skeleton = UsageRunLogFixtures.run1
        let lines = try UsageRunLogFixtures.lines(skeleton)
        let objects = try UsageRunLogFixtures.objects(skeleton)
        let index = try XCTUnwrap(
            objects.firstIndex { $0["type"] as? String == "cost-state" }, "Fixture error: run1 has a cost-state line")
        return (Array(lines.prefix(index)), Array(lines.dropFirst(index)))
    }

    private func writeTranscript(_ lines: [Data], session: String) throws {
        try Data(lines.map { $0 + Data("\n".utf8) }.joined()).write(to: URL(fileURLWithPath: transcriptPath(session)))
    }

    private func appendTranscript(_ lines: [Data], session: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: transcriptPath(session)), "Fixture error")
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + Data("\n".utf8) }.joined()))
    }

    /// The unreported row R2b pins for run1 with its last export withheld,
    /// computed independently from the capture: (6, 534, 49589, 1220).
    private var run1SixOfSevenRow: UsageUnreportedStoredRow {
        UsageUnreportedStoredRow(
            sessionID: Self.run1Session, sequence: 1, timeNs: Self.run1End, model: Self.sonnet,
            totals: UsageTokenTotals(input: 6, output: 534, cacheRead: 49_589, cacheCreation: 1_220))
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar
    }

    // MARK: - Tracking off, deleting

    func test_trackingOff_isDropped_createsNothing_andReadsNoRunLog() async throws {
        tracking.set(false)
        let ledger = try makeLedger()
        let export = try element(try captured(run: "run1"), at: 1)

        let outcome = await ingest(export, into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .dropped)
        XCTAssertFalse(exists(storePath), "nothing may be created while tracking is off")
        let calls = try await runLogScript().calls
        XCTAssertEqual(calls, [])
    }

    func test_trackingOff_withAnExistingDatabase_isDropped_andStoresNothing() async throws {
        try await seedStore()
        tracking.set(false)
        let ledger = try makeLedger()

        let outcome = await ingest(try element(try captured(run: "run1"), at: 1), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .dropped)
        let points = try await inspect(ledger) { try await $0.pointRows() }
        let starts = try await inspect(ledger) { try await $0.processStarts() }
        XCTAssertEqual(points, [])
        XCTAssertEqual(starts, [])
        let calls = try await runLogScript().calls
        XCTAssertEqual(calls, [])
    }

    func test_deleteInProgress_isDropped() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        await script.gate(1)
        let ledger = try makeLedger()
        let first = try synthetic(Self.sessionA, value: 10, seconds: 10)
        let other = try synthetic(Self.sessionB, value: 7, seconds: 11)

        let firstOutcome = await ingestWithoutWaitingForTheSettle(ledger, first.body, receivedAtNs: first.receivedAtNs)
        XCTAssertEqual(firstOutcome, .stored)
        // An implementation that waited for its settle would hold every
        // later call too; stop here (tearDown releases the gate).
        guard firstOutcome == .stored else { return }
        try await waitForRunLogCalls(1)
        let deleting = Task { try await ledger.deleteAll() }
        await waitUntilDeleting(ledger)

        let duringDelete = await ingest(other, into: ledger)

        XCTAssertEqual(duringDelete, .dropped)
        await script.release(1)
        try await deleting.value
        await ledger.waitUntilIdle()
        let calls = await script.calls
        XCTAssertEqual(calls.map(\.sessionID), [Self.sessionA])
        let points = try await inspect(ledger) { try await $0.pointRows() }
        XCTAssertEqual(points, [])
    }

    // MARK: - Undecodable

    func test_undecodableBodies_areUndecodable_storeNothing_andAreReported() async throws {
        try await seedStore()
        let ledger = try makeLedger()
        let deep = Data(("{\"resourceMetrics\":" + String(repeating: "[", count: 600)
                         + String(repeating: "]", count: 600) + "}").utf8)
        let bodies: [(String, Data)] = [
            ("not JSON", Data("this is not JSON".utf8)),
            ("a JSON array", Data("[1,2,3]".utf8)),
            ("nested 600 deep", deep),
        ]

        for (name, body) in bodies {
            let outcome = await ledger.ingestExport(body, receivedAtNs: Self.syntheticStartNs)
            XCTAssertEqual(outcome, .undecodable, name)
        }
        await ledger.waitUntilIdle()

        let points = try await inspect(ledger) { try await $0.pointRows() }
        let starts = try await inspect(ledger) { try await $0.processStarts() }
        XCTAssertEqual(points, [])
        XCTAssertEqual(starts, [])
        assertDiagnostics([.exportUndecodable, .exportUndecodable, .exportUndecodable])
        let calls = try await runLogScript().calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Stored, then settled

    // run1's transcript is complete (it ends with its cost-state line) and
    // its last export is withheld: after the settles the run log is the
    // skeleton's and the unreported row is R2b's pinned one.
    func test_captureExports_areStored_andSettlingStoresTheRunLogAndTheUnreportedRow() async throws {
        try await seedStore()
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let ledger = try makeLedger()
        let exports = try captured(run: "run1")
        XCTAssertEqual(exports.count, 7, "Fixture error")

        await ingestAll(Array(exports.prefix(6)), into: ledger)
        await ledger.waitUntilIdle()

        let calls = try await runLogScript().calls
        XCTAssertFalse(calls.isEmpty, "the exports that changed the session settle it")
        XCTAssertEqual(Set(calls.map(\.sessionID)), [Self.run1Session])
        let expectedLog = try UsageRunLogFixtures.expectedLog(UsageRunLogFixtures.run1)
        let stored = try await inspect(ledger) { store in
            (try await store.runLog(forSession: Self.run1Session)?.log, try await store.unreportedRows(),
             try await store.pointRows())
        }
        XCTAssertEqual(stored.0, expectedLog)
        XCTAssertEqual(stored.1, [run1SixOfSevenRow])
        XCTAssertFalse(stored.2.isEmpty, "the points of the six exports are stored")
        XCTAssertEqual(Set(stored.2.map(\.sessionID)), [Self.run1Session])
        assertDiagnostics([])
    }

    // Received points plus the unreported row equal Claude Code's own
    // totals, and the withheld export, once received, leaves no row.
    func test_captureExports_pointsPlusUnreportedEqualCostState_andTheLastExportRemovesTheRow() async throws {
        try await seedStore()
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let ledger = try makeLedger()
        let exports = try captured(run: "run1")
        await ingestAll(Array(exports.prefix(6)), into: ledger)
        await ledger.waitUntilIdle()

        let points = try await inspect(ledger) { try await $0.pointRows() }
        var sum = Fixtures.totals(of: points)
        let row = run1SixOfSevenRow
        sum[Self.sonnet]?["input"]? += row.totals.input
        sum[Self.sonnet]?["output"]? += row.totals.output
        sum[Self.sonnet]?["cacheRead"]? += row.totals.cacheRead
        sum[Self.sonnet]?["cacheCreation"]? += row.totals.cacheCreation
        XCTAssertEqual(sum, try Fixtures.expectedTotals(run: "run1"))

        await ingestAll([try element(exports, at: 6)], into: ledger)
        await ledger.waitUntilIdle()
        let rows = try await inspect(ledger) { try await $0.unreportedRows() }
        XCTAssertEqual(rows, [])
    }

    // MARK: - Scheduling

    func test_ingestExport_answersWhileItsSettleIsHeld_andRequestsDuringItCostExactlyOneMoreSettle() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        await script.gate(1)
        let ledger = try makeLedger()

        let first = try synthetic(Self.sessionA, value: 10, seconds: 10)
        let answer = await ingestWithoutWaitingForTheSettle(ledger, first.body, receivedAtNs: first.receivedAtNs)
        XCTAssertEqual(answer, .stored)
        guard answer == .stored else { return }
        try await waitForRunLogCalls(1)
        let finishedWhileHeld = await script.finished
        XCTAssertEqual(finishedWhileHeld, 0, "the settle is still held")

        let second = await ingest(try synthetic(Self.sessionA, value: 20, seconds: 15), into: ledger)
        let third = await ingest(try synthetic(Self.sessionA, value: 30, seconds: 20), into: ledger)
        XCTAssertEqual(second, .stored)
        XCTAssertEqual(third, .stored)
        let callsWhileHeld = await script.calls.count
        XCTAssertEqual(callsWhileHeld, 1, "no second settle of the session while one runs")

        await script.release(1)
        await ledger.waitUntilIdle()

        let calls = await script.calls
        let perSession = await script.maxConcurrentPerSession
        XCTAssertEqual(calls.map(\.sessionID), [Self.sessionA, Self.sessionA],
                       "any number of requests during a settle cost exactly one more")
        XCTAssertEqual(perSession, 1)
        let points = try await inspect(ledger) { try await $0.pointRows() }
        XCTAssertEqual(points.map(\.inputTokens).reduce(0, +), 30, "every export was committed")
    }

    func test_differentSessions_settleIndependently() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        await script.gate(1)
        let ledger = try makeLedger()

        let first = try synthetic(Self.sessionA, value: 10, seconds: 10)
        let answer = await ingestWithoutWaitingForTheSettle(ledger, first.body, receivedAtNs: first.receivedAtNs)
        XCTAssertEqual(answer, .stored)
        guard answer == .stored else { return }
        try await waitForRunLogCalls(1)
        let other = await ingest(try synthetic(Self.sessionB, value: 5, seconds: 11), into: ledger)
        XCTAssertEqual(other, .stored)

        // B's settle starts while A's is still held.
        try await waitForRunLogCalls(2)
        let callsWhileHeld = await script.calls.map(\.sessionID)
        XCTAssertEqual(callsWhileHeld, [Self.sessionA, Self.sessionB])
        await script.release(1)
        await ledger.waitUntilIdle()

        let maxConcurrent = await script.maxConcurrent
        let calls = await script.calls.map(\.sessionID)
        XCTAssertEqual(maxConcurrent, 2)
        XCTAssertEqual(calls, [Self.sessionA, Self.sessionB])
    }

    // An export that changed nothing (the same values again) settles nothing.
    func test_anExportThatChangesNothing_requestsNoSettle() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()

        await ingestAll([try synthetic(Self.sessionA, value: 10, seconds: 10)], into: ledger)
        await ledger.waitUntilIdle()
        await ingestAll([try synthetic(Self.sessionA, value: 10, seconds: 15)], into: ledger)
        await ledger.waitUntilIdle()

        let calls = await script.calls.map(\.sessionID)
        XCTAssertEqual(calls, [Self.sessionA])
    }

    // MARK: - Unavailable store

    func test_storeThatCannotBeOpened_isUnavailable_andReported() async throws {
        try FileManager.default.createDirectory(atPath: databasePath, withIntermediateDirectories: true)
        let ledger = try makeLedger()

        let outcome = await ingest(try synthetic(Self.sessionA, value: 10, seconds: 10), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .unavailable)
        XCTAssertGreaterThanOrEqual(storeUnavailableCount, 1)
        XCTAssertEqual(diagnostics.all.count, storeUnavailableCount, "\(diagnostics.all)")
        let calls = try await runLogScript().calls
        XCTAssertEqual(calls, [])
    }

    // MARK: - Settle failures

    func test_settle_runLogReadFailure_isReported() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.fails)
        let ledger = try makeLedger()

        let outcome = await ingest(try synthetic(Self.sessionA, value: 10, seconds: 10), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .stored, "the export was committed before the settle")
        assertDiagnostics([
            .runLogReadFailed(sessionID: Self.sessionA, error: UsageLedgerDiagnostic.Failure(InjectedRunLogFailure())),
        ])
    }

    func test_settle_unusableTranscript_isReported_andMissingIsNot() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setOutcome(.status(.notARegularFile), forCall: 1)
        await script.setOutcome(.status(.redirected), forCall: 2)
        await script.setOutcome(.status(.missing), forCall: 3)
        let ledger = try makeLedger()

        await ingestAll([try synthetic(Self.sessionA, value: 10, seconds: 10)], into: ledger)
        await ledger.waitUntilIdle()
        await ingestAll([try synthetic(Self.sessionA, value: 20, seconds: 15)], into: ledger)
        await ledger.waitUntilIdle()
        await ingestAll([try synthetic(Self.sessionA, value: 30, seconds: 20)], into: ledger)
        await ledger.waitUntilIdle()

        let calls = await script.calls.count
        XCTAssertEqual(calls, 3, "Fixture error")
        assertDiagnostics([
            .transcriptNotUsable(sessionID: Self.sessionA, status: .notARegularFile),
            .transcriptNotUsable(sessionID: Self.sessionA, status: .redirected),
        ])
    }

    // MARK: - catchUp

    /// run1 while it runs: the transcript without its exit, exports 1-6
    /// received and settled. Returns the lines its exit appends.
    private func run1RunningWithSixExports(_ ledger: UsageLedger) async throws -> [Data] {
        let split = try run1SkeletonSplit()
        try writeTranscript(split.beforeExit, session: Self.run1Session)
        await ingestAll(Array(try captured(run: "run1").prefix(6)), into: ledger)
        await ledger.waitUntilIdle()
        let rows = try await inspect(ledger) { try await $0.unreportedRows() }
        XCTAssertEqual(rows, [], "Fixture error: no run is closed before the exit")
        return split.exit
    }

    func test_catchUp_afterTheExitWasAppended_storesTheUnreportedRow_andReturnsWhenDone() async throws {
        try await seedStore()
        let ledger = try makeLedger()
        let exit = try await run1RunningWithSixExports(ledger)
        try appendTranscript(exit, session: Self.run1Session)
        let script = try runLogScript()
        let callsBefore = await script.calls.count

        await ledger.catchUp()

        let calls = await script.calls
        let finished = await script.finished
        XCTAssertEqual(calls.count, callsBefore + 1, "one settle of the one session heard")
        XCTAssertEqual(finished, calls.count, "catchUp returns when its settles are done")
        let rows = try await inspect(ledger) { try await $0.unreportedRows() }
        XCTAssertEqual(rows, [run1SixOfSevenRow])
    }

    func test_catchUp_trackingOff_doesNothing() async throws {
        try await seedStore()
        let ledger = try makeLedger()
        let exit = try await run1RunningWithSixExports(ledger)
        try appendTranscript(exit, session: Self.run1Session)
        let script = try runLogScript()
        let callsBefore = await script.calls.count
        tracking.set(false)

        await ledger.catchUp()
        await ledger.waitUntilIdle()

        let calls = await script.calls.count
        XCTAssertEqual(calls, callsBefore)
        let rows = try await inspect(ledger) { try await $0.unreportedRows() }
        XCTAssertEqual(rows, [])
    }

    func test_catchUp_settlesEverySessionHeard_oneAfterAnother() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()
        await ingestAll([
            try synthetic(Self.sessionA, value: 10, seconds: 10),
            try synthetic(Self.sessionB, value: 10, seconds: 11),
        ], into: ledger)
        await ledger.waitUntilIdle()
        let before = await script.calls.count
        await script.resetStatistics()

        await ledger.catchUp()

        let calls = await script.calls.map(\.sessionID)
        let maxConcurrent = await script.maxConcurrent
        XCTAssertEqual(Array(calls.dropFirst(before)).sorted(), [Self.sessionA, Self.sessionB])
        XCTAssertEqual(maxConcurrent, 1, "catchUp settles one session after another")
    }

    // A session that never had a transcript: `catchUp` does not look for it
    // again within 10 minutes of finding it missing (the ledger's clock),
    // does after, and an export that changes the session always looks.
    func test_catchUp_missingTranscript_isNotLookedForWithin10Minutes_butIsAfter_andAnExportAlwaysLooks() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.missing))
        let ledger = try makeLedger()
        let start = Date(timeIntervalSince1970: 1_791_200_000)
        clock.set(start)

        await ingestAll([try synthetic(Self.sessionA, value: 10, seconds: 10)], into: ledger)
        await ledger.waitUntilIdle()
        let afterExport = await script.count(forSession: Self.sessionA)
        XCTAssertEqual(afterExport, 1)

        await ledger.catchUp()
        clock.set(start.addingTimeInterval(9 * 60))
        await ledger.catchUp()
        let within = await script.count(forSession: Self.sessionA)
        XCTAssertEqual(within, 1, "not looked for again within 10 minutes")

        clock.set(start.addingTimeInterval(11 * 60))
        await ledger.catchUp()
        let after = await script.count(forSession: Self.sessionA)
        XCTAssertEqual(after, 2, "looked for again after 10 minutes")

        // Just found missing again; an export that changes the session
        // looks at once.
        await ingestAll([try synthetic(Self.sessionA, value: 20, seconds: 15)], into: ledger)
        await ledger.waitUntilIdle()
        let byExport = await script.count(forSession: Self.sessionA)
        XCTAssertEqual(byExport, 3)
        assertDiagnostics([])
    }

    // MARK: - Project root

    // The resolver fails. After that the session's settles pass
    // `resolveProjectRoot: false` until a new line was read, so git is not
    // asked every few seconds; once a line was read it is asked again.
    func test_projectRootFailure_isNotRetried_untilANewLineWasRead() async throws {
        try await seedStore()
        resolver.setFails(true)
        script = RunLogScript(root: root, resolver: resolver, directoryState: .present)
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let ledger = try makeLedger()

        await ingestAll([try element(try captured(run: "run1"), at: 1)], into: ledger)
        await ledger.waitUntilIdle()
        XCTAssertEqual(resolver.calls, 1, "the first settle asks the resolver")
        XCTAssertTrue(diagnostics.all.contains(.projectRootResolutionFailed(sessionID: Self.run1Session)))

        await ledger.catchUp()
        await ledger.catchUp()
        await ingestAll([try element(try captured(run: "run1"), at: 2)], into: ledger)
        await ledger.waitUntilIdle()
        await ledger.catchUp()
        XCTAssertEqual(resolver.calls, 1, "no new line was read: the resolver is not asked again")
        let script = try runLogScript()
        let flags = await script.calls.map(\.resolveProjectRoot)
        XCTAssertEqual(flags.first, true)
        XCTAssertEqual(Array(flags.dropFirst()), Array(repeating: false, count: max(0, flags.count - 1)))

        let line = #"{"type":"user","timestamp":"2026-10-05T07:30:00.000Z","sessionId":"#
            + #""11111111-1111-4111-8111-111111111111","cwd":"/fixture/project"}"#
        try appendTranscript([Data(line.utf8)], session: Self.run1Session)
        await ledger.catchUp()
        await ledger.catchUp()
        XCTAssertEqual(resolver.calls, 2, "a new line was read: the resolver is asked once more")
    }

    // `deleteAll` forgets the note: the first settle after it asks again.
    func test_projectRootFailure_isForgottenByDeleteAll() async throws {
        try await seedStore()
        resolver.setFails(true)
        script = RunLogScript(root: root, resolver: resolver, directoryState: .present)
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let ledger = try makeLedger()
        await ingestAll([try element(try captured(run: "run1"), at: 1)], into: ledger)
        await ledger.waitUntilIdle()
        XCTAssertEqual(resolver.calls, 1, "Fixture error")

        try await ledger.deleteAll()
        // The delete restarted tracking at the system clock: a process
        // started far later counts.
        await ingestAll(
            [try synthetic(Self.run1Session, value: 10, seconds: 10, startNs: Self.futureStartNs)], into: ledger)
        await ledger.waitUntilIdle()

        let script = try runLogScript()
        let last = await script.calls.last
        XCTAssertEqual(last, RunLogScript.Call(sessionID: Self.run1Session, resolveProjectRoot: true))
        XCTAssertEqual(resolver.calls, 2)
    }

    // MARK: - tokenReports

    func test_tokenReports_catchesUpFirst() async throws {
        try await seedStore()
        let ledger = try makeLedger()
        let exit = try await run1RunningWithSixExports(ledger)
        try appendTranscript(exit, session: Self.run1Session)

        let results = try await ledger.tokenReports(
            [UsageTokenQuery(groupBy: [.model]), UsageTokenQuery(groupBy: [.model], thread: "main")],
            calendar: Self.utc)

        XCTAssertEqual(results.count, 2)
        let byModel = try element(results, at: 0)
        let unreported = byModel.filter(\.isUnreported)
        XCTAssertEqual(unreported.count, 1, "only the catch-up can have produced it: \(byModel)")
        let row = try XCTUnwrap(unreported.first)
        XCTAssertEqual(row.key, [Self.sonnet])
        XCTAssertEqual(row.inputTokens, 6)
        XCTAssertEqual(row.outputTokens, 534)
        XCTAssertEqual(row.cacheReadTokens, 49_589)
        XCTAssertEqual(row.cacheCreationTokens, 1_220)
        XCTAssertEqual(row.lastTimestampMs, Self.run1End / 1_000_000)
        XCTAssertEqual(try element(results, at: 1).filter(\.isUnreported), [], "a thread filter drops unreported rows")
    }

    func test_tokenReports_trackingOffWithoutADatabase_answersEmptyLists_andCreatesNothing() async throws {
        tracking.set(false)
        let ledger = try makeLedger()

        let results = try await ledger.tokenReports(
            [UsageTokenQuery(), UsageTokenQuery(groupBy: [.session])], calendar: Self.utc)

        XCTAssertEqual(results, [[], []])
        XCTAssertFalse(exists(storePath))
        let calls = try await runLogScript().calls
        XCTAssertEqual(calls, [])
    }

    func test_tokenReports_aStoreErrorIsThrown() async throws {
        try await seedStore()
        let ledger = try makeLedger()

        do {
            _ = try await ledger.tokenReports([UsageTokenQuery(groupBy: [.model, .model])], calendar: Self.utc)
            XCTFail("a repeated dimension must throw")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .invalidQuery)
        }
    }

    // MARK: - deleteAll during a settle

    // The held settle runs the real reader once released; a delete that
    // did not wait for it would find its run log written afterwards. A
    // second export during the settle asked for one more run, which the
    // delete drops.
    func test_deleteAll_duringASettle_waitsForIt_dropsTheRequestedRun_leavesNothing_andLaterExportsWork() async throws {
        try await seedStore()
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let script = try runLogScript()
        await script.gate(1)
        let ledger = try makeLedger()
        let exports = try captured(run: "run1")

        let answer = await ingestWithoutWaitingForTheSettle(
            ledger, try element(exports, at: 1).body, receivedAtNs: try element(exports, at: 1).receivedAtNs)
        XCTAssertEqual(answer, .stored)
        guard answer == .stored else { return }
        try await waitForRunLogCalls(1)
        // Another process of the session: a new series, so the session
        // changed and one more run is requested.
        await ingestAll([try synthetic(Self.run1Session, value: 5, seconds: 30)], into: ledger)

        let returned = Box<Bool>()
        let deleting = Task {
            try await ledger.deleteAll()
            returned.set(true)
        }
        await waitUntilDeleting(ledger)
        for _ in 0..<50 {
            await Task.yield()
        }
        XCTAssertNil(returned.value, "deleteAll returned while a settle was running")
        await script.release(1)
        try await deleting.value
        await ledger.waitUntilIdle()

        let calls = await script.calls.count
        XCTAssertEqual(calls, 1, "the run requested before the delete is dropped")
        let left = try await inspect(ledger) { store in
            (try await store.runLog(forSession: Self.run1Session) == nil, try await store.unreportedRows(),
             try await store.pointRows(), try await store.sessionsWithSeries())
        }
        XCTAssertTrue(left.0, "no run log may be left behind")
        XCTAssertEqual(left.1, [])
        XCTAssertEqual(left.2, [])
        XCTAssertEqual(left.3, [])

        let later = await ingest(try synthetic(Self.sessionA, value: 42, seconds: 10, startNs: Self.futureStartNs),
                                 into: ledger)
        await ledger.waitUntilIdle()
        XCTAssertEqual(later, .stored)
        let points = try await inspect(ledger) { try await $0.pointRows() }
        XCTAssertEqual(points.map(\.sessionID), [Self.sessionA])
        XCTAssertEqual(points.map(\.inputTokens), [42])
    }

    // MARK: - syncTracking

    func test_syncTracking_trackingOff_withoutADatabase_createsNothing() async throws {
        tracking.set(false)
        let ledger = try makeLedger()

        await ledger.syncTracking()

        XCTAssertFalse(exists(storePath))
    }

    func test_syncTracking_trackingOn_createsTheStore_active() async throws {
        let ledger = try makeLedger()

        await ledger.syncTracking()

        XCTAssertTrue(exists(databasePath))
        let active = try await inspect(ledger) { try await $0.isTrackingActive() }
        XCTAssertTrue(active)
    }

    func test_syncTracking_trackingOff_withADatabase_pausesTheFlag() async throws {
        try await seedStore()
        tracking.set(false)
        let ledger = try makeLedger()

        await ledger.syncTracking()

        let active = try await inspect(ledger) { try await $0.isTrackingActive() }
        XCTAssertFalse(active)
    }

    /// A process heard while tracking was on: exports at +10 s and +15 s
    /// (input 10, then 25).
    private func heardProcess(_ ledger: UsageLedger) async throws {
        await ingestAll([
            try synthetic(Self.sessionA, value: 10, seconds: 10),
            try synthetic(Self.sessionA, value: 25, seconds: 15),
        ], into: ledger)
        await ledger.waitUntilIdle()
    }

    /// The same process's next export, received long after any restart's
    /// settling window, with input grown to 1_000.
    private func grownExportOfTheHeardProcess() throws -> Export {
        let export = try synthetic(Self.sessionA, value: 1_000, seconds: 20)
        return Export(body: export.body, receivedAtNs: Self.futureStartNs)
    }

    // Tracking off, synced, then on: the next export is applied only after
    // the switch restarted tracking, so what the running process counted
    // meanwhile (975 tokens) is never added.
    func test_switchBackOn_afterAnExplicitSync_restartsTrackingBeforeTheNextExport() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()
        try await heardProcess(ledger)

        tracking.set(false)
        await ledger.syncTracking()
        tracking.set(true)
        let outcome = await ingest(try grownExportOfTheHeardProcess(), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .stored)
        let state = try await inspect(ledger) { store in
            (try await store.pointRows().map(\.inputTokens).reduce(0, +), try await store.isTrackingActive())
        }
        XCTAssertEqual(state.0, 25, "usage counted while tracking was off must not be added")
        XCTAssertTrue(state.1)
    }

    // The ledger notices the setting changed at an export it drops.
    func test_switchBackOn_noticedAtADroppedExport_restartsTrackingBeforeTheNextExport() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()
        try await heardProcess(ledger)

        tracking.set(false)
        let dropped = await ingest(try synthetic(Self.sessionA, value: 500, seconds: 17), into: ledger)
        tracking.set(true)
        let outcome = await ingest(try grownExportOfTheHeardProcess(), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(dropped, .dropped)
        XCTAssertEqual(outcome, .stored)
        let total = try await inspect(ledger) { try await $0.pointRows().map(\.inputTokens).reduce(0, +) }
        XCTAssertEqual(total, 25, "usage counted while tracking was off must not be added")
    }

    // Calyx quit while tracking was paused (the flag on disk) and starts
    // again with tracking on: a new ledger restarts tracking before it
    // applies the first export.
    func test_newLedger_findingThePausedFlag_restartsTrackingBeforeItsFirstExport() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let earlier = try makeLedger()
        try await heardProcess(earlier)
        tracking.set(false)
        await earlier.syncTracking()
        await earlier.close()
        let paused = try await inspect(earlier) { try await $0.isTrackingActive() }
        XCTAssertFalse(paused, "Fixture error")

        tracking.set(true)
        let ledger = try makeLedger()
        let outcome = await ingest(try grownExportOfTheHeardProcess(), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .stored)
        let total = try await inspect(ledger) { try await $0.pointRows().map(\.inputTokens).reduce(0, +) }
        XCTAssertEqual(total, 25)
    }

    // Steady state: tracking stayed on, so the same process's growth counts.
    func test_trackingStayedOn_theGrowthCounts() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()
        try await heardProcess(ledger)

        let outcome = await ingest(try grownExportOfTheHeardProcess(), into: ledger)
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .stored)
        let total = try await inspect(ledger) { try await $0.pointRows().map(\.inputTokens).reduce(0, +) }
        XCTAssertEqual(total, 1_000)
    }

    // MARK: - deleteAll during an apply (review round 1, W1)

    /// Runs `body` in a task and waits for it, bounded by `waitSeconds`.
    /// False (and a test failure) when it did not finish: a regression
    /// that never lets it finish fails the test instead of hanging the run.
    private func finishes(
        _ what: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let done = Box<Bool>()
        let finished = expectation(description: "\(what) finished")
        Task {
            await body()
            done.set(true)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: Self.waitSeconds)
        return done.value == true
    }

    private func waitUntilAnApplyIsHeld() async {
        let applyGate = self.applyGate
        let held = expectation(description: "an apply is held after it committed")
        Task {
            await applyGate.waitUntilHeld()
            held.fulfill()
        }
        await fulfillment(of: [held], timeout: Self.waitSeconds)
    }

    // An export whose `apply` committed but has not returned to the ledger
    // when `deleteAll()` starts. The delete waits for it, and the export,
    // resuming during the delete, requests no settle: nothing of the
    // session is written back after the delete returned.
    func test_deleteAll_whileAnExportsApplyIsInFlight_waitsForIt_andNothingIsWrittenBack() async throws {
        try await seedStore()
        try writeTranscript(try UsageRunLogFixtures.lines(UsageRunLogFixtures.run1), session: Self.run1Session)
        let ledger = try makeLedger()
        let export = try element(try captured(run: "run1"), at: 1)
        await applyGate.arm()

        let answered = Box<UsageIngestOutcome>()
        let ingesting = Task {
            answered.set(await ledger.ingestExport(export.body, receivedAtNs: export.receivedAtNs))
        }
        await waitUntilAnApplyIsHeld()
        guard await applyGate.isHeld else { return }

        // Fulfilled when deleteAll returns, which it must not do while the
        // apply is held: inverted, bounded at 2 s. A delete that does not
        // wait for the store call returns within milliseconds and fails
        // here; the gate is then opened only after it returned, so the
        // test also shows what the resumed export writes back.
        let returnedWhileHeld = expectation(description: "deleteAll returned while an apply was in flight")
        returnedWhileHeld.isInverted = true
        let deleting = Task {
            try await ledger.deleteAll()
            returnedWhileHeld.fulfill()
        }
        await fulfillment(of: [returnedWhileHeld], timeout: 2)
        await applyGate.open()
        guard await finishes("deleteAll", { _ = try? await deleting.value }),
              await finishes("the ingest", { await ingesting.value }) else { return }
        let script = try runLogScript()
        let callsWhenDeleted = await script.calls.count
        guard await finishes("waitUntilIdle", { await ledger.waitUntilIdle() }) else { return }

        XCTAssertEqual(answered.value, .stored)
        let callsAfter = await script.calls.count
        XCTAssertEqual(callsAfter, callsWhenDeleted, "readRunLog was called after the delete returned")
        XCTAssertEqual(callsAfter, 0, "the export resumed during the delete and must request no settle")
        let left = try await inspect(ledger) { store in
            (try await store.runLog(forSession: Self.run1Session) == nil,
             try await store.session(Self.run1Session) == nil,
             try await store.pointRows(), try await store.unreportedRows())
        }
        XCTAssertTrue(left.0, "no run log may be written back")
        XCTAssertTrue(left.1, "no session row may be written back")
        XCTAssertEqual(left.2, [])
        XCTAssertEqual(left.3, [])
    }

    // MARK: - Reports during a delete (review round 2)

    // A delete is held in progress (it waits for an export's apply held by
    // the gate). A report asked meanwhile waits for the delete and answers
    // the store as it is afterwards: empty, not the points from before.
    func test_tokenReports_duringADelete_waitsForIt_andAnswersThePostDeleteState() async throws {
        try await seedStore()
        let script = try runLogScript()
        await script.setDefault(.status(.read))
        let ledger = try makeLedger()
        await ingestAll([try synthetic(Self.sessionA, value: 10, seconds: 10)], into: ledger)
        guard await finishes("waitUntilIdle", { await ledger.waitUntilIdle() }) else { return }
        let before = try await ledger.tokenReports([UsageTokenQuery(groupBy: [.model])], calendar: Self.utc)
        XCTAssertEqual(before.first?.count, 1, "Fixture error: a recorded row before the delete")

        await applyGate.arm()
        let held = try synthetic(Self.sessionA, value: 20, seconds: 15)
        let ingesting = Task { _ = await ledger.ingestExport(held.body, receivedAtNs: held.receivedAtNs) }
        await waitUntilAnApplyIsHeld()
        guard await applyGate.isHeld else { return }
        let deleting = Task { try await ledger.deleteAll() }
        await waitUntilDeleting(ledger)

        let answer = Box<[[UsageTokenRow]]>()
        let answeredDuringDelete = expectation(description: "tokenReports answered while the delete was in progress")
        answeredDuringDelete.isInverted = true
        let reporting = Task {
            let rows = (try? await ledger.tokenReports([UsageTokenQuery(groupBy: [.model])], calendar: Self.utc))
            answer.set(rows ?? [[UsageTokenRow(
                key: ["error"], isUnreported: false, inputTokens: -1, cacheReadTokens: -1, cacheCreationTokens: -1,
                outputTokens: -1, lastTimestampMs: -1)]])
            answeredDuringDelete.fulfill()
        }
        await fulfillment(of: [answeredDuringDelete], timeout: 2)

        await applyGate.open()
        guard await finishes("deleteAll", { _ = try? await deleting.value }),
              await finishes("the ingest", { await ingesting.value }),
              await finishes("tokenReports", { await reporting.value }) else { return }
        XCTAssertEqual(answer.value, [[]], "the report answers the store as it is after the delete")
    }
}
