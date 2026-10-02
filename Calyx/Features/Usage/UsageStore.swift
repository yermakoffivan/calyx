// UsageStore.swift
// Calyx
//
// The Silver layer of the usage ledger: one row per API response
// (UsageRecord), per-session metadata, and per-transcript-file read
// checkpoints, in a SQLite database. SQLite rather than the JSON documents
// used elsewhere because a batch -- records, session meta and the file
// checkpoint -- must commit atomically on every agent turn, and the data
// only grows. The store touches nothing outside its own directory; later
// slices resolve transcript paths and project roots and pass them in.

import Foundation
import SQLite3

// MARK: - Batch

struct UsageSessionMeta: Sendable, Equatable {
    let sessionID: String
    let transcriptPath: String?
    /// The repository root the session is attributed to, resolved by the
    /// caller; nil while unknown.
    let projectRoot: String?
}

struct UsageFileCheckpoint: Sendable, Equatable {
    let path: String
    let checkpoint: TranscriptCheckpoint
}

/// What one read of one transcript file produced. Applied as a unit so
/// the checkpoint can never run ahead of (or behind) the records it
/// accounts for.
struct UsageBatch: Sendable, Equatable {
    var records: [UsageRecord]
    var session: UsageSessionMeta?
    var fileCheckpoint: UsageFileCheckpoint?
}

// MARK: - Errors

/// Errors of the store itself. A failed SQLite call is thrown as
/// `SQLiteError`, a failed file operation as the Foundation / POSIX error.
enum UsageStoreError: Error, Equatable {
    /// The store was closed; every method but `close()` throws this.
    case closed
    /// The report query is not well-formed (a dimension listed twice).
    case invalidQuery
    /// The database was written by a newer schema than this build knows.
    /// Raised while opening, where it makes the file be moved aside.
    case unsupportedSchemaVersion(Int64)
    /// The database is at this build's schema version but lacks a table
    /// or column the store's statements need. Raised while opening, where
    /// it makes the file be moved aside.
    case incompatibleSchema
    /// `PRAGMA quick_check` reported damage (or anything but the single
    /// row "ok"). Raised while opening, where it makes the file be moved
    /// aside.
    case integrityCheckFailed
    /// A stored row holds a value this build cannot decode (a NULL in a
    /// required column, an unknown thread kind).
    case malformedRow
    /// The injected calendar gave no usable local-day interval for a
    /// timestamp, so `Dimension.day` cannot be computed.
    case dayBoundaryUnavailable
}

// MARK: - UsageStore

actor UsageStore {
    static let databaseFileName = "usage.sqlite"

    /// The schema this build reads and writes (`PRAGMA user_version`).
    private static let schemaVersion: Int64 = 1

    /// nil once closed. Never leaves the actor: SQLiteConnection is not
    /// Sendable, and the actor is what serializes access to it.
    private var connection: SQLiteConnection?

    /// Opens the database in `directory`, creating both as needed.
    ///
    /// - The directory is created (with intermediates) and set to 0700
    ///   even if it already existed with looser permissions.
    /// - `usage.sqlite` is created, or tightened, to 0600 BEFORE SQLite
    ///   opens it: SQLite gives `-wal` / `-shm` the main file's mode, so
    ///   this is what keeps those owner-only too.
    /// - A file that is not a SQLite database, is reported corrupt, has a
    ///   newer schema version, claims this version without having the
    ///   store's tables and columns, fails `PRAGMA quick_check`, or is a
    ///   symbolic link (never followed) is moved aside to
    ///   `usage.sqlite.corrupt-<suffix>` and a fresh database is created:
    ///   Silver can be rebuilt from the transcripts, and refusing to start
    ///   would be worse than starting empty.
    init(directory: URL) throws {
        connection = try Self.openDatabase(in: directory)
    }

    /// Applies one batch in ONE transaction; any failure rolls back all of
    /// it and is rethrown. An entirely empty batch is a no-op.
    ///
    /// - Records: for each key the stored record (if any) and the incoming
    ///   ones are folded with `UsageRecord.winner`, which is the single
    ///   definition of the ordering -- deliberately not re-encoded in SQL.
    ///   A record with an empty key is rejected by a CHECK constraint.
    /// - Session meta: a non-nil `transcriptPath` replaces the stored one
    ///   and nil leaves it; `projectRoot` is only set while the stored
    ///   value is nil (the first non-nil root wins).
    /// - File checkpoint: the last one applied for a path is kept as is.
    func apply(_ batch: UsageBatch) throws {
        let connection = try openConnection()
        guard !batch.records.isEmpty || batch.session != nil || batch.fileCheckpoint != nil else { return }

        // Fold repeated keys first, keeping first-seen order, so each key
        // costs one read and at most one write.
        var keys: [String] = []
        var folded: [String: UsageRecord] = [:]
        for record in batch.records {
            if let seen = folded[record.key] {
                folded[record.key] = UsageRecord.winner(seen, record)
            } else {
                keys.append(record.key)
                folded[record.key] = record
            }
        }

        try connection.transaction {
            for key in keys {
                guard let incoming = folded[key] else { continue }
                let existing = try Self.record(forKey: key, connection: connection)
                let winner = existing.map { UsageRecord.winner($0, incoming) } ?? incoming
                if winner != existing {
                    try Self.write(winner, connection: connection)
                }
            }
            if let session = batch.session {
                try connection.withStatement(Self.upsertSessionSQL) { statement in
                    try statement.bind(session.sessionID, at: 1)
                    try statement.bind(session.transcriptPath, at: 2)
                    try statement.bind(session.projectRoot, at: 3)
                    _ = try statement.step()
                }
            }
            if let file = batch.fileCheckpoint {
                try connection.withStatement(Self.upsertFileSQL) { statement in
                    try statement.bind(file.path, at: 1)
                    try statement.bind(Int64(bitPattern: file.checkpoint.inode), at: 2)
                    try statement.bind(Int64(bitPattern: file.checkpoint.offset), at: 3)
                    _ = try statement.step()
                }
            }
        }
    }

    /// The stored records of one session, ordered by key ascending.
    func records(forSession sessionID: String) throws -> [UsageRecord] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSessionRecordsSQL) { statement in
            try statement.bind(sessionID, at: 1)
            var records: [UsageRecord] = []
            while try statement.step() {
                records.append(try Self.decodeRecord(statement))
            }
            return records
        }
    }

    /// Every session that a batch carried metadata for, ordered by id.
    func sessions() throws -> [UsageSessionMeta] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSessionsSQL) { statement in
            var sessions: [UsageSessionMeta] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                sessions.append(UsageSessionMeta(
                    sessionID: sessionID, transcriptPath: statement.text(at: 1), projectRoot: statement.text(at: 2)))
            }
            return sessions
        }
    }

    /// Where the last applied read of `path` stopped; nil if never read.
    func checkpoint(forPath path: String) throws -> TranscriptCheckpoint? {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectFileSQL) { statement in
            try statement.bind(path, at: 1)
            guard try statement.step() else { return nil }
            return TranscriptCheckpoint(
                inode: UInt64(bitPattern: statement.int64(at: 0)),
                offset: UInt64(bitPattern: statement.int64(at: 1)))
        }
    }

    /// The Gold query: see `UsageGold.rows`.
    func report(_ query: UsageQuery, calendar: Calendar) throws -> [UsageRow] {
        let connection = try openConnection()
        return try UsageGold.rows(for: query, calendar: calendar, connection: connection)
    }

    /// Removes every record, session and checkpoint in one transaction.
    /// The store stays open and usable.
    func deleteAll() throws {
        let connection = try openConnection()
        try connection.transaction {
            try connection.execute(
                "DELETE FROM usage_records; DELETE FROM usage_sessions; DELETE FROM usage_files;")
        }
    }

    /// Closes the database; idempotent. Closing the only connection
    /// checkpoints the WAL and removes `-wal` / `-shm`. Every other method
    /// throws `UsageStoreError.closed` afterwards.
    func close() {
        connection?.close()
        connection = nil
    }

    private func openConnection() throws -> SQLiteConnection {
        guard let connection else { throw UsageStoreError.closed }
        return connection
    }

    // MARK: - Schema

    /// Version 1. `key` is the primary key because one API response is one
    /// row whatever file it was read from. The indexes serve the two ways
    /// rows are selected: by session (`records(forSession:)`, the session
    /// filter) and by time range (report filters, day intervals).
    /// `inode` / `offset` hold a UInt64's bit pattern, since SQLite
    /// integers are signed 64-bit.
    private static let schemaV1 = """
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

    /// Brings a database at `version` up to `schemaVersion`, one step per
    /// version, all in one transaction with the version bump, so a crash
    /// cannot leave a half-migrated file that claims either version.
    private static func migrate(_ connection: SQLiteConnection, from version: Int64) throws {
        guard version < schemaVersion else { return }
        try connection.transaction {
            if version < 1 {
                try connection.execute(schemaV1)
            }
            // A version 2 step goes here: `if version < 2 { ... }`.
            try connection.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    /// Every fixed statement the store runs. Together they name every
    /// table and every column the store (and the Gold queries, which read
    /// the same columns) depends on.
    private static let fixedStatements = [
        selectRecordSQL, selectSessionRecordsSQL, writeRecordSQL,
        upsertSessionSQL, selectSessionsSQL, upsertFileSQL, selectFileSQL,
    ]

    /// Migrates, then proves the result is the schema this build uses by
    /// PREPARING every fixed statement: SQLite resolves each table and
    /// column name at prepare time, so a missing table or a missing column
    /// fails here, at open, instead of on the first `apply` of every
    /// launch with no way to heal. (It also leaves the statements cached
    /// for use.) Checking table names alone would miss a missing column.
    ///
    /// SQLITE_ERROR is SQLite's code for exactly that kind of failure --
    /// "no such table", "no such column", and, in the migration, "table
    /// already exists" for a file holding a clashing table -- so only it
    /// becomes `incompatibleSchema`. An I/O or lock error has its own code
    /// and propagates untouched; it must never cost a healthy database.
    private static func migrateAndValidate(_ connection: SQLiteConnection, from version: Int64) throws {
        do {
            try migrate(connection, from: version)
            for sql in fixedStatements {
                try connection.withStatement(sql) { _ in }
            }
        } catch let error as SQLiteError where error.primaryCode == SQLITE_ERROR {
            throw UsageStoreError.incompatibleSchema
        }
    }

    /// The version read and the schema validation only touch page 1 and
    /// the schema, so a database with a damaged table or index page would
    /// open as healthy and then fail EVERY `apply`, read and report with
    /// "database disk image is malformed", on every turn and every launch,
    /// with nothing to heal it. `PRAGMA quick_check` walks every page once
    /// at open instead: one scan per launch (about 10 MB at the measured
    /// transcript volume), cheap next to never recovering. `quick_check`
    /// rather than `integrity_check` because the latter's extra work
    /// (index-against-table comparison) costs more and guards nothing the
    /// store cannot rebuild from the transcripts.
    ///
    /// Damage is REPORTED as result rows, so anything but the single row
    /// "ok" is `integrityCheckFailed`. A SQLITE_CORRUPT thrown by the
    /// pragma is already an unusable database; an I/O or lock error has
    /// its own code and propagates without a move-aside.
    private static func checkIntegrity(_ connection: SQLiteConnection) throws {
        let findings = try connection.withTransientStatement("PRAGMA quick_check") { statement in
            var findings: [String?] = []
            while try statement.step() {
                findings.append(statement.text(at: 0))
            }
            return findings
        }
        guard findings == ["ok"] else { throw UsageStoreError.integrityCheckFailed }
    }

    // MARK: - Opening

    private static func openDatabase(in directory: URL) throws -> SQLiteConnection {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing directory's mode alone.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // The directory may legitimately be reached through symbolic
        // links (/var is one on macOS), but SQLite's NOFOLLOW open rejects
        // a link in any path component. Resolving the directory here
        // leaves exactly one unresolved component, the database file name,
        // which is the one that must never be followed.
        guard let resolved = realpath(directory.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        let path = String(cString: resolved) + "/" + databaseFileName

        // The store never follows a symbolic link at its database path:
        // following one would chmod, read and write whatever it points at
        // (possibly another store's database). A link is therefore an
        // unusable database, decided here, before any chmod or open.
        if try isSymbolicLink(atPath: path) {
            try moveAside(path)
        }
        try ensureOwnerOnlyFile(atPath: path)
        do {
            return try openAndMigrate(path: path)
        } catch where isUnusableDatabase(error) {
            try moveAside(path)
            try ensureOwnerOnlyFile(atPath: path)
            return try openAndMigrate(path: path)
        }
    }

    /// Same convention as MCPServerRegistry's corrupt document (both name
    /// the file with `CorruptFileSuffix`): keep the item for inspection
    /// under a `.corrupt-` name so a fresh database can take its place.
    /// `rename` moves a symbolic link itself, never its target. Any
    /// `-wal` / `-shm` left beside it describe the moved database and
    /// would be replayed into the new one, so they are removed (`unlink`
    /// does not follow links either).
    private static func moveAside(_ path: String) throws {
        guard rename(path, path + ".corrupt-" + CorruptFileSuffix.make()) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        for suffix in ["-wal", "-shm"] {
            guard unlink(path + suffix) == 0 || errno == ENOENT else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    /// `lstat`, so the link itself is examined. A missing path is simply
    /// not a link.
    private static func isSymbolicLink(atPath path: String) throws -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (status.st_mode & S_IFMT) == S_IFLNK
    }

    /// Only these mean "this file is not a database this build can use".
    /// Anything else (I/O error, locked, cannot open) may be transient and
    /// must not cost the user a healthy database, so it propagates.
    private static func isUnusableDatabase(_ error: any Error) -> Bool {
        if let error = error as? SQLiteError {
            return error.primaryCode == SQLITE_NOTADB || error.primaryCode == SQLITE_CORRUPT
        }
        switch error as? UsageStoreError {
        case .unsupportedSchemaVersion, .incompatibleSchema, .integrityCheckFailed: return true
        default: return false
        }
    }

    /// Reads the schema version FIRST: that is the first read of the file,
    /// so it is where a non-database fails (SQLITE_NOTADB), and a too-new
    /// database must be recognized before anything writes to it. The
    /// schema is then migrated and validated, the content is checked, and
    /// only a database that passed is switched to WAL, so a file about to
    /// be moved aside is not rewritten first.
    private static func openAndMigrate(path: String) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(path: path)
        do {
            let version = try connection.withTransientStatement("PRAGMA user_version") { statement in
                guard try statement.step() else { throw UsageStoreError.malformedRow }
                return statement.int64(at: 0)
            }
            guard version <= schemaVersion else {
                throw UsageStoreError.unsupportedSchemaVersion(version)
            }
            try connection.disablePersistentWAL()
            try migrateAndValidate(connection, from: version)
            try checkIntegrity(connection)
            // WAL: readers (reports) do not block the per-turn writer.
            // NORMAL: in WAL mode a power loss can lose the last commits
            // but not corrupt the file, and lost Silver is re-read from
            // the transcripts.
            try connection.execute("PRAGMA journal_mode = WAL")
            try connection.execute("PRAGMA synchronous = NORMAL")
            return connection
        } catch {
            // The file may be moved aside next; release it first.
            connection.close()
            throw error
        }
    }

    /// Creates the file with mode 0600, or tightens an existing one.
    /// O_NOFOLLOW (as `ConfigFileOpener.createFileExclusively` uses): if a
    /// symbolic link appears at the path after the check in
    /// `openDatabase`, this fails (ELOOP) instead of creating or chmod-ing
    /// the link's target.
    private static func ensureOwnerOnlyFile(atPath path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(descriptor) }
        // The creation mode is subject to the umask and does not apply to
        // a file that already existed.
        guard fchmod(descriptor, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    // MARK: - Statements

    private static let recordColumns = """
        key, session_id, timestamp_ms, model, effort, thread, agent_id, agent_type, git_branch, cwd, \
        input_tokens, output_tokens, thinking_tokens, cache_read_tokens, cache_creation_tokens, \
        cache_creation_1h_tokens, is_final
        """

    private static let selectRecordSQL = "SELECT \(recordColumns) FROM usage_records WHERE key = ?1"

    private static let selectSessionRecordsSQL =
        "SELECT \(recordColumns) FROM usage_records WHERE session_id = ?1 ORDER BY key"

    /// REPLACE resolves only the primary-key conflict; the CHECK on `key`
    /// still aborts the statement.
    private static let writeRecordSQL = """
        INSERT OR REPLACE INTO usage_records (\(recordColumns)) \
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
        """

    private static let upsertSessionSQL = """
        INSERT INTO usage_sessions (session_id, transcript_path, project_root) VALUES (?1, ?2, ?3) \
        ON CONFLICT (session_id) DO UPDATE SET \
        transcript_path = COALESCE(excluded.transcript_path, transcript_path), \
        project_root = COALESCE(project_root, excluded.project_root)
        """

    private static let selectSessionsSQL =
        "SELECT session_id, transcript_path, project_root FROM usage_sessions ORDER BY session_id"

    private static let upsertFileSQL = """
        INSERT INTO usage_files (path, inode, offset) VALUES (?1, ?2, ?3) \
        ON CONFLICT (path) DO UPDATE SET inode = excluded.inode, offset = excluded.offset
        """

    private static let selectFileSQL = "SELECT inode, offset FROM usage_files WHERE path = ?1"

    private static func record(forKey key: String, connection: SQLiteConnection) throws -> UsageRecord? {
        try connection.withStatement(selectRecordSQL) { statement in
            try statement.bind(key, at: 1)
            guard try statement.step() else { return nil }
            return try decodeRecord(statement)
        }
    }

    private static func write(_ record: UsageRecord, connection: SQLiteConnection) throws {
        try connection.withStatement(writeRecordSQL) { statement in
            try statement.bind(record.key, at: 1)
            try statement.bind(record.sessionID, at: 2)
            try statement.bind(record.timestampMs, at: 3)
            try statement.bind(record.model, at: 4)
            try statement.bind(record.effort, at: 5)
            try statement.bind(record.thread.rawValue, at: 6)
            try statement.bind(record.agentID, at: 7)
            try statement.bind(record.agentType, at: 8)
            try statement.bind(record.gitBranch, at: 9)
            try statement.bind(record.cwd, at: 10)
            try statement.bind(record.inputTokens, at: 11)
            try statement.bind(record.outputTokens, at: 12)
            try statement.bind(record.thinkingTokens, at: 13)
            try statement.bind(record.cacheReadTokens, at: 14)
            try statement.bind(record.cacheCreationTokens, at: 15)
            try statement.bind(record.cacheCreation1hTokens, at: 16)
            try statement.bind(record.isFinal ? 1 : 0, at: 17)
            _ = try statement.step()
        }
    }

    /// Decodes a row selected with `recordColumns`.
    private static func decodeRecord(_ statement: SQLiteStatement) throws -> UsageRecord {
        guard let key = statement.text(at: 0),
              let sessionID = statement.text(at: 1),
              let model = statement.text(at: 3),
              let threadRaw = statement.text(at: 5),
              let thread = UsageRecord.Thread(rawValue: threadRaw) else {
            throw UsageStoreError.malformedRow
        }
        return UsageRecord(
            key: key,
            sessionID: sessionID,
            timestampMs: statement.int64(at: 2),
            model: model,
            effort: statement.text(at: 4),
            thread: thread,
            agentID: statement.text(at: 6),
            agentType: statement.text(at: 7),
            gitBranch: statement.text(at: 8),
            cwd: statement.text(at: 9),
            inputTokens: statement.int64(at: 10),
            outputTokens: statement.int64(at: 11),
            thinkingTokens: statement.int64(at: 12),
            cacheReadTokens: statement.int64(at: 13),
            cacheCreationTokens: statement.int64(at: 14),
            cacheCreation1hTokens: statement.int64(at: 15),
            isFinal: statement.int64(at: 16) != 0
        )
    }
}
