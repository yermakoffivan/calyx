//
//  UsageStoreTests.swift
//  CalyxTests
//
//  Pins UsageStore (actor), the SQLite-backed Silver layer of the usage
//  ledger: owner-only file modes, a corrupt or too-new database moved
//  aside to "usage.sqlite.corrupt-*", atomic batches (records + session
//  meta + file checkpoint in one transaction), per-key winner folding via
//  UsageRecord.winner, session meta merge rules, checkpoints, deleteAll,
//  and close().
//
//  Every database lives in a per-test temporary directory removed in
//  tearDown after every opened store is closed. All fixtures are synthetic.
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageStoreTests: XCTestCase {

    private var tempDirectory: URL!
    private var openedStores: [UsageStore] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
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
    private var storeDirectory: URL {
        tempDirectory.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("usage", isDirectory: true)
    }

    private var databaseURL: URL { storeDirectory.appendingPathComponent("usage.sqlite") }

    private func openStore() throws -> UsageStore {
        let store = try UsageStore(directory: storeDirectory)
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
        try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK, "Fixture error: sqlite3_open failed")
        XCTAssertEqual(
            sqlite3_exec(database, "PRAGMA user_version = \(version); CREATE TABLE fixture(x);", nil, nil, nil),
            SQLITE_OK, "Fixture error: sqlite3_exec failed")
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK, "Fixture error: sqlite3_close failed")
    }

    private func makeRecord(
        key: String = "msg_01",
        sessionID: String = "session-a",
        timestampMs: Int64 = 1_790_935_200_000,
        model: String = "claude-opus-5-5",
        effort: String? = "high",
        thread: UsageRecord.Thread = .main,
        agentID: String? = nil,
        agentType: String? = nil,
        gitBranch: String? = "main",
        cwd: String? = "/tmp/project",
        inputTokens: Int64 = 3,
        outputTokens: Int64 = 100,
        thinkingTokens: Int64 = 10,
        cacheReadTokens: Int64 = 9_000,
        cacheCreationTokens: Int64 = 120,
        cacheCreation1hTokens: Int64 = 100,
        isFinal: Bool = true
    ) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID,
            timestampMs: timestampMs,
            model: model,
            effort: effort,
            thread: thread,
            agentID: agentID,
            agentType: agentType,
            gitBranch: gitBranch,
            cwd: cwd,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            isFinal: isFinal
        )
    }

    private func batch(
        _ records: [UsageRecord] = [],
        session: UsageSessionMeta? = nil,
        fileCheckpoint: UsageFileCheckpoint? = nil
    ) -> UsageBatch {
        UsageBatch(records: records, session: session, fileCheckpoint: fileCheckpoint)
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

    // The three lines of one response: two partial lines, then the final one.
    private var partialEarly: UsageRecord {
        makeRecord(timestampMs: 1_790_935_200_000, outputTokens: 8, thinkingTokens: 0, isFinal: false)
    }
    private var partialLate: UsageRecord {
        makeRecord(timestampMs: 1_790_935_201_000, outputTokens: 60, thinkingTokens: 0, isFinal: false)
    }
    private var finalLine: UsageRecord {
        makeRecord(timestampMs: 1_790_935_202_000, outputTokens: 420, thinkingTokens: 150, isFinal: true)
    }

    // MARK: - Opening: names and modes

    func test_databaseFileName_isUsageSqlite() {
        XCTAssertEqual(UsageStore.databaseFileName, "usage.sqlite")
    }

    func test_init_createsIntermediateDirectoriesWithMode0700() throws {
        XCTAssertFalse(exists(storeDirectory), "Fixture error: the directory must not exist yet")

        _ = try openStore()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try mode(of: storeDirectory), 0o700)
    }

    func test_init_createsDatabaseFileWithMode0600() throws {
        _ = try openStore()

        XCTAssertTrue(exists(databaseURL))
        XCTAssertEqual(try mode(of: databaseURL), 0o600)
    }

    func test_openStoreAfterWriting_databaseAndSideFilesAre0600() async throws {
        let store = try openStore()
        try await store.apply(batch(
            [finalLine],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 99))
        ))

        XCTAssertEqual(try mode(of: databaseURL), 0o600)
        for suffix in ["-wal", "-shm"] {
            let sideFile = storeDirectory.appendingPathComponent("usage.sqlite" + suffix)
            if exists(sideFile) {
                XCTAssertEqual(try mode(of: sideFile), 0o600, "usage.sqlite\(suffix) must be owner-only")
            }
        }
    }

    func test_init_freshDatabase_hasUserVersion1() async throws {
        let store = try openStore()
        await store.close()

        XCTAssertEqual(userVersion(at: databaseURL), 1)
    }

    // MARK: - Persistence across close / reopen

    func test_reopenAfterClose_seesRecordsSessionsAndCheckpoints() async throws {
        let first = try openStore()
        try await first.apply(batch(
            [finalLine],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 99))
        ))
        await first.close()

        let second = try openStore()

        let records = try await second.records(forSession: "session-a")
        let sessions = try await second.sessions()
        let checkpoint = try await second.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(records, [finalLine])
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
        ])
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 7, offset: 99))
        XCTAssertEqual(try corruptSiblings(), [], "A healthy database must not be moved aside on reopen")
    }

    // MARK: - Corrupt or too-new database

    func test_init_existingFileIsNotASQLiteDatabase_movesItAsideAndStartsFresh() async throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        // 16 KiB of non-SQLite bytes: larger than a page, so SQLite cannot
        // mistake the file for an empty database.
        let garbage = Data(repeating: UInt8(ascii: "g"), count: 16_384)
        try garbage.write(to: databaseURL)

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            let moved = try Data(contentsOf: storeDirectory.appendingPathComponent(sibling))
            XCTAssertEqual(moved, garbage, "The moved-aside file must keep the original bytes")
        }

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
        XCTAssertEqual(try mode(of: databaseURL), 0o600)

        await store.close()
        XCTAssertEqual(userVersion(at: databaseURL), 1)
    }

    func test_init_existingDatabaseWithNewerUserVersion_movesItAsideAndStartsFresh() async throws {
        try createDatabase(at: databaseURL, userVersion: 999)
        XCTAssertEqual(userVersion(at: databaseURL), 999, "Fixture error")

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(userVersion(at: storeDirectory.appendingPathComponent(sibling)), 999,
                           "The moved-aside file must be the original version-999 database")
        }

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])

        await store.close()
        XCTAssertEqual(userVersion(at: databaseURL), 1)
    }

    // MARK: - close()

    func test_close_leavesNoWalOrShmFile() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))

        await store.close()

        XCTAssertTrue(exists(databaseURL))
        XCTAssertFalse(exists(storeDirectory.appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(storeDirectory.appendingPathComponent("usage.sqlite-shm")))
    }

    func test_close_calledTwice_isIdempotent() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))

        await store.close()
        await store.close()

        XCTAssertFalse(exists(storeDirectory.appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(storeDirectory.appendingPathComponent("usage.sqlite-shm")))
        let reopened = try openStore()
        let records = try await reopened.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_afterClose_everyOtherMethodThrowsClosed() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))
        await store.close()

        let record = finalLine
        let utc = Calendar(identifier: .gregorian)
        await assertThrows(.closed, "apply") { try await store.apply(UsageBatch(records: [record], session: nil, fileCheckpoint: nil)) }
        await assertThrows(.closed, "records") { try await store.records(forSession: "session-a") }
        await assertThrows(.closed, "sessions") { try await store.sessions() }
        await assertThrows(.closed, "checkpoint") { try await store.checkpoint(forPath: "/t/a.jsonl") }
        await assertThrows(.closed, "report") { try await store.report(UsageQuery(), calendar: utc) }
        await assertThrows(.closed, "deleteAll") { try await store.deleteAll() }
    }

    // MARK: - Atomic apply

    func test_apply_batchWithEmptyKeyRecordLast_throwsAndStoresNothingOfThatBatch() async throws {
        let store = try openStore()
        let valid = makeRecord(key: "msg_valid", sessionID: "session-b")
        let invalid = makeRecord(key: "", sessionID: "session-b")
        let failing = batch(
            [valid, invalid],
            session: UsageSessionMeta(sessionID: "session-b", transcriptPath: "/t/b.jsonl", projectRoot: "/r/b"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/b.jsonl", checkpoint: TranscriptCheckpoint(inode: 5, offset: 500))
        )

        do {
            try await store.apply(failing)
            XCTFail("apply must throw for a record with an empty key")
        } catch {
            XCTAssertNotEqual(error as? UsageStoreError, .closed, "The store must stay open")
        }

        let records = try await store.records(forSession: "session-b")
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: "/t/b.jsonl")
        XCTAssertEqual(records, [], "No record of the failed batch may be stored")
        XCTAssertEqual(sessions, [], "No session row of the failed batch may be stored")
        XCTAssertNil(checkpoint, "The checkpoint of the failed batch must not be stored")
    }

    func test_apply_failedBatch_leavesEarlierDataIntactAndStoreUsable() async throws {
        let store = try openStore()
        try await store.apply(batch(
            [makeRecord(key: "msg_01", outputTokens: 60, isFinal: false)],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: nil),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 100))
        ))

        // Would upgrade msg_01 to final, set the root and advance the checkpoint.
        let failing = batch(
            [makeRecord(key: "msg_01", outputTokens: 420, isFinal: true), makeRecord(key: "")],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/moved.jsonl", projectRoot: "/r/a"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 900))
        )
        do {
            try await store.apply(failing)
            XCTFail("apply must throw for a record with an empty key")
        } catch {}

        var records = try await store.records(forSession: "session-a")
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(records, [makeRecord(key: "msg_01", outputTokens: 60, isFinal: false)])
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: nil),
        ])
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 7, offset: 100))

        try await store.apply(batch([makeRecord(key: "msg_02")]))
        records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records.map(\.key), ["msg_01", "msg_02"])
    }

    // MARK: - Winner folding

    func test_apply_nonFinalThenFinalInOneBatch_storesTheFinalRecord() async throws {
        let store = try openStore()

        try await store.apply(batch([partialEarly, finalLine]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_apply_finalThenNonFinalInOneBatch_storesTheFinalRecord() async throws {
        let store = try openStore()

        try await store.apply(batch([finalLine, partialEarly]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_apply_nonFinalThenFinalAcrossBatches_storesTheFinalRecord() async throws {
        let store = try openStore()

        try await store.apply(batch([partialEarly]))
        try await store.apply(batch([finalLine]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_apply_finalThenNonFinalAcrossBatches_keepsTheFinalRecord() async throws {
        let store = try openStore()

        try await store.apply(batch([finalLine]))
        try await store.apply(batch([partialLate]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_apply_twoNonFinalLines_keepsTheLargerOutputInEitherOrder() async throws {
        let store = try openStore()

        try await store.apply(batch([partialLate]))
        try await store.apply(batch([partialEarly]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [partialLate])
    }

    func test_apply_keyRepeatedThreeTimesInOneBatch_storesOneWinner() async throws {
        let store = try openStore()
        let other = makeRecord(key: "msg_02", outputTokens: 7)

        try await store.apply(batch([partialLate, other, finalLine, partialEarly]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine, other])
    }

    func test_apply_sameLineAppliedTwice_isIdempotent() async throws {
        let store = try openStore()

        try await store.apply(batch([finalLine]))
        try await store.apply(batch([finalLine]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    func test_apply_sameKeyInAnotherSession_recordBelongsToTheWinnersSession() async throws {
        let store = try openStore()
        let partialInA = makeRecord(key: "msg_dup", sessionID: "session-a", outputTokens: 8, isFinal: false)
        let finalInB = makeRecord(key: "msg_dup", sessionID: "session-b", outputTokens: 420, isFinal: true)

        try await store.apply(batch([partialInA]))
        try await store.apply(batch([finalInB]))

        let inA = try await store.records(forSession: "session-a")
        let inB = try await store.records(forSession: "session-b")
        XCTAssertEqual(inA, [], "The key is stored once, under the winner's session")
        XCTAssertEqual(inB, [finalInB])
    }

    // MARK: - Record round-trip and records(forSession:)

    func test_apply_recordWithEveryFieldSet_roundTripsExactly() async throws {
        let store = try openStore()
        let full = UsageRecord(
            key: "msg_full#adv2",
            sessionID: "session-full",
            timestampMs: 1_790_936_849_765,
            model: "claude-fable-5-1",
            effort: "max",
            thread: .subagent,
            agentID: "a1b2c3",
            agentType: "swift-specialist",
            gitBranch: "機能/ブランチ-é",
            cwd: "/tmp/プロジェクト/sub dir",
            inputTokens: 11,
            outputTokens: 22,
            thinkingTokens: 33,
            cacheReadTokens: 5_000_000_044,
            cacheCreationTokens: 55,
            cacheCreation1hTokens: 66,
            isFinal: true
        )

        try await store.apply(batch([full]))

        let records = try await store.records(forSession: "session-full")
        XCTAssertEqual(records, [full])
    }

    func test_apply_recordWithNilOptionalsAndNonFinal_roundTripsExactly() async throws {
        let store = try openStore()
        let sparse = UsageRecord(
            key: "msg_sparse",
            sessionID: "session-sparse",
            timestampMs: 1,
            model: "claude-haiku-5",
            effort: nil,
            thread: .advisor,
            agentID: nil,
            agentType: nil,
            gitBranch: nil,
            cwd: nil,
            inputTokens: 0,
            outputTokens: 1,
            thinkingTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 1,
            cacheCreation1hTokens: 0,
            isFinal: false
        )

        try await store.apply(batch([sparse]))

        let records = try await store.records(forSession: "session-sparse")
        XCTAssertEqual(records, [sparse])
    }

    func test_recordsForSession_returnsMainSubagentAndAdvisorOrderedByKey_andOnlyThatSession() async throws {
        let store = try openStore()
        let main = makeRecord(key: "msg_02")
        let advisor = makeRecord(key: "msg_02#adv1", model: "claude-fable-5-1", effort: nil, thread: .advisor)
        let subagent = makeRecord(key: "msg_01", thread: .subagent, agentID: "a1", agentType: "swift-specialist")
        let later = makeRecord(key: "msg_03")
        let foreign = makeRecord(key: "msg_00", sessionID: "session-b")

        try await store.apply(batch([later, advisor, foreign, main, subagent]))

        let inA = try await store.records(forSession: "session-a")
        let inB = try await store.records(forSession: "session-b")
        XCTAssertEqual(inA, [subagent, main, advisor, later])
        XCTAssertEqual(inB, [foreign])
    }

    func test_recordsForSession_unknownSession_returnsEmpty() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))

        let records = try await store.records(forSession: "session-none")

        XCTAssertEqual(records, [])
    }

    // MARK: - Session meta

    func test_sessions_freshStore_isEmpty() async throws {
        let store = try openStore()

        let sessions = try await store.sessions()

        XCTAssertEqual(sessions, [])
    }

    func test_apply_recordsWithoutSessionMeta_createsNoSessionRow() async throws {
        let store = try openStore()

        try await store.apply(batch([finalLine], session: nil))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [])
    }

    func test_apply_sessionMetaWithoutRecords_createsTheSessionRow() async throws {
        let store = try openStore()
        let meta = UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")

        try await store.apply(batch(session: meta))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [meta])
    }

    func test_apply_sessionMetaWithAllNil_createsRowWithNilFields() async throws {
        let store = try openStore()
        let meta = UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: nil)

        try await store.apply(batch(session: meta))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [meta])
    }

    func test_apply_nonNilTranscriptPath_replacesTheStoredOne() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/old.jsonl", projectRoot: nil)))

        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/new.jsonl", projectRoot: nil)))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/new.jsonl", projectRoot: nil),
        ])
    }

    func test_apply_nilTranscriptPath_leavesTheStoredOne() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")))

        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: nil)))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
        ])
    }

    func test_apply_secondNonNilProjectRoot_neverOverwritesTheFirst() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/first")))

        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/second")))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/first"),
        ])
    }

    func test_apply_projectRootArrivingLater_isSetWhenStoredValueIsNil() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: nil)))

        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: "/r/late")))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/late"),
        ])
    }

    func test_sessions_areOrderedBySessionID() async throws {
        let store = try openStore()
        let c = UsageSessionMeta(sessionID: "session-c", transcriptPath: "/t/c.jsonl", projectRoot: nil)
        let a = UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: "/r/a")
        let b = UsageSessionMeta(sessionID: "session-b", transcriptPath: "/t/b.jsonl", projectRoot: "/r/b")

        try await store.apply(batch(session: c))
        try await store.apply(batch(session: a))
        try await store.apply(batch(session: b))

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions, [a, b, c])
    }

    // MARK: - Checkpoints

    func test_checkpoint_unknownPath_isNil() async throws {
        let store = try openStore()

        let checkpoint = try await store.checkpoint(forPath: "/t/none.jsonl")

        XCTAssertNil(checkpoint)
    }

    func test_checkpoint_afterApply_roundTripsInodeAndOffset() async throws {
        let store = try openStore()
        let stored = TranscriptCheckpoint(inode: 8_000_000_123, offset: 6_000_000_456)

        try await store.apply(batch(fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: stored)))

        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(checkpoint, stored)
    }

    func test_checkpoint_appliedAgain_isOverwrittenByTheLastOne() async throws {
        let store = try openStore()
        try await store.apply(batch(fileCheckpoint: UsageFileCheckpoint(
            path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 900))))

        // A replaced file: different inode and a SMALLER offset still wins.
        try await store.apply(batch(fileCheckpoint: UsageFileCheckpoint(
            path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 8, offset: 40))))

        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 8, offset: 40))
    }

    func test_checkpoint_isKeptPerPath() async throws {
        let store = try openStore()
        try await store.apply(batch(fileCheckpoint: UsageFileCheckpoint(
            path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 900))))
        try await store.apply(batch(fileCheckpoint: UsageFileCheckpoint(
            path: "/t/a/subagents/agent-a1.jsonl", checkpoint: TranscriptCheckpoint(inode: 9, offset: 12))))

        let main = try await store.checkpoint(forPath: "/t/a.jsonl")
        let subagent = try await store.checkpoint(forPath: "/t/a/subagents/agent-a1.jsonl")
        XCTAssertEqual(main, TranscriptCheckpoint(inode: 7, offset: 900))
        XCTAssertEqual(subagent, TranscriptCheckpoint(inode: 9, offset: 12))
    }

    // MARK: - deleteAll

    func test_deleteAll_removesRecordsSessionsAndCheckpoints() async throws {
        let store = try openStore()
        try await store.apply(batch(
            [finalLine, makeRecord(key: "msg_02", sessionID: "session-b")],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 99))
        ))

        try await store.deleteAll()

        let inA = try await store.records(forSession: "session-a")
        let inB = try await store.records(forSession: "session-b")
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        let report = try await store.report(UsageQuery(), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(inA, [])
        XCTAssertEqual(inB, [])
        XCTAssertEqual(sessions, [])
        XCTAssertNil(checkpoint)
        XCTAssertEqual(report, [])
    }

    func test_deleteAll_storeStaysUsable() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))
        try await store.deleteAll()

        // A non-final line must not be beaten by the deleted final one.
        try await store.apply(batch(
            [partialEarly],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/new"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 1, offset: 2))
        ))

        let records = try await store.records(forSession: "session-a")
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(records, [partialEarly])
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/new"),
        ])
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 1, offset: 2))
    }

    // MARK: - Pinned decisions

    /// Reads `PRAGMA journal_mode` with the SQLite C API. The WAL mode is
    /// persistent in the database file.
    ///
    /// Opens READWRITE for the same reason as `userVersion(at:)`: a closed
    /// WAL-mode database without side files cannot be opened read-only.
    /// The connection is closed by the `defer` before the function returns.
    private func journalMode(at url: URL) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }

    func test_openStoreAfterWriting_walFileExistsWithMode0600() async throws {
        let store = try openStore()

        try await store.apply(batch([finalLine]))

        let wal = storeDirectory.appendingPathComponent("usage.sqlite-wal")
        XCTAssertTrue(exists(wal), "The store must run in WAL mode: usage.sqlite-wal must exist after a write")
        if exists(wal) {
            XCTAssertEqual(try mode(of: wal), 0o600)
        }
        let shm = storeDirectory.appendingPathComponent("usage.sqlite-shm")
        if exists(shm) {
            XCTAssertEqual(try mode(of: shm), 0o600)
        }
    }

    func test_close_databaseFileIsInWALJournalMode() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine]))

        await store.close()

        XCTAssertEqual(journalMode(at: databaseURL)?.lowercased(), "wal")
    }

    func test_apply_entirelyEmptyBatch_isANoOpAndDoesNotThrow() async throws {
        let store = try openStore()
        try await store.apply(batch(
            [finalLine],
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
            fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: TranscriptCheckpoint(inode: 7, offset: 99))
        ))

        try await store.apply(UsageBatch(records: [], session: nil, fileCheckpoint: nil))

        let records = try await store.records(forSession: "session-a")
        let sessions = try await store.sessions()
        let checkpoint = try await store.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(records, [finalLine])
        XCTAssertEqual(sessions, [
            UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a"),
        ])
        XCTAssertEqual(checkpoint, TranscriptCheckpoint(inode: 7, offset: 99))
    }

    func test_apply_entirelyEmptyBatchOnFreshStore_storesNothing() async throws {
        let store = try openStore()

        try await store.apply(UsageBatch(records: [], session: nil, fileCheckpoint: nil))

        let sessions = try await store.sessions()
        let report = try await store.report(UsageQuery(), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(sessions, [])
        XCTAssertEqual(report, [])
    }

    func test_init_existingDirectoryWithMode0755_isTightenedTo0700() throws {
        try FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        // createDirectory applies the umask; set the mode explicitly.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDirectory.path)
        XCTAssertEqual(try mode(of: storeDirectory), 0o755, "Fixture error")

        _ = try openStore()

        XCTAssertEqual(try mode(of: storeDirectory), 0o700)
        XCTAssertEqual(try mode(of: databaseURL), 0o600)
    }

    func test_init_existingZeroByteDatabaseFile_isInitialisedAsFreshNotMovedAside() async throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try Data().write(to: databaseURL)
        XCTAssertTrue(exists(databaseURL), "Fixture error")

        let store = try openStore()

        XCTAssertEqual(try corruptSiblings(), [], "A zero-byte file is a fresh database, not a corrupt one")
        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
        XCTAssertEqual(try mode(of: databaseURL), 0o600)

        await store.close()
        XCTAssertEqual(userVersion(at: databaseURL), 1)
        XCTAssertEqual(try corruptSiblings(), [])
    }

    // MARK: - Incompatible schema at the supported user_version

    /// True when the database at `url` has a table named `name`. Opens
    /// READWRITE for the same reason as `userVersion(at:)`; the connection
    /// is closed before the function returns.
    private func tableExists(_ name: String, at url: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) == 1
    }

    func test_init_existingDatabaseAtUserVersion1WithoutStoreTables_movesItAsideAndStartsFresh() async throws {
        // A valid SQLite database, user_version 1, holding only the
        // unrelated table "fixture".
        try createDatabase(at: databaseURL, userVersion: 1)
        XCTAssertEqual(userVersion(at: databaseURL), 1, "Fixture error")
        XCTAssertTrue(tableExists("fixture", at: databaseURL), "Fixture error")

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertTrue(tableExists("fixture", at: storeDirectory.appendingPathComponent(sibling)),
                          "The moved-aside file must still contain the unrelated table")
        }

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])

        await store.close()
        XCTAssertFalse(tableExists("fixture", at: databaseURL), "The fresh database must not contain the unrelated table")
        XCTAssertEqual(userVersion(at: databaseURL), 1)
    }

    // MARK: - Review A1: corrupt data page

    func test_init_databaseWithCorruptDataPage_movesItAsideAndStartsFresh() async throws {
        let first = try openStore()
        var many: [UsageRecord] = []
        for index in 0..<3_000 {
            many.append(makeRecord(key: String(format: "msg_%05d", index), sessionID: "session-old"))
        }
        try await first.apply(batch(many))
        await first.close()

        // Overwrite two late 4 KiB pages with garbage; page 1 (header and
        // schema root) stays intact.
        let pageSize = 4_096
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber).intValue
        let pageCount = size / pageSize
        XCTAssertGreaterThanOrEqual(pageCount, 8, "Fixture error: the database must be several pages long")
        guard pageCount >= 8 else { return }
        let handle = try FileHandle(forUpdating: databaseURL)
        try handle.seek(toOffset: UInt64((pageCount - 3) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: 2 * pageSize))
        try handle.close()

        let store = try openStore()

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "A database with a corrupt data page must be moved aside. Got: \(siblings)")

        let old = try await store.records(forSession: "session-old")
        let report = try await store.report(UsageQuery(), calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(old, [], "The fresh store must hold no old data")
        XCTAssertEqual(report, [])

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
    }

    // MARK: - Review A2: symlink at the database path

    private func fileType(of url: URL) throws -> FileAttributeType? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    }

    func test_init_databasePathIsSymlinkToUnrelatedFile_neverFollowsTheLink() async throws {
        let target = tempDirectory.appendingPathComponent("unrelated.txt")
        let targetBytes = Data("unrelated file, not a database\n".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: target)
        XCTAssertEqual(try fileType(of: databaseURL), .typeSymbolicLink, "Fixture error")
        XCTAssertEqual(try mode(of: target), 0o644, "Fixture error")

        let store = try openStore()

        XCTAssertEqual(try mode(of: target), 0o644, "The link target's mode must not be changed")
        XCTAssertEqual(try Data(contentsOf: target), targetBytes, "The link target's bytes must not be changed")

        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(try fileType(of: storeDirectory.appendingPathComponent(sibling)), .typeSymbolicLink,
                           "The moved-aside item must be the link itself")
        }
        XCTAssertEqual(try fileType(of: databaseURL), .typeRegular, "usage.sqlite must now be a regular file")
        XCTAssertEqual(try mode(of: databaseURL), 0o600)

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])

        await store.close()
        XCTAssertEqual(try mode(of: target), 0o644)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    func test_init_databasePathIsSymlinkToAnotherStoreDatabase_neitherOpensNorModifiesIt() async throws {
        let otherDirectory = tempDirectory.appendingPathComponent("other-store", isDirectory: true)
        let other = try UsageStore(directory: otherDirectory)
        openedStores.append(other)
        let foreign = makeRecord(key: "msg_foreign", sessionID: "session-foreign")
        try await other.apply(batch([foreign]))
        await other.close()
        let otherDatabase = otherDirectory.appendingPathComponent("usage.sqlite")
        let otherBytes = try Data(contentsOf: otherDatabase)
        let otherMode = try mode(of: otherDatabase)

        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: otherDatabase)
        XCTAssertEqual(try fileType(of: databaseURL), .typeSymbolicLink, "Fixture error")

        let store = try openStore()

        let seen = try await store.records(forSession: "session-foreign")
        XCTAssertEqual(seen, [], "The store must not open the database behind the link")
        let siblings = try corruptSiblings()
        XCTAssertEqual(siblings.count, 1, "Got: \(siblings)")
        if let sibling = siblings.first {
            XCTAssertEqual(try fileType(of: storeDirectory.appendingPathComponent(sibling)), .typeSymbolicLink)
        }
        XCTAssertEqual(try fileType(of: databaseURL), .typeRegular)

        try await store.apply(batch([finalLine]))
        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records, [finalLine])
        await store.close()

        XCTAssertEqual(try Data(contentsOf: otherDatabase), otherBytes, "The linked database must not be modified")
        XCTAssertEqual(try mode(of: otherDatabase), otherMode)
        XCTAssertFalse(exists(otherDirectory.appendingPathComponent("usage.sqlite-wal")))
        XCTAssertFalse(exists(otherDirectory.appendingPathComponent("usage.sqlite-shm")))
    }

    // MARK: - Review A3: embedded NUL in text columns

    func test_apply_textWithEmbeddedNUL_roundTripsByteExactly() async throws {
        let store = try openStore()
        let record = makeRecord(key: "msg_nul", gitBranch: "n\u{0}x", cwd: "/tmp/a\u{0}b/c")

        try await store.apply(batch([record]))

        let records = try await store.records(forSession: "session-a")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.gitBranch.map { Array($0.utf8) }, Array("n\u{0}x".utf8))
        XCTAssertEqual(records.first?.cwd.map { Array($0.utf8) }, Array("/tmp/a\u{0}b/c".utf8))
        XCTAssertEqual(records, [record])
    }

    // MARK: - Review B1: a lock error propagates, never a move-aside

    func test_init_databaseLockedExclusivelyByAnotherHandle_throwsBusyAndMovesNothingAside() throws {
        try createDatabase(at: databaseURL, userVersion: 1)

        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &holder, SQLITE_OPEN_READWRITE, nil), SQLITE_OK,
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
            let store = try UsageStore(directory: storeDirectory)
            openedStores.append(store)
            XCTFail("init must throw while another handle holds an exclusive lock")
        } catch {
            XCTAssertEqual((error as? SQLiteError)?.primaryCode, SQLITE_BUSY, "Got: \(error)")
        }

        XCTAssertEqual(try corruptSiblings(), [], "A lock error must never move the database aside")

        release()
        XCTAssertTrue(exists(databaseURL))
        XCTAssertEqual(userVersion(at: databaseURL), 1)
        XCTAssertTrue(tableExists("fixture", at: databaseURL), "The locked database must be untouched")
    }

    // MARK: - Review B4: UInt64 extremes in a checkpoint

    func test_checkpoint_withUInt64MaxInodeAndOffset_roundTripsAcrossReopen() async throws {
        let extreme = TranscriptCheckpoint(inode: UInt64.max, offset: UInt64.max - 1)
        let first = try openStore()

        try await first.apply(batch(fileCheckpoint: UsageFileCheckpoint(path: "/t/a.jsonl", checkpoint: extreme)))

        let beforeClose = try await first.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(beforeClose, extreme)
        XCTAssertEqual(beforeClose?.inode, 18_446_744_073_709_551_615)
        XCTAssertEqual(beforeClose?.offset, 18_446_744_073_709_551_614)

        await first.close()
        let second = try openStore()
        let afterReopen = try await second.checkpoint(forPath: "/t/a.jsonl")
        XCTAssertEqual(afterReopen, extreme)
    }

    // MARK: - session(_:)

    func test_session_unknownID_isNil() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")))

        let unknown = try await store.session("session-zzz")

        XCTAssertNil(unknown)
    }

    func test_session_freshStore_isNil() async throws {
        let store = try openStore()

        let session = try await store.session("session-a")

        XCTAssertNil(session)
    }

    func test_session_recordsAppliedWithoutSessionMeta_isNil() async throws {
        let store = try openStore()
        try await store.apply(batch([finalLine], session: nil))

        let session = try await store.session("session-a")

        XCTAssertNil(session, "Records alone create no session row")
    }

    func test_session_afterBatchWithSessionMeta_returnsThatMeta() async throws {
        let store = try openStore()
        let meta = UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")
        try await store.apply(batch(session: meta))

        let session = try await store.session("session-a")

        XCTAssertEqual(session, meta)
    }

    func test_session_metaWithAllNil_returnsRowWithNilFields() async throws {
        let store = try openStore()
        let meta = UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: nil)
        try await store.apply(batch(session: meta))

        let session = try await store.session("session-a")

        XCTAssertEqual(session, meta)
    }

    func test_session_returnsOnlyTheRequestedSession() async throws {
        let store = try openStore()
        let metaA = UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")
        let metaB = UsageSessionMeta(sessionID: "session-b", transcriptPath: "/t/b.jsonl", projectRoot: "/r/b")
        try await store.apply(batch(session: metaA))
        try await store.apply(batch(session: metaB))

        let sessionA = try await store.session("session-a")
        let sessionB = try await store.session("session-b")

        XCTAssertEqual(sessionA, metaA)
        XCTAssertEqual(sessionB, metaB)
    }

    func test_session_secondNonNilProjectRoot_stillReturnsTheFirst() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/first")))
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: "/r/second")))

        let session = try await store.session("session-a")

        XCTAssertEqual(
            session, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/first"))
    }

    func test_session_projectRootArrivingLater_isReturnedOnceSet() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: nil)))
        let before = try await store.session("session-a")
        XCTAssertEqual(
            before, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: nil))

        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: nil, projectRoot: "/r/late")))

        let after = try await store.session("session-a")
        XCTAssertEqual(
            after, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/late"))
    }

    func test_session_nonNilTranscriptPath_returnsTheReplacedPath() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/old.jsonl", projectRoot: "/r/a")))
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/new.jsonl", projectRoot: nil)))

        let session = try await store.session("session-a")

        XCTAssertEqual(
            session, UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/new.jsonl", projectRoot: "/r/a"))
    }

    func test_session_afterDeleteAll_isNil() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")))
        try await store.deleteAll()

        let session = try await store.session("session-a")

        XCTAssertNil(session)
    }

    func test_session_afterClose_throwsClosed() async throws {
        let store = try openStore()
        try await store.apply(batch(
            session: UsageSessionMeta(sessionID: "session-a", transcriptPath: "/t/a.jsonl", projectRoot: "/r/a")))
        await store.close()

        await assertThrows(.closed, "session") { try await store.session("session-a") }
    }

    // MARK: - reports(_:calendar:)

    /// Two sessions on two days, with different models and threads, so
    /// the queries below have different answers.
    private func seedForReports(_ store: UsageStore) async throws {
        try await store.apply(batch([
            makeRecord(key: "msg_a1", sessionID: "session-a", timestampMs: 1_790_935_200_000, model: "claude-opus-5-5"),
            makeRecord(key: "msg_a2", sessionID: "session-a", timestampMs: 1_790_935_201_000, model: "claude-opus-5-5"),
            makeRecord(
                key: "msg_b1", sessionID: "session-b", timestampMs: 1_791_021_600_000, model: "claude-sonnet-5",
                thread: .subagent, agentID: "a1", agentType: "swift-specialist"),
        ]))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // One call answers every query, in the order given, each exactly as
    // `report` answers it alone.
    func test_reports_answersEachQueryInOrder_likeReportDoes() async throws {
        let store = try openStore()
        try await seedForReports(store)
        let queries = [
            UsageQuery(groupBy: [.model]),
            UsageQuery(),
            UsageQuery(groupBy: [.day], sessionID: "session-b"),
            UsageQuery(thread: .advisor),
        ]

        let results = try await store.reports(queries, calendar: utc)

        var expected: [[UsageRow]] = []
        for query in queries {
            expected.append(try await store.report(query, calendar: utc))
        }
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results, expected)
        // The four answers differ, so an answer in the wrong slot shows.
        XCTAssertEqual(results[0].map(\.key), [["claude-opus-5-5"], ["claude-sonnet-5"]])
        XCTAssertEqual(results[1].map(\.responses), [3])
        XCTAssertEqual(results[2].map(\.key), [["2026-10-03"]])
        XCTAssertEqual(results[3], [])
    }

    func test_reports_passesTheCalendarToEveryQuery() async throws {
        let store = try openStore()
        try await seedForReports(store)
        // 2026-10-02T10:00Z is already 2026-10-03 at UTC+14.
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 3_600))

        let results = try await store.reports(
            [UsageQuery(groupBy: [.day], sessionID: "session-a"), UsageQuery(groupBy: [.day])], calendar: kiritimati)

        XCTAssertEqual(results.map { $0.map(\.key) }, [[["2026-10-03"]], [["2026-10-03"], ["2026-10-04"]]])
    }

    func test_reports_emptyList_returnsEmpty() async throws {
        let store = try openStore()
        try await seedForReports(store)

        let results = try await store.reports([], calendar: utc)

        XCTAssertEqual(results, [])
    }

    func test_reports_aQueryThatThrows_failsTheWholeCall() async throws {
        let store = try openStore()
        try await seedForReports(store)

        await assertThrows(.invalidQuery, "the invalid query is last") {
            try await store.reports([UsageQuery(), UsageQuery(groupBy: [.model, .model])], calendar: utc)
        }
        await assertThrows(.invalidQuery, "the invalid query is first") {
            try await store.reports([UsageQuery(groupBy: [.effort, .effort]), UsageQuery()], calendar: utc)
        }
    }

    func test_reports_afterClose_throwsClosed() async throws {
        let store = try openStore()
        await store.close()

        await assertThrows(.closed, "reports") { try await store.reports([UsageQuery()], calendar: utc) }
    }
}
