//
//  UsageStoreRunLogTests.swift
//  CalyxTests
//
//  Pins the run-log part of UsageStore: `runLog(forSession:)` /
//  `saveRunLog(_:file:forSession:)` (replace semantics, nil times, model
//  names with brackets, UInt64 checkpoints), `sessionsWithSeries()`,
//  `setProjectRootIfUnset(_:forSession:)`, what `deleteAll()` and
//  `resetTracking()` do to run logs, and the schema: version 2 gains the
//  run-log tables in place, so a version-2 file written by the previous
//  slice (frozen here) is moved aside, a version-1 file migrates in one
//  step, and a version-3 file is moved aside.
//
//  Every database lives in a per-test temporary directory removed in
//  tearDown after every opened store is closed. The store's clock is
//  injected. All data is synthetic.
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageStoreRunLogTests: XCTestCase {

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreRunLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectory = url
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

    // MARK: - Helpers

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    private func storeDirectory() throws -> URL {
        guard let tempDirectory else { throw FixtureError(description: "no temporary directory") }
        return tempDirectory.appendingPathComponent("usage", isDirectory: true)
    }

    private func databaseURL() throws -> URL {
        try storeDirectory().appendingPathComponent("usage.sqlite")
    }

    private func openStore() throws -> UsageStore {
        let store = try UsageStore(directory: try storeDirectory(), now: { Date(timeIntervalSince1970: 0) })
        openedStores.append(store)
        return store
    }

    private func execute(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw FixtureError(description: "sqlite3_open failed")
        }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError(description: "sqlite3_exec failed")
        }
    }

    /// One integer from `sql`, or nil. READWRITE: a closed WAL database
    /// cannot be opened read-only.
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

    private func tableCount(_ table: String, at url: URL) -> Int64? {
        integer("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'", at: url)
    }

    private func corruptSiblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try storeDirectory().path)
            .filter { $0.hasPrefix("usage.sqlite.corrupt-") }
    }

    private let runLogTables = ["usage_run_logs", "usage_runs", "usage_run_totals"]

    private func file(_ path: String = "/p/-proj/s.jsonl", inode: UInt64 = 7, offset: UInt64 = 99) -> UsageRunLogFile {
        UsageRunLogFile(path: path, checkpoint: TranscriptCheckpoint(inode: inode, offset: offset))
    }

    /// A log exercising every stored field: a run without times, runs
    /// with several models (one with brackets), an open run and a cwd.
    private var richLog: UsageRunLog {
        UsageRunLog(
            runs: [
                UsageRun(sequence: 1, beginNs: nil, endNs: nil, totals: [
                    "claude-opus-5-5[1m]": UsageTokenTotals(input: 2, output: 4, cacheRead: 10_738, cacheCreation: 16_899),
                ]),
                UsageRun(sequence: 2, beginNs: 1_791_183_405_437_000_000, endNs: 1_791_183_438_061_000_000, totals: [
                    "claude-opus-5-5[1m]": UsageTokenTotals(input: 5, output: 9, cacheRead: 20_000, cacheCreation: 17_000),
                    "claude-haiku-4-5-20251001": UsageTokenTotals(input: 944, output: 11, cacheRead: 0, cacheCreation: 0),
                    "unknown": UsageTokenTotals(input: Int64.max, output: 0, cacheRead: 1, cacheCreation: 0),
                ]),
                UsageRun(sequence: 3, beginNs: -5, endNs: 0, totals: [:]),
            ],
            openBeginNs: 1_791_183_500_000_000_000, openEndNs: 1_791_183_400_000_000_000,
            cwd: "/fixture/project")
    }

    private func sample(session: String, series: Int, value: Int64 = 5) -> UsageSeriesSample {
        UsageSeriesSample(
            sessionID: session, seriesID: String(format: "%064x", series), startNs: 1_000, timeNs: 2_000 + Int64(series),
            kind: .input, value: value, model: "claude-sonnet-5-5", effort: nil, thread: "main", agent: nil)
    }

    /// Stores series for `session` through the real telemetry path.
    private func addSeries(_ store: UsageStore, session: String, count: Int = 1) async throws {
        let samples = (1...max(count, 1)).map { sample(session: session, series: $0) }
        let outcome = try await store.apply(
            samples: samples, processStarts: [UsageProcessStart(sessionID: session, startNs: 10, startType: "fresh")],
            receivedAtNs: 60_000_000_000)
        XCTAssertFalse(outcome.ignored, "Fixture error: the export must be stored")
    }

    private func assertThrowsClosed<T>(
        _ name: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("\(name) must throw after close", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .closed, name, file: file, line: line)
        }
    }

    // MARK: - runLog / saveRunLog

    func test_runLog_unknownSession_isNil() async throws {
        let store = try openStore()

        let stored = try await store.runLog(forSession: "nobody")

        XCTAssertNil(stored)
    }

    func test_saveRunLog_thenRunLog_roundTripsEveryField() async throws {
        let store = try openStore()

        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, richLog)
        XCTAssertEqual(stored?.file, file())
    }

    func test_saveRunLog_emptyLogWithNilFields_roundTrips() async throws {
        let store = try openStore()

        try await store.saveRunLog(UsageRunLog(), file: file(offset: 0), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, UsageRunLog(runs: [], openBeginNs: nil, openEndNs: nil, cwd: nil))
        XCTAssertEqual(stored?.file, file(offset: 0))
    }

    func test_saveRunLog_uint64ExtremesInTheCheckpoint_roundTripAcrossReopen() async throws {
        let first = try openStore()
        let extreme = file(inode: UInt64.max, offset: UInt64.max - 1)
        try await first.saveRunLog(richLog, file: extreme, forSession: "session-a")
        await first.close()

        let second = try openStore()
        let stored = try await second.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.file, extreme)
        XCTAssertEqual(stored?.log, richLog)
    }

    func test_saveRunLog_secondSaveWithFewerRuns_leavesNoStaleRunOrTotal() async throws {
        let store = try openStore()
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        let shorter = UsageRunLog(
            runs: [UsageRun(sequence: 1, beginNs: 10, endNs: 20, totals: ["m": UsageTokenTotals(input: 1)])],
            openBeginNs: nil, openEndNs: nil, cwd: "/other")

        try await store.saveRunLog(shorter, file: file("/p/-proj2/s.jsonl", inode: 8, offset: 3), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, shorter)
        XCTAssertEqual(stored?.file, file("/p/-proj2/s.jsonl", inode: 8, offset: 3))
        await store.close()
        let url = try databaseURL()
        XCTAssertEqual(integer("SELECT count(*) FROM usage_runs", at: url), 1)
        XCTAssertEqual(integer("SELECT count(*) FROM usage_run_totals", at: url), 1)
    }

    func test_saveRunLog_sameRunWithFewerModels_dropsTheMissingModel() async throws {
        let store = try openStore()
        let two = UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: 1, endNs: 2, totals: [
            "a": UsageTokenTotals(input: 1), "b": UsageTokenTotals(input: 2),
        ])])
        let one = UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: 1, endNs: 2, totals: ["a": UsageTokenTotals(input: 3)])])
        try await store.saveRunLog(two, file: file(), forSession: "session-a")

        try await store.saveRunLog(one, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, one)
    }

    func test_saveRunLog_isPerSession_replacingOneLeavesTheOther() async throws {
        let store = try openStore()
        let other = UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: 7, endNs: 8, totals: ["x": UsageTokenTotals(output: 9)])],
                                cwd: "/b")
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        try await store.saveRunLog(other, file: file("/p/-b/t.jsonl"), forSession: "session-b")

        try await store.saveRunLog(UsageRunLog(), file: file(offset: 0), forSession: "session-a")
        let storedA = try await store.runLog(forSession: "session-a")
        let storedB = try await store.runLog(forSession: "session-b")

        XCTAssertEqual(storedA?.log, UsageRunLog())
        XCTAssertEqual(storedB?.log, other)
        XCTAssertEqual(storedB?.file, file("/p/-b/t.jsonl"))
    }

    func test_saveRunLog_doesNotTouchTheV1Checkpoints() async throws {
        let store = try openStore()

        try await store.saveRunLog(richLog, file: file("/same/path.jsonl", inode: 1, offset: 500), forSession: "session-a")
        let v1 = try await store.checkpoint(forPath: "/same/path.jsonl")

        XCTAssertNil(v1)
    }

    func test_v1Checkpoint_doesNotCreateARunLog() async throws {
        let store = try openStore()
        try await store.apply(UsageBatch(
            records: [], session: nil,
            fileCheckpoint: UsageFileCheckpoint(path: "/same/path.jsonl", checkpoint: TranscriptCheckpoint(inode: 1, offset: 5))))

        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertNil(stored)
    }

    // MARK: - saveRunLog writes only what changed

    /// The bytes of a file in the store directory; nil when absent.
    private func fileBytes(_ name: String) throws -> Data? {
        let url = try storeDirectory().appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func run(_ sequence: Int, _ begin: Int64, _ input: Int64, models: [String] = ["m"]) -> UsageRun {
        UsageRun(sequence: sequence, beginNs: begin, endNs: begin + 1,
                 totals: Dictionary(uniqueKeysWithValues: models.map { ($0, UsageTokenTotals(input: input, output: 1)) }))
    }

    func test_saveRunLog_unchangedLog_writesNoByteOfTheDatabaseOrTheWAL() async throws {
        let store = try openStore()
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        let databaseBefore = try fileBytes("usage.sqlite")
        let walBefore = try fileBytes("usage.sqlite-wal")
        XCTAssertNotNil(walBefore, "Fixture error: the WAL must exist while the store is open")

        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")

        XCTAssertEqual(try fileBytes("usage.sqlite"), databaseBefore, "an unchanged save must not write the database")
        XCTAssertEqual(try fileBytes("usage.sqlite-wal"), walBefore, "an unchanged save must not write the WAL")
        let stored = try await store.runLog(forSession: "session-a")
        XCTAssertEqual(stored?.log, richLog)
    }

    func test_saveRunLog_oneMoreRun_keepsTheEarlierRuns_andAddsTheNewOne() async throws {
        let store = try openStore()
        let two = UsageRunLog(runs: [run(1, 10, 5, models: ["a", "b"]), run(2, 20, 6)], cwd: "/w")
        let three = UsageRunLog(runs: two.runs + [run(3, 30, 7, models: ["c", "d"])], cwd: "/w")
        try await store.saveRunLog(two, file: file(offset: 10), forSession: "session-a")

        try await store.saveRunLog(three, file: file(offset: 20), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, three)
        XCTAssertEqual(stored?.file, file(offset: 20))
        XCTAssertEqual(stored?.log.runs.prefix(2).map { $0 }, two.runs)
    }

    func test_saveRunLog_changedTotalInTheLastRun_isStored() async throws {
        let store = try openStore()
        let before = UsageRunLog(runs: [run(1, 10, 5), run(2, 20, 6, models: ["m", "n"])])
        let replaced = UsageRunLog(runs: [run(1, 10, 5), UsageRun(sequence: 2, beginNs: 20, endNs: 21, totals: [
            "m": UsageTokenTotals(input: 60, output: 1), "n": UsageTokenTotals(input: 6, output: 1),
        ])])
        try await store.saveRunLog(before, file: file(), forSession: "session-a")

        try await store.saveRunLog(replaced, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, replaced)
    }

    func test_saveRunLog_onlyTheOpenRunChanged_isStored() async throws {
        let store = try openStore()
        let before = UsageRunLog(runs: [run(1, 10, 5)], openBeginNs: 50, openEndNs: 50, cwd: "/w")
        let after = UsageRunLog(runs: [run(1, 10, 5)], openBeginNs: 50, openEndNs: 90, cwd: "/w")
        try await store.saveRunLog(before, file: file(offset: 1), forSession: "session-a")

        try await store.saveRunLog(after, file: file(offset: 2), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, after)
        XCTAssertEqual(stored?.file, file(offset: 2))
    }

    func test_saveRunLog_logDivergingAtRunOne_isFullyReplaced() async throws {
        let store = try openStore()
        let before = UsageRunLog(runs: [run(1, 10, 5, models: ["a"]), run(2, 20, 6, models: ["b"]), run(3, 30, 7)])
        let after = UsageRunLog(runs: [run(1, 11, 9, models: ["z"]), run(2, 20, 6, models: ["b"])])
        try await store.saveRunLog(before, file: file(), forSession: "session-a")

        try await store.saveRunLog(after, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, after)
        await store.close()
        let url = try databaseURL()
        XCTAssertEqual(integer("SELECT count(*) FROM usage_runs", at: url), 2)
        XCTAssertEqual(integer("SELECT count(*) FROM usage_run_totals", at: url), 2)
    }

    func test_saveRunLog_sameRunsWithAModelAdded_isStored() async throws {
        let store = try openStore()
        let before = UsageRunLog(runs: [run(1, 10, 5, models: ["a"])])
        let after = UsageRunLog(runs: [run(1, 10, 5, models: ["a", "b"])])
        try await store.saveRunLog(before, file: file(), forSession: "session-a")

        try await store.saveRunLog(after, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, after)
    }

    // MARK: - sessionsWithSeries

    func test_sessionsWithSeries_freshStore_isEmpty() async throws {
        let store = try openStore()

        let sessions = try await store.sessionsWithSeries()

        XCTAssertEqual(sessions, [])
    }

    func test_sessionsWithSeries_listsOnlySessionsWithASeries_ascending_withoutDuplicates() async throws {
        let store = try openStore()
        try await addSeries(store, session: "session-c", count: 3)
        try await addSeries(store, session: "session-a", count: 1)
        // A run log and a session row, but no series.
        try await store.saveRunLog(richLog, file: file(), forSession: "session-b")
        try await store.setProjectRootIfUnset("/r", forSession: "session-d")

        let sessions = try await store.sessionsWithSeries()

        XCTAssertEqual(sessions, ["session-a", "session-c"])
    }

    func test_sessionsWithSeries_afterResetTracking_isEmpty_becauseTheSeriesAreGone() async throws {
        let store = try openStore()
        try await addSeries(store, session: "session-a")

        try await store.resetTracking()
        let sessions = try await store.sessionsWithSeries()

        XCTAssertEqual(sessions, [])
    }

    // MARK: - setProjectRootIfUnset

    func test_setProjectRootIfUnset_withNoSessionRow_createsItWithTheRoot() async throws {
        let store = try openStore()

        try await store.setProjectRootIfUnset("/work/repo", forSession: "session-a")
        let sessions = try await store.sessions()

        XCTAssertEqual(sessions, [UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: "/work/repo")])
    }

    func test_setProjectRootIfUnset_neverReplacesAStoredRoot() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/work/first", forSession: "session-a")

        try await store.setProjectRootIfUnset("/work/second", forSession: "session-a")
        let session = try await store.session("session-a")

        XCTAssertEqual(session?.projectRoot, "/work/first")
    }

    func test_setProjectRootIfUnset_neverReplacesARootSetByAV1Batch() async throws {
        let store = try openStore()
        try await store.apply(UsageBatch(
            records: [], session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t.jsonl", projectRoot: "/v1/root"),
            fileCheckpoint: nil))

        try await store.setProjectRootIfUnset("/work/other", forSession: "session-a")
        let session = try await store.session("session-a")

        XCTAssertEqual(session, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t.jsonl", projectRoot: "/v1/root"))
    }

    func test_setProjectRootIfUnset_onARowWithoutRoot_setsIt_andKeepsTheTranscriptPath() async throws {
        let store = try openStore()
        try await store.apply(UsageBatch(
            records: [], session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t.jsonl", projectRoot: nil),
            fileCheckpoint: nil))

        try await store.setProjectRootIfUnset("/work/repo", forSession: "session-a")
        let session = try await store.session("session-a")

        XCTAssertEqual(session, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t.jsonl", projectRoot: "/work/repo"))
    }

    // MARK: - deleteAll / resetTracking

    func test_deleteAll_removesEveryRunLogRunAndTotal() async throws {
        let store = try openStore()
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        try await store.saveRunLog(richLog, file: file(), forSession: "session-b")

        try await store.deleteAll()
        let storedA = try await store.runLog(forSession: "session-a")
        let storedB = try await store.runLog(forSession: "session-b")

        XCTAssertNil(storedA)
        XCTAssertNil(storedB)
        await store.close()
        let url = try databaseURL()
        for table in runLogTables {
            XCTAssertEqual(integer("SELECT count(*) FROM \(table)", at: url), 0, table)
        }
    }

    func test_resetTracking_keepsEveryRunLog() async throws {
        let store = try openStore()
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        try await addSeries(store, session: "session-a")

        try await store.resetTracking()
        let stored = try await store.runLog(forSession: "session-a")

        XCTAssertEqual(stored?.log, richLog)
        XCTAssertEqual(stored?.file, file())
    }

    // MARK: - Schema

    /// The version-2 schema exactly as the previous slice (R1) created it,
    /// frozen here: version 1's tables plus the telemetry tables, WITHOUT
    /// the run-log tables.
    private static let r1Version2Schema = """
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
        CREATE TABLE usage_series (
            session_id TEXT NOT NULL,
            series_id TEXT NOT NULL,
            start_ns INTEGER NOT NULL,
            kind TEXT NOT NULL,
            model TEXT NOT NULL,
            last_value INTEGER NOT NULL,
            last_time_ns INTEGER NOT NULL,
            first_heard_ns INTEGER NOT NULL,
            PRIMARY KEY (session_id, series_id, start_ns)
        ) WITHOUT ROWID;
        CREATE TABLE usage_points (
            session_id TEXT NOT NULL,
            minute INTEGER NOT NULL,
            model TEXT NOT NULL,
            effort TEXT,
            thread TEXT,
            agent TEXT,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_creation_tokens INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX usage_points_group ON usage_points (
            session_id, minute, model, coalesce(effort, 0), coalesce(thread, 0), coalesce(agent, 0));
        CREATE TABLE usage_process_starts (
            session_id TEXT NOT NULL,
            start_ns INTEGER NOT NULL,
            start_type TEXT,
            PRIMARY KEY (session_id, start_ns)
        ) WITHOUT ROWID;
        CREATE TABLE usage_retired_processes (
            digest TEXT NOT NULL PRIMARY KEY
        ) WITHOUT ROWID;
        CREATE TABLE usage_meta (
            key TEXT NOT NULL PRIMARY KEY,
            value INTEGER NOT NULL
        ) WITHOUT ROWID;
        INSERT INTO usage_meta VALUES ('tracked_from_ns', 0);
        INSERT INTO usage_sessions VALUES ('session-r1', '/t/r1.jsonl', '/r/r1');
        PRAGMA user_version = 2;
        """

    /// Version 1 as the first release created it.
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
        INSERT INTO usage_sessions VALUES ('session-v1', '/t/v1.jsonl', '/r/v1');
        PRAGMA user_version = 1;
        """

    func test_freshDatabase_hasTheRunLogTables_atVersion2() async throws {
        let store = try openStore()
        await store.close()
        let url = try databaseURL()

        XCTAssertEqual(integer("PRAGMA user_version", at: url), 2)
        for table in runLogTables {
            XCTAssertEqual(tableCount(table, at: url), 1, table)
        }
    }

    func test_version2DatabaseWithoutTheRunLogTables_isMovedAside_andAFreshOneOpens() async throws {
        let url = try databaseURL()
        try execute(Self.r1Version2Schema, at: url)
        XCTAssertEqual(tableCount("usage_run_logs", at: url), 0, "Fixture error")

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            let moved = try storeDirectory().appendingPathComponent(sibling)
            XCTAssertEqual(integer("SELECT count(*) FROM usage_sessions WHERE session_id = 'session-r1'", at: moved), 1)
        }
        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [], "The fresh database starts empty")
        try await store.saveRunLog(richLog, file: file(), forSession: "session-a")
        let stored = try await store.runLog(forSession: "session-a")
        XCTAssertEqual(stored?.log, richLog)
    }

    func test_version1Database_migratesInOneStep_toEveryTable() async throws {
        let url = try databaseURL()
        try execute(Self.version1Schema, at: url)

        let store = try openStore()

        XCTAssertEqual(try corruptSiblings(), [], "A version-1 database is migrated, not moved aside")
        let session = try await store.session("session-v1")
        XCTAssertEqual(session, UsageSessionMeta(sessionID: "session-v1", transcriptPath: "/t/v1.jsonl", projectRoot: "/r/v1"))
        try await store.saveRunLog(richLog, file: file(), forSession: "session-v1")
        let stored = try await store.runLog(forSession: "session-v1")
        XCTAssertEqual(stored?.log, richLog)
        await store.close()
        XCTAssertEqual(integer("PRAGMA user_version", at: url), 2)
        for table in runLogTables + ["usage_series", "usage_points", "usage_meta", "usage_process_starts",
                                     "usage_retired_processes", "usage_records", "usage_files"] {
            XCTAssertEqual(tableCount(table, at: url), 1, table)
        }
    }

    func test_databaseClaimingVersion3_isMovedAside() async throws {
        let url = try databaseURL()
        try execute("PRAGMA user_version = 3; CREATE TABLE fixture(x);", at: url)

        let store = try openStore()

        XCTAssertEqual(try corruptSiblings().count, 1)
        let stored = try await store.runLog(forSession: "session-a")
        XCTAssertNil(stored)
    }

    func test_reopen_keepsTheRunLog_withoutMovingAnythingAside() async throws {
        let first = try openStore()
        try await first.saveRunLog(richLog, file: file(), forSession: "session-a")
        await first.close()

        let second = try openStore()
        let stored = try await second.runLog(forSession: "session-a")

        XCTAssertEqual(try corruptSiblings(), [])
        XCTAssertEqual(stored?.log, richLog)
    }

    // MARK: - Closed

    func test_afterClose_everyRunLogMethodThrowsClosed() async throws {
        let store = try openStore()
        await store.close()

        await assertThrowsClosed("runLog") { try await store.runLog(forSession: "s") }
        await assertThrowsClosed("saveRunLog") { try await store.saveRunLog(UsageRunLog(), file: self.file(), forSession: "s") }
        await assertThrowsClosed("sessionsWithSeries") { try await store.sessionsWithSeries() }
        await assertThrowsClosed("setProjectRootIfUnset") { try await store.setProjectRootIfUnset("/r", forSession: "s") }
    }
}
