//
//  UsageStoreTests.swift
//  CalyxTests
//
//  Pins UsageStore (actor), the SQLite-backed store of the usage ledger:
//  owner-only file modes, a corrupt, too-new or earlier-shaped database
//  moved aside to "usage.sqlite.corrupt-*", the final schema (version 2,
//  exactly the tables the telemetry path uses), session project roots,
//  deleteAll, and close().
//
//  Earlier database shapes (version 1; version 2 that still has
//  `usage_records` / `usage_files`) are built with raw SQL through the
//  SQLite C API, from literals frozen here, never through store API.
//
//  Every database lives in a per-test temporary directory removed in
//  tearDown after every opened store is closed. All fixtures are synthetic.
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageStoreTests: XCTestCase {

    private var tempDirectory: URL?
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Helpers

    /// The directory handed to the store: a not-yet-existing nested path.
    private func temporaryDirectory() throws -> URL {
        try XCTUnwrap(tempDirectory, "Fixture error: no temporary directory")
    }

    private func storeDirectory() throws -> URL {
        try temporaryDirectory().appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
    }

    private func databaseURL() throws -> URL { try storeDirectory().appendingPathComponent("usage.sqlite") }

    /// 2027-01-15T08:00:00Z, the injected store clock of the schema tests.
    private static let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private static let clockNs: Int64 = 1_800_000_000_000_000_000

    private func openStore() throws -> UsageStore {
        let store = try UsageStore(directory: try storeDirectory())
        openedStores.append(store)
        return store
    }

    private func openStoreWithFixedClock() throws -> UsageStore {
        let store = try UsageStore(directory: try storeDirectory(), now: { UsageStoreTests.clock })
        openedStores.append(store)
        return store
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Names in the store directory that start with "usage.sqlite.corrupt-".
    private func corruptSiblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try storeDirectory().path)
            .filter { $0.hasPrefix("usage.sqlite.corrupt-") }
            .sorted()
    }

    /// Reads `PRAGMA user_version` with the SQLite C API. Returns nil when
    /// the file cannot be opened or queried as a database.
    ///
    /// Opens READWRITE on purpose: Apple's SQLite cannot open a WAL-mode
    /// database read-only when its `-wal` / `-shm` files are absent (it
    /// fails with "unable to open database file (14)"), and the store
    /// leaves no side files after `close()`. Any side files this open
    /// creates are removed when the connection closes, which the `defer`
    /// does before the function returns.
    private func userVersion(at url: URL) -> Int32? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int(statement, 0)
    }

    /// Creates a valid SQLite database whose user_version is `version`.
    private func createDatabase(at url: URL, userVersion version: Int) throws {
        try execute("PRAGMA user_version = \(version); CREATE TABLE fixture(x);", at: url)
    }

    /// Runs `sql` on a new connection to the database file, creating the
    /// directory and the file as needed. Throws on any failure, so a
    /// broken fixture fails as a fixture error, never as a store result.
    private func execute(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw FixtureError("Fixture error: sqlite3_open failed")
        }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw FixtureError("Fixture error: sqlite3_exec failed: \(text)")
        }
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The first column of every row of `sql`, as text (NULL as "NULL");
    /// nil when the file cannot be opened or the statement fails. Opens
    /// READWRITE for the same reason as `userVersion(at:)`.
    private func strings(_ sql: String, at url: URL) -> [String]? {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        var values: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return values }
            guard step == SQLITE_ROW else { return nil }
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            } else {
                values.append("NULL")
            }
        }
    }

    /// One integer from `sql`, or nil.
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

    /// The names of the database's own tables, ascending.
    private func tableNames(at url: URL) -> [String]? {
        strings("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
                at: url)
    }

    /// The names of the explicitly created indexes, ascending.
    private func indexNames(at url: URL) -> [String]? {
        strings("SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL ORDER BY name", at: url)
    }

    /// Asserts that `body` throws exactly `expected`.
    private func assertThrows<T>(
        _ expected: UsageStoreError,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected) to be thrown. \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? UsageStoreError, expected, message, file: file, line: line)
        }
    }

    private func meta(_ sessionID: String, _ root: String?) -> UsageSessionMeta {
        UsageSessionMeta(sessionID: sessionID, projectRoot: root)
    }

    private func runLogFile(_ path: String = "/t/a.jsonl", inode: UInt64 = 7, offset: UInt64 = 99) -> UsageRunLogFile {
        UsageRunLogFile(path: path, checkpoint: TranscriptCheckpoint(inode: inode, offset: offset))
    }

    /// Writes one session root and one run log through the store.
    private func writeSomething(_ store: UsageStore, session: String = "session-a") async throws {
        try await store.setProjectRootIfUnset("/r/a", forSession: session)
        try await store.saveRunLog(UsageRunLog(cwd: "/w/a"), file: runLogFile(), forSession: session)
    }

    // MARK: - Frozen schema literals

    /// The version-1 tables exactly as the first release created them.
    private static let version1Tables = """
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

    /// One synthetic row in each version-1 table.
    private static let version1Rows = """
        INSERT INTO usage_records VALUES ('msg_v1', 'session-v1', 1790935200000, 'claude-opus-5-5', 'high', \
        'main', NULL, NULL, 'main', '/tmp/project', 3, 100, 10, 9000, 120, 100, 1);
        INSERT INTO usage_sessions VALUES ('session-v1', '/t/v1.jsonl', '/r/v1');
        INSERT INTO usage_files VALUES ('/t/v1.jsonl', 7, 99);
        """

    /// The final `usage_sessions`: no transcript path.
    private static let finalSessionsTable = """
        CREATE TABLE usage_sessions (
            session_id TEXT NOT NULL PRIMARY KEY,
            project_root TEXT
        ) WITHOUT ROWID;
        """

    /// The telemetry tables, identical in the earlier version-2 layouts
    /// and in the final one.
    private static let telemetryTables = """
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
        CREATE TABLE usage_run_logs (
            session_id TEXT NOT NULL PRIMARY KEY,
            path TEXT NOT NULL,
            inode INTEGER NOT NULL,
            offset INTEGER NOT NULL,
            open_begin_ns INTEGER,
            open_end_ns INTEGER,
            cwd TEXT
        ) WITHOUT ROWID;
        CREATE TABLE usage_runs (
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            begin_ns INTEGER,
            end_ns INTEGER,
            PRIMARY KEY (session_id, sequence)
        ) WITHOUT ROWID;
        CREATE TABLE usage_run_totals (
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_creation_tokens INTEGER NOT NULL,
            PRIMARY KEY (session_id, sequence, model)
        ) WITHOUT ROWID;
        CREATE TABLE usage_unreported (
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            model TEXT NOT NULL,
            time_ns INTEGER NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_creation_tokens INTEGER NOT NULL,
            PRIMARY KEY (session_id, sequence, model)
        ) WITHOUT ROWID;
        """

    /// The two time-range indexes (R2c rule 10: optional).
    private static let timeRangeIndexes = """
        CREATE INDEX usage_points_minute ON usage_points (minute);
        CREATE INDEX usage_unreported_time ON usage_unreported (time_ns);
        """

    /// The final layout without data.
    private static let finalSchema = finalSessionsTable + telemetryTables + timeRangeIndexes

    /// One synthetic row in every final table, `tracked_from_ns` = 1234
    /// and tracking paused, so a database that was recreated instead of
    /// opened in place is visible.
    private static let finalRows = """
        INSERT INTO usage_meta VALUES ('tracked_from_ns', 1234);
        INSERT INTO usage_meta VALUES ('tracking_active', 0);
        INSERT INTO usage_sessions VALUES ('session-f', '/r/f');
        INSERT INTO usage_series VALUES ('session-f', 'series-1', 100, 'input', 'claude-opus-5-5', 42, 200, 300);
        INSERT INTO usage_points VALUES ('session-f', 29000000, 'claude-opus-5-5', 'high', NULL, NULL, 1, 2, 3, 4);
        INSERT INTO usage_process_starts VALUES ('session-f', 100, 'fresh');
        INSERT INTO usage_retired_processes VALUES ('digest-1');
        INSERT INTO usage_run_logs VALUES ('session-f', '/t/f.jsonl', 7, 99, NULL, NULL, '/w/f');
        INSERT INTO usage_runs VALUES ('session-f', 1, 10, 20);
        INSERT INTO usage_run_totals VALUES ('session-f', 1, 'claude-opus-5-5', 11, 12, 13, 14);
        INSERT INTO usage_unreported VALUES ('session-f', 1, 'claude-opus-5-5', 20, 5, 6, 7, 8);
        """

    /// Every table of the final layout, ascending (SQLite BINARY order).
    private static let finalTables = [
        "usage_meta", "usage_points", "usage_process_starts", "usage_retired_processes",
        "usage_run_logs", "usage_run_totals", "usage_runs", "usage_series", "usage_sessions",
        "usage_unreported",
    ]

    /// Every explicitly created index of the final layout, ascending.
    private static let finalIndexes = ["usage_points_group", "usage_points_minute", "usage_unreported_time"]

    /// Asserts the database at `databaseURL` (closed) is a fresh final one
    /// started at the fixed clock.
    private func assertFreshFinalDatabase(
        _ store: UsageStore, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let trackedFrom = try await store.trackedFromNs()
        XCTAssertEqual(trackedFrom, Self.clockNs, "A fresh database tracks from the store's clock", file: file, line: line)
        let points = try await store.pointRows()
        XCTAssertEqual(points, [], "The fresh database starts empty", file: file, line: line)
        await store.close()
        XCTAssertEqual(userVersion(at: try databaseURL()), 2, file: file, line: line)
        XCTAssertEqual(tableNames(at: try databaseURL()), Self.finalTables, file: file, line: line)
    }

    // MARK: - Opening: names and modes

    func test_databaseFileName_isUsageSqlite() {
        XCTAssertEqual(UsageStore.databaseFileName, "usage.sqlite")
    }

    func test_init_createsIntermediateDirectoriesWithMode0700() throws {
        XCTAssertFalse(exists(try storeDirectory()), "Fixture error: the directory must not exist yet")

        _ = try openStore()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: try storeDirectory().path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try mode(of: try storeDirectory()), 0o700)
    }

    func test_init_createsDatabaseFileWithMode0600() throws {
        _ = try openStore()

        XCTAssertTrue(exists(try databaseURL()))
        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)
    }

    func test_openStoreAfterWriting_databaseAndSideFilesAre0600() async throws {
        let store = try openStore()
        try await writeSomething(store)

        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)
        for suffix in ["-wal", "-shm"] {
            let sideFile = try storeDirectory().appendingPathComponent("usage.sqlite" + suffix)
            if exists(sideFile) {
                XCTAssertEqual(try mode(of: sideFile), 0o600, "usage.sqlite\(suffix) must be owner-only")
            }
        }
    }

    func test_init_freshDatabase_hasUserVersion2() async throws {
        let store = try openStore()
        await store.close()

        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
    }

    // MARK: - Persistence across close / reopen

    func test_reopenAfterClose_seesSessionsAndRunLogs() async throws {
        let first = try openStore()
        try await writeSomething(first)
        await first.close()

        let second = try openStore()

        let session = try await second.session("session-a")
        let runLog = try await second.runLog(forSession: "session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
        XCTAssertEqual(runLog?.file, runLogFile())
        XCTAssertEqual(runLog?.log, UsageRunLog(cwd: "/w/a"))
        XCTAssertEqual(try corruptSiblings(), [], "A healthy database must not be moved aside on reopen")
    }

    // MARK: - Corrupt or too-new database

    func test_init_existingFileIsNotASQLiteDatabase_movesItAsideAndStartsFresh() async throws {
        try FileManager.default.createDirectory(at: try storeDirectory(), withIntermediateDirectories: true)
        // 16 KiB of non-SQLite bytes: larger than a page, so SQLite cannot
        // mistake the file for an empty database.
        let garbage = Data(repeating: UInt8(ascii: "g"), count: 16_384)
        try garbage.write(to: try databaseURL())

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            let moved = try Data(contentsOf: try storeDirectory().appendingPathComponent(sibling))
            XCTAssertEqual(moved, garbage, "The moved-aside file must keep the original bytes")
        }

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)

        await store.close()
        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
    }

    func test_init_existingDatabaseWithNewerUserVersion_movesItAsideAndStartsFresh() async throws {
        try createDatabase(at: try databaseURL(), userVersion: 999)
        XCTAssertEqual(userVersion(at: try databaseURL()), 999, "Fixture error")

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(userVersion(at: try storeDirectory().appendingPathComponent(sibling)), 999,
                           "The moved-aside file must be the original version-999 database")
        }

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))

        await store.close()
        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
    }

    // MARK: - close()

    func test_close_leavesNoWalOrShmFile() async throws {
        let store = try openStore()
        try await writeSomething(store)

        await store.close()

        XCTAssertTrue(exists(try databaseURL()))
        XCTAssertFalse(exists(try storeDirectory().appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(try storeDirectory().appendingPathComponent("usage.sqlite-shm")))
    }

    func test_close_calledTwice_isIdempotent() async throws {
        let store = try openStore()
        try await writeSomething(store)

        await store.close()
        await store.close()

        XCTAssertFalse(exists(try storeDirectory().appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(try storeDirectory().appendingPathComponent("usage.sqlite-shm")))
        let reopened = try openStore()
        let session = try await reopened.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
    }

    func test_afterClose_everyOtherMethodThrowsClosed() async throws {
        let store = try openStore()
        try await writeSomething(store)
        await store.close()

        let utc = Calendar(identifier: .gregorian)
        await assertThrows(.closed, "session") { try await store.session("session-a") }
        await assertThrows(.closed, "setProjectRootIfUnset") {
            try await store.setProjectRootIfUnset("/r/b", forSession: "session-b")
        }
        await assertThrows(.closed, "tokenReport") { try await store.tokenReport(UsageTokenQuery(), calendar: utc) }
        await assertThrows(.closed, "deleteAll") { try await store.deleteAll() }
    }

    // MARK: - deleteAll

    func test_deleteAll_removesSessionsAndRunLogs() async throws {
        let store = try openStore()
        try await writeSomething(store, session: "session-a")
        try await store.setProjectRootIfUnset("/r/b", forSession: "session-b")

        try await store.deleteAll()

        let sessionA = try await store.session("session-a")
        let sessionB = try await store.session("session-b")
        let runLog = try await store.runLog(forSession: "session-a")
        XCTAssertNil(sessionA)
        XCTAssertNil(sessionB)
        XCTAssertNil(runLog)
    }

    func test_deleteAll_storeStaysUsable_andAnEarlierRootNoLongerWins() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/old", forSession: "session-a")
        try await store.deleteAll()

        try await store.setProjectRootIfUnset("/r/new", forSession: "session-a")

        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/new"))
    }

    // MARK: - Pinned decisions

    /// Reads `PRAGMA journal_mode` with the SQLite C API. The WAL mode is
    /// persistent in the database file.
    private func journalMode(at url: URL) -> String? {
        strings("PRAGMA journal_mode", at: url)?.first
    }

    func test_openStoreAfterWriting_walFileExistsWithMode0600() async throws {
        let store = try openStore()

        try await writeSomething(store)

        let wal = try storeDirectory().appendingPathComponent("usage.sqlite-wal")
        XCTAssertTrue(exists(wal), "The store must run in WAL mode: usage.sqlite-wal must exist after a write")
        if exists(wal) {
            XCTAssertEqual(try mode(of: wal), 0o600)
        }
        let shm = try storeDirectory().appendingPathComponent("usage.sqlite-shm")
        if exists(shm) {
            XCTAssertEqual(try mode(of: shm), 0o600)
        }
    }

    func test_close_databaseFileIsInWALJournalMode() async throws {
        let store = try openStore()
        try await writeSomething(store)

        await store.close()

        XCTAssertEqual(journalMode(at: try databaseURL())?.lowercased(), "wal")
    }

    func test_init_existingDirectoryWithMode0755_isTightenedTo0700() throws {
        try FileManager.default.createDirectory(
            at: try storeDirectory(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        // createDirectory applies the umask; set the mode explicitly.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: try storeDirectory().path)
        XCTAssertEqual(try mode(of: try storeDirectory()), 0o755, "Fixture error")

        _ = try openStore()

        XCTAssertEqual(try mode(of: try storeDirectory()), 0o700)
        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)
    }

    func test_init_existingZeroByteDatabaseFile_isInitialisedAsFreshNotMovedAside() async throws {
        try FileManager.default.createDirectory(at: try storeDirectory(), withIntermediateDirectories: true)
        try Data().write(to: try databaseURL())
        XCTAssertTrue(exists(try databaseURL()), "Fixture error")

        let store = try openStore()

        XCTAssertEqual(try corruptSiblings(), [], "A zero-byte file is a fresh database, not a corrupt one")
        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)

        await store.close()
        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
        XCTAssertEqual(try corruptSiblings(), [])
    }

    // MARK: - Incompatible schema

    /// True when the database at `url` has a table named `name`.
    private func tableExists(_ name: String, at url: URL) -> Bool {
        integer("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'", at: url) == 1
    }

    func test_init_existingDatabaseAtUserVersion1WithoutStoreTables_movesItAsideAndStartsFresh() async throws {
        // A valid SQLite database, user_version 1, holding only the
        // unrelated table "fixture".
        try createDatabase(at: try databaseURL(), userVersion: 1)
        XCTAssertEqual(userVersion(at: try databaseURL()), 1, "Fixture error")
        XCTAssertTrue(tableExists("fixture", at: try databaseURL()), "Fixture error")

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertTrue(tableExists("fixture", at: try storeDirectory().appendingPathComponent(sibling)),
                          "The moved-aside file must still contain the unrelated table")
        }

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))

        await store.close()
        XCTAssertFalse(tableExists("fixture", at: try databaseURL()), "The fresh database must not contain the unrelated table")
        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
    }

    // MARK: - Review A1: corrupt data page

    func test_init_databaseWithCorruptDataPage_movesItAsideAndStartsFresh() async throws {
        let first = try openStore()
        await first.close()
        // 3000 session rows in one transaction, written with raw SQL into
        // the store's own (final) schema: enough pages to damage late ones.
        var inserts = "BEGIN;"
        for index in 0..<3_000 {
            inserts += "INSERT INTO usage_sessions (session_id, project_root) VALUES "
                + "('session-old-\(String(format: "%05d", index))', '/r/old/\(index)');"
        }
        inserts += "COMMIT;"
        try execute(inserts, at: try databaseURL())

        // Overwrite two late 4 KiB pages with garbage; page 1 (header and
        // schema root) stays intact.
        let pageSize = 4_096
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: try databaseURL().path)[.size] as? NSNumber).intValue
        let pageCount = size / pageSize
        XCTAssertGreaterThanOrEqual(pageCount, 8, "Fixture error: the database must be several pages long")
        guard pageCount >= 8 else { return }
        let handle = try FileHandle(forUpdating: try databaseURL())
        try handle.seek(toOffset: UInt64((pageCount - 3) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 2 * pageSize))
        try handle.close()

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "A database with a corrupt data page must be moved aside. Got: \(siblings)")

        let old = try await store.session("session-old-00000")
        XCTAssertNil(old, "The fresh store must hold no old data")

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
    }

    // MARK: - Review A2: symlink at the database path

    private func fileType(of url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    func test_init_databasePathIsSymlinkToUnrelatedFile_neverFollowsTheLink() async throws {
        let target = try temporaryDirectory().appendingPathComponent("unrelated.txt")
        let targetBytes = Data("unrelated file, not a database\n".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(at: try storeDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: try databaseURL(), withDestinationURL: target)
        XCTAssertEqual(try fileType(of: try databaseURL()), .typeSymbolicLink, "Fixture error")
        XCTAssertEqual(try mode(of: target), 0o644, "Fixture error")

        let store = try openStore()

        XCTAssertEqual(try mode(of: target), 0o644, "The link target's mode must not be changed")
        XCTAssertEqual(try Data(contentsOf: target), targetBytes, "The link target's bytes must not be changed")

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(try fileType(of: try storeDirectory().appendingPathComponent(sibling)), .typeSymbolicLink,
                           "The moved-aside item must be the link itself")
        }
        XCTAssertEqual(try fileType(of: try databaseURL()), .typeRegular, "usage.sqlite must now be a regular file")
        XCTAssertEqual(try mode(of: try databaseURL()), 0o600)

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))

        await store.close()
        XCTAssertEqual(try mode(of: target), 0o644)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func test_init_databasePathIsSymlinkToAnotherStoreDatabase_neitherOpensNorModifiesIt() async throws {
        let otherDirectory = try temporaryDirectory().appendingPathComponent("other-store", isDirectory: true)
        let other = try UsageStore(directory: otherDirectory)
        openedStores.append(other)
        try await other.setProjectRootIfUnset("/r/foreign", forSession: "session-foreign")
        await other.close()
        let otherDatabase = otherDirectory.appendingPathComponent("usage.sqlite")
        let otherBytes = try Data(contentsOf: otherDatabase)
        let otherMode = try mode(of: otherDatabase)

        try FileManager.default.createDirectory(at: try storeDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: try databaseURL(), withDestinationURL: otherDatabase)
        XCTAssertEqual(try fileType(of: try databaseURL()), .typeSymbolicLink, "Fixture error")

        let store = try openStore()

        let seen = try await store.session("session-foreign")
        XCTAssertNil(seen, "The store must not open the database behind the link")
        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(try fileType(of: try storeDirectory().appendingPathComponent(sibling)), .typeSymbolicLink)
        }
        XCTAssertEqual(try fileType(of: try databaseURL()), .typeRegular)

        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        let session = try await store.session("session-a")
        XCTAssertEqual(session, meta("session-a", "/r/a"))
        await store.close()

        XCTAssertEqual(try Data(contentsOf: otherDatabase), otherBytes, "The linked database must not be modified")
        XCTAssertEqual(try mode(of: otherDatabase), otherMode)
        XCTAssertFalse(exists(otherDirectory.appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(otherDirectory.appendingPathComponent("usage.sqlite-shm")))
    }

    // MARK: - Review A3: embedded NUL in text columns

    func test_projectRootWithEmbeddedNUL_roundTripsByteExactly() async throws {
        let store = try openStore()
        let root = "/tmp/a\u{0}b/c"

        try await store.setProjectRootIfUnset(root, forSession: "session-a")

        let session = try await store.session("session-a")
        XCTAssertEqual(session?.projectRoot.map { Array($0.utf8) }, Array(root.utf8))
    }

    // MARK: - Review B1: a lock error propagates, never a move-aside

    func test_init_databaseLockedExclusivelyByAnotherHandle_throwsBusyAndMovesNothingAside() throws {
        try createDatabase(at: try databaseURL(), userVersion: 1)

        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(try databaseURL().path, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
                       "Fixture error: could not open the lock holder")
        var released = false
        func release() {
            guard !released else { return }
            released = true
            sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
            sqlite3_close(holder)
        }
        defer { release() }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK,
                       "Fixture error: could not take the exclusive lock")

        do {
            let store = try UsageStore(directory: try storeDirectory())
            openedStores.append(store)
            XCTFail("init must throw while another handle holds an exclusive lock")
        } catch {
            XCTAssertEqual((error as? SQLiteError)?.primaryCode, SQLITE_BUSY, "Got: \(error)")
        }

        XCTAssertEqual(try corruptSiblings(), [], "A lock error must never move the database aside")

        release()
        XCTAssertTrue(exists(try databaseURL()))
        XCTAssertEqual(userVersion(at: try databaseURL()), 1)
        XCTAssertTrue(tableExists("fixture", at: try databaseURL()), "The locked database must be untouched")
    }

    // MARK: - session(_:)

    func test_session_unknownID_isNil() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")

        let unknown = try await store.session("session-zzz")

        XCTAssertNil(unknown)
    }

    func test_session_freshStore_isNil() async throws {
        let store = try openStore()

        let session = try await store.session("session-a")

        XCTAssertNil(session)
    }

    func test_session_runLogAloneCreatesNoSessionRow() async throws {
        let store = try openStore()
        try await store.saveRunLog(UsageRunLog(cwd: "/w/a"), file: runLogFile(), forSession: "session-a")

        let session = try await store.session("session-a")

        XCTAssertNil(session, "A run log alone creates no session row")
    }

    func test_session_returnsOnlyTheRequestedSession() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        try await store.setProjectRootIfUnset("/r/b", forSession: "session-b")

        let sessionA = try await store.session("session-a")
        let sessionB = try await store.session("session-b")

        XCTAssertEqual(sessionA, meta("session-a", "/r/a"))
        XCTAssertEqual(sessionB, meta("session-b", "/r/b"))
    }

    func test_session_secondRoot_stillReturnsTheFirst() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/first", forSession: "session-a")
        try await store.setProjectRootIfUnset("/r/second", forSession: "session-a")

        let session = try await store.session("session-a")

        XCTAssertEqual(session, meta("session-a", "/r/first"))
    }

    func test_session_afterDeleteAll_isNil() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        try await store.deleteAll()

        let session = try await store.session("session-a")

        XCTAssertNil(session)
    }

    func test_session_afterClose_throwsClosed() async throws {
        let store = try openStore()
        try await store.setProjectRootIfUnset("/r/a", forSession: "session-a")
        await store.close()

        await assertThrows(.closed, "session") { try await store.session("session-a") }
    }

    // MARK: - R5d: the final schema

    func test_freshDatabase_hasExactlyTheFinalTablesAndIndexes() async throws {
        let store = try openStoreWithFixedClock()
        await store.close()

        XCTAssertEqual(userVersion(at: try databaseURL()), 2)
        XCTAssertEqual(tableNames(at: try databaseURL()), Self.finalTables)
        XCTAssertEqual(indexNames(at: try databaseURL()), Self.finalIndexes)
    }

    func test_freshDatabase_usageSessionsHasOnlySessionIDAndProjectRoot() async throws {
        let store = try openStoreWithFixedClock()
        await store.close()

        XCTAssertEqual(strings("SELECT name FROM pragma_table_info('usage_sessions') ORDER BY cid", at: try databaseURL()),
                       ["session_id", "project_root"])
    }

    func test_version1Database_isMovedAside_andReplacedByAFreshFinalDatabase() async throws {
        try execute(Self.version1Tables + Self.version1Rows + "PRAGMA user_version = 1;", at: try databaseURL())
        XCTAssertEqual(userVersion(at: try databaseURL()), 1, "Fixture error")

        let store = try openStoreWithFixedClock()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "A version-1 database must be moved aside. Got: \(siblings)")
        if let sibling = siblings.first {
            let moved = try storeDirectory().appendingPathComponent(sibling)
            XCTAssertEqual(userVersion(at: moved), 1, "The moved-aside file must be the original database")
            XCTAssertEqual(integer("SELECT count(*) FROM usage_records", at: moved), 1)
            XCTAssertEqual(integer("SELECT count(*) FROM usage_files", at: moved), 1)
        }
        let session = try await store.session("session-v1")
        XCTAssertNil(session, "Nothing of the version-1 file is carried over")
        try await assertFreshFinalDatabase(store)
    }

    func test_earlierVersion2DatabaseWithRecordsAndFiles_isMovedAside_andReplacedByAFreshFinalDatabase() async throws {
        // The version-2 layout before R5d: the version-1 tables (with
        // `usage_sessions.transcript_path`) plus every telemetry table.
        try execute(
            Self.version1Tables + Self.telemetryTables + Self.timeRangeIndexes + Self.version1Rows + """
                INSERT INTO usage_meta VALUES ('tracked_from_ns', 1234);
                INSERT INTO usage_points VALUES ('session-v1', 29000000, 'claude-opus-5-5', 'high', NULL, NULL, 1, 2, 3, 4);
                PRAGMA user_version = 2;
                """,
            at: try databaseURL())
        XCTAssertEqual(userVersion(at: try databaseURL()), 2, "Fixture error")

        let store = try openStoreWithFixedClock()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "An earlier version-2 layout must be moved aside. Got: \(siblings)")
        if let sibling = siblings.first {
            let moved = try storeDirectory().appendingPathComponent(sibling)
            XCTAssertEqual(integer("SELECT count(*) FROM usage_records", at: moved), 1)
            XCTAssertEqual(integer("SELECT count(*) FROM usage_points", at: moved), 1)
        }
        let session = try await store.session("session-v1")
        XCTAssertNil(session)
        try await assertFreshFinalDatabase(store)
    }

    func test_finalLayoutPlusUsageRecords_isMovedAside() async throws {
        let records = """
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
            """
        try execute(Self.finalSchema + records + Self.finalRows + "PRAGMA user_version = 2;", at: try databaseURL())

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings().count, 1, "A file still holding usage_records must be moved aside")
        let session = try await store.session("session-f")
        XCTAssertNil(session)
        try await assertFreshFinalDatabase(store)
    }

    func test_finalLayoutPlusUsageFiles_isMovedAside() async throws {
        let files = """
            CREATE TABLE usage_files (
                path TEXT NOT NULL PRIMARY KEY,
                inode INTEGER NOT NULL,
                offset INTEGER NOT NULL
            ) WITHOUT ROWID;
            """
        try execute(Self.finalSchema + files + Self.finalRows + "PRAGMA user_version = 2;", at: try databaseURL())

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings().count, 1, "A file still holding usage_files must be moved aside")
        let session = try await store.session("session-f")
        XCTAssertNil(session)
        try await assertFreshFinalDatabase(store)
    }

    /// Runs `sql` (a final layout altered by the caller, without rows),
    /// opens the store and asserts the file was moved aside and replaced.
    private func assertMovedAsideAndReplaced(
        _ sql: String, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try execute(sql + "PRAGMA user_version = 2;", at: try databaseURL())
        XCTAssertEqual(userVersion(at: try databaseURL()), 2, "Fixture error", file: file, line: line)

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings().count, 1, message, file: file, line: line)
        try await assertFreshFinalDatabase(store, file: file, line: line)
    }

    /// `finalSchema` with `original` (which must occur in it) replaced.
    private func finalSchema(replacing original: String, with replacement: String) throws -> String {
        guard Self.finalSchema.contains(original) else { throw FixtureError("Fixture error: \(original) not found") }
        return Self.finalSchema.replacingOccurrences(of: original, with: replacement)
    }

    func test_finalTablesWithUsageSessionsTranscriptPathStillPresent_isMovedAside() async throws {
        let sql = try finalSchema(
            replacing: "session_id TEXT NOT NULL PRIMARY KEY,\n    project_root TEXT",
            with: "session_id TEXT NOT NULL PRIMARY KEY,\n    transcript_path TEXT,\n    project_root TEXT")
        try await assertMovedAsideAndReplaced(sql, "usage_sessions.transcript_path is an earlier layout")
    }

    func test_finalLayoutPlusAnUnknownTable_isMovedAside() async throws {
        try await assertMovedAsideAndReplaced(
            Self.finalSchema + "CREATE TABLE usage_extra (x INTEGER);", "An extra table is not the final layout")
    }

    func test_finalLayoutWithATableMissingOneColumn_isMovedAside() async throws {
        let sql = try finalSchema(
            replacing: "last_time_ns INTEGER NOT NULL,\n    first_heard_ns INTEGER NOT NULL,",
            with: "last_time_ns INTEGER NOT NULL,")
        try await assertMovedAsideAndReplaced(sql, "usage_series without first_heard_ns is not the final layout")
    }

    func test_finalLayoutWithAnExtraTrailingColumn_isMovedAside() async throws {
        let sql = try finalSchema(
            replacing: "cache_creation_tokens INTEGER NOT NULL\n);",
            with: "cache_creation_tokens INTEGER NOT NULL,\n    extra TEXT\n);")
        try await assertMovedAsideAndReplaced(sql, "usage_points with an extra column is not the final layout")
    }

    func test_finalLayoutWithColumnsInAnotherOrder_isMovedAside() async throws {
        let sql = try finalSchema(
            replacing: "session_id TEXT NOT NULL PRIMARY KEY,\n    project_root TEXT",
            with: "project_root TEXT,\n    session_id TEXT NOT NULL PRIMARY KEY")
        try await assertMovedAsideAndReplaced(sql, "Columns are compared in order")
    }

    func test_version0DatabaseHoldingATable_isMovedAside_andReplacedByAFreshFinalDatabase() async throws {
        try createDatabase(at: try databaseURL(), userVersion: 0)
        XCTAssertTrue(tableExists("fixture", at: try databaseURL()), "Fixture error")

        let store = try openStoreWithFixedClock()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Only an empty version-0 file is a new database. Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertTrue(tableExists("fixture", at: try storeDirectory().appendingPathComponent(sibling)))
        }
        try await assertFreshFinalDatabase(store)
    }

    /// Asserts the store reads back exactly `finalRows`.
    private func assertFinalRows(_ store: UsageStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let trackedFrom = try await store.trackedFromNs()
        let active = try await store.isTrackingActive()
        let session = try await store.session("session-f")
        let series = try await store.seriesRows()
        let points = try await store.pointRows()
        let starts = try await store.processStarts()
        let retired = try await store.retiredProcessCount()
        let runLog = try await store.runLog(forSession: "session-f")
        let unreported = try await store.unreportedRows()
        XCTAssertEqual(trackedFrom, 1234, "tracked_from_ns must be the stored one, not the clock", file: file, line: line)
        XCTAssertFalse(active, file: file, line: line)
        XCTAssertEqual(session, meta("session-f", "/r/f"), file: file, line: line)
        XCTAssertEqual(series, [UsageSeriesRow(
            sessionID: "session-f", seriesID: "series-1", startNs: 100, kind: .input, model: "claude-opus-5-5",
            lastValue: 42, lastTimeNs: 200, firstHeardNs: 300)], file: file, line: line)
        XCTAssertEqual(points, [UsagePointRow(
            sessionID: "session-f", minute: 29_000_000, model: "claude-opus-5-5", effort: "high", thread: nil,
            agent: nil, inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4)],
            file: file, line: line)
        XCTAssertEqual(starts, [UsageProcessStart(sessionID: "session-f", startNs: 100, startType: "fresh")],
                       file: file, line: line)
        XCTAssertEqual(retired, 1, file: file, line: line)
        XCTAssertEqual(runLog?.file, runLogFile("/t/f.jsonl"), file: file, line: line)
        XCTAssertEqual(runLog?.log, UsageRunLog(
            runs: [UsageRun(sequence: 1, beginNs: 10, endNs: 20, totals: [
                "claude-opus-5-5": UsageTokenTotals(input: 11, output: 12, cacheRead: 13, cacheCreation: 14),
            ])],
            openBeginNs: nil, openEndNs: nil, cwd: "/w/f"), file: file, line: line)
        XCTAssertEqual(unreported, [UsageUnreportedStoredRow(
            sessionID: "session-f", sequence: 1, timeNs: 20, model: "claude-opus-5-5",
            totals: UsageTokenTotals(input: 5, output: 6, cacheRead: 7, cacheCreation: 8))], file: file, line: line)
    }

    func test_finalLayout_opensInPlace_withItsData() async throws {
        try execute(Self.finalSchema + Self.finalRows + "PRAGMA user_version = 2;", at: try databaseURL())
        XCTAssertEqual(tableNames(at: try databaseURL()), Self.finalTables, "Fixture error")

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings(), [], "The final layout must open in place")
        try await assertFinalRows(store)
    }

    func test_finalLayoutWithoutTheTimeRangeIndexes_opensInPlace_withItsData() async throws {
        try execute(Self.finalSessionsTable + Self.telemetryTables + Self.finalRows + "PRAGMA user_version = 2;",
                    at: try databaseURL())
        XCTAssertEqual(indexNames(at: try databaseURL()), ["usage_points_group"], "Fixture error")

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings(), [], "A missing index must not move the database aside")
        try await assertFinalRows(store)
    }

    // MARK: - R5d review round 1

    func test_finalLayoutAfterANALYZE_reopensInPlace_withItsData() async throws {
        try execute(Self.finalSchema + Self.finalRows + "PRAGMA user_version = 2; ANALYZE;", at: try databaseURL())
        XCTAssertTrue(tableExists("sqlite_stat1", at: try databaseURL()),
                      "Fixture error: ANALYZE must have created sqlite_stat1")

        let store = try openStoreWithFixedClock()

        XCTAssertEqual(try corruptSiblings(), [], "SQLite's own statistics tables are not part of the layout")
        try await assertFinalRows(store)
        await store.close()
        XCTAssertTrue(tableExists("sqlite_stat1", at: try databaseURL()), "The file must be the one opened in place")
    }

    /// Runs `sql` on the database at `url` with the system `sqlite3` tool.
    /// Used only where the C API cannot build the fixture: its connections
    /// run in defensive mode, which forbids `PRAGMA writable_schema`
    /// edits of `sqlite_master`, and `sqlite3_db_config` (the switch) is a
    /// C variadic function Swift cannot call. `-init /dev/null` keeps any
    /// personal `~/.sqliterc` out of the fixture.
    private func executeWithSQLiteTool(_ sql: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tool = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw FixtureError("Fixture error: /usr/bin/sqlite3 is missing")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-batch", "-bail", "-init", "/dev/null", url.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError("Fixture error: sqlite3 exited with \(process.terminationStatus)")
        }
    }

    func test_version2FileWhoseLayoutCannotBeRead_isMovedAside_andReplacedByAFreshFinalDatabase() async throws {
        // A table of a module this SQLite does not have: listing the tables
        // works, but `pragma_table_info` on it fails with SQLITE_ERROR
        // ("no such module"), deterministically, on every open.
        try executeWithSQLiteTool("""
            CREATE TABLE usage_meta (key TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;
            PRAGMA writable_schema = ON;
            INSERT INTO sqlite_master (type, name, tbl_name, rootpage, sql) VALUES \
            ('table', 'usage_foreign', 'usage_foreign', 0, 'CREATE VIRTUAL TABLE usage_foreign USING calyx_no_such_module()');
            PRAGMA writable_schema = OFF;
            PRAGMA user_version = 2;
            """, at: try databaseURL())
        XCTAssertEqual(userVersion(at: try databaseURL()), 2, "Fixture error")
        XCTAssertTrue(tableExists("usage_foreign", at: try databaseURL()), "Fixture error")
        XCTAssertNil(strings("SELECT name FROM pragma_table_info('usage_foreign')", at: try databaseURL()),
                     "Fixture error: the layout of the file must be unreadable")

        let store = try openStoreWithFixedClock()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "A file whose layout cannot be read must be moved aside. Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertTrue(tableExists("usage_foreign", at: try storeDirectory().appendingPathComponent(sibling)),
                          "The moved-aside file must be the original one")
        }
        try await assertFreshFinalDatabase(store)
    }
}
