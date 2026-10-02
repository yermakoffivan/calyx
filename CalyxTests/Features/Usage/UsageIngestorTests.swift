//
//  UsageIngestorTests.swift
//  CalyxTests
//
//  Pins UsageIngestor.ingest(_:), which reads one session's transcripts
//  (the main file, then "subagents/agent-*.jsonl" in name order) from the
//  stored checkpoints into the store: one batch per read that consumed
//  something, a partial last line left for later, a replaced or truncated
//  file read again from 0, an over-long line skipped and counted, session
//  meta only on main-file batches, the project root resolved once per
//  session, and a store failure propagating without a retry.
//
//  This is the first in-process integration of the parser, the line
//  reader and the REAL UsageStore, so every test uses real files and a
//  real database in a per-test temporary directory, removed in tearDown
//  after every opened store is closed. Transcript lines are raw text with
//  a fixed key order, so byte offsets are deterministic; expected records
//  are written out by hand, never produced by the parser. All fixtures
//  are synthetic; ~/.claude is never read.
//

import XCTest
@testable import Calyx

// MARK: - Test doubles

private struct InjectedFailure: Error, Equatable {}

/// Records every cwd it is asked about and answers as configured.
private actor FakeProjectRootResolver: ProjectRootResolving {
    enum Behavior: Sendable {
        case returns(String?)
        case fails
    }

    private let behavior: Behavior
    private(set) var askedCWDs: [String] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func projectRoot(forCWD cwd: String) async throws -> String? {
        askedCWDs.append(cwd)
        switch behavior {
        case .returns(let root): return root
        case .fails: throw InjectedFailure()
        }
    }
}

/// Forwards to the real store, failing the configured calls.
private actor FailingStore: UsageBatchStoring {
    private let store: UsageStore
    /// 1-based index of the `apply` call that throws; nil never throws.
    private let failingApply: Int?
    private let failsCheckpoint: Bool
    private let failsSession: Bool
    private(set) var applyCalls = 0
    private(set) var sessionCalls = 0

    init(wrapping store: UsageStore, failingApply: Int? = nil,
         failsCheckpoint: Bool = false, failsSession: Bool = false) {
        self.store = store
        self.failingApply = failingApply
        self.failsCheckpoint = failsCheckpoint
        self.failsSession = failsSession
    }

    func checkpoint(forPath path: String) async throws -> TranscriptCheckpoint? {
        if failsCheckpoint { throw InjectedFailure() }
        return try await store.checkpoint(forPath: path)
    }

    func session(_ sessionID: String) async throws -> UsageSessionMeta? {
        sessionCalls += 1
        if failsSession { throw InjectedFailure() }
        return try await store.session(sessionID)
    }

    func apply(_ batch: UsageBatch) async throws {
        applyCalls += 1
        if applyCalls == failingApply { throw InjectedFailure() }
        try await store.apply(batch)
    }
}

/// Holds the outcome of an ingest that runs in an unstructured task.
private actor IngestOutcome {
    private(set) var result: UsageIngestResult?
    private(set) var errorDescription: String?

    func set(result: UsageIngestResult) { self.result = result }
    func set(error: any Error) { errorDescription = "\(error)" }
}

// MARK: - Tests

final class UsageIngestorTests: XCTestCase {

    private let sessionID = "11111111-2222-3333-4444-555555555555"
    private let otherSessionID = "99999999-8888-7777-6666-555555555555"
    /// The cwd every fixture line carries unless a test says otherwise.
    private let defaultCWD = "/work/repo/sub"

    /// realpath(3) of the per-test temporary directory, so every path the
    /// tests build is already fully resolved.
    private var tempPath: String!
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageIngestorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw InjectedFailure() }
        tempPath = String(cString: resolved)
        free(resolved)
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        if let tempPath {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        tempPath = nil
        try await super.tearDown()
    }

    // MARK: - Paths

    private var root: String { tempPath + "/projects" }
    private var projectDirectory: String { root + "/-Users-someone-repo" }
    private var mainPath: String { projectDirectory + "/" + sessionID + ".jsonl" }
    private var subagentsDirectory: String { projectDirectory + "/" + sessionID + "/subagents" }

    private func subagentPath(_ agentID: String) -> String {
        subagentsDirectory + "/agent-" + agentID + ".jsonl"
    }

    /// The location `ClaudeTranscriptLocator.locate` returns for the main
    /// transcript, built by hand so these tests do not depend on it.
    private var location: ClaudeTranscriptLocation {
        ClaudeTranscriptLocation(mainPath: mainPath, sessionID: sessionID, subagentsDirectory: subagentsDirectory)
    }

    // MARK: - Store and ingestor

    private func openStore(_ name: String = "store") throws -> UsageStore {
        let store = try UsageStore(directory: URL(fileURLWithPath: tempPath + "/" + name, isDirectory: true))
        openedStores.append(store)
        return store
    }

    private func makeIngestor(
        store: any UsageBatchStoring,
        resolver: FakeProjectRootResolver,
        maxLineBytes: Int = UsageIngestor.defaultMaxLineBytes,
        byteBudget: Int = UsageIngestor.defaultByteBudget
    ) -> UsageIngestor {
        UsageIngestor(store: store, resolver: resolver, maxLineBytes: maxLineBytes, byteBudget: byteBudget)
    }

    /// A resolver that says "not a repository" (so the root is the cwd).
    private func noRepositoryResolver() -> FakeProjectRootResolver {
        FakeProjectRootResolver(.returns(nil))
    }

    /// Ingests the session into `store` with default limits.
    @discardableResult
    private func ingest(into store: UsageStore, resolver: FakeProjectRootResolver? = nil) async throws
        -> UsageIngestResult {
        try await makeIngestor(store: store, resolver: resolver ?? noRepositoryResolver()).ingest(location)
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

    private func fileInfo(_ path: String) throws -> (inode: UInt64, size: UInt64) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw InjectedFailure() }
        return (UInt64(info.st_ino), UInt64(info.st_size))
    }

    /// Bytes of `lines` on disk: each line plus its "\n".
    private func byteCount(_ lines: [String]) -> UInt64 {
        UInt64(lines.reduce(0) { $0 + $1.utf8.count + 1 })
    }

    // MARK: - Transcript lines

    /// One assistant line in the transcript's shape, as raw text.
    ///
    /// - `cwd` is inserted verbatim between quotes, so a JSON escape such
    ///   as `\u0007` can be passed; nil omits the key.
    /// - `agentID` non-nil makes it a subagent (sidechain) line.
    /// - `advisor` adds an advisor iteration at index 1 (final lines only).
    /// - `pad` adds an ignored string value of that many bytes.
    private func assistantLine(
        _ id: String,
        sessionID: String? = nil,
        cwd: String? = "/work/repo/sub",
        agentID: String? = nil,
        final: Bool = true,
        output: Int = 420,
        advisor: Bool = false,
        pad: Int = 0
    ) -> String {
        var text = #"{"type":"assistant","sessionId":""# + (sessionID ?? self.sessionID) + #"","#
        text += #""timestamp":"2026-10-02T10:27:29.765Z","#
        if let cwd { text += #""cwd":""# + cwd + #"","# }
        text += #""gitBranch":"main","effort":"high","#
        if let agentID {
            text += #""isSidechain":true,"agentId":""# + agentID + #"","attributionAgent":"swift-specialist","#
        } else {
            text += #""isSidechain":false,"#
        }
        if pad > 0 { text += #""pad":""# + String(repeating: "x", count: pad) + #"","# }
        text += #""message":{"id":""# + id + #"","model":"claude-opus-5-5","stop_reason":"#
        text += final ? #""end_turn","# : "null,"
        text += #""usage":{"input_tokens":3,"output_tokens":"# + String(output)
        text += #","cache_read_input_tokens":90000,"cache_creation_input_tokens":1200,"#
        text += #""cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":200},"#
        text += #""output_tokens_details":{"thinking_tokens":150}"#
        if advisor {
            text += #","iterations":[{"type":"message","input_tokens":3,"output_tokens":420},"#
            text += #"{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":125008,"#
            text += #""output_tokens":10278,"cache_read_input_tokens":77,"cache_creation_input_tokens":55}]"#
        }
        text += "}}}"
        return text
    }

    /// A line that is read but yields no record.
    private var userLine: String {
        #"{"type":"user","sessionId":"11111111-2222-3333-4444-555555555555","message":{"role":"user"}}"#
    }

    /// The record `assistantLine(id, ...)` stands for, written by hand
    /// from the fixture text: 2026-10-02T10:27:29.765Z is
    /// 1_790_936_849_765 ms.
    private func record(
        _ key: String,
        sessionID: String? = nil,
        cwd: String? = "/work/repo/sub",
        agentID: String? = nil,
        final: Bool = true,
        output: Int64 = 420
    ) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID ?? self.sessionID,
            timestampMs: 1_790_936_849_765,
            model: "claude-opus-5-5",
            effort: "high",
            thread: agentID == nil ? .main : .subagent,
            agentID: agentID,
            agentType: agentID == nil ? nil : "swift-specialist",
            gitBranch: "main",
            cwd: cwd,
            inputTokens: 3,
            outputTokens: output,
            thinkingTokens: 150,
            cacheReadTokens: 90_000,
            cacheCreationTokens: 1_200,
            cacheCreation1hTokens: 1_000,
            isFinal: final
        )
    }

    /// The advisor record of `assistantLine(id, advisor: true)`.
    private func advisorRecord(_ id: String, cwd: String? = "/work/repo/sub") -> UsageRecord {
        UsageRecord(
            key: id + "#adv1",
            sessionID: sessionID,
            timestampMs: 1_790_936_849_765,
            model: "claude-fable-5-1",
            effort: nil,
            thread: .advisor,
            agentID: nil,
            agentType: nil,
            gitBranch: "main",
            cwd: cwd,
            inputTokens: 125_008,
            outputTokens: 10_278,
            thinkingTokens: 0,
            cacheReadTokens: 77,
            cacheCreationTokens: 55,
            cacheCreation1hTokens: 0,
            isFinal: true
        )
    }

    private func fileResult(
        _ path: String,
        status: UsageIngestFileResult.Status = .read,
        linesRead: Int = 0,
        recordsEmitted: Int = 0,
        oversizeLinesSkipped: Int = 0,
        batchesApplied: Int = 0
    ) -> UsageIngestFileResult {
        UsageIngestFileResult(
            path: path, status: status, linesRead: linesRead, recordsEmitted: recordsEmitted,
            oversizeLinesSkipped: oversizeLinesSkipped, batchesApplied: batchesApplied)
    }

    /// Asserts that `ingest` throws the injected failure.
    private func assertIngestThrowsInjectedFailure(
        _ ingestor: UsageIngestor, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await ingestor.ingest(location)
            XCTFail("Expected ingest to throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? InjectedFailure, InjectedFailure(), "Got: \(error)", file: file, line: line)
        }
    }

    // MARK: - Defaults

    func test_defaults_maxLineBytesIs16MiB_andByteBudgetIs4MiB() {
        XCTAssertEqual(UsageIngestor.defaultMaxLineBytes, 16_777_216)
        XCTAssertEqual(UsageIngestor.defaultByteBudget, 4_194_304)
    }

    // MARK: - Main and subagent files

    func test_ingest_mainAndSubagentFiles_storesMainSubagentAndAdvisorRecords() async throws {
        let store = try openStore()
        try write([userLine, assistantLine("msg_m1", advisor: true)], to: mainPath)
        // Created out of name order.
        try write([assistantLine("msg_s2", agentID: "b2")], to: subagentPath("b2"))
        try write(
            [assistantLine("msg_s1", agentID: "a1", final: false, output: 8), assistantLine("msg_s3", agentID: "a1")],
            to: subagentPath("a1"))
        try write(["{}"], to: subagentsDirectory + "/agent-a1.meta.json")

        let result = try await ingest(into: store)

        XCTAssertEqual(result, UsageIngestResult(
            files: [
                fileResult(mainPath, linesRead: 2, recordsEmitted: 2, batchesApplied: 1),
                fileResult(subagentPath("a1"), linesRead: 2, recordsEmitted: 2, batchesApplied: 1),
                fileResult(subagentPath("b2"), linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
            ],
            projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [
            record("msg_m1"),
            advisorRecord("msg_m1"),
            record("msg_s1", agentID: "a1", final: false, output: 8),
            record("msg_s2", agentID: "b2"),
            record("msg_s3", agentID: "a1"),
        ])
    }

    func test_ingest_locationFromTheLocator_ingestsMainAndSubagents() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        let located = try XCTUnwrap(
            ClaudeTranscriptLocator.locate(transcriptPath: mainPath, sessionID: sessionID, root: root))

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver()).ingest(located)

        XCTAssertEqual(result.files.map(\.path), [mainPath, subagentPath("a1")])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_s1", agentID: "a1")])
    }

    func test_ingest_storesACheckpointPerFileAtItsInodeAndSize() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))

        try await ingest(into: store)

        let main = try fileInfo(mainPath)
        let sub = try fileInfo(subagentPath("a1"))
        let mainCheckpoint = try await store.checkpoint(forPath: mainPath)
        let subCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(mainCheckpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
        XCTAssertEqual(subCheckpoint, TranscriptCheckpoint(inode: sub.inode, offset: sub.size))
    }

    func test_ingest_linesYieldingNoRecord_areCountedAsReadAndCheckpointed() async throws {
        let store = try openStore()
        try write([userLine, "not json", userLine], to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 3, recordsEmitted: 0, batchesApplied: 1)])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [])
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint?.offset, try fileInfo(mainPath).size)
    }

    // MARK: - Nothing new

    func test_ingest_secondTimeWithNothingNew_readsNothingAndAppliesNoBatch() async throws {
        let store = try openStore()
        try write([userLine, assistantLine("msg_m1", advisor: true)], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try await ingest(into: store)
        let recordsBefore = try await store.records(forSession: sessionID)
        let sessionsBefore = try await store.sessions()
        let mainCheckpointBefore = try await store.checkpoint(forPath: mainPath)
        let subCheckpointBefore = try await store.checkpoint(forPath: subagentPath("a1"))

        let result = try await ingest(into: store)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath), fileResult(subagentPath("a1"))],
            projectRootResolutionFailed: false))
        let recordsAfter = try await store.records(forSession: sessionID)
        let sessionsAfter = try await store.sessions()
        let mainCheckpointAfter = try await store.checkpoint(forPath: mainPath)
        let subCheckpointAfter = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(recordsAfter, [record("msg_m1"), advisorRecord("msg_m1"), record("msg_s1", agentID: "a1")])
        XCTAssertEqual(recordsAfter, recordsBefore)
        XCTAssertEqual(sessionsAfter, sessionsBefore)
        XCTAssertEqual(mainCheckpointAfter, mainCheckpointBefore)
        XCTAssertEqual(subCheckpointAfter, subCheckpointBefore)
    }

    func test_ingest_secondTimeThroughAStoreDouble_callsApplyZeroTimes() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try await ingest(into: store)
        let counting = FailingStore(wrapping: store)

        _ = try await makeIngestor(store: counting, resolver: noRepositoryResolver()).ingest(location)

        let applyCalls = await counting.applyCalls
        XCTAssertEqual(applyCalls, 0)
    }

    func test_ingest_emptyMainFile_isReadWithZeroCountersAndStoresNothing() async throws {
        let store = try openStore()
        try write([], to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath)])
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(sessions, [], "A read that consumed nothing applies nothing, session meta included")
        XCTAssertNil(checkpoint)
    }

    // MARK: - Appends

    func test_ingest_afterAppend_readsOnlyTheNewLines() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try await ingest(into: store)
        try append(assistantLine("msg_m3", advisor: true) + "\n", to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [
            fileResult(mainPath, linesRead: 1, recordsEmitted: 2, batchesApplied: 1),
            fileResult(subagentPath("a1")),
        ])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [
            record("msg_m1"), record("msg_m2"), record("msg_m3"), advisorRecord("msg_m3"),
            record("msg_s1", agentID: "a1"),
        ])
        let main = try fileInfo(mainPath)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
    }

    func test_ingest_subagentFileAppearingLater_isIngestedWithoutMainChanging() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try await ingest(into: store)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [
            fileResult(mainPath),
            fileResult(subagentPath("a1"), linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
        ])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_s1", agentID: "a1")])
    }

    // MARK: - Partial last line

    func test_ingest_partialLastLine_isNotConsumedUntilItsNewlineArrives() async throws {
        let store = try openStore()
        let first = assistantLine("msg_m1")
        let second = assistantLine("msg_m2")
        let cut = second.index(second.startIndex, offsetBy: 200)
        try write([first], to: mainPath)
        try append(String(second[..<cut]), to: mainPath)
        let inode = try fileInfo(mainPath).inode
        let afterFirstLine = TranscriptCheckpoint(inode: inode, offset: byteCount([first]))

        // Only the complete line is consumed.
        let firstResult = try await ingest(into: store)
        XCTAssertEqual(firstResult.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let checkpointAfterFirst = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpointAfterFirst, afterFirstLine)
        XCTAssertLessThan(afterFirstLine.offset, try fileInfo(mainPath).size, "Fixture error")

        // The tail is still unterminated: nothing is consumed or applied.
        let secondResult = try await ingest(into: store)
        XCTAssertEqual(secondResult.files, [fileResult(mainPath)])
        let checkpointAfterSecond = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpointAfterSecond, afterFirstLine)
        let recordsBeforeNewline = try await store.records(forSession: sessionID)
        XCTAssertEqual(recordsBeforeNewline, [record("msg_m1")])

        // The rest of the line and its newline arrive.
        try append(String(second[cut...]) + "\n", to: mainPath)
        let thirdResult = try await ingest(into: store)
        XCTAssertEqual(thirdResult.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let checkpointAfterThird = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpointAfterThird, TranscriptCheckpoint(inode: inode, offset: byteCount([first, second])))
        let recordsAfterNewline = try await store.records(forSession: sessionID)
        XCTAssertEqual(recordsAfterNewline, [record("msg_m1"), record("msg_m2")])
    }

    func test_ingest_fileHoldingOnlyAPartialLine_appliesNothingAndStoresNoCheckpoint() async throws {
        let store = try openStore()
        try write([], to: mainPath)
        try append(assistantLine("msg_m1"), to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath)])
        let records = try await store.records(forSession: sessionID)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(records, [])
        XCTAssertNil(checkpoint)
    }

    // MARK: - Replaced or truncated file

    func test_ingest_fileReplacedByANewInode_isReadAgainFromTheStart() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1"), assistantLine("msg_m2")], to: mainPath)
        try await ingest(into: store)
        let old = try fileInfo(mainPath)
        // The replacement is LONGER than the stored offset, so only the
        // changed inode can send the read back to 0. It is written beside
        // the old file and renamed over it, which guarantees a new inode.
        let replacement = [assistantLine("msg_m3"), assistantLine("msg_m2"), assistantLine("msg_m1")]
        let staging = projectDirectory + "/staging.tmp"
        try write(replacement, to: staging)
        XCTAssertEqual(rename(staging, mainPath), 0, "Fixture error: rename failed")
        let new = try fileInfo(mainPath)
        XCTAssertNotEqual(new.inode, old.inode, "Fixture error: the inode did not change")
        XCTAssertGreaterThan(new.size, old.size, "Fixture error")

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 3, recordsEmitted: 3, batchesApplied: 1)])
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: new.inode, offset: new.size))
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_m2"), record("msg_m3")])

        let fresh = try openStore("fresh")
        try await ingest(into: fresh)
        let freshRecords = try await fresh.records(forSession: sessionID)
        XCTAssertEqual(records, freshRecords)
    }

    func test_ingest_fileTruncatedAndRewrittenShorter_isReadAgainFromTheStart() async throws {
        let store = try openStore()
        // The padding only makes the first version long; it is not stored.
        try write([assistantLine("msg_m1", pad: 2_000), assistantLine("msg_m2")], to: mainPath)
        try await ingest(into: store)
        let old = try fileInfo(mainPath)
        // Rewritten in place (same inode), shorter than the stored offset.
        let rewritten = [assistantLine("msg_m2"), assistantLine("msg_m1")]
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: mainPath))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(rewritten.map { $0 + "\n" }.joined().utf8))
        try handle.close()
        let new = try fileInfo(mainPath)
        XCTAssertEqual(new.inode, old.inode, "Fixture error: the inode changed")
        XCTAssertLessThan(new.size, old.size, "Fixture error")
        XCTAssertEqual(new.size, byteCount(rewritten), "Fixture error")

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 2, recordsEmitted: 2, batchesApplied: 1)])
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: new.inode, offset: new.size))
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_m2")])

        let fresh = try openStore("fresh")
        try await ingest(into: fresh)
        let freshRecords = try await fresh.records(forSession: sessionID)
        XCTAssertEqual(records, freshRecords)
    }

    // MARK: - Byte budget

    func test_ingest_smallByteBudget_appliesOneBatchPerReadAndEndsAtTheFileSize() async throws {
        let store = try openStore()
        let lines = [
            assistantLine("msg_m1"), userLine, assistantLine("msg_m2", advisor: true), assistantLine("msg_m3"),
        ]
        try write(lines, to: mainPath)

        // A budget of one byte stops every read after its first line.
        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver(), byteBudget: 1)
            .ingest(location)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 4, recordsEmitted: 4, batchesApplied: 4)])
        let main = try fileInfo(mainPath)
        XCTAssertEqual(main.size, byteCount(lines), "Fixture error")
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_m2"), advisorRecord("msg_m2"), record("msg_m3")])

        let single = try openStore("single")
        let singleResult = try await ingest(into: single)
        XCTAssertEqual(singleResult.files, [fileResult(mainPath, linesRead: 4, recordsEmitted: 4, batchesApplied: 1)])
        let singleRecords = try await single.records(forSession: sessionID)
        let singleSessions = try await single.sessions()
        let sessions = try await store.sessions()
        XCTAssertEqual(records, singleRecords)
        XCTAssertEqual(sessions, singleSessions)
    }

    func test_ingest_smallByteBudget_appliesToSubagentFilesToo() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write(
            [assistantLine("msg_s1", agentID: "a1"), assistantLine("msg_s2", agentID: "a1")], to: subagentPath("a1"))

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver(), byteBudget: 1)
            .ingest(location)

        XCTAssertEqual(result.files, [
            fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
            fileResult(subagentPath("a1"), linesRead: 2, recordsEmitted: 2, batchesApplied: 2),
        ])
        let sub = try fileInfo(subagentPath("a1"))
        let checkpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: sub.inode, offset: sub.size))
    }

    // MARK: - Over-long line

    func test_ingest_lineLongerThanMaxLineBytes_isSkippedAndCounted_neighboursAreIngested() async throws {
        let store = try openStore()
        let before = assistantLine("msg_m1")
        let tooLong = assistantLine("msg_big", pad: 2_000)
        let after = assistantLine("msg_m2")
        XCTAssertLessThanOrEqual(before.utf8.count, 1_024, "Fixture error")
        XCTAssertLessThanOrEqual(after.utf8.count, 1_024, "Fixture error")
        XCTAssertGreaterThan(tooLong.utf8.count, 1_024, "Fixture error")
        try write([before, tooLong, after], to: mainPath)

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver(), maxLineBytes: 1_024)
            .ingest(location)

        XCTAssertEqual(result.files, [
            fileResult(mainPath, linesRead: 2, recordsEmitted: 2, oversizeLinesSkipped: 1, batchesApplied: 1),
        ])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_m2")])
        let main = try fileInfo(mainPath)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
    }

    func test_ingest_sameLineUnderTheDefaultLimit_isIngested() async throws {
        let store = try openStore()
        try write([assistantLine("msg_big", pad: 2_000)], to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_big")])
    }

    // MARK: - Several lines of one response

    func test_ingest_nonFinalThenFinalLineInSeparateBatches_endsAsOneFinalRow() async throws {
        let store = try openStore()
        try write(
            [assistantLine("msg_m1", final: false, output: 8), assistantLine("msg_m1", final: true, output: 420)],
            to: mainPath)

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver(), byteBudget: 1)
            .ingest(location)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 2, recordsEmitted: 2, batchesApplied: 2)])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1", final: true, output: 420)])
    }

    func test_ingest_finalThenNonFinalLineInSeparateBatches_keepsTheFinalRow() async throws {
        let store = try openStore()
        try write(
            [assistantLine("msg_m1", final: true, output: 420), assistantLine("msg_m1", final: false, output: 8)],
            to: mainPath)

        _ = try await makeIngestor(store: store, resolver: noRepositoryResolver(), byteBudget: 1).ingest(location)

        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1", final: true, output: 420)])
    }

    func test_ingest_nonFinalLineInMainAndFinalLineInSubagentFile_endsAsOneFinalRow() async throws {
        let store = try openStore()
        try write([assistantLine("msg_x", agentID: "a1", final: false, output: 8)], to: mainPath)
        try write([assistantLine("msg_x", agentID: "a1", final: true, output: 420)], to: subagentPath("a1"))

        try await ingest(into: store)

        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_x", agentID: "a1", final: true, output: 420)])
    }

    func test_ingest_finalLineInMainAndNonFinalLineInSubagentFile_keepsTheFinalRow() async throws {
        let store = try openStore()
        try write([assistantLine("msg_x", agentID: "a1", final: true, output: 420)], to: mainPath)
        try write([assistantLine("msg_x", agentID: "a1", final: false, output: 8)], to: subagentPath("a1"))

        try await ingest(into: store)

        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_x", agentID: "a1", final: true, output: 420)])
    }

    // MARK: - Session id of a line

    func test_ingest_lineWithAnotherSessionID_isStoredUnderItsOwnSessionID() async throws {
        let store = try openStore()
        try write(
            [assistantLine("msg_m1"), assistantLine("msg_foreign", sessionID: otherSessionID)], to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 2, recordsEmitted: 2, batchesApplied: 1)])
        let own = try await store.records(forSession: sessionID)
        let foreign = try await store.records(forSession: otherSessionID)
        XCTAssertEqual(own, [record("msg_m1")])
        XCTAssertEqual(foreign, [record("msg_foreign", sessionID: otherSessionID)])
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.map(\.sessionID), [sessionID], "Session meta is only written for the location's id")
    }

    // MARK: - Session meta

    func test_ingest_storesSessionMetaWithMainPathAndProjectRoot() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))

        try await ingest(into: store, resolver: FakeProjectRootResolver(.returns("/work/repo")))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: "/work/repo"),
        ])
    }

    func test_ingest_mainFileWithOnlyNonRecordLines_stillStoresSessionMeta() async throws {
        let store = try openStore()
        try write([userLine], to: mainPath)

        try await ingest(into: store)

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: nil)])
    }

    func test_ingest_subagentOnlyGrowth_isIngestedAndLeavesSessionMetaUnchanged() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try await ingest(into: store, resolver: resolver)
        try append(assistantLine("msg_s2", agentID: "a1") + "\n", to: subagentPath("a1"))

        let result = try await ingest(into: store, resolver: resolver)

        XCTAssertEqual(result.files, [
            fileResult(mainPath),
            fileResult(subagentPath("a1"), linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
        ])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [
            record("msg_m1"), record("msg_s1", agentID: "a1"), record("msg_s2", agentID: "a1"),
        ])
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: "/work/repo"),
        ])
    }

    func test_ingest_batchesFromSubagentFiles_carryNoSessionMeta() async throws {
        let store = try openStore()
        // The main file exists but has nothing to consume, so the only
        // batch applied comes from the subagent file.
        try write([], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [
            fileResult(mainPath),
            fileResult(subagentPath("a1"), linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
        ])
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        XCTAssertEqual(records, [record("msg_s1", agentID: "a1")])
        XCTAssertEqual(sessions, [])
    }

    // MARK: - Project root

    func test_ingest_resolverReturnsARoot_thatRootIsStored() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([assistantLine("msg_m1", cwd: "/work/repo/sub")], to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/repo/sub"])
        XCTAssertEqual(stored?.projectRoot, "/work/repo")
        XCTAssertFalse(result.projectRootResolutionFailed)
    }

    func test_ingest_resolverReturnsNil_theCWDItselfIsStored() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(nil))
        try write([assistantLine("msg_m1", cwd: "/work/no-repo")], to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/no-repo"])
        XCTAssertEqual(stored?.projectRoot, "/work/no-repo")
        XCTAssertFalse(result.projectRootResolutionFailed)
    }

    func test_ingest_resolverThrows_theCWDIsStoredAndTheFailureIsReportedNotThrown() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.fails)
        try write([assistantLine("msg_m1", cwd: "/work/broken")], to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)],
            projectRootResolutionFailed: true))
        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(asked, ["/work/broken"])
        XCTAssertEqual(stored?.projectRoot, "/work/broken")
        XCTAssertEqual(records, [record("msg_m1", cwd: "/work/broken")])
    }

    func test_ingest_firstMainRecordHasUnusableCWD_theNextMainRecordWithACWDIsUsed() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(nil))
        // A control character makes the parser drop the first cwd.
        try write(
            [assistantLine("msg_m1", cwd: #"/work/pro\u0007ject"#), assistantLine("msg_m2", cwd: "/work/second"),
             assistantLine("msg_m3", cwd: "/work/third")],
            to: mainPath)

        try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(asked, ["/work/second"])
        XCTAssertEqual(stored?.projectRoot, "/work/second")
        XCTAssertEqual(records.first, record("msg_m1", cwd: nil), "Fixture error: the first cwd must parse to nil")
    }

    func test_ingest_noMainRecordWithACWD_rootIsNilAndTheResolverIsNeverCalled() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([userLine, assistantLine("msg_m1", cwd: nil)], to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let sessions = try await store.sessions()
        XCTAssertEqual(asked, [])
        XCTAssertEqual(sessions, [UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: nil)])
        XCTAssertFalse(result.projectRootResolutionFailed)
    }

    func test_ingest_cwdOfARecordInASubagentFile_isNeverUsedAsTheProjectRoot() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([assistantLine("msg_m1", cwd: nil)], to: mainPath)
        try write([assistantLine("msg_s1", cwd: "/work/from-subagent", agentID: "a1")], to: subagentPath("a1"))

        try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let sessions = try await store.sessions()
        XCTAssertEqual(asked, [])
        XCTAssertEqual(sessions, [UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: nil)])
    }

    func test_ingest_sidechainRecordInsideTheMainFile_doesNotSupplyTheProjectRoot() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(nil))
        try write(
            [assistantLine("msg_side", cwd: "/work/sidechain", agentID: "a1"),
             assistantLine("msg_m1", cwd: "/work/main")],
            to: mainPath)

        try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/main"])
        XCTAssertEqual(stored?.projectRoot, "/work/main")
    }

    func test_ingest_onceARootIsStored_theResolverIsNotCalledAgain() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(nil))
        try write([assistantLine("msg_m1", cwd: "/work/first")], to: mainPath)
        try await ingest(into: store, resolver: resolver)
        try append(assistantLine("msg_m2", cwd: "/work/elsewhere") + "\n", to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/first"])
        XCTAssertEqual(stored?.projectRoot, "/work/first")
    }

    func test_ingest_severalBatchesWithCWDsInOneIngest_callsTheResolverOnceWithTheFirst() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(nil))
        try write(
            [assistantLine("msg_m1", cwd: "/work/first"), assistantLine("msg_m2", cwd: "/work/second"),
             assistantLine("msg_m3", cwd: "/work/third")],
            to: mainPath)

        let result = try await makeIngestor(store: store, resolver: resolver, byteBudget: 1).ingest(location)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 3, recordsEmitted: 3, batchesApplied: 3)])
        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/first"])
        XCTAssertEqual(stored?.projectRoot, "/work/first")
    }

    func test_ingest_rootUnknownAfterTheFirstIngest_isResolvedWhenACWDArrivesLater() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([assistantLine("msg_m1", cwd: nil)], to: mainPath)
        try await ingest(into: store, resolver: resolver)
        let askedAfterFirst = await resolver.askedCWDs
        XCTAssertEqual(askedAfterFirst, [])
        try append(assistantLine("msg_m2", cwd: "/work/repo/late") + "\n", to: mainPath)

        try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let sessions = try await store.sessions()
        XCTAssertEqual(asked, ["/work/repo/late"])
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: "/work/repo"),
        ])
    }

    // MARK: - The resolved root is a label like any other

    /// Ingests one main line whose cwd is "/work/repo/sub" with a resolver
    /// answering `answer`, and asserts the stored root and the flag.
    private func assertResolverAnswer(
        _ answer: String, isStoredAs expectedRoot: String, resolutionFailed: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns(answer))
        try write([assistantLine("msg_m1", cwd: "/work/repo/sub")], to: mainPath)

        let result = try await ingest(into: store, resolver: resolver)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)],
            projectRootResolutionFailed: resolutionFailed), file: file, line: line)
        let asked = await resolver.askedCWDs
        let sessions = try await store.sessions()
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(asked, ["/work/repo/sub"], file: file, line: line)
        XCTAssertEqual(
            sessions, [UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: expectedRoot)],
            file: file, line: line)
        XCTAssertEqual(records, [record("msg_m1", cwd: "/work/repo/sub")], file: file, line: line)
    }

    func test_ingest_resolverAnswerWithBidiOverride_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer(
            "/work/re\u{202E}po", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithEscapeCharacter_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer(
            "/work/re\u{1B}[31mpo", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithZeroWidthSpace_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer(
            "/work/re\u{200B}po", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithZeroWidthSpaceAtTheEdges_isNotTrimmedIntoAValidRoot() async throws {
        try await assertResolverAnswer(
            "\u{200B}/work/repo\u{200B}", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithNewline_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer(
            "/work/repo\n/etc", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerOf1025Scalars_fallsBackToTheCWDAndReportsTheFailure() async throws {
        let answer = "/" + String(repeating: "a", count: 1_024)
        XCTAssertEqual(answer.unicodeScalars.count, 1_025, "Fixture error")
        try await assertResolverAnswer(answer, isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerOfExactly1024Scalars_isStoredVerbatim() async throws {
        let answer = "/" + String(repeating: "a", count: 1_023)
        XCTAssertEqual(answer.unicodeScalars.count, 1_024, "Fixture error")
        try await assertResolverAnswer(answer, isStoredAs: answer, resolutionFailed: false)
    }

    func test_ingest_resolverAnswerLengthIsCountedInScalarsNotCharacters() async throws {
        // 513 Characters but 1,025 scalars: "e" + U+0301 is one Character.
        let answer = "/" + String(repeating: "e\u{301}", count: 512)
        XCTAssertEqual(answer.unicodeScalars.count, 1_025, "Fixture error")
        XCTAssertEqual(answer.count, 513, "Fixture error")
        try await assertResolverAnswer(answer, isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerIsEmpty_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer("", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithLeadingSpace_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer(" /work/repo", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithTrailingSpace_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer("/work/repo ", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithTrailingTab_fallsBackToTheCWDAndReportsTheFailure() async throws {
        try await assertResolverAnswer("/work/repo\t", isStoredAs: "/work/repo/sub", resolutionFailed: true)
    }

    func test_ingest_resolverAnswerWithNonASCIILettersAndAnInnerSpace_isStoredVerbatim() async throws {
        let answer = "/work/日本語 プロジェクト/répo"
        try await assertResolverAnswer(answer, isStoredAs: answer, resolutionFailed: false)
    }

    func test_ingest_invalidResolverAnswer_isNotAskedForAgainOnceTheCWDIsStored() async throws {
        // The fallback root is stored like any other root, so the next
        // ingest finds it and does not consult the resolver again.
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/re\u{202E}po"))
        try write([assistantLine("msg_m1", cwd: "/work/repo/sub")], to: mainPath)
        try await ingest(into: store, resolver: resolver)
        try append(assistantLine("msg_m2", cwd: "/work/repo/other") + "\n", to: mainPath)

        let second = try await ingest(into: store, resolver: resolver)

        let asked = await resolver.askedCWDs
        let stored = try await store.session(sessionID)
        XCTAssertEqual(asked, ["/work/repo/sub"])
        XCTAssertEqual(stored?.projectRoot, "/work/repo/sub")
        XCTAssertFalse(second.projectRootResolutionFailed)
    }

    // MARK: - Missing or non-regular main file

    func test_ingest_missingMainFile_reportsMissingAndStoresNothing() async throws {
        let store = try openStore()
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainPath), "Fixture error")

        let result = try await ingest(into: store, resolver: resolver)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, status: .missing)], projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        let asked = await resolver.askedCWDs
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(checkpoint)
        XCTAssertEqual(asked, [])
    }

    func test_ingest_missingMainFile_isPickedUpByALaterIngestOnceItExists() async throws {
        let store = try openStore()
        try await ingest(into: store)
        try write([assistantLine("msg_m1")], to: mainPath)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1")])
    }

    func test_ingest_mainPathReplacedByASymlink_reportsNotARegularFileAndStoresNothing() async throws {
        let store = try openStore()
        // The link target is a perfectly valid transcript: following the
        // link would ingest it.
        let target = tempPath + "/elsewhere.jsonl"
        try write([assistantLine("msg_m1")], to: target)
        try FileManager.default.createSymbolicLink(atPath: mainPath, withDestinationPath: target)

        let result = try await ingest(into: store)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, status: .notARegularFile)], projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        let targetCheckpoint = try await store.checkpoint(forPath: target)
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(checkpoint)
        XCTAssertNil(targetCheckpoint)
    }

    func test_ingest_mainPathIsADirectory_reportsNotARegularFileAndStoresNothing() async throws {
        let store = try openStore()
        try FileManager.default.createDirectory(atPath: mainPath, withIntermediateDirectories: true)

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, status: .notARegularFile)])
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(sessions, [])
        XCTAssertNil(checkpoint)
    }

    // MARK: - Store failures

    func test_ingest_secondApplyThrows_propagatesAndKeepsOnlyTheFirstBatch() async throws {
        let store = try openStore()
        let failing = FailingStore(wrapping: store, failingApply: 2)
        let lines = [assistantLine("msg_m1"), assistantLine("msg_m2"), assistantLine("msg_m3")]
        try write(lines, to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        // One line per batch: the main file alone needs three applies.
        let ingestor = makeIngestor(store: failing, resolver: noRepositoryResolver(), byteBudget: 1)

        await assertIngestThrowsInjectedFailure(ingestor)

        let applyCalls = await failing.applyCalls
        XCTAssertEqual(applyCalls, 2, "No retry, and nothing is attempted after the failure")
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1")])
        let inode = try fileInfo(mainPath).inode
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: inode, offset: byteCount([lines[0]])))
        let subCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertNil(subCheckpoint)
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: defaultCWD),
        ])
    }

    func test_ingest_afterAFailedApply_theNextIngestReadsTheRestFromTheStoredCheckpoint() async throws {
        let store = try openStore()
        let failing = FailingStore(wrapping: store, failingApply: 2)
        try write([assistantLine("msg_m1"), assistantLine("msg_m2"), assistantLine("msg_m3")], to: mainPath)
        await assertIngestThrowsInjectedFailure(
            makeIngestor(store: failing, resolver: noRepositoryResolver(), byteBudget: 1))

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 2, recordsEmitted: 2, batchesApplied: 1)])
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_m2"), record("msg_m3")])
    }

    func test_ingest_checkpointLookupThrows_propagatesBeforeAnythingIsApplied() async throws {
        let store = try openStore()
        let failing = FailingStore(wrapping: store, failsCheckpoint: true)
        let resolver = FakeProjectRootResolver(.returns("/work/repo"))
        try write([assistantLine("msg_m1")], to: mainPath)

        await assertIngestThrowsInjectedFailure(makeIngestor(store: failing, resolver: resolver))

        let applyCalls = await failing.applyCalls
        let asked = await resolver.askedCWDs
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(asked, [], "Nothing was read, so no cwd was seen")
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
    }

    func test_ingest_sessionLookupThrows_propagatesAndStoresNothingOfThatBatch() async throws {
        let store = try openStore()
        let failing = FailingStore(wrapping: store, failsSession: true)
        try write([assistantLine("msg_m1")], to: mainPath)

        await assertIngestThrowsInjectedFailure(makeIngestor(store: failing, resolver: noRepositoryResolver()))

        let applyCalls = await failing.applyCalls
        let records = try await store.records(forSession: sessionID)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(records, [])
        XCTAssertNil(checkpoint)
    }

    func test_ingest_closedStore_throwsClosed() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        await store.close()

        do {
            _ = try await ingest(into: store)
            XCTFail("Expected ingest to throw")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .closed, "Got: \(error)")
        }
    }

    // MARK: - The main transcript anchors the session

    func test_ingest_missingMainFileWithValidSubagentFiles_stopsAtMainAndStoresNothing() async throws {
        let store = try openStore()
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainPath), "Fixture error")

        let result = try await ingest(into: store)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, status: .missing)], projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let subCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(subCheckpoint, "The subagent file must not have been read")
    }

    func test_ingest_mainIsSymlinkWithValidSubagentFiles_stopsAtMainAndStoresNothing() async throws {
        let store = try openStore()
        let target = tempPath + "/elsewhere.jsonl"
        try write([assistantLine("msg_m1")], to: target)
        try FileManager.default.createSymbolicLink(atPath: mainPath, withDestinationPath: target)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))

        let result = try await ingest(into: store)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, status: .notARegularFile)], projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let subCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(subCheckpoint, "The subagent file must not have been read")
    }

    // MARK: - Symlinked subagents directory

    func test_ingest_subagentsDirectoryIsSymlinkToDirectoryOutsideRoot_ingestsOnlyTheMainFile() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        let outside = tempPath + "/elsewhere/subagents"
        try write([assistantLine("msg_s1", agentID: "a1")], to: outside + "/agent-a1.jsonl")
        try FileManager.default.createDirectory(
            atPath: projectDirectory + "/" + sessionID, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: subagentsDirectory, withDestinationPath: outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subagentPath("a1")), "Fixture error")

        let result = try await ingest(into: store)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1)])
        let records = try await store.records(forSession: sessionID)
        let throughLink = try await store.checkpoint(forPath: subagentPath("a1"))
        let direct = try await store.checkpoint(forPath: outside + "/agent-a1.jsonl")
        XCTAssertEqual(records, [record("msg_m1")])
        XCTAssertNil(throughLink)
        XCTAssertNil(direct)
    }

    // MARK: - Opening never blocks

    func test_ingest_mainPathIsAFIFO_reportsNotARegularFileWithoutBlocking() async throws {
        let store = try openStore()
        let fifoPath = mainPath
        XCTAssertEqual(mkfifo(fifoPath, 0o600), 0, "Fixture error: mkfifo failed")
        // If the ingest blocked opening the FIFO, opening the write end
        // releases it, so a failing run cannot hang the suite or leak a
        // stuck thread past this test.
        addTeardownBlock {
            let writer = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        let ingestor = makeIngestor(store: store, resolver: noRepositoryResolver())
        let location = self.location
        let outcome = IngestOutcome()
        let finished = expectation(description: "ingest returned")
        Task {
            do {
                await outcome.set(result: try await ingestor.ingest(location))
            } catch {
                await outcome.set(error: error)
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5)

        let result = await outcome.result
        let errorDescription = await outcome.errorDescription
        XCTAssertNil(errorDescription, "ingest must not throw for a FIFO")
        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(mainPath, status: .notARegularFile)], projectRootResolutionFailed: false))
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(sessions, [])
        XCTAssertNil(checkpoint)
    }

    // MARK: - Failures under subagents/

    /// Asserts that `ingest` throws the given POSIX error.
    private func assertIngestThrowsPOSIX(
        _ code: Int32, _ ingestor: UsageIngestor, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let result = try await ingestor.ingest(location)
            XCTFail("Expected a POSIX error \(code), got \(result)", file: file, line: line)
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain, "Got: \(error)", file: file, line: line)
            XCTAssertEqual(nsError.code, Int(code), "Got: \(error)", file: file, line: line)
        }
    }

    func test_ingest_unreadableSubagentFile_isReportedAsFailedAndTheNextFileIsStillIngested() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try write([assistantLine("msg_s2", agentID: "b2")], to: subagentPath("b2"))
        let unreadable = subagentPath("a1")
        XCTAssertEqual(chmod(unreadable, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(unreadable, 0o600) }

        let first = try await ingest(into: store)

        XCTAssertEqual(first, UsageIngestResult(
            files: [
                fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
                fileResult(subagentPath("a1"), status: .failed(errno: EACCES)),
                fileResult(subagentPath("b2"), linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
            ],
            projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let failedCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(records, [record("msg_m1"), record("msg_s2", agentID: "b2")])
        XCTAssertNil(failedCheckpoint)

        let second = try await ingest(into: store)

        XCTAssertEqual(second, UsageIngestResult(
            files: [
                fileResult(mainPath),
                fileResult(subagentPath("a1"), status: .failed(errno: EACCES)),
                fileResult(subagentPath("b2")),
            ],
            projectRootResolutionFailed: false))
        let recordsAfter = try await store.records(forSession: sessionID)
        let failedCheckpointAfter = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(recordsAfter, records)
        XCTAssertNil(failedCheckpointAfter)
    }

    func test_ingest_unreadableSubagentsDirectory_throwsEACCESAndKeepsTheMainFileApplied() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        let directory = subagentsDirectory
        XCTAssertEqual(chmod(directory, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(directory, 0o700) }

        await assertIngestThrowsPOSIX(EACCES, makeIngestor(store: store, resolver: noRepositoryResolver()))

        let main = try fileInfo(mainPath)
        let records = try await store.records(forSession: sessionID)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        let sessions = try await store.sessions()
        XCTAssertEqual(records, [record("msg_m1")])
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: sessionID, transcriptPath: mainPath, projectRoot: defaultCWD),
        ])
    }

    func test_ingest_unreadableMainFile_throwsEACCESAndStoresNothing() async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        let unreadable = mainPath
        XCTAssertEqual(chmod(unreadable, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(unreadable, 0o600) }

        await assertIngestThrowsPOSIX(EACCES, makeIngestor(store: store, resolver: noRepositoryResolver()))

        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let subCheckpoint = try await store.checkpoint(forPath: subagentPath("a1"))
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(subCheckpoint)
    }

    // MARK: - The opened file must be the validated file

    func test_ingest_mainPathRoutedThroughSymlinkedProjectDirectory_reportsRedirectedAndStoresNothing()
        async throws {
        let store = try openStore()
        // Models a project directory swapped for a link after `locate`:
        // O_NOFOLLOW only guards the last component.
        let outside = tempPath + "/elsewhere/project"
        try write([assistantLine("msg_m1")], to: outside + "/" + sessionID + ".jsonl")
        try write([assistantLine("msg_s1", agentID: "a1")], to: outside + "/" + sessionID + "/subagents/agent-a1.jsonl")
        let linked = root + "/linked-project"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: outside)
        let swapped = ClaudeTranscriptLocation(
            mainPath: linked + "/" + sessionID + ".jsonl", sessionID: sessionID,
            subagentsDirectory: linked + "/" + sessionID + "/subagents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: swapped.mainPath), "Fixture error")

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver()).ingest(swapped)

        XCTAssertEqual(result, UsageIngestResult(
            files: [fileResult(swapped.mainPath, status: .redirected)], projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let sessions = try await store.sessions()
        let throughLink = try await store.checkpoint(forPath: swapped.mainPath)
        let direct = try await store.checkpoint(forPath: outside + "/" + sessionID + ".jsonl")
        XCTAssertEqual(records, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(throughLink)
        XCTAssertNil(direct)
    }

    func test_ingest_subagentsDirectoryRoutedThroughSymlinkedAncestor_reportsEachFileRedirectedAndStoresOnlyMain()
        async throws {
        let store = try openStore()
        try write([assistantLine("msg_m1")], to: mainPath)
        let outside = tempPath + "/elsewhere/project"
        let outsideSubagents = outside + "/" + sessionID + "/subagents"
        try write([assistantLine("msg_s1", agentID: "a1")], to: outsideSubagents + "/agent-a1.jsonl")
        try write([assistantLine("msg_s2", agentID: "b2")], to: outsideSubagents + "/agent-b2.jsonl")
        let linked = root + "/linked-project"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: outside)
        // The session directory and "subagents" are real directories; the
        // link is one level above them.
        let routed = linked + "/" + sessionID + "/subagents"
        let swapped = ClaudeTranscriptLocation(mainPath: mainPath, sessionID: sessionID, subagentsDirectory: routed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: routed + "/agent-a1.jsonl"), "Fixture error")

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver()).ingest(swapped)

        XCTAssertEqual(result, UsageIngestResult(
            files: [
                fileResult(mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
                fileResult(routed + "/agent-a1.jsonl", status: .redirected),
                fileResult(routed + "/agent-b2.jsonl", status: .redirected),
            ],
            projectRootResolutionFailed: false))
        let records = try await store.records(forSession: sessionID)
        let throughLink = try await store.checkpoint(forPath: routed + "/agent-a1.jsonl")
        let direct = try await store.checkpoint(forPath: outsideSubagents + "/agent-a1.jsonl")
        XCTAssertEqual(records, [record("msg_m1")])
        XCTAssertNil(throughLink)
        XCTAssertNil(direct)
    }

    // MARK: - A batch is applied whenever the offset moved

    func test_ingest_fileWhoseOnlyLineIsOverLong_appliesOneBatchAndCheckpointsAtTheFileSize() async throws {
        let store = try openStore()
        let tooLong = assistantLine("msg_big", pad: 2_000)
        XCTAssertGreaterThan(tooLong.utf8.count, 1_024, "Fixture error")
        try write([tooLong], to: mainPath)
        let ingestor = makeIngestor(store: store, resolver: noRepositoryResolver(), maxLineBytes: 1_024)

        let first = try await ingestor.ingest(location)

        XCTAssertEqual(first.files, [fileResult(mainPath, oversizeLinesSkipped: 1, batchesApplied: 1)])
        let main = try fileInfo(mainPath)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: main.size))
        XCTAssertEqual(records, [])

        let second = try await ingestor.ingest(location)

        XCTAssertEqual(second.files, [fileResult(mainPath)])
    }

    func test_ingest_fileHoldingOnlyEmptyLines_appliesOneBatchAndCheckpointsAtTheFileSize() async throws {
        let store = try openStore()
        try write(["", "", ""], to: mainPath)
        XCTAssertEqual(try fileInfo(mainPath).size, 3, "Fixture error")

        let first = try await ingest(into: store)

        XCTAssertEqual(first.files, [fileResult(mainPath, batchesApplied: 1)])
        let main = try fileInfo(mainPath)
        let checkpoint = try await store.checkpoint(forPath: mainPath)
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: main.inode, offset: 3))

        let second = try await ingest(into: store)

        XCTAssertEqual(second.files, [fileResult(mainPath)])
    }

    // MARK: - The stored session is only looked up when there is a root to decide

    func test_ingest_mainBatchWithoutAMainThreadCWD_doesNotLookUpTheStoredSession() async throws {
        let store = try openStore()
        let counting = FailingStore(wrapping: store)
        try write(
            [userLine, assistantLine("msg_m1", cwd: nil), assistantLine("msg_side", cwd: "/work/side", agentID: "a1")],
            to: mainPath)

        let result = try await makeIngestor(store: counting, resolver: noRepositoryResolver()).ingest(location)

        XCTAssertEqual(result.files, [fileResult(mainPath, linesRead: 3, recordsEmitted: 2, batchesApplied: 1)])
        let sessionCalls = await counting.sessionCalls
        let applyCalls = await counting.applyCalls
        XCTAssertEqual(sessionCalls, 0)
        XCTAssertEqual(applyCalls, 1)
    }

    // MARK: - Non-ASCII path components

    /// A directory name whose NFC and NFD spellings differ in bytes.
    private let nonASCIIName = "\u{30D7}\u{30ED}\u{30B8}\u{30A7}\u{30AF}\u{30C8}\u{304C}-caf\u{E9}"

    /// Puts a projects root beneath "<tmp>/<created>", then locates,
    /// lists and ingests the session through "<tmp>/<requested>".
    private func assertLocatesAndIngests(
        createdAs created: String, requestedAs requested: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let createdProject = tempPath + "/" + created + "/projects/-Users-someone-repo"
        try write([assistantLine("msg_m1")], to: createdProject + "/" + sessionID + ".jsonl")
        try write(
            [assistantLine("msg_s1", agentID: "a1")],
            to: createdProject + "/" + sessionID + "/subagents/agent-a1.jsonl")
        let requestedRoot = tempPath + "/" + requested + "/projects"
        let requestedPath = requestedRoot + "/-Users-someone-repo/" + sessionID + ".jsonl"
        // realpath(3) of the request, computed outside the code under test.
        let resolved = try XCTUnwrap(realpath(requestedPath, nil), "Fixture error", file: file, line: line)
        let expectedMainPath = String(cString: resolved)
        free(resolved)
        let store = try openStore()

        let located = try XCTUnwrap(
            ClaudeTranscriptLocator.locate(transcriptPath: requestedPath, sessionID: sessionID, root: requestedRoot),
            "locate returned nil", file: file, line: line)
        XCTAssertEqual(located.mainPath, expectedMainPath, file: file, line: line)

        let subagents = try ClaudeTranscriptLocator.subagentTranscripts(in: located)
        XCTAssertEqual(subagents, [located.subagentsDirectory + "/agent-a1.jsonl"], file: file, line: line)

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver()).ingest(located)
        XCTAssertEqual(result, UsageIngestResult(
            files: [
                fileResult(located.mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
                fileResult(
                    located.subagentsDirectory + "/agent-a1.jsonl", linesRead: 1, recordsEmitted: 1,
                    batchesApplied: 1),
            ],
            projectRootResolutionFailed: false), file: file, line: line)
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_s1", agentID: "a1")], file: file, line: line)
    }

    func test_nonASCIIName_fixture_nfcAndNFDSpellingsDifferInBytes() {
        let nfc = nonASCIIName.precomposedStringWithCanonicalMapping
        let nfd = nonASCIIName.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))
        XCTAssertEqual(nfc.unicodeScalars.count, 12)
        XCTAssertEqual(nfd.unicodeScalars.count, 16)
    }

    func test_ingest_rootBeneathNFCNamedDirectory_locatesListsAndIngests() async throws {
        let nfc = nonASCIIName.precomposedStringWithCanonicalMapping
        try await assertLocatesAndIngests(createdAs: nfc, requestedAs: nfc)
    }

    func test_ingest_rootBeneathNFDNamedDirectory_locatesListsAndIngests() async throws {
        let nfd = nonASCIIName.decomposedStringWithCanonicalMapping
        try await assertLocatesAndIngests(createdAs: nfd, requestedAs: nfd)
    }

    func test_ingest_directoryCreatedAsNFDButRequestedAsNFC_locatesListsAndIngests() async throws {
        try await assertLocatesAndIngests(
            createdAs: nonASCIIName.decomposedStringWithCanonicalMapping,
            requestedAs: nonASCIIName.precomposedStringWithCanonicalMapping)
    }

    func test_ingest_directoryCreatedAsNFCButRequestedAsNFD_locatesListsAndIngests() async throws {
        try await assertLocatesAndIngests(
            createdAs: nonASCIIName.precomposedStringWithCanonicalMapping,
            requestedAs: nonASCIIName.decomposedStringWithCanonicalMapping)
    }

    // MARK: - One canonical spelling: F_GETPATH

    private let dataVolumePrefix = "/System/Volumes/Data"

    /// The path the kernel reports for the opened item (`F_GETPATH`),
    /// computed outside the code under test.
    private func descriptorPath(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Skips unless "/System/Volumes/Data" + `path` names the same item
    /// as `path` (the data-volume firmlink layout).
    private func skipUnlessReachableThroughDataVolume(_ path: String) throws {
        var plain = stat()
        var prefixed = stat()
        guard stat(path, &plain) == 0, stat(dataVolumePrefix + path, &prefixed) == 0,
              plain.st_ino == prefixed.st_ino, plain.st_dev == prefixed.st_dev else {
            throw XCTSkip("\(dataVolumePrefix) does not alias \(path) on this volume layout")
        }
    }

    /// Locates the session with the given spellings of the root and the
    /// transcript path, then ingests the located session.
    private func assertLocatesAndIngests(
        rootPrefix: String, pathPrefix: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try write([assistantLine("msg_m1")], to: mainPath)
        try write([assistantLine("msg_s1", agentID: "a1")], to: subagentPath("a1"))
        try skipUnlessReachableThroughDataVolume(mainPath)
        let store = try openStore()

        let located = try XCTUnwrap(
            ClaudeTranscriptLocator.locate(
                transcriptPath: pathPrefix + mainPath, sessionID: sessionID, root: rootPrefix + root),
            "locate returned nil", file: file, line: line)
        XCTAssertEqual(located.mainPath, try descriptorPath(mainPath), file: file, line: line)

        let result = try await makeIngestor(store: store, resolver: noRepositoryResolver()).ingest(located)

        XCTAssertEqual(result, UsageIngestResult(
            files: [
                fileResult(located.mainPath, linesRead: 1, recordsEmitted: 1, batchesApplied: 1),
                fileResult(
                    located.subagentsDirectory + "/agent-a1.jsonl", linesRead: 1, recordsEmitted: 1,
                    batchesApplied: 1),
            ],
            projectRootResolutionFailed: false), file: file, line: line)
        let records = try await store.records(forSession: sessionID)
        XCTAssertEqual(records, [record("msg_m1"), record("msg_s1", agentID: "a1")], file: file, line: line)
    }

    func test_ingest_rootAndPathThroughDataVolumePrefix_locatesAndIngestsMainAndSubagent() async throws {
        try await assertLocatesAndIngests(rootPrefix: dataVolumePrefix, pathPrefix: dataVolumePrefix)
    }

    func test_ingest_onlyRootThroughDataVolumePrefix_locatesAndIngestsMainAndSubagent() async throws {
        try await assertLocatesAndIngests(rootPrefix: dataVolumePrefix, pathPrefix: "")
    }

    func test_ingest_onlyPathThroughDataVolumePrefix_locatesAndIngestsMainAndSubagent() async throws {
        try await assertLocatesAndIngests(rootPrefix: "", pathPrefix: dataVolumePrefix)
    }
}
