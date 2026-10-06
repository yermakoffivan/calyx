//
//  UsageRunLogReaderTests.swift
//  CalyxTests
//
//  Pins UsageRunLogReader.read(sessionID:resolveProjectRoot:), which reads
//  one session's MAIN transcript incrementally into the stored run log:
//  the file found by session id (or by the stored path while it is still
//  accepted), complete lines only, one save per bounded read, a truncated
//  or replaced file read again from 0 with the stored log discarded, and
//  the session's project root decided from the log's cwd (stored answer,
//  nil -> cwd, throw or invalid answer -> nothing stored and retried,
//  vanished directory -> cwd without asking, a stored root never
//  replaced).
//
//  Real files and a real UsageStore in a per-test temporary directory
//  (resolved with realpath(3), the spelling the kernel reports there),
//  removed in tearDown after every store is closed. The resolver and
//  `directoryState` are injected stubs. Expected runs come from the table
//  in UsageRunLogFixtureSupport.swift or are written out by hand.
//

import os
import SQLite3
import XCTest
@testable import Calyx

// MARK: - Test doubles

private struct ResolverFailure: Error {}

/// Answers each call with the next configured answer (the last one
/// repeats) and records every cwd it is asked about.
private actor StubResolver: ProjectRootResolving {
    enum Answer: Sendable {
        case root(String?)
        case fails
    }

    private var answers: [Answer]
    private(set) var askedCWDs: [String] = []

    init(_ answers: Answer...) {
        self.answers = answers
    }

    func projectRoot(forCWD cwd: String) async throws -> String? {
        askedCWDs.append(cwd)
        let answer: Answer
        if answers.count > 1 {
            answer = answers.removeFirst()
        } else {
            answer = answers.first ?? .root(nil)
        }
        switch answer {
        case .root(let root): return root
        case .fails: throw ResolverFailure()
        }
    }
}

/// The injected `directoryState`: a settable answer, every question
/// recorded.
private final class DirectoryProbe: Sendable {
    private let state: OSAllocatedUnfairLock<(answer: UsageDirectoryState, asked: [String])>

    init(_ answer: UsageDirectoryState) {
        state = OSAllocatedUnfairLock(initialState: (answer, []))
    }

    var asked: [String] { state.withLock { $0.asked } }

    func set(_ answer: UsageDirectoryState) { state.withLock { $0.answer = answer } }

    var function: @Sendable (String) -> UsageDirectoryState {
        { [state] path in
            state.withLock { value in
                value.asked.append(path)
                return value.answer
            }
        }
    }
}

// MARK: - Tests

final class UsageRunLogReaderTests: XCTestCase {

    private var tempPath: String?
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageRunLogReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let resolved = realpath(url.path, nil) else { throw ResolverFailure() }
        tempPath = String(cString: resolved)
        free(resolved)
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

    // MARK: - Paths and setup

    private let projectDirectory = "-fixture-project"
    /// A session for synthetic content (its lines carry no sessionId).
    private let syntheticID = "33333333-3333-4333-8333-333333333333"

    private func base() throws -> String {
        try XCTUnwrap(tempPath)
    }

    /// The projects root of case `name` (each case its own tree).
    private func root(_ name: String = "main") throws -> String {
        try base() + "/" + name + "/projects"
    }

    private func transcriptPath(_ sessionID: String, directory: String? = nil, root rootName: String = "main") throws -> String {
        try root(rootName) + "/" + (directory ?? projectDirectory) + "/" + sessionID + ".jsonl"
    }

    private func openStore(_ name: String = "main") throws -> UsageStore {
        let directory = URL(fileURLWithPath: try base() + "/" + name + "/store", isDirectory: true)
        let store = try UsageStore(directory: directory, now: { Date(timeIntervalSince1970: 0) })
        openedStores.append(store)
        return store
    }

    private func reader(
        _ store: UsageStore, resolver: StubResolver = StubResolver(.root(nil)), probe: DirectoryProbe = DirectoryProbe(.present),
        root rootName: String = "main", maxLineBytes: Int = TranscriptLineReader.defaultMaxLineBytes,
        byteBudget: Int = TranscriptLineReader.defaultByteBudget
    ) throws -> UsageRunLogReader {
        let projectsRoot = try root(rootName)
        return UsageRunLogReader(
            store: store, resolver: resolver, projectsRoot: { projectsRoot }, directoryState: probe.function,
            maxLineBytes: maxLineBytes, byteBudget: byteBudget)
    }

    private func write(_ data: Data, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func append(_ data: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func inode(_ path: String) throws -> UInt64 {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return UInt64(status.st_ino)
    }

    private func copy(_ skeleton: UsageRunLogSkeleton, directory: String? = nil, root rootName: String = "main") throws -> String {
        let path = try transcriptPath(skeleton.sessionID, directory: directory, root: rootName)
        try write(try UsageRunLogFixtures.data(skeleton), to: path)
        return path
    }

    private func result(
        _ status: UsageRunLogReadResult.Status, lines: Int = 0, runsClosed: Int = 0, restarted: Bool = false,
        failed: Bool = false
    ) -> UsageRunLogReadResult {
        UsageRunLogReadResult(
            status: status, linesRead: lines, runsClosed: runsClosed, restarted: restarted,
            projectRootResolutionFailed: failed)
    }

    // MARK: - Synthetic lines (no sessionId; 2026-10-05T00:00:00Z = 1_791_158_400_000 ms)

    /// A user line at 2026-10-05T00:00:SS.000Z.
    private func activity(second: Int, cwd: String? = nil) -> String {
        let seconds = second < 10 ? "0\(second)" : "\(second)"
        let cwdField = cwd.map { #","cwd":""# + $0 + "\"" } ?? ""
        return #"{"type":"user","timestamp":"2026-10-05T00:00:"# + seconds + #".000Z""# + cwdField + "}\n"
    }

    /// The nanoseconds of `activity(second:)`.
    private func ns(second: Int) -> Int64 {
        (1_791_158_400_000 + Int64(second) * 1_000) * 1_000_000
    }

    private func costState(input: Int64) -> String {
        #"{"type":"cost-state","modelUsage":{"m":{"inputTokens":"# + "\(input)" + "}}}\n"
    }

    private func data(_ lines: [String]) -> Data {
        Data(lines.joined().utf8)
    }

    /// Two runs; 5 lines.
    private var contentA: [String] {
        [activity(second: 1, cwd: "/work/a"), costState(input: 5), activity(second: 2), activity(second: 3), costState(input: 9)]
    }

    private var expectedA: UsageRunLog {
        UsageRunLog(runs: [
            UsageRun(sequence: 1, beginNs: ns(second: 1), endNs: ns(second: 1), totals: ["m": UsageTokenTotals(input: 5)]),
            UsageRun(sequence: 2, beginNs: ns(second: 2), endNs: ns(second: 3), totals: ["m": UsageTokenTotals(input: 9)]),
        ], cwd: "/work/a")
    }

    /// One run; shorter than `contentA`.
    private var contentShort: [String] {
        [activity(second: 40, cwd: "/work/b"), costState(input: 1)]
    }

    private var expectedShort: UsageRunLog {
        UsageRunLog(runs: [
            UsageRun(sequence: 1, beginNs: ns(second: 40), endNs: ns(second: 40), totals: ["m": UsageTokenTotals(input: 1)]),
        ], cwd: "/work/b")
    }

    /// One run; longer than `contentA`.
    private var contentLong: [String] {
        [activity(second: 50, cwd: "/work/c"), activity(second: 51), activity(second: 52), activity(second: 53),
         activity(second: 54), activity(second: 55), activity(second: 56), costState(input: 77)]
    }

    private var expectedLong: UsageRunLog {
        UsageRunLog(runs: [
            UsageRun(sequence: 1, beginNs: ns(second: 50), endNs: ns(second: 56), totals: ["m": UsageTokenTotals(input: 77)]),
        ], cwd: "/work/c")
    }

    // MARK: - Fixtures

    func test_read_everyFixtureSkeleton_storesTheExpectedRunsAndCheckpoint() async throws {
        for (index, skeleton) in UsageRunLogFixtures.all.enumerated() {
            let name = "case-\(index)"
            let store = try openStore(name)
            let path = try copy(skeleton, root: name)
            let lineCount = try UsageRunLogFixtures.lines(skeleton).count
            let expected = try UsageRunLogFixtures.expectedLog(skeleton)
            let size = UInt64(try UsageRunLogFixtures.data(skeleton).count)

            let outcome = try await reader(store, root: name).read(sessionID: skeleton.sessionID)
            let stored = try await store.runLog(forSession: skeleton.sessionID)

            XCTAssertEqual(outcome, result(.read, lines: lineCount, runsClosed: expected.runs.count), "\(skeleton)")
            XCTAssertEqual(stored?.log, expected, "\(skeleton)")
            XCTAssertEqual(stored?.file, UsageRunLogFile(
                path: path, checkpoint: TranscriptCheckpoint(inode: try inode(path), offset: size)), "\(skeleton)")
        }
    }

    func test_read_secondCallWithNoNewBytes_readsNothingAndChangesNothing() async throws {
        let store = try openStore()
        _ = try copy(UsageRunLogFixtures.run3)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: UsageRunLogFixtures.run3.sessionID)
        let before = try await store.runLog(forSession: UsageRunLogFixtures.run3.sessionID)

        let outcome = try await subject.read(sessionID: UsageRunLogFixtures.run3.sessionID)
        let after = try await store.runLog(forSession: UsageRunLogFixtures.run3.sessionID)

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(after?.log, before?.log)
        XCTAssertEqual(after?.file, before?.file)
    }

    func test_read_appendedLines_areReadIncrementally_run7ParentThenItsResumeInRun8() async throws {
        let store = try openStore()
        let first = UsageRunLogFixtures.run7a
        let whole = UsageRunLogFixtures.run8b
        XCTAssertEqual(first.sessionID, whole.sessionID, "Fixture error")
        let firstData = try UsageRunLogFixtures.data(first)
        let wholeData = try UsageRunLogFixtures.data(whole)
        XCTAssertTrue(wholeData.starts(with: firstData), "Fixture error: run8 skeleton-2 begins with run7 skeleton-1")
        let path = try copy(first)
        let subject = try reader(store)
        let firstOutcome = try await subject.read(sessionID: first.sessionID)
        XCTAssertEqual(firstOutcome, result(.read, lines: 34, runsClosed: 1))

        try append(wholeData.suffix(from: wholeData.startIndex + firstData.count), to: path)
        let secondOutcome = try await subject.read(sessionID: whole.sessionID)
        let stored = try await store.runLog(forSession: whole.sessionID)

        XCTAssertEqual(secondOutcome, result(.read, lines: 17, runsClosed: 1))
        XCTAssertEqual(stored?.log, try UsageRunLogFixtures.expectedLog(whole))
        XCTAssertEqual(stored?.file.checkpoint.offset, UInt64(wholeData.count))
    }

    func test_read_unterminatedLastLine_isNotReadUntilItIsCompleted() async throws {
        let store = try openStore()
        let skeleton = UsageRunLogFixtures.run1
        let whole = try UsageRunLogFixtures.data(skeleton)
        let path = try transcriptPath(skeleton.sessionID)
        try write(whole.dropLast(), to: path)
        let subject = try reader(store)

        let firstOutcome = try await subject.read(sessionID: skeleton.sessionID)
        let open = try await store.runLog(forSession: skeleton.sessionID)

        XCTAssertEqual(firstOutcome, result(.read, lines: 44))
        // Lines 1-44: an open run from line 1 (06:56:45.437) to line 43 (06:57:18.061).
        XCTAssertEqual(open?.log, UsageRunLog(
            runs: [], openBeginNs: 1_791_183_405_437_000_000, openEndNs: 1_791_183_438_061_000_000,
            cwd: UsageRunLogFixtures.cwd))
        let lastLineLength = try XCTUnwrap(UsageRunLogFixtures.lines(skeleton).last).count
        XCTAssertEqual(open?.file.checkpoint.offset, UInt64(whole.count - lastLineLength - 1))

        try append(Data("\n".utf8), to: path)
        let secondOutcome = try await subject.read(sessionID: skeleton.sessionID)
        let closed = try await store.runLog(forSession: skeleton.sessionID)

        XCTAssertEqual(secondOutcome, result(.read, lines: 1, runsClosed: 1))
        XCTAssertEqual(closed?.log, try UsageRunLogFixtures.expectedLog(skeleton))
    }

    func test_read_smallByteBudget_storesTheSameLogAsAnUnlimitedOne() async throws {
        let skeleton = UsageRunLogFixtures.run8b
        _ = try copy(skeleton)
        let small = try openStore("small")
        let large = try openStore("large")

        let smallOutcome = try await reader(small, byteBudget: 1).read(sessionID: skeleton.sessionID)
        let largeOutcome = try await reader(large, byteBudget: Int.max).read(sessionID: skeleton.sessionID)
        let smallStored = try await small.runLog(forSession: skeleton.sessionID)
        let largeStored = try await large.runLog(forSession: skeleton.sessionID)

        XCTAssertEqual(smallOutcome, largeOutcome)
        XCTAssertEqual(smallStored?.log, try UsageRunLogFixtures.expectedLog(skeleton))
        XCTAssertEqual(smallStored?.log, largeStored?.log)
        XCTAssertEqual(smallStored?.file, largeStored?.file)
    }

    func test_read_overlongLine_isSkipped_andTheRestIsRead() async throws {
        let store = try openStore()
        let long = #"{"type":"user","timestamp":"2026-10-05T00:00:09.000Z","pad":""# + String(repeating: "x", count: 600) + "\"}\n"
        let path = try transcriptPath(syntheticID)
        try write(data([activity(second: 1, cwd: "/work/a"), long, costState(input: 5)]), to: path)

        let outcome = try await reader(store, maxLineBytes: 200).read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, lines: 2, runsClosed: 1))
        XCTAssertEqual(stored?.log, UsageRunLog(runs: [
            UsageRun(sequence: 1, beginNs: ns(second: 1), endNs: ns(second: 1), totals: ["m": UsageTokenTotals(input: 5)]),
        ], cwd: "/work/a"))
    }

    // MARK: - Rewritten files

    func test_read_truncatedAndRewrittenInPlace_restarts_andStoresExactlyTheNewContentsRuns() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let oldInode = try inode(path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data(contentShort))
        try handle.close()
        XCTAssertEqual(try inode(path), oldInode, "Fixture error: rewritten in place")
        XCTAssertLessThan(data(contentShort).count, data(contentA).count, "Fixture error")

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, lines: 2, runsClosed: 1, restarted: true))
        XCTAssertEqual(stored?.log, expectedShort)
        XCTAssertEqual(stored?.file.checkpoint, TranscriptCheckpoint(inode: oldInode, offset: UInt64(data(contentShort).count)))
    }

    func test_read_replacedByANewLongerFile_restarts_andStoresExactlyTheNewContentsRuns() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let oldInode = try inode(path)
        let replacement = try base() + "/replacement.jsonl"
        try write(data(contentLong), to: replacement)
        XCTAssertEqual(rename(replacement, path), 0, "Fixture error")
        XCTAssertNotEqual(try inode(path), oldInode, "Fixture error: a new inode")
        XCTAssertGreaterThan(data(contentLong).count, data(contentA).count, "Fixture error: only the inode can tell")

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, lines: 8, runsClosed: 1, restarted: true))
        XCTAssertEqual(stored?.log, expectedLong)
        XCTAssertEqual(stored?.file.checkpoint, TranscriptCheckpoint(inode: try inode(path), offset: UInt64(data(contentLong).count)))
    }

    /// Contract issue (recorded in the hand-back): a restart onto an EMPTY
    /// file consumes no bytes, so the fresh log is saved at the restart.
    func test_read_truncatedToEmpty_restarts_andLeavesNoStaleRuns() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.close()

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, restarted: true))
        XCTAssertEqual(stored?.log, UsageRunLog())
        XCTAssertEqual(stored?.file.checkpoint, TranscriptCheckpoint(inode: try inode(path), offset: 0))
    }

    /// Contract issue (recorded in the hand-back): a stored checkpoint of
    /// (same inode, offset 0) describes this file, so it is continued, not
    /// restarted again on every call.
    func test_read_afterARestartOntoAnEmptyFile_theNextCallIsNotARestart() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.close()
        _ = try await subject.read(sessionID: syntheticID)

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(stored?.log, UsageRunLog())
    }

    func test_read_restartIsReportedOnce_theNextCallContinues() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data(contentShort))
        try handle.close()
        _ = try await subject.read(sessionID: syntheticID)

        let outcome = try await subject.read(sessionID: syntheticID)

        XCTAssertEqual(outcome, result(.read))
    }

    // MARK: - Missing and rejected files

    func test_read_noTranscript_isMissing_andStoresNothing() async throws {
        let store = try openStore()
        try FileManager.default.createDirectory(atPath: try root() + "/" + projectDirectory, withIntermediateDirectories: true)

        let outcome = try await reader(store).read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)
        let session = try await store.session(syntheticID)

        XCTAssertEqual(outcome, result(.missing))
        XCTAssertNil(stored)
        XCTAssertNil(session)
    }

    func test_read_missingProjectsRoot_isMissing() async throws {
        let store = try openStore()

        let outcome = try await reader(store).read(sessionID: syntheticID)

        XCTAssertEqual(outcome, result(.missing))
    }

    func test_read_symbolicLinkAtThePath_isNotRead_andStoresNothing() async throws {
        let store = try openStore()
        let target = try base() + "/elsewhere/" + syntheticID + ".jsonl"
        try write(data(contentA), to: target)
        let path = try transcriptPath(syntheticID)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        let outcome = try await reader(store).read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.missing))
        XCTAssertNil(stored)
    }

    func test_read_directoryAtThePath_isNotRead_andStoresNothing() async throws {
        let store = try openStore()
        try FileManager.default.createDirectory(atPath: try transcriptPath(syntheticID), withIntermediateDirectories: true)

        let outcome = try await reader(store).read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.missing))
        XCTAssertNil(stored)
    }

    func test_read_storedFileReplacedByASymbolicLink_isNotRead_andTheStoredLogStays() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID)
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let before = try await store.runLog(forSession: syntheticID)
        let target = try base() + "/elsewhere/" + syntheticID + ".jsonl"
        try write(data(contentLong), to: target)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

        let outcome = try await subject.read(sessionID: syntheticID)
        let after = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.missing))
        XCTAssertEqual(after?.log, before?.log)
        XCTAssertEqual(after?.file, before?.file)
    }

    // MARK: - Finding the file

    func test_read_noStoredPath_findsTheFileBySessionID() async throws {
        let store = try openStore()
        try write(data(["{}\n"]), to: try root() + "/-a/other-session.jsonl")
        let path = try transcriptPath(syntheticID, directory: "-b")
        try write(data(contentA), to: path)

        let outcome = try await reader(store).read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, lines: 5, runsClosed: 2))
        XCTAssertEqual(stored?.file.path, path)
        XCTAssertEqual(stored?.log, expectedA)
    }

    func test_read_storedPathIsKept_evenWhenAnotherDirectoryLaterGetsANewerFileOfTheSameName() async throws {
        let store = try openStore()
        let path = try transcriptPath(syntheticID, directory: "-b")
        try write(data(contentA), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        let other = try transcriptPath(syntheticID, directory: "-c")
        try write(data(contentLong), to: other)
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: 0)]
        XCTAssertEqual(utimensat(AT_FDCWD, path, &times, 0), 0, "Fixture error")
        XCTAssertEqual(ClaudeTranscriptLocator.locate(sessionID: syntheticID, root: try root())?.mainPath, other,
                       "Fixture error: by session id alone the newer file would win")

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(stored?.file.path, path)
        XCTAssertEqual(stored?.log, expectedA)
    }

    func test_read_storedPathNoLongerExists_findsTheFileBySessionIDAgain_andRestarts() async throws {
        let store = try openStore()
        let oldPath = try transcriptPath(syntheticID, directory: "-b")
        try write(data(contentA), to: oldPath)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: syntheticID)
        try FileManager.default.removeItem(atPath: oldPath)
        let newPath = try transcriptPath(syntheticID, directory: "-c")
        try write(data(contentShort), to: newPath)

        let outcome = try await subject.read(sessionID: syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)

        XCTAssertEqual(outcome, result(.read, lines: 2, runsClosed: 1, restarted: true))
        XCTAssertEqual(stored?.file.path, newPath)
        XCTAssertEqual(stored?.log, expectedShort)
    }

    // MARK: - Project root

    private func readFixtureForRoot(
        resolver: StubResolver, probe: DirectoryProbe = DirectoryProbe(.present), resolveProjectRoot: Bool = true
    ) async throws -> (outcome: UsageRunLogReadResult, store: UsageStore, reader: UsageRunLogReader) {
        let store = try openStore()
        _ = try copy(UsageRunLogFixtures.run1)
        let subject = try reader(store, resolver: resolver, probe: probe)
        let outcome = try await subject.read(sessionID: UsageRunLogFixtures.run1.sessionID, resolveProjectRoot: resolveProjectRoot)
        return (outcome, store, subject)
    }

    private var run1ID: String { UsageRunLogFixtures.run1.sessionID }

    func test_projectRoot_resolversAnswerIsStored() async throws {
        let resolver = StubResolver(.root("/fixture"))

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertEqual(session?.projectRoot, "/fixture")
        XCTAssertEqual(asked, [UsageRunLogFixtures.cwd])
    }

    func test_projectRoot_resolverAnswersNil_theCWDIsStored() async throws {
        let resolver = StubResolver(.root(nil))

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver)
        let session = try await store.session(run1ID)

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertEqual(session?.projectRoot, UsageRunLogFixtures.cwd)
    }

    func test_projectRoot_resolverThrows_nothingIsStored_andTheFlagIsSet() async throws {
        let resolver = StubResolver(.fails)

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver)
        let session = try await store.session(run1ID)
        let stored = try await store.runLog(forSession: run1ID)

        XCTAssertTrue(outcome.projectRootResolutionFailed)
        XCTAssertNil(session?.projectRoot)
        XCTAssertEqual(stored?.log, try UsageRunLogFixtures.expectedLog(UsageRunLogFixtures.run1), "The runs are still stored")
    }

    func test_projectRoot_afterAThrow_aLaterCallWithNoNewBytes_resolvesAndStoresIt() async throws {
        let resolver = StubResolver(.fails, .root("/fixture"))
        let (_, store, subject) = try await readFixtureForRoot(resolver: resolver)

        let outcome = try await subject.read(sessionID: run1ID)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(session?.projectRoot, "/fixture")
        XCTAssertEqual(asked, [UsageRunLogFixtures.cwd, UsageRunLogFixtures.cwd])
    }

    func test_projectRoot_invalidAnswer_nothingIsStored_andTheFlagIsSet() async throws {
        for answer in [" /fixture", "/fix\u{7}ture", "", "/" + String(repeating: "a", count: 1_024)] {
            try await openedStoresClosedAndCleared()
            let resolver = StubResolver(.root(answer))

            let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver)
            let session = try await store.session(run1ID)

            XCTAssertTrue(outcome.projectRootResolutionFailed, answer)
            XCTAssertNil(session?.projectRoot, answer)
        }
    }

    func test_projectRoot_afterAnInvalidAnswer_aLaterCallStoresAValidOne() async throws {
        let resolver = StubResolver(.root("/fix\u{7}ture"), .root("/fixture"))
        let (_, store, subject) = try await readFixtureForRoot(resolver: resolver)

        let outcome = try await subject.read(sessionID: run1ID)
        let session = try await store.session(run1ID)

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertEqual(session?.projectRoot, "/fixture")
    }

    func test_projectRoot_cwdDirectoryGone_theCWDIsStoredWithoutAskingTheResolver() async throws {
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.gone)

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver, probe: probe)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertEqual(session?.projectRoot, UsageRunLogFixtures.cwd)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(probe.asked, [UsageRunLogFixtures.cwd])
    }

    func test_projectRoot_resolveProjectRootFalse_neitherAsksNorStores_butTheRunsAreStored() async throws {
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.present)

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver, probe: probe, resolveProjectRoot: false)
        let session = try await store.session(run1ID)
        let stored = try await store.runLog(forSession: run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertNil(session?.projectRoot)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(probe.asked, [])
        XCTAssertEqual(stored?.log, try UsageRunLogFixtures.expectedLog(UsageRunLogFixtures.run1))
    }

    func test_projectRoot_alreadyStored_isNeverReplaced_andTheResolverIsNotAsked() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/already", forSession: run1ID)
        _ = try copy(UsageRunLogFixtures.run1)
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.present)

        let outcome = try await reader(store, resolver: resolver, probe: probe).read(sessionID: run1ID)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertFalse(outcome.projectRootResolutionFailed)
        XCTAssertEqual(session?.projectRoot, "/already")
        XCTAssertEqual(asked, [])
    }

    func test_projectRoot_onceStored_aLaterCallDoesNotAskAgain() async throws {
        let resolver = StubResolver(.root("/fixture"), .root("/second"))
        let (_, store, subject) = try await readFixtureForRoot(resolver: resolver)

        _ = try await subject.read(sessionID: run1ID)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(session?.projectRoot, "/fixture")
        XCTAssertEqual(asked, [UsageRunLogFixtures.cwd])
    }

    func test_projectRoot_logWithoutACWD_asksNothingAndStoresNothing() async throws {
        let store = try openStore()
        try write(data([activity(second: 1), costState(input: 5)]), to: try transcriptPath(syntheticID))
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.present)

        let outcome = try await reader(store, resolver: resolver, probe: probe).read(sessionID: syntheticID)
        let session = try await store.session(syntheticID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(outcome, result(.read, lines: 2, runsClosed: 1))
        XCTAssertNil(session)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(probe.asked, [])
    }

    func test_projectRoot_onlyARelativeCWD_storesNothing_asksNothing_andDoesNotFlag() async throws {
        let store = try openStore()
        try write(data([activity(second: 1, cwd: "src"), activity(second: 2, cwd: "./x"), costState(input: 5)]),
                  to: try transcriptPath(syntheticID))
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.present)

        let outcome = try await reader(store, resolver: resolver, probe: probe).read(sessionID: syntheticID)
        let session = try await store.session(syntheticID)
        let stored = try await store.runLog(forSession: syntheticID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(outcome, result(.read, lines: 3, runsClosed: 1))
        XCTAssertNil(session)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(probe.asked, [])
        XCTAssertNil(stored?.log.cwd)
    }

    func test_projectRoot_directoryStateUnknown_storesNothing_flags_andDoesNotAskTheResolver() async throws {
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.unknown)

        let (outcome, store, _) = try await readFixtureForRoot(resolver: resolver, probe: probe)
        let session = try await store.session(run1ID)
        let stored = try await store.runLog(forSession: run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertTrue(outcome.projectRootResolutionFailed)
        XCTAssertNil(session?.projectRoot)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(probe.asked, [UsageRunLogFixtures.cwd])
        XCTAssertEqual(stored?.log, try UsageRunLogFixtures.expectedLog(UsageRunLogFixtures.run1), "The runs are still stored")
    }

    func test_projectRoot_afterUnknown_aLaterCallWithNoNewBytesAndPresent_resolvesAndStores() async throws {
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.unknown)
        let (_, store, subject) = try await readFixtureForRoot(resolver: resolver, probe: probe)
        probe.set(.present)

        let outcome = try await subject.read(sessionID: run1ID)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(session?.projectRoot, "/fixture")
        XCTAssertEqual(asked, [UsageRunLogFixtures.cwd])
    }

    func test_projectRoot_afterUnknown_aLaterCallWithGone_storesTheCWD() async throws {
        let resolver = StubResolver(.root("/fixture"))
        let probe = DirectoryProbe(.unknown)
        let (_, store, subject) = try await readFixtureForRoot(resolver: resolver, probe: probe)
        probe.set(.gone)

        let outcome = try await subject.read(sessionID: run1ID)
        let session = try await store.session(run1ID)
        let asked = await resolver.askedCWDs

        XCTAssertEqual(outcome, result(.read))
        XCTAssertEqual(session?.projectRoot, UsageRunLogFixtures.cwd)
        XCTAssertEqual(asked, [])
    }

    // MARK: - Default directoryState

    func test_directoryState_existingDirectory_isPresent() throws {
        XCTAssertEqual(UsageRunLogReader.directoryState(try base()), .present)
    }

    func test_directoryState_missingPath_isGone() throws {
        XCTAssertEqual(UsageRunLogReader.directoryState(try base() + "/no-such-directory"), .gone)
    }

    func test_directoryState_regularFile_isGone() throws {
        let file = try base() + "/a-file"
        try write(Data("x".utf8), to: file)

        XCTAssertEqual(UsageRunLogReader.directoryState(file), .gone)
    }

    func test_directoryState_pathThroughARegularFile_isGone() throws {
        // stat fails with ENOTDIR.
        let file = try base() + "/a-file"
        try write(Data("x".utf8), to: file)

        XCTAssertEqual(UsageRunLogReader.directoryState(file + "/sub"), .gone)
    }

    func test_directoryState_directoryInsideAnUnsearchableParent_isUnknown() throws {
        // stat fails with EACCES: the directory may well exist.
        let parent = try base() + "/locked"
        try FileManager.default.createDirectory(atPath: parent + "/repo", withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent, 0o000), 0, "Fixture error")
        addTeardownBlock { _ = chmod(parent, 0o700) }
        var status = stat()
        XCTAssertNotEqual(stat(parent + "/repo", &status), 0, "Fixture error: the test must not run as root")
        XCTAssertEqual(errno, EACCES, "Fixture error")

        XCTAssertEqual(UsageRunLogReader.directoryState(parent + "/repo"), .unknown)
    }

    // MARK: - Store failure

    func test_read_storeLockedByASecondConnection_throws_andLeavesTheStoredLogAsItWas() async throws {
        let store = try openStore()
        let skeleton = UsageRunLogFixtures.run7a
        let lines = try UsageRunLogFixtures.lines(skeleton)
        let path = try transcriptPath(skeleton.sessionID)
        try write(Data(lines.prefix(20).map { $0 + Data("\n".utf8) }.joined()), to: path)
        let subject = try reader(store)
        _ = try await subject.read(sessionID: skeleton.sessionID)
        let before = try await store.runLog(forSession: skeleton.sessionID)
        try append(Data(lines.dropFirst(20).map { $0 + Data("\n".utf8) }.joined()), to: path)

        let databasePath = try base() + "/main/store/usage.sqlite"
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK, "Fixture error")
        var released = false
        func release() {
            guard !released else { return }
            released = true
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
            sqlite3_close(holder)
        }
        defer { release() }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK, "Fixture error")

        do {
            let outcome = try await subject.read(sessionID: skeleton.sessionID)
            XCTFail("read must throw while the database is locked, got \(outcome)")
        } catch {
            XCTAssertEqual((error as? SQLiteError)?.primaryCode, SQLITE_BUSY, "Got: \(error)")
        }
        release()

        let after = try await store.runLog(forSession: skeleton.sessionID)
        XCTAssertEqual(after?.log, before?.log)
        XCTAssertEqual(after?.file, before?.file)
        let retried = try await subject.read(sessionID: skeleton.sessionID)
        let final = try await store.runLog(forSession: skeleton.sessionID)
        XCTAssertEqual(retried.runsClosed, 1)
        XCTAssertEqual(final?.log, try UsageRunLogFixtures.expectedLog(skeleton))
    }

    // MARK: - Helpers for looping tests

    /// Closes every store and removes the per-test tree, so a loop can
    /// start each case from nothing.
    private func openedStoresClosedAndCleared() async throws {
        for store in openedStores {
            await store.close()
        }
        openedStores = []
        let directory = try base() + "/main"
        if FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.removeItem(atPath: directory)
        }
    }
}
