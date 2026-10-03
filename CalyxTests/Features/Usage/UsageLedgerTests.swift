//
//  UsageLedgerTests.swift
//  CalyxTests
//
//  Pins UsageLedger, the actor between an accepted hook event and the
//  usage store: off means no ingest
//  and no file; the store opens lazily; a note is located on every call
//  and a rejection is never remembered; an ingest starts for a transcript
//  not ingested yet or for a trigger event; one ingest per transcript is
//  in flight and any number of triggers during it cost one re-run; only a
//  main status of `.read` marks the transcript and publishes the session's
//  total row; partial results become diagnostics; `reconcileKnown` and
//  `report` re-read every known session; `deleteAll` waits for running
//  ingests, refuses new ones, empties the store and publishes nil.
//
//  The `ingest` seam is a scripted actor (`IngestScript`) that records
//  every call, can hold a call until the test releases it, and answers as
//  configured; the REAL UsageIngestor runs behind the same seam for the
//  end-to-end paths. The store is always a real UsageStore in a per-test
//  temporary directory; transcripts are synthetic files under a synthetic
//  projects root in that directory, removed in tearDown after every
//  ledger and store is closed. ~/.claude, Application Support and
//  UserDefaults are never touched. Nothing here sleeps to synchronise:
//  ordering comes from the gate, `waitUntilIdle()` and awaited tasks.
//

import os
import SQLite3
import XCTest
@testable import Calyx

// MARK: - Test doubles

private struct InjectedIngestFailure: Error {}

/// "Not a repository": the session's root is its cwd.
private struct NoRepositoryResolver: ProjectRootResolving {
    func projectRoot(forCWD cwd: String) async throws -> String? { nil }
}

/// The scripted `ingest` seam.
private actor IngestScript {
    enum Outcome: Sendable {
        /// Applies `records` and the session meta to the store, then
        /// returns a `.read` main entry followed by `subagents`.
        case read(records: [UsageRecord], subagents: [UsageIngestFileResult], rootFailed: Bool)
        /// Returns a single main entry with this status; stores nothing.
        case main(UsageIngestFileResult.Status)
        /// Returns a result without any file entry; stores nothing.
        case noFiles
        case fails
        /// Runs the real UsageIngestor.
        case real
    }

    /// Every call's location, in call order. Call indices are 1-based.
    private(set) var started: [ClaudeTranscriptLocation] = []
    private(set) var finished = 0
    /// "start <n>" / "end <n>" per call, plus whatever a test logs.
    private(set) var events: [String] = []
    private(set) var maxConcurrent = 0
    private(set) var maxConcurrentPerPath = 0

    private var defaultOutcome: Outcome = .read(records: [], subagents: [], rootFailed: false)
    private var outcomes: [Int: Outcome] = [:]
    private var hooks: [Int: @Sendable () async -> Void] = [:]
    private var gated: Set<Int> = []
    private var released: Set<Int> = []
    private var gatesOpen = false
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var running = 0
    private var runningByPath: [String: Int] = [:]

    func setDefault(_ outcome: Outcome) { defaultOutcome = outcome }
    func setOutcome(_ outcome: Outcome, forCall index: Int) { outcomes[index] = outcome }
    /// Runs inside call `index`, after its gate and before its outcome.
    func setHook(forCall index: Int, _ hook: @escaping @Sendable () async -> Void) { hooks[index] = hook }
    func log(_ event: String) { events.append(event) }

    func count(forSession sessionID: String) -> Int {
        started.filter { $0.sessionID == sessionID }.count
    }

    func resetStatistics() {
        maxConcurrent = running
        maxConcurrentPerPath = runningByPath.values.max() ?? 0
        events = []
    }

    /// Call `index` suspends inside the seam until `release(index)`.
    func gate(_ index: Int) { gated.insert(index) }

    func release(_ index: Int) {
        released.insert(index)
        releaseWaiters.removeValue(forKey: index)?.resume()
    }

    /// Opens every gate, present and future (tearDown).
    func releaseEverything() {
        gatesOpen = true
        let waiters = releaseWaiters.values
        releaseWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once at least `count` calls have entered the seam.
    func waitForStart(_ count: Int) async {
        if started.count >= count { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func run(_ location: ClaudeTranscriptLocation, store: UsageStore) async throws -> UsageIngestResult {
        started.append(location)
        let index = started.count
        events.append("start \(index)")
        running += 1
        runningByPath[location.mainPath, default: 0] += 1
        maxConcurrent = max(maxConcurrent, running)
        maxConcurrentPerPath = max(maxConcurrentPerPath, runningByPath[location.mainPath] ?? 0)
        let ready = startWaiters.filter { $0.count <= index }
        startWaiters.removeAll { $0.count <= index }
        for waiter in ready { waiter.continuation.resume() }
        defer {
            running -= 1
            runningByPath[location.mainPath, default: 1] -= 1
            finished += 1
            events.append("end \(index)")
        }

        if gated.contains(index), !released.contains(index), !gatesOpen {
            await withCheckedContinuation { releaseWaiters[index] = $0 }
        }
        if let hook = hooks[index] {
            await hook()
        }

        func mainEntry(_ status: UsageIngestFileResult.Status) -> UsageIngestFileResult {
            UsageIngestFileResult(
                path: location.mainPath, status: status, linesRead: 0, recordsEmitted: 0,
                oversizeLinesSkipped: 0, batchesApplied: 0)
        }
        switch outcomes[index] ?? defaultOutcome {
        case .read(let records, let subagents, let rootFailed):
            try await store.apply(UsageBatch(
                records: records,
                session: UsageSessionMeta(
                    sessionID: location.sessionID, transcriptPath: location.mainPath, projectRoot: nil),
                fileCheckpoint: nil))
            return UsageIngestResult(files: [mainEntry(.read)] + subagents, projectRootResolutionFailed: rootFailed)
        case .main(let status):
            return UsageIngestResult(files: [mainEntry(status)], projectRootResolutionFailed: false)
        case .noFiles:
            return UsageIngestResult(files: [], projectRootResolutionFailed: false)
        case .fails:
            throw InjectedIngestFailure()
        case .real:
            return try await UsageIngestor(store: store, resolver: NoRepositoryResolver()).ingest(location)
        }
    }
}

private struct Published: Equatable, Sendable {
    let sessionID: String
    let row: UsageRow?
}

/// The `publish` seam: records every call in order.
private actor PublishLog {
    private(set) var entries: [Published] = []
    private var hook: (@Sendable (Published) async -> Void)?

    /// Runs inside every later `publish` call, after it was recorded.
    func setHook(_ hook: @escaping @Sendable (Published) async -> Void) { self.hook = hook }
    func clearHook() { hook = nil }

    func record(_ sessionID: String, _ row: UsageRow?) async {
        let entry = Published(sessionID: sessionID, row: row)
        entries.append(entry)
        if let hook {
            await hook(entry)
        }
    }
}

/// The `onDiagnostic` seam (a synchronous closure).
private final class DiagnosticLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [UsageLedgerDiagnostic]())

    func append(_ diagnostic: UsageLedgerDiagnostic) { state.withLock { $0.append(diagnostic) } }
    var all: [UsageLedgerDiagnostic] { state.withLock { $0 } }
}

// MARK: - Tests

final class UsageLedgerTests: XCTestCase {

    private let sessionA = "11111111-2222-3333-4444-555555555555"
    private let sessionB = "99999999-8888-7777-6666-555555555555"
    private let sessionC = "cccccccc-0000-0000-0000-000000000003"

    /// realpath(3) of the per-test temporary directory.
    private var tempPath: String!
    private var script: IngestScript!
    private var publishLog: PublishLog!
    private var diagnosticLog: DiagnosticLog!
    /// What `isEnabled()` answers; tests flip it.
    private var enabled: OSAllocatedUnfairLock<Bool>!
    private var ledgers: [UsageLedger] = []
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw InjectedIngestFailure() }
        tempPath = String(cString: resolved)
        free(resolved)
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
        script = IngestScript()
        publishLog = PublishLog()
        diagnosticLog = DiagnosticLog()
        enabled = OSAllocatedUnfairLock(initialState: true)
    }

    override func tearDown() async throws {
        // A failed test may leave an ingest held at its gate; let it go so
        // closing the ledgers cannot wait forever.
        await script?.releaseEverything()
        await publishLog?.clearHook()
        for ledger in ledgers {
            await ledger.close()
        }
        ledgers = []
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        if let tempPath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = nil
        script = nil
        publishLog = nil
        diagnosticLog = nil
        enabled = nil
        try await super.tearDown()
    }

    // MARK: - Paths

    private var root: String { tempPath + "/projects" }
    private var projectDirectory: String { root + "/-Users-someone-repo" }
    private var storePath: String { tempPath + "/store/usage" }
    private var databasePath: String { storePath + "/usage.sqlite" }

    private func mainPath(_ sessionID: String) -> String {
        projectDirectory + "/" + sessionID + ".jsonl"
    }

    private func subagentPath(_ sessionID: String, _ agentID: String) -> String {
        projectDirectory + "/" + sessionID + "/subagents/agent-" + agentID + ".jsonl"
    }

    /// The location `ClaudeTranscriptLocator.locate` returns, by hand.
    private func location(_ sessionID: String) -> ClaudeTranscriptLocation {
        ClaudeTranscriptLocation(
            mainPath: mainPath(sessionID), sessionID: sessionID,
            subagentsDirectory: projectDirectory + "/" + sessionID + "/subagents")
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Ledger

    private func makeLedger(storeDirectory: String? = nil) -> UsageLedger {
        let script = self.script!
        let publishLog = self.publishLog!
        let diagnosticLog = self.diagnosticLog!
        let enabled = self.enabled!
        let root = self.root
        let ledger = UsageLedger(
            isEnabled: { enabled.withLock { $0 } },
            projectsRoot: { root },
            storeDirectory: URL(fileURLWithPath: storeDirectory ?? storePath, isDirectory: true),
            ingest: { location, store in try await script.run(location, store: store) },
            publish: { sessionID, row in await publishLog.record(sessionID, row) },
            onDiagnostic: { diagnosticLog.append($0) })
        ledgers.append(ledger)
        return ledger
    }

    private func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    private func activity(_ event: String, _ sessionID: String? = nil, path: String? = nil) -> UsageActivity {
        let session = sessionID ?? sessionA
        return UsageActivity(sessionID: session, transcriptPath: path ?? mainPath(session), hookEventName: event)
    }

    /// Notes and waits until no ingest is running or pending.
    private func noteAndSettle(_ ledger: UsageLedger, _ event: String, _ sessionID: String? = nil) async {
        await ledger.note(activity(event, sessionID))
        await ledger.waitUntilIdle()
    }

    private func ingestCount() async -> Int {
        await script.started.count
    }

    /// Diagnostics compared without regard to order.
    private func assertDiagnostics(
        _ expected: [UsageLedgerDiagnostic], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            diagnosticLog.all.map { "\($0)" }.sorted(), expected.map { "\($0)" }.sorted(), file: file, line: line)
    }

    // MARK: - Direct store access (fixtures and inspection)

    /// Opens the store directory the ledger uses. Only while no ledger
    /// holds it open, or for reading next to one.
    private func openStoreDirectly() throws -> UsageStore {
        let store = try UsageStore(directory: URL(fileURLWithPath: storePath, isDirectory: true))
        openedStores.append(store)
        return store
    }

    /// Writes batches into the store before a ledger exists, and closes it.
    private func seedStore(_ batches: [UsageBatch]) async throws {
        let store = try openStoreDirectly()
        for batch in batches {
            try await store.apply(batch)
        }
        await store.close()
    }

    private func sessionBatch(_ sessionID: String, transcriptPath: String?, records: [UsageRecord] = []) -> UsageBatch {
        UsageBatch(
            records: records,
            session: UsageSessionMeta(sessionID: sessionID, transcriptPath: transcriptPath, projectRoot: nil),
            fileCheckpoint: nil)
    }

    // MARK: - Files

    /// Writes `lines`, each terminated by "\n".
    private func write(_ lines: [String], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Appends raw text (no newline is added) to an existing file.
    private func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path), "Fixture error: cannot open \(path)")
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// An existing (synthetic) main transcript holding one non-record line.
    private func makeMainFile(_ sessionID: String? = nil) throws {
        try write([userLine], to: mainPath(sessionID ?? sessionA))
    }

    // MARK: - Transcript lines (same shape as UsageIngestorTests)

    /// One final assistant line in the transcript's shape, as raw text.
    /// `agentID` non-nil makes it a subagent (sidechain) line.
    private func assistantLine(_ id: String, sessionID: String? = nil, agentID: String? = nil) -> String {
        var text = #"{"type":"assistant","sessionId":""# + (sessionID ?? sessionA) + #"","#
        text += #""timestamp":"2026-10-02T10:27:29.765Z","#
        text += #""cwd":"/work/repo/sub","#
        text += #""gitBranch":"main","effort":"high","#
        if let agentID {
            text += #""isSidechain":true,"agentId":""# + agentID + #"","attributionAgent":"swift-specialist","#
        } else {
            text += #""isSidechain":false,"#
        }
        text += #""message":{"id":""# + id + #"","model":"claude-opus-5-5","stop_reason":"end_turn","#
        text += #""usage":{"input_tokens":3,"output_tokens":420"#
        text += #","cache_read_input_tokens":90000,"cache_creation_input_tokens":1200,"#
        text += #""cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":200},"#
        text += #""output_tokens_details":{"thinking_tokens":150}"#
        text += "}}}"
        return text
    }

    /// A line that is read but yields no record.
    private var userLine: String {
        #"{"type":"user","sessionId":"11111111-2222-3333-4444-555555555555","message":{"role":"user"}}"#
    }

    /// The record `assistantLine(key, ...)` stands for, written by hand:
    /// 2026-10-02T10:27:29.765Z is 1_790_936_849_765 ms.
    private func record(_ key: String, sessionID: String? = nil, agentID: String? = nil) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID ?? sessionA,
            timestampMs: 1_790_936_849_765,
            model: "claude-opus-5-5",
            effort: "high",
            thread: agentID == nil ? .main : .subagent,
            agentID: agentID,
            agentType: agentID == nil ? nil : "swift-specialist",
            gitBranch: "main",
            cwd: "/work/repo/sub",
            inputTokens: 3,
            outputTokens: 420,
            thinkingTokens: 150,
            cacheReadTokens: 90_000,
            cacheCreationTokens: 1_200,
            cacheCreation1hTokens: 1_000,
            isFinal: true
        )
    }

    /// The total row of a session holding `responses` of those records,
    /// by hand: every record is final with input 3, output 420, thinking
    /// 150, cache read 90,000, cache creation 1,200 (1,000 of it 1h).
    private func totalRow(_ responses: Int64, key: [String?] = []) -> UsageRow {
        UsageRow(
            key: key,
            responses: responses,
            finalResponses: responses,
            inputTokens: 3 * responses,
            cacheReadTokens: 90_000 * responses,
            cacheCreationTokens: 1_200 * responses,
            cacheCreation1hTokens: 1_000 * responses,
            outputTokensFinal: 420 * responses,
            thinkingTokensFinal: 150 * responses,
            lastTimestampMs: 1_790_936_849_765
        )
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A scripted successful outcome that stores `records`.
    private func stores(_ records: [UsageRecord]) -> IngestScript.Outcome {
        .read(records: records, subagents: [], rootFailed: false)
    }

    private func subagentEntry(_ path: String, _ status: UsageIngestFileResult.Status) -> UsageIngestFileResult {
        UsageIngestFileResult(
            path: path, status: status, linesRead: 0, recordsEmitted: 0, oversizeLinesSkipped: 0, batchesApplied: 0)
    }

    // MARK: - Constants

    func test_ingestTriggerEvents_areExactlyStopSubagentStopAndSessionEnd() {
        XCTAssertEqual(UsageLedger.ingestTriggerEvents, ["Stop", "SubagentStop", "SessionEnd"])
    }

    // MARK: - init

    func test_init_touchesNoFile() async {
        _ = makeLedger()

        XCTAssertFalse(exists(tempPath + "/store"), "init must not create the store directory")
        let count = await ingestCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Off means no Bronze read and no file created

    func test_off_note_doesNotCallTheSeamAndCreatesNoFile() async throws {
        setEnabled(false)
        try makeMainFile()
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        await noteAndSettle(ledger, "SessionStart")

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0)
        XCTAssertEqual(published, [])
        assertDiagnostics([])
        XCTAssertFalse(exists(tempPath + "/store"), "Nothing may be created while tracking is off")
    }

    func test_off_reconcileKnown_withoutAStore_doesNothingAndCreatesNoFile() async {
        setEnabled(false)
        let ledger = makeLedger()

        await ledger.reconcileKnown()

        let count = await ingestCount()
        XCTAssertEqual(count, 0)
        assertDiagnostics([])
        XCTAssertFalse(exists(tempPath + "/store"))
    }

    func test_off_reconcileKnown_withAStoredSession_doesNotCallTheSeam() async throws {
        try makeMainFile()
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA), records: [record("msg_m1")])])
        setEnabled(false)
        let ledger = makeLedger()

        await ledger.reconcileKnown()

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0)
        XCTAssertEqual(published, [])
        assertDiagnostics([])
    }

    func test_turnedOffAfterAnIngest_laterNotesAndReconcilesDoNothing() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        let before = await ingestCount()
        XCTAssertEqual(before, 1, "Fixture error: the first note must ingest")

        setEnabled(false)
        await noteAndSettle(ledger, "Stop")
        await ledger.reconcileKnown()

        let after = await ingestCount()
        XCTAssertEqual(after, 1)
    }

    func test_turnedOnLater_theNextNoteIngests() async throws {
        setEnabled(false)
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "SessionStart")

        setEnabled(true)
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Store lifetime

    func test_on_firstIngest_createsTheStoreInTheGivenDirectory() async throws {
        try makeMainFile()
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")

        XCTAssertTrue(exists(databasePath))
        assertDiagnostics([])
    }

    func test_off_report_withoutADatabase_returnsNoRowsAndCreatesNothing() async throws {
        setEnabled(false)
        let ledger = makeLedger()

        let rows = try await ledger.report(UsageQuery(), calendar: utc)

        XCTAssertEqual(rows, [])
        XCTAssertFalse(exists(tempPath + "/store"))
        assertDiagnostics([])
    }

    func test_off_deleteAll_withoutADatabase_doesNothingAndCreatesNothing() async throws {
        setEnabled(false)
        let ledger = makeLedger()

        try await ledger.deleteAll()

        let published = await publishLog.entries
        XCTAssertEqual(published, [])
        XCTAssertFalse(exists(tempPath + "/store"))
        assertDiagnostics([])
    }

    func test_off_report_withAnExistingDatabase_readsItWithoutCallingTheSeam() async throws {
        // The transcript on disk holds more than the store does; a
        // reconcile would be visible as a seam call.
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath(sessionA))
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA), records: [record("msg_m1")])])
        setEnabled(false)
        let ledger = makeLedger()

        let rows = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)

        let count = await ingestCount()
        XCTAssertEqual(rows, [totalRow(1)])
        XCTAssertEqual(count, 0)
        assertDiagnostics([])
    }

    func test_off_deleteAll_withAnExistingDatabase_emptiesIt() async throws {
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA), records: [record("msg_m1")])])
        setEnabled(false)
        let ledger = makeLedger()

        try await ledger.deleteAll()

        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
        await ledger.close()
        let store = try openStoreDirectly()
        let sessions = try await store.sessions()
        let records = try await store.records(forSession: sessionA)
        XCTAssertEqual(sessions, [])
        XCTAssertEqual(records, [])
    }

    func test_afterClose_theNextIngestOpensTheStoreAgain() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        await script.setOutcome(stores([record("msg_m2")]), forCall: 2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        await ledger.close()
        // The scripted ingest writes through the store it is handed: a
        // closed store would throw and surface as `.ingestFailed`.
        await noteAndSettle(ledger, "Stop")

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 2)
        assertDiagnostics([])
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(1)), Published(sessionID: sessionA, row: totalRow(2)),
        ])
    }

    func test_afterClose_reportOpensTheStoreAgain() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        await ledger.close()
        setEnabled(false)

        let rows = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)

        XCTAssertEqual(rows, [totalRow(1)])
    }

    func test_close_waitsForARunningIngest() async throws {
        try makeMainFile()
        await script.gate(1)
        let ledger = makeLedger()
        await ledger.note(activity("Stop"))
        await script.waitForStart(1)

        let script = self.script!
        let closing = Task {
            await ledger.close()
            await script.log("closed")
        }
        await script.release(1)
        await closing.value

        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "closed"])
        assertDiagnostics([])
    }

    // MARK: - Note locates every time and never remembers a rejection

    func test_note_pathThatIsNotTheSessionsMainTranscript_isDroppedSilently() async throws {
        try makeMainFile()
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath(sessionA, "a1"))
        try write([userLine], to: tempPath + "/elsewhere/" + sessionA + ".jsonl")
        let ledger = makeLedger()

        // Empty (remote-served sessions), relative, outside the root, a
        // subagent transcript, another session's id, a missing file.
        await ledger.note(activity("Stop", path: ""))
        await ledger.note(activity("Stop", path: "projects/-Users-someone-repo/" + sessionA + ".jsonl"))
        await ledger.note(activity("Stop", path: tempPath + "/elsewhere/" + sessionA + ".jsonl"))
        await ledger.note(activity("Stop", path: subagentPath(sessionA, "a1")))
        await ledger.note(activity("Stop", sessionB, path: mainPath(sessionA)))
        await ledger.note(activity("Stop", sessionB))
        await ledger.waitUntilIdle()

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0)
        XCTAssertEqual(published, [])
        assertDiagnostics([])
    }

    func test_note_sessionIDThatIsNotAValidLabel_isDroppedSilently_evenWhenItsFileExists() async throws {
        // The session id becomes the publish key and a stored value, so
        // it must pass the same label rule as every other stored string.
        let hidden = "abc\u{202E}def"
        try makeMainFile(hidden)
        XCTAssertTrue(exists(mainPath(hidden)), "Fixture error: the transcript must exist under that name")
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop", hidden)

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0)
        XCTAssertEqual(published, [])
        assertDiagnostics([])
    }

    func test_note_rejectionIsNotCached_theFileCreatedLaterIsIngestedByTheNextNote() async throws {
        let ledger = makeLedger()
        // SessionStart fires before Claude Code writes the transcript.
        await noteAndSettle(ledger, "SessionStart")
        let before = await ingestCount()
        XCTAssertEqual(before, 0)

        try makeMainFile()
        await noteAndSettle(ledger, "PreToolUse")

        let started = await script.started
        XCTAssertEqual(started, [location(sessionA)])
        assertDiagnostics([])
    }

    // MARK: - What starts an ingest

    func test_note_firstEventForATranscript_ingestsWhateverTheEventIs_withTheLocatedLocation() async throws {
        try makeMainFile()
        let ledger = makeLedger()

        await noteAndSettle(ledger, "SessionStart")

        let started = await script.started
        XCTAssertEqual(started, [location(sessionA)])
    }

    func test_note_nonTriggerEventAfterASuccessfulIngest_doesNotIngest() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "SessionStart")

        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                      "SubagentStart", "stop", "Stop ", ""] {
            await noteAndSettle(ledger, event)
        }

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 1)
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: nil)])
    }

    func test_note_everyTriggerEventAfterASuccessfulIngest_ingestsAgain() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "SessionStart")

        await noteAndSettle(ledger, "Stop")
        let afterStop = await ingestCount()
        await noteAndSettle(ledger, "SubagentStop")
        let afterSubagentStop = await ingestCount()
        await noteAndSettle(ledger, "SessionEnd")
        let afterSessionEnd = await ingestCount()

        XCTAssertEqual([afterStop, afterSubagentStop, afterSessionEnd], [2, 3, 4])
    }

    func test_note_ingestedIsKeyedByTheLocatedMainPath_notByTheHooksOwnString() async throws {
        try makeMainFile()
        // A second spelling of the same projects root.
        let linkedRoot = tempPath + "/linked-projects"
        try FileManager.default.createSymbolicLink(atPath: linkedRoot, withDestinationPath: root)
        let aliased = linkedRoot + "/-Users-someone-repo/" + sessionA + ".jsonl"
        XCTAssertEqual(
            ClaudeTranscriptLocator.locate(transcriptPath: aliased, sessionID: sessionA, root: root),
            location(sessionA), "Fixture error: the aliased spelling must locate the same transcript")
        let ledger = makeLedger()

        await ledger.note(activity("SessionStart", path: aliased))
        await ledger.waitUntilIdle()
        // Same transcript under its canonical spelling, non-trigger event.
        await noteAndSettle(ledger, "PreToolUse")

        let started = await script.started
        XCTAssertEqual(started, [location(sessionA)])
    }

    // MARK: - Single flight per transcript

    func test_note_returnsWithoutWaitingForTheIngest() async throws {
        try makeMainFile()
        await script.gate(1)
        let ledger = makeLedger()
        let noted = expectation(description: "note returned")

        let stop = activity("Stop")
        let noting = Task {
            await ledger.note(stop)
            noted.fulfill()
        }
        // The ingest is held at its gate for as long as this waits.
        await fulfillment(of: [noted], timeout: 30)
        await script.waitForStart(1)
        let finishedWhileHeld = await script.finished

        await script.release(1)
        await noting.value
        await ledger.waitUntilIdle()
        XCTAssertEqual(finishedWhileHeld, 0)
        let finished = await script.finished
        XCTAssertEqual(finished, 1)
    }

    func test_fiveTriggersDuringOneRunningIngest_costExactlyOneMoreIngest() async throws {
        try makeMainFile()
        await script.gate(1)
        let ledger = makeLedger()
        await ledger.note(activity("Stop"))
        await script.waitForStart(1)

        for event in ["Stop", "SubagentStop", "SessionEnd", "Stop", "Stop"] {
            await ledger.note(activity(event))
        }
        let startedWhileRunning = await ingestCount()
        await script.release(1)
        await ledger.waitUntilIdle()

        let events = await script.events
        let published = await publishLog.entries
        XCTAssertEqual(startedWhileRunning, 1, "The re-run must not start while the first ingest runs")
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2"])
        XCTAssertEqual(published.count, 2)
        assertDiagnostics([])
    }

    func test_oneTriggerDuringARunningIngest_isNotLost() async throws {
        // The transcript may lag the turn: a Stop arriving while an older
        // ingest runs must still cause a read after that ingest ends.
        try makeMainFile()
        await script.gate(1)
        let ledger = makeLedger()
        await ledger.note(activity("SessionStart"))
        await script.waitForStart(1)

        await ledger.note(activity("Stop"))
        await script.release(1)
        await ledger.waitUntilIdle()

        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2"])
    }

    func test_reRunFlagIsConsumed_aLaterTriggerCostsOneIngestAgain() async throws {
        try makeMainFile()
        await script.gate(1)
        let ledger = makeLedger()
        await ledger.note(activity("Stop"))
        await script.waitForStart(1)
        await ledger.note(activity("Stop"))
        await ledger.note(activity("Stop"))
        await script.release(1)
        await ledger.waitUntilIdle()
        let afterBurst = await ingestCount()

        await noteAndSettle(ledger, "PreToolUse")
        let afterNonTrigger = await ingestCount()
        await noteAndSettle(ledger, "Stop")
        let afterTrigger = await ingestCount()

        XCTAssertEqual([afterBurst, afterNonTrigger, afterTrigger], [2, 2, 3])
    }

    func test_triggersForAnotherTranscript_doNotMarkARerunOfTheRunningOne() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        await script.gate(1)
        let ledger = makeLedger()
        await ledger.note(activity("Stop", sessionA))
        await script.waitForStart(1)

        for _ in 0..<3 {
            await ledger.note(activity("Stop", sessionB))
        }
        await script.release(1)
        await ledger.waitUntilIdle()

        let countA = await script.count(forSession: sessionA)
        let countB = await script.count(forSession: sessionB)
        let maxPerPath = await script.maxConcurrentPerPath
        XCTAssertEqual(countA, 1, "Session B's triggers must not re-run session A")
        // B's first note starts (or queues) its ingest; whether the other
        // two met it running is the implementation's scheduling choice.
        XCTAssertTrue((1...2).contains(countB), "Got \(countB)")
        XCTAssertEqual(maxPerPath, 1)
    }

    // MARK: - What counts as success

    func test_missingMainTranscript_isNotMarkedNotPublishedNotReported_andIsRetriedByANonTriggerEvent()
        async throws {
        try makeMainFile()
        await script.setOutcome(.main(.missing), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "SessionStart")
        let publishedAfterMissing = await publishLog.entries
        let diagnosticsAfterMissing = diagnosticLog.all
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(publishedAfterMissing, [])
        XCTAssertEqual(diagnosticsAfterMissing, [])
        XCTAssertEqual(count, 2, "A transcript whose ingest found nothing is not marked ingested")
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: nil)])
        assertDiagnostics([])
    }

    func test_mainTranscriptNotARegularFile_isReportedNotPublished_andRetriedByANonTriggerEvent() async throws {
        try makeMainFile()
        await script.setOutcome(.main(.notARegularFile), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        let publishedAfterFailure = await publishLog.entries
        XCTAssertEqual(publishedAfterFailure, [])
        assertDiagnostics([.mainTranscriptUnusable(sessionID: sessionA, status: .notARegularFile)])

        await noteAndSettle(ledger, "PreToolUse")
        let count = await ingestCount()
        XCTAssertEqual(count, 2)
    }

    func test_mainTranscriptRedirected_isReportedNotPublished_andRetriedByANonTriggerEvent() async throws {
        try makeMainFile()
        await script.setOutcome(.main(.redirected), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        let publishedAfterFailure = await publishLog.entries
        XCTAssertEqual(publishedAfterFailure, [])
        assertDiagnostics([.mainTranscriptUnusable(sessionID: sessionA, status: .redirected)])

        await noteAndSettle(ledger, "PreToolUse")
        let count = await ingestCount()
        XCTAssertEqual(count, 2)
    }

    func test_thrownIngest_isReportedNotPublishedNotRetriedOnItsOwn_andRetriedByTheNextNonTriggerEvent()
        async throws {
        try makeMainFile()
        await script.setOutcome(.fails, forCall: 1)
        await script.setOutcome(stores([record("msg_m1")]), forCall: 2)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        let countAfterFailure = await ingestCount()
        let publishedAfterFailure = await publishLog.entries
        let diagnostics = diagnosticLog.all
        XCTAssertEqual(countAfterFailure, 1, "Nothing retries on its own")
        XCTAssertEqual(publishedAfterFailure, [])
        XCTAssertEqual(diagnostics.count, 1)
        guard case .ingestFailed(let failedSession, let failure)? = diagnostics.first else {
            return XCTFail("Expected .ingestFailed, got \(diagnostics)")
        }
        XCTAssertEqual(failedSession, sessionA)
        XCTAssertEqual(failure.description, "InjectedIngestFailure()")
        // A Swift error without a domain of its own carries whatever it
        // bridges to.
        XCTAssertEqual(failure, UsageLedgerDiagnostic.Failure(InjectedIngestFailure()))

        await noteAndSettle(ledger, "PreToolUse")
        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 2, "A failed transcript is not marked ingested")
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
        XCTAssertEqual(diagnosticLog.all.count, 1)
    }

    func test_mainTranscriptFailedWithAnErrno_isReportedAsIngestFailed_notPublished_andRetried() async throws {
        // An I/O failure of the main file: the real ingestor throws for
        // it, so a result carrying it is reported the same way.
        try makeMainFile()
        await script.setOutcome(.main(.failed(errno: ENOSPC)), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        let publishedAfterFailure = await publishLog.entries
        let diagnostics = diagnosticLog.all
        XCTAssertEqual(publishedAfterFailure, [])
        XCTAssertEqual(diagnostics.count, 1)
        guard case .ingestFailed(let failedSession, let failure)? = diagnostics.first else {
            return XCTFail("Expected .ingestFailed, got \(diagnostics)")
        }
        XCTAssertEqual(failedSession, sessionA)
        // The errno stays readable next to a text that may name a path.
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.code, Int(ENOSPC))
        XCTAssertEqual(
            failure.description, String(describing: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))

        await noteAndSettle(ledger, "PreToolUse")
        let count = await ingestCount()
        XCTAssertEqual(count, 2, "A failed transcript is not marked ingested")
    }

    func test_storeFailureDuringAnIngest_isReportedWithSQLitesDomainAndResultCode() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        await script.setOutcome(stores([record("msg_m2")]), forCall: 2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        assertDiagnostics([])

        // Another connection holds the database's write lock, so the
        // second ingest's write fails at once (there is no busy timeout).
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
                       "Fixture error: could not open the lock holder")
        defer {
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
            sqlite3_close(holder)
        }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK,
                       "Fixture error: could not take the write lock")

        await noteAndSettle(ledger, "Stop")

        let diagnostics = diagnosticLog.all
        XCTAssertEqual(diagnostics.count, 1)
        guard case .ingestFailed(let failedSession, let failure)? = diagnostics.first else {
            return XCTFail("Expected .ingestFailed, got \(diagnostics)")
        }
        XCTAssertEqual(failedSession, sessionA)
        XCTAssertEqual(failure.domain, "SQLite")
        XCTAssertEqual(failure.code, Int(SQLITE_BUSY))
        XCTAssertEqual(
            failure.description, String(describing: SQLiteError(code: SQLITE_BUSY, message: "database is locked")))
        let published = await publishLog.entries
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
    }

    /// What opening a store in `directory` fails with, as a diagnostic's
    /// failure. The directory must be one that cannot be opened.
    private func storeOpenFailure(_ directory: String) async throws -> UsageLedgerDiagnostic.Failure {
        do {
            let store = try UsageStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
            await store.close()
        } catch {
            return UsageLedgerDiagnostic.Failure(error)
        }
        XCTFail("Fixture error: \(directory) could be opened")
        throw InjectedIngestFailure()
    }

    func test_resultWithoutAMainEntry_isNotMarkedAndNotPublished() async throws {
        try makeMainFile()
        await script.setOutcome(.noFiles, forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        let publishedAfterEmpty = await publishLog.entries
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        XCTAssertEqual(publishedAfterEmpty, [])
        XCTAssertEqual(count, 2)
    }

    // MARK: - Partial results are reported

    func test_subagentEntriesNotRead_areEachReported_andTheTranscriptIsStillMarkedAndPublished() async throws {
        try makeMainFile()
        let directory = projectDirectory + "/" + sessionA + "/subagents/"
        await script.setOutcome(
            .read(
                records: [record("msg_m1")],
                subagents: [
                    subagentEntry(directory + "agent-a1.jsonl", .failed(errno: EACCES)),
                    subagentEntry(directory + "agent-b2.jsonl", .read),
                    subagentEntry(directory + "agent-c3.jsonl", .missing),
                    subagentEntry(directory + "agent-d4.jsonl", .notARegularFile),
                    subagentEntry(directory + "agent-e5.jsonl", .redirected),
                ],
                rootFailed: false),
            forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        let published = await publishLog.entries
        assertDiagnostics([
            .subagentFileNotRead(path: directory + "agent-a1.jsonl", status: .failed(errno: EACCES)),
            .subagentFileNotRead(path: directory + "agent-c3.jsonl", status: .missing),
            .subagentFileNotRead(path: directory + "agent-d4.jsonl", status: .notARegularFile),
            .subagentFileNotRead(path: directory + "agent-e5.jsonl", status: .redirected),
        ])
        XCTAssertEqual(count, 1, "The transcript is marked ingested despite the partial result")
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
    }

    func test_projectRootResolutionFailure_isReported_andTheTranscriptIsStillMarkedAndPublished() async throws {
        try makeMainFile()
        await script.setOutcome(.read(records: [record("msg_m1")], subagents: [], rootFailed: true), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        let published = await publishLog.entries
        assertDiagnostics([.projectRootResolutionFailed(sessionID: sessionA)])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
    }

    func test_partialResultOfAnUnsuccessfulIngest_isNotReportedAsSubagentOrRootDiagnostics() async throws {
        // Only a SUCCESSFUL ingest reports its partial results.
        try makeMainFile()
        await script.setOutcome(.main(.missing), forCall: 1)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")

        assertDiagnostics([])
    }

    // MARK: - Publish

    func test_publish_afterEverySuccessfulIngest_carriesTheSessionsStoredTotal() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        await script.setOutcome(stores([record("msg_a1")]), forCall: 1)
        await script.setOutcome(stores([record("msg_b1", sessionID: sessionB)]), forCall: 2)
        await script.setOutcome(stores([record("msg_a2"), record("msg_a3")]), forCall: 3)
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop", sessionA)
        await noteAndSettle(ledger, "Stop", sessionB)
        await noteAndSettle(ledger, "Stop", sessionA)

        let published = await publishLog.entries
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(1)),
            Published(sessionID: sessionB, row: totalRow(1)),
            Published(sessionID: sessionA, row: totalRow(3)),
        ])
        // The published value IS the stored total of that session.
        let stored = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)
        XCTAssertEqual(stored, [totalRow(3)])
    }

    func test_publish_sessionWithoutAnyRecord_publishesNil() async throws {
        try makeMainFile()
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop")

        let published = await publishLog.entries
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: nil)])
    }

    // MARK: - End to end with the real ingestor

    func test_realIngestor_mainAndSubagentFile_publishedRowEqualsTheStoredTotal() async throws {
        await script.setDefault(.real)
        try write([userLine, assistantLine("msg_m1")], to: mainPath(sessionA))
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath(sessionA, "a1"))
        try write([assistantLine("msg_b1", sessionID: sessionB)], to: mainPath(sessionB))
        let ledger = makeLedger()

        await noteAndSettle(ledger, "Stop", sessionA)
        await noteAndSettle(ledger, "Stop", sessionB)

        let published = await publishLog.entries
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(2)),
            Published(sessionID: sessionB, row: totalRow(1)),
        ])
        assertDiagnostics([])
        let storedTotal = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)
        let byThread = try await ledger.report(UsageQuery(groupBy: [.thread], sessionID: sessionA), calendar: utc)
        XCTAssertEqual(storedTotal, [totalRow(2)])
        XCTAssertEqual(byThread, [totalRow(1, key: ["main"]), totalRow(1, key: ["subagent"])])
    }

    func test_realIngestor_stopAfterMoreLines_publishesTheGrownTotal() async throws {
        await script.setDefault(.real)
        try write([assistantLine("msg_m1")], to: mainPath(sessionA))
        let ledger = makeLedger()
        await noteAndSettle(ledger, "SessionStart")

        try append(assistantLine("msg_m2") + "\n", to: mainPath(sessionA))
        await noteAndSettle(ledger, "PostToolUse")
        let afterNonTrigger = await publishLog.entries
        await noteAndSettle(ledger, "Stop")

        let published = await publishLog.entries
        XCTAssertEqual(afterNonTrigger, [Published(sessionID: sessionA, row: totalRow(1))])
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(1)), Published(sessionID: sessionA, row: totalRow(2)),
        ])
    }

    // MARK: - ReconcileKnown

    func test_reconcileKnown_picksUpAppendedLinesWithoutAnyNote() async throws {
        await script.setDefault(.real)
        try write([assistantLine("msg_m1")], to: mainPath(sessionA))
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        try append(assistantLine("msg_m2") + "\n", to: mainPath(sessionA))
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath(sessionA, "a1"))
        await ledger.reconcileKnown()

        // No waitUntilIdle: reconcileKnown waits for the ingests it starts.
        let finished = await script.finished
        let published = await publishLog.entries
        XCTAssertEqual(finished, 2)
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(1)), Published(sessionID: sessionA, row: totalRow(3)),
        ])
        assertDiagnostics([])
    }

    func test_reconcileKnown_sessionsStoredByAnEarlierProcess_areIngestedWithoutAnyNote() async throws {
        await script.setDefault(.real)
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath(sessionA))
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA))])
        let ledger = makeLedger()

        await ledger.reconcileKnown()

        let started = await script.started
        let published = await publishLog.entries
        XCTAssertEqual(started, [location(sessionA)])
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(2))])
    }

    func test_reconcileKnown_ingestsEveryKnownSession_oneAfterAnother() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop", sessionA)
        await noteAndSettle(ledger, "Stop", sessionB)
        await script.resetStatistics()

        await ledger.reconcileKnown()

        let started = await script.started
        let finished = await script.finished
        let maxConcurrent = await script.maxConcurrent
        XCTAssertEqual(started.count, 4)
        XCTAssertEqual(Set(started.suffix(2).map(\.sessionID)), [sessionA, sessionB])
        XCTAssertEqual(finished, 4, "reconcileKnown must wait for every ingest it starts")
        XCTAssertEqual(maxConcurrent, 1, "Sessions are reconciled one after another")
    }

    func test_reconcileKnown_skipsSessionsThatCannotBeLocated_silently() async throws {
        // A: no transcript path stored. B: the stored file is gone.
        // C: the stored path is outside the projects root.
        let outside = tempPath + "/elsewhere/" + sessionC + ".jsonl"
        try write([userLine], to: outside)
        try await seedStore([
            sessionBatch(sessionA, transcriptPath: nil),
            sessionBatch(sessionB, transcriptPath: mainPath(sessionB)),
            sessionBatch(sessionC, transcriptPath: outside),
        ])
        let ledger = makeLedger()

        await ledger.reconcileKnown()

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0)
        XCTAssertEqual(published, [])
        assertDiagnostics([])
    }

    func test_reconcileKnown_aFailedSessionIsReported_andTheOthersAreStillIngested() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        try await seedStore([
            sessionBatch(sessionA, transcriptPath: mainPath(sessionA)),
            sessionBatch(sessionB, transcriptPath: mainPath(sessionB)),
        ])
        await script.setOutcome(.fails, forCall: 1)
        let ledger = makeLedger()

        await ledger.reconcileKnown()

        let started = await script.started
        let published = await publishLog.entries
        XCTAssertEqual(Set(started.map(\.sessionID)), [sessionA, sessionB])
        XCTAssertEqual(started.count, 2)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(diagnosticLog.all.count, 1)
        guard case .ingestFailed(let failedSession, _)? = diagnosticLog.all.first else {
            return XCTFail("Expected .ingestFailed, got \(diagnosticLog.all)")
        }
        XCTAssertEqual(failedSession, started.first?.sessionID)
        XCTAssertEqual(published.first?.sessionID, started.last?.sessionID)
    }

    func test_reconcileKnown_storeCannotBeOpened_reportsStoreUnavailableAndDoesNotThrow() async throws {
        // The store directory sits beneath a regular file, so it can
        // never be created.
        let blocker = tempPath + "/blocker"
        try Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        let ledger = makeLedger(storeDirectory: blocker + "/usage")

        await ledger.reconcileKnown()

        let count = await ingestCount()
        XCTAssertEqual(count, 0)
        XCTAssertEqual(diagnosticLog.all.count, 1)
        guard case .storeUnavailable(let failure)? = diagnosticLog.all.first else {
            return XCTFail("Expected .storeUnavailable, got \(diagnosticLog.all)")
        }
        // The domain and code of what opening that directory fails with.
        // The text is not compared whole: Foundation prints an address in
        // it that differs from one failure to the next.
        let expected = try await storeOpenFailure(blocker + "/usage")
        XCTAssertEqual(failure.domain, expected.domain)
        XCTAssertEqual(failure.code, expected.code)
        XCTAssertTrue(failure.description.contains(blocker), failure.description)
    }

    func test_note_storeCannotBeOpened_reportsStoreUnavailableOnce_andNothingIsPublished() async throws {
        try makeMainFile()
        let blocker = tempPath + "/blocker"
        try Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        let ledger = makeLedger(storeDirectory: blocker + "/usage")

        await noteAndSettle(ledger, "Stop")

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(count, 0, "There is no store to hand to the seam")
        XCTAssertEqual(published, [])
        XCTAssertEqual(diagnosticLog.all.count, 1)
        guard case .storeUnavailable(let failure)? = diagnosticLog.all.first else {
            return XCTFail("Expected .storeUnavailable, got \(diagnosticLog.all)")
        }
        // The domain and code of what opening that directory fails with.
        // The text is not compared whole: Foundation prints an address in
        // it that differs from one failure to the next.
        let expected = try await storeOpenFailure(blocker + "/usage")
        XCTAssertEqual(failure.domain, expected.domain)
        XCTAssertEqual(failure.code, expected.code)
        XCTAssertTrue(failure.description.contains(blocker), failure.description)
    }

    func test_reconcileKnown_cancellingItsCaller_doesNotCancelTheIngest() async throws {
        try makeMainFile()
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA))])
        await script.gate(1)
        let seenCancelled = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await script.setHook(forCall: 1) { seenCancelled.withLock { $0 = Task.isCancelled } }
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()

        let caller = Task { await ledger.reconcileKnown() }
        await script.waitForStart(1)
        caller.cancel()
        await script.release(1)
        await caller.value
        await ledger.waitUntilIdle()
        // Marked: a non-trigger note does not ingest again.
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        let published = await publishLog.entries
        XCTAssertEqual(seenCancelled.withLock { $0 }, false, "The ingest must not run in its caller's task")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
        assertDiagnostics([])
    }

    func test_report_cancellingItsCaller_doesNotCancelTheIngest() async throws {
        try makeMainFile()
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA))])
        await script.gate(1)
        let seenCancelled = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await script.setHook(forCall: 1) { seenCancelled.withLock { $0 = Task.isCancelled } }
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        let calendar = utc

        let caller = Task { _ = try? await ledger.report(UsageQuery(), calendar: calendar) }
        await script.waitForStart(1)
        caller.cancel()
        await script.release(1)
        await caller.value
        await ledger.waitUntilIdle()

        let published = await publishLog.entries
        XCTAssertEqual(seenCancelled.withLock { $0 }, false, "The ingest must not run in its caller's task")
        XCTAssertEqual(published, [Published(sessionID: sessionA, row: totalRow(1))])
        assertDiagnostics([])
    }

    func test_reconcileKnown_whileThatTranscriptIsBeingIngested_goesThroughTheSameSingleFlight() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        await script.gate(2)
        await ledger.note(activity("Stop"))
        await script.waitForStart(2)

        let reconciling = Task { await ledger.reconcileKnown() }
        await script.release(2)
        await reconciling.value
        await ledger.waitUntilIdle()

        // Whether the reconcile met call 2 running (one re-run) or came
        // after it (its own ingest), the total is three, never overlapping.
        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3"])
    }

    // MARK: - Report

    func test_on_report_reconcilesFirst_soAppendedLinesAreInTheResult() async throws {
        await script.setDefault(.real)
        try write([assistantLine("msg_m1")], to: mainPath(sessionA))
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        try append(assistantLine("msg_m2") + "\n", to: mainPath(sessionA))

        let rows = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)

        XCTAssertEqual(rows, [totalRow(2)])
    }

    func test_on_report_aFailedReconcileDoesNotFailTheReport() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        await script.setOutcome(.fails, forCall: 2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        let rows = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)

        let count = await ingestCount()
        XCTAssertEqual(rows, [totalRow(1)])
        XCTAssertEqual(count, 2, "Fixture error: the report must have reconciled")
        XCTAssertEqual(diagnosticLog.all.count, 1)
        guard case .ingestFailed(let failedSession, _)? = diagnosticLog.all.first else {
            return XCTFail("Expected .ingestFailed, got \(diagnosticLog.all)")
        }
        XCTAssertEqual(failedSession, sessionA)
    }

    func test_report_passesTheQueryAndTheCalendarToTheStore() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        await script.setOutcome(stores([record("msg_a1"), record("msg_a2")]), forCall: 1)
        await script.setOutcome(stores([record("msg_b1", sessionID: sessionB)]), forCall: 2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop", sessionA)
        await noteAndSettle(ledger, "Stop", sessionB)
        setEnabled(false)
        // 2026-10-02T10:27:29Z is already 2026-10-03 at UTC+14.
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))

        let bySession = try await ledger.report(UsageQuery(groupBy: [.session]), calendar: utc)
        let byDayUTC = try await ledger.report(UsageQuery(groupBy: [.day]), calendar: utc)
        let byDayEast = try await ledger.report(UsageQuery(groupBy: [.day]), calendar: kiritimati)

        XCTAssertEqual(bySession, [totalRow(2, key: [sessionA]), totalRow(1, key: [sessionB])])
        XCTAssertEqual(byDayUTC, [totalRow(3, key: ["2026-10-02"])])
        XCTAssertEqual(byDayEast, [totalRow(3, key: ["2026-10-03"])])
    }

    func test_report_storeErrorOfTheReadItself_isThrown() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        let invalid = UsageQuery(groupBy: [.model, .model])

        for isOn in [true, false] {
            setEnabled(isOn)
            do {
                _ = try await ledger.report(invalid, calendar: utc)
                XCTFail("Expected invalidQuery (enabled: \(isOn))")
            } catch {
                XCTAssertEqual(error as? UsageStoreError, .invalidQuery, "enabled: \(isOn), got \(error)")
            }
        }
    }

    // MARK: - Reports (several queries, one reconcile)

    // A caller that needs several aggregates pays for one reconcile, not
    // one per aggregate: each reconcile reads every stored session once,
    // which is visible as one call of the ingest seam.
    func test_on_reports_reconcilesOncePerCall_notOncePerQuery() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        let before = await ingestCount()
        XCTAssertEqual(before, 1, "Fixture error")

        let results = try await ledger.reports(
            [UsageQuery(sessionID: sessionA), UsageQuery(groupBy: [.session]), UsageQuery(thread: .advisor)],
            calendar: utc)

        let after = await ingestCount()
        XCTAssertEqual(after, 2, "one reconcile for the whole call")
        XCTAssertEqual(results, [[totalRow(1)], [totalRow(1, key: [sessionA])], []])
    }

    // The reconcile happens before the read, so what the transcripts
    // gained since the last ingest is in every answer of the call.
    func test_on_reports_reconcilesFirst_soEveryAnswerHasTheAppendedLines() async throws {
        await script.setDefault(.real)
        try write([assistantLine("msg_m1")], to: mainPath(sessionA))
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        try append(assistantLine("msg_m2") + "\n", to: mainPath(sessionA))

        let results = try await ledger.reports([UsageQuery(), UsageQuery(groupBy: [.model])], calendar: utc)

        XCTAssertEqual(results, [[totalRow(2)], [totalRow(2, key: ["claude-opus-5-5"])]])
    }

    // An empty list follows the same rules: it still reconciles once.
    func test_on_reports_emptyList_returnsEmpty_andStillReconcilesOnce() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        let results = try await ledger.reports([], calendar: utc)

        let count = await ingestCount()
        XCTAssertEqual(results, [])
        XCTAssertEqual(count, 2)
    }

    func test_off_reports_withAnExistingDatabase_readsItWithoutCallingTheSeam() async throws {
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath(sessionA))
        try await seedStore([sessionBatch(sessionA, transcriptPath: mainPath(sessionA), records: [record("msg_m1")])])
        setEnabled(false)
        let ledger = makeLedger()

        let results = try await ledger.reports(
            [UsageQuery(sessionID: sessionA), UsageQuery(groupBy: [.session])], calendar: utc)

        let count = await ingestCount()
        XCTAssertEqual(results, [[totalRow(1)], [totalRow(1, key: [sessionA])]])
        XCTAssertEqual(count, 0)
        assertDiagnostics([])
    }

    func test_off_reports_withoutADatabase_returnsNoRowsPerQueryAndCreatesNothing() async throws {
        setEnabled(false)
        let ledger = makeLedger()

        let two = try await ledger.reports([UsageQuery(), UsageQuery(groupBy: [.model])], calendar: utc)
        let none = try await ledger.reports([], calendar: utc)

        XCTAssertEqual(two, [[], []])
        XCTAssertEqual(none, [])
        XCTAssertFalse(exists(tempPath + "/store"))
        let count = await ingestCount()
        XCTAssertEqual(count, 0)
        assertDiagnostics([])
    }

    func test_reports_aQueryThatThrows_failsTheWholeCall() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        for isOn in [true, false] {
            setEnabled(isOn)
            do {
                _ = try await ledger.reports(
                    [UsageQuery(), UsageQuery(groupBy: [.model, .model])], calendar: utc)
                XCTFail("Expected invalidQuery (enabled: \(isOn))")
            } catch {
                XCTAssertEqual(error as? UsageStoreError, .invalidQuery, "enabled: \(isOn), got \(error)")
            }
        }
    }

    // `report` keeps its behaviour: one reconcile, then the one answer.
    func test_on_report_reconcilesOnce_andAnswersLikeReportsWithOneQuery() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1"), record("msg_m2")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        let single = try await ledger.report(UsageQuery(groupBy: [.session]), calendar: utc)
        let afterReport = await ingestCount()
        let listed = try await ledger.reports([UsageQuery(groupBy: [.session])], calendar: utc)
        let afterReports = await ingestCount()

        XCTAssertEqual(single, [totalRow(2, key: [sessionA])])
        XCTAssertEqual(listed, [single])
        XCTAssertEqual(afterReport, 2)
        XCTAssertEqual(afterReports, 3)
    }

    // MARK: - isTracking

    /// Compiles only while `isTracking` is readable without awaiting the
    /// actor (it is nonisolated).
    private func readTrackingSynchronously(_ ledger: UsageLedger) -> Bool {
        ledger.isTracking
    }

    func test_isTracking_isReadFromTheClosureAtEveryAccess() async throws {
        let answer = OSAllocatedUnfairLock(initialState: false)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let ledger = UsageLedger(
            isEnabled: {
                reads.withLock { $0 += 1 }
                return answer.withLock { $0 }
            },
            projectsRoot: { "/nonexistent" },
            storeDirectory: URL(fileURLWithPath: storePath, isDirectory: true),
            ingest: { _, _ in throw InjectedIngestFailure() },
            publish: { _, _ in },
            onDiagnostic: { _ in })
        ledgers.append(ledger)
        XCTAssertEqual(reads.withLock { $0 }, 0, "Fixture error: init must not read the setting")

        let first = readTrackingSynchronously(ledger)
        answer.withLock { $0 = true }
        let second = readTrackingSynchronously(ledger)
        let third = ledger.isTracking
        answer.withLock { $0 = false }
        let fourth = ledger.isTracking

        XCTAssertEqual([first, second, third, fourth], [false, true, true, false])
        XCTAssertEqual(reads.withLock { $0 }, 4, "one read of the closure per access")
    }

    // MARK: - DeleteAll

    /// Returns once `deleteAll` has begun in some other task.
    ///
    /// Bounded, so a ledger that never reports the deletion fails the
    /// calling test instead of hanging the suite: after `maxPolls` reads
    /// the helper records a failure and returns, and the test runs on to
    /// its end and its teardown. Every poll suspends this task twice (the
    /// hop to the ledger and the yield), and the deleting task only has
    /// to be scheduled once and run its first statement, so a correct
    /// ledger is seen within a handful of polls. That is a matter of
    /// scheduling order, not of elapsed time, so load does not stretch
    /// it; 1,000,000 polls is far beyond it and still ends in seconds.
    private func waitUntilDeleting(
        _ ledger: UsageLedger, maxPolls: Int = 1_000_000, file: StaticString = #filePath, line: UInt = #line
    ) async {
        var polls = 0
        while !(await ledger.isDeleting) {
            guard polls < maxPolls else {
                XCTFail("deleteAll never began: isDeleting was still false after \(maxPolls) polls",
                        file: file, line: line)
                return
            }
            polls += 1
            await Task.yield()
        }
    }

    func test_isDeleting_isFalseBeforeAndAfterADelete() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        let before = await ledger.isDeleting
        await noteAndSettle(ledger, "Stop")

        try await ledger.deleteAll()

        let after = await ledger.isDeleting
        XCTAssertFalse(before)
        XCTAssertFalse(after)
    }

    func test_deleteAll_doesNotDeleteWhileAnIngestIsRunning_andLeavesTheStoreEmptyAfterwards() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        // The held ingest writes another record when it is released.
        await script.setOutcome(stores([record("msg_m2")]), forCall: 2)
        await script.gate(2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        // A second connection, to look at the store from outside.
        let observer = try openStoreDirectly()
        await ledger.note(activity("Stop"))
        await script.waitForStart(2)

        let script = self.script!
        let deleting = Task {
            try await ledger.deleteAll()
            await script.log("deleteAll returned")
        }
        await waitUntilDeleting(ledger)
        // The delete has begun and the ingest is held: for as long as
        // that lasts the records must stay. A correct ledger passes every
        // round whatever the scheduling; one that deletes without waiting
        // is given these rounds to do so.
        for round in 0..<50 {
            await Task.yield()
            let records = try await observer.records(forSession: sessionA)
            let stillDeleting = await ledger.isDeleting
            XCTAssertEqual(records, [record("msg_m1")], "round \(round)")
            XCTAssertTrue(stillDeleting, "deleteAll returned while the ingest was still running (round \(round))")
        }
        await script.release(2)
        try await deleting.value

        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2", "deleteAll returned"])
        let records = try await observer.records(forSession: sessionA)
        let sessions = try await observer.sessions()
        XCTAssertEqual(records, [], "An ingest must never write after the delete that overlapped it returned")
        XCTAssertEqual(sessions, [])
        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
    }

    func test_deleteAll_aReRunRequestedBeforeItBegan_isNotRun() async throws {
        try makeMainFile()
        await script.gate(2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        await ledger.note(activity("Stop"))
        await script.waitForStart(2)
        // Asks the running ingest for one re-run.
        await ledger.note(activity("Stop"))

        let deleting = Task { try await ledger.deleteAll() }
        await waitUntilDeleting(ledger)
        await script.release(2)
        try await deleting.value
        await ledger.waitUntilIdle()

        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2"], "The requested re-run must not run")
        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
    }

    func test_deleteAll_aReconcileArrivingWhileItRuns_returnsWithoutCallingTheSeam() async throws {
        // Session A is stored and idle. Session B's first ingest is held
        // before it stores anything, so the store knows only A and a
        // reconcile that got through would ingest A.
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        await script.gate(2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop", sessionA)
        await ledger.note(activity("Stop", sessionB))
        await script.waitForStart(2)

        let deleting = Task { try await ledger.deleteAll() }
        await waitUntilDeleting(ledger)
        await ledger.reconcileKnown()
        let countWhileDeleting = await ingestCount()
        await script.release(2)
        try await deleting.value
        await ledger.waitUntilIdle()

        let count = await ingestCount()
        XCTAssertEqual(countWhileDeleting, 2)
        XCTAssertEqual(count, 2)
        assertDiagnostics([])
    }

    func test_deleteAll_aNoteArrivingWhileItWaitsForAnIngest_isDropped() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        await script.gate(2)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop", sessionA)
        await ledger.note(activity("Stop", sessionB))
        await script.waitForStart(2)

        let deleting = Task { try await ledger.deleteAll() }
        await waitUntilDeleting(ledger)
        // A trigger for the idle transcript and one for the running one.
        await ledger.note(activity("Stop", sessionA))
        await ledger.note(activity("Stop", sessionB))
        await script.release(2)
        try await deleting.value
        await ledger.waitUntilIdle()

        let events = await script.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2"])
        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
    }

    func test_deleteAll_publishesNilForEverySessionItHadPublished_once() async throws {
        try makeMainFile(sessionA)
        try makeMainFile(sessionB)
        try makeMainFile(sessionC)
        await script.setOutcome(stores([record("msg_a1")]), forCall: 1)
        // B is published with a nil row (no record); C is never published.
        await script.setOutcome(.main(.missing), forCall: 3)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop", sessionA)
        await noteAndSettle(ledger, "Stop", sessionB)
        await noteAndSettle(ledger, "Stop", sessionC)
        let before = await publishLog.entries
        XCTAssertEqual(before, [
            Published(sessionID: sessionA, row: totalRow(1)), Published(sessionID: sessionB, row: nil),
        ], "Fixture error")

        try await ledger.deleteAll()
        let afterFirst = await publishLog.entries
        try await ledger.deleteAll()
        let afterSecond = await publishLog.entries

        let cleared = afterFirst.dropFirst(2).sorted { $0.sessionID < $1.sessionID }
        XCTAssertEqual(cleared, [Published(sessionID: sessionA, row: nil), Published(sessionID: sessionB, row: nil)])
        XCTAssertEqual(afterSecond.count, 4, "A second deleteAll has nothing left to clear")
        assertDiagnostics([])
    }

    func test_deleteAll_forgetsWhatWasIngested_theNextNonTriggerNoteIngestsAgain() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        await noteAndSettle(ledger, "PreToolUse")
        let before = await ingestCount()
        XCTAssertEqual(before, 1, "Fixture error: the non-trigger note must not ingest before the delete")

        try await ledger.deleteAll()
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        XCTAssertEqual(count, 2)
    }

    func test_deleteAll_emptiesTheStore_whateverTheSetting() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        setEnabled(false)

        try await ledger.deleteAll()

        let published = await publishLog.entries
        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(1)), Published(sessionID: sessionA, row: nil),
        ])
        await ledger.close()
        let store = try openStoreDirectly()
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [])
    }

    func test_deleteAll_aNoteArrivingBeforeItHasFinished_isDropped() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        // deleteAll's own publish(sessionID, nil) is a point that is
        // certainly inside deleteAll: a trigger note sent from there
        // arrives "meanwhile". The hook is installed after the first
        // ingest published, so only deleteAll's publish runs it.
        let trigger = activity("Stop")
        await publishLog.setHook { entry in
            if entry.row == nil {
                await ledger.note(trigger)
            }
        }

        try await ledger.deleteAll()
        await publishLog.clearHook()
        await ledger.waitUntilIdle()

        let count = await ingestCount()
        XCTAssertEqual(count, 1, "A note arriving during deleteAll must be dropped")
        let rows = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(rows, [])
    }

    func test_realIngestor_afterDeleteAll_theTranscriptIsReadAgainFromItsStart() async throws {
        // Checkpoints are deleted too, so the whole file counts again.
        await script.setDefault(.real)
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath(sessionA))
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")

        try await ledger.deleteAll()
        await noteAndSettle(ledger, "PreToolUse")

        let published = await publishLog.entries
        XCTAssertEqual(published, [
            Published(sessionID: sessionA, row: totalRow(2)),
            Published(sessionID: sessionA, row: nil),
            Published(sessionID: sessionA, row: totalRow(2)),
        ])
    }

    // MARK: - A failed deleteAll

    func test_deleteAll_thatThrows_keepsTheData_publishesNothing_andLeavesNoTranscriptIngested() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        await noteAndSettle(ledger, "PreToolUse")
        let countBefore = await ingestCount()
        XCTAssertEqual(countBefore, 1, "Fixture error: the transcript must count as ingested")

        // Another connection holds the database's write lock, so the
        // store's delete fails at once (there is no busy timeout).
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
                       "Fixture error: could not open the lock holder")
        var released = false
        func release() {
            guard !released else { return }
            released = true
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
            sqlite3_close(holder)
        }
        defer { release() }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK,
                       "Fixture error: could not take the write lock")

        do {
            try await ledger.deleteAll()
            XCTFail("deleteAll must throw while the database is locked")
        } catch {
            XCTAssertEqual((error as? SQLiteError)?.primaryCode, SQLITE_BUSY, "Got: \(error)")
        }
        release()
        let stillDeleting = await ledger.isDeleting
        XCTAssertFalse(stillDeleting)

        let publishedAfterFailure = await publishLog.entries
        XCTAssertEqual(publishedAfterFailure, [Published(sessionID: sessionA, row: totalRow(1))],
                       "A failed delete publishes nothing")
        await noteAndSettle(ledger, "PreToolUse")

        let count = await ingestCount()
        XCTAssertEqual(count, 2, "After a failed delete the next note of any event reads the transcript again")
        let rows = try await ledger.report(UsageQuery(sessionID: sessionA), calendar: utc)
        XCTAssertEqual(rows, [totalRow(1)], "The records are still stored")
    }

    // MARK: - close overlapping other work

    func test_close_overlappingReportAndNote_neverThrowsAndNeverReportsADiagnostic() async throws {
        try makeMainFile()
        await script.setOutcome(stores([record("msg_m1")]), forCall: 1)
        let ledger = makeLedger()
        await noteAndSettle(ledger, "Stop")
        let stop = activity("Stop")
        let query = UsageQuery(sessionID: sessionA)
        let calendar = utc

        var failures: [String] = []
        for round in 0..<200 {
            let thrown = await withTaskGroup(of: String?.self) { group in
                group.addTask { await ledger.close(); return nil }
                group.addTask {
                    do {
                        _ = try await ledger.report(query, calendar: calendar)
                        return nil
                    } catch {
                        return "report: \(error)"
                    }
                }
                group.addTask { await ledger.note(stop); return nil }
                group.addTask { await ledger.close(); return nil }
                group.addTask {
                    do {
                        _ = try await ledger.report(query, calendar: calendar)
                        return nil
                    } catch {
                        return "report: \(error)"
                    }
                }
                var thrown: [String] = []
                for await result in group {
                    if let result { thrown.append("round \(round) " + result) }
                }
                return thrown
            }
            failures += thrown
            await ledger.waitUntilIdle()
        }

        XCTAssertEqual(failures, [])
        assertDiagnostics([])
        let rows = try await ledger.report(query, calendar: calendar)
        XCTAssertEqual(rows, [totalRow(1)])
    }

    func test_close_twoConcurrentCalls_bothReturnOnlyAfterTheDatabaseIsClosed() async throws {
        try makeMainFile()
        let ledger = makeLedger()
        let directory = URL(fileURLWithPath: storePath, isDirectory: true)

        for round in 0..<200 {
            // Opens the store and writes, so the close has a WAL to fold.
            await script.setDefault(stores([record("msg_\(round)")]))
            await noteAndSettle(ledger, "Stop")

            // Whichever call returns first, the database must be closed
            // by then: while a connection is still closing, a second one
            // cannot open the database.
            let failure: String? = await withTaskGroup(of: Void.self) { group in
                group.addTask { await ledger.close() }
                group.addTask { await ledger.close() }
                await group.next()
                var failure: String?
                do {
                    let fresh = try UsageStore(directory: directory)
                    await fresh.close()
                } catch {
                    failure = "\(error)"
                }
                await group.waitForAll()
                return failure
            }
            if let failure {
                return XCTFail("round \(round): the database was not closed when a close() returned: \(failure)")
            }
        }
        assertDiagnostics([])
    }

    // MARK: - Timing

    func test_timing_secondReportOver200IngestedSessionsWith5SubagentFilesEach_finishesWithin5Seconds()
        async throws {
        await script.setDefault(.real)
        var sessions: [String] = []
        for index in 0..<200 {
            let sessionID = String(format: "00000000-0000-0000-0000-%012d", index)
            sessions.append(sessionID)
            try write([assistantLine("msg_\(index)_m", sessionID: sessionID)], to: mainPath(sessionID))
            for agent in 0..<5 {
                try write(
                    [assistantLine("msg_\(index)_s\(agent)", sessionID: sessionID, agentID: "a\(agent)")],
                    to: subagentPath(sessionID, "a\(agent)"))
            }
        }
        let ledger = makeLedger()
        for sessionID in sessions {
            await ledger.note(activity("Stop", sessionID))
        }
        await ledger.waitUntilIdle()
        // Everything is ingested; the first report reconciles once more.
        let first = try await ledger.report(UsageQuery(), calendar: utc)
        XCTAssertEqual(first, [totalRow(1_200)], "Fixture error: 200 sessions x 6 files x 1 record")
        let callsBefore = await ingestCount()

        let clock = ContinuousClock()
        var second: [UsageRow] = []
        let elapsed = try await clock.measure {
            second = try await ledger.report(UsageQuery(), calendar: utc)
        }

        let callsAfter = await ingestCount()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("USAGE-LEDGER-TIMING second report, 200 sessions x 5 subagent files, nothing new: "
            + String(format: "%.3f", seconds) + " s")
        XCTAssertEqual(second, [totalRow(1_200)])
        XCTAssertEqual(callsAfter - callsBefore, 200, "The measured report must have reconciled every session")
        XCTAssertLessThan(elapsed, .seconds(5))
        assertDiagnostics([])
    }
}
