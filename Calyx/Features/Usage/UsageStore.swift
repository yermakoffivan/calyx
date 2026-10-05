// UsageStore.swift
// Calyx
//
// The Silver layer of the usage ledger: one row per API response
// (UsageRecord), per-session metadata, and per-transcript-file read
// checkpoints, in a SQLite database. Schema version 2 adds the telemetry
// side: per-series baselines of Claude Code's cumulative token metric,
// the per-minute token points their increments are added to, the process
// starts, and the time tracking started from, and the run logs read from
// Claude Code's own `cost-state` lines, and the unreported amounts the two
// sources' comparison yields. SQLite rather than the JSON documents
// used elsewhere because a batch -- records, session meta and the file
// checkpoint -- must commit atomically on every agent turn, and the data
// only grows. The store touches nothing outside its own directory; later
// slices resolve transcript paths and project roots and pass them in.

import CryptoKit
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

/// Shown to a person or an agent: one fixed sentence per case, never a
/// path or a stored label.
extension UsageStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .closed:
            return "The usage database is closed."
        case .invalidQuery:
            return "The usage report query is not valid: a dimension is listed more than once."
        case .unsupportedSchemaVersion(let version):
            return "The usage database was written by a newer version of Calyx (schema version \(version))."
        case .incompatibleSchema:
            return "The usage database is missing tables or columns this version of Calyx needs."
        case .integrityCheckFailed:
            return "The usage database failed its integrity check."
        case .malformedRow:
            return "The usage database holds a row this version of Calyx cannot read."
        case .dayBoundaryUnavailable:
            return "The calendar gave no usable day boundary, so usage cannot be grouped by day."
        }
    }
}

// MARK: - UsageStore

actor UsageStore {
    static let databaseFileName = "usage.sqlite"

    /// The schema this build reads and writes (`PRAGMA user_version`).
    private static let schemaVersion: Int64 = 2

    /// nil once closed. Never leaves the actor: SQLiteConnection is not
    /// Sendable, and the actor is what serializes access to it.
    private var connection: SQLiteConnection?

    /// The store's clock: read when tracking starts (a new database, the
    /// migration from version 1, `deleteAll`). Injected so tests can pin it.
    private let now: @Sendable () -> Date

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
    ///   `usage.sqlite.corrupt-<suffix>` and a fresh database is created.
    ///   The version-1 tables can be rebuilt from the transcripts; the
    ///   telemetry tables (series, points, process starts) cannot: their
    ///   source is exports Claude Code sends once, so what a moved-aside
    ///   file held is lost from the ledger (it stays in the moved file).
    ///   Refusing to start would still be worse than starting empty.
    /// - A version-1 database is migrated in place; it and a new database
    ///   get `tracked_from_ns` = `now()` at that moment.
    init(directory: URL, now: @escaping @Sendable () -> Date) throws {
        self.now = now
        connection = try Self.openDatabase(in: directory, now: now)
    }

    /// As `init(directory:now:)` with the system clock.
    init(directory: URL) throws {
        try self.init(directory: directory, now: { Date() })
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

    /// The stored metadata of one session; nil if no batch carried any.
    func session(_ sessionID: String) throws -> UsageSessionMeta? {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSessionSQL) { statement in
            try statement.bind(sessionID, at: 1)
            guard try statement.step() else { return nil }
            guard let storedID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
            return UsageSessionMeta(
                sessionID: storedID, transcriptPath: statement.text(at: 1), projectRoot: statement.text(at: 2))
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

    /// The Gold query: see `UsageGold.rows`. Of `calendar` only the time
    /// zone is used (`UsagePeriod.localDayCalendar`).
    func report(_ query: UsageQuery, calendar: Calendar) throws -> [UsageRow] {
        let connection = try openConnection()
        return try UsageGold.rows(for: query, calendar: calendar, connection: connection)
    }

    /// Several Gold queries answered in one actor call, one result per
    /// query in order. Nothing here suspends, so no batch can be applied
    /// between two of the answers: they all describe the same stored
    /// state. Any query that throws fails the whole call. Of `calendar`
    /// only the time zone is used (`UsagePeriod.localDayCalendar`).
    func reports(_ queries: [UsageQuery], calendar: Calendar) throws -> [[UsageRow]] {
        let connection = try openConnection()
        return try queries.map { try UsageGold.rows(for: $0, calendar: calendar, connection: connection) }
    }

    /// The token Gold query: see `UsageTokenGold.rows`. Of `calendar`
    /// only the time zone is used (`UsagePeriod.localDayCalendar`).
    func tokenReport(_ query: UsageTokenQuery, calendar: Calendar) throws -> [UsageTokenRow] {
        let connection = try openConnection()
        return try UsageTokenGold.rows(for: query, calendar: calendar, connection: connection)
    }

    /// Several token Gold queries answered in one actor call, one result
    /// per query in order. Nothing here suspends, so no batch can be
    /// applied between two of the answers. Any query that throws fails the
    /// whole call.
    func tokenReports(_ queries: [UsageTokenQuery], calendar: Calendar) throws -> [[UsageTokenRow]] {
        let connection = try openConnection()
        return try queries.map { try UsageTokenGold.rows(for: $0, calendar: calendar, connection: connection) }
    }

    /// Removes every record, session, checkpoint, point, series baseline,
    /// run log (with its runs and totals) and unreported row in one transaction and restarts tracking at the store's
    /// clock (see `restartTracking`). The processes heard so far are
    /// retired, so their later exports only set baselines and deleted
    /// usage never comes back; only their digests remain. The store stays
    /// open and usable.
    func deleteAll() throws {
        let connection = try openConnection()
        let trackedFrom = Self.nanoseconds(now())
        try connection.transaction {
            try connection.execute("""
                DELETE FROM usage_records; DELETE FROM usage_sessions; DELETE FROM usage_files; \
                DELETE FROM usage_points; DELETE FROM usage_run_logs; DELETE FROM usage_runs; \
                DELETE FROM usage_run_totals; DELETE FROM usage_unreported;
                """)
            try Self.restartTracking(at: trackedFrom, connection: connection)
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

    /// Version 2 adds these to version 1's tables, unchanged. A new
    /// database runs the version-1 and then this step, so the tables have
    /// a single definition whether created fresh or by migration.
    ///
    /// - `usage_series`: one baseline per `(session_id, series_id, start_ns)`:
    ///   `last_value` / `last_time_ns` are the sender's values, used only
    ///   to order the series' samples; `kind` and `model` are those of
    ///   the first sample, `first_heard_ns` its receive time.
    /// - `usage_points`: token sums per session, minute of the receive
    ///   time (since the epoch) and label group. A nil effort / thread / agent is stored as NULL,
    ///   and SQLite treats NULLs as distinct in a UNIQUE constraint, so
    ///   the uniqueness is declared on `coalesce(label, 0)`: NULL becomes
    ///   the INTEGER 0, which never equals any TEXT (not even '0'), so all
    ///   nil labels form one group of their own. The store finds a group
    ///   with `IS` (NULL-safe equality); the index guards that no second
    ///   row of a group can ever be inserted.
    /// - `usage_process_starts`: the processes heard since tracking last
    ///   (re)started ("active"), one row per start of a session.
    /// - `usage_retired_processes`: the processes heard before a restart
    ///   of tracking, and those whose export was ignored inside the
    ///   settling window because they predate tracking, as digests only, so the table holds no readable
    ///   identifier. Never deleted: a retired process must predate
    ///   tracking whatever any clock says.
    /// - `usage_meta`: `tracked_from_ns`, the time tracking started from.
    /// - `usage_run_logs`: one row per session whose main transcript was
    ///   read for its `cost-state` lines: the transcript path, where
    ///   reading stopped (`inode` / `offset`, a UInt64's bit pattern), the
    ///   open run and the first cwd. Its own checkpoint, not `usage_files`:
    ///   the version-1 reader reads the same file for something else, and
    ///   neither may move the other's position.
    /// - `usage_runs`: the closed runs of a session, by `sequence`.
    /// - `usage_run_totals`: each closed run's totals per model.
    /// - `usage_unreported`: per session, run and model, the tokens Claude
    ///   Code's totals hold beyond what was received (`reconcile(session:)`);
    ///   `time_ns` is the run's end. The token columns are named as in
    ///   `usage_points` so one aggregate can read both.
    /// - `usage_points_minute` / `usage_unreported_time`: the time-range
    ///   indexes of the token Gold query. A version-2 file created before
    ///   they existed lacks them; that is only slower, never incompatible,
    ///   so no fixed statement depends on them.
    private static let schemaV2Additions = """
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
        CREATE INDEX usage_points_minute ON usage_points (minute);
        CREATE INDEX usage_unreported_time ON usage_unreported (time_ns);
        """

    /// Brings a database at `version` up to `schemaVersion`, one step per
    /// version, all in one transaction with the version bump, so a crash
    /// cannot leave a half-migrated file that claims either version.
    private static func migrate(
        _ connection: SQLiteConnection, from version: Int64, now: @Sendable () -> Date
    ) throws {
        guard version < schemaVersion else { return }
        try connection.transaction {
            if version < 1 {
                try connection.execute(schemaV1)
            }
            if version < 2 {
                try connection.execute(schemaV2Additions)
                // Tracking starts now: whatever running processes counted
                // before this moment only sets their baselines.
                try setTrackedFrom(nanoseconds(now()), connection: connection)
            }
            try connection.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    /// Every fixed statement the store runs. Together they name every
    /// table and every column the store (and the Gold queries, which read
    /// the same columns) depends on.
    private static let fixedStatements = [
        selectRecordSQL, selectSessionRecordsSQL, writeRecordSQL,
        upsertSessionSQL, selectSessionsSQL, selectSessionSQL, upsertFileSQL, selectFileSQL,
        selectSeriesSQL, insertSeriesSQL, updateSeriesSQL, selectPointSQL, insertPointSQL, updatePointSQL,
        insertProcessStartSQL, selectProcessStartSQL, selectRetiredSQL, insertRetiredSQL, countRetiredSQL, selectTrackedFromSQL, upsertTrackedFromSQL,
        selectPointRowsSQL, selectSeriesRowsSQL, selectProcessStartsSQL,
        selectRunLogSQL, selectRunsSQL, selectRunTotalsSQL, upsertRunLogSQL, deleteRunSQL, deleteRunTotalsSQL,
        insertRunSQL, insertRunTotalSQL, selectSessionsWithSeriesSQL,
        selectSessionPointTotalsSQL, selectSessionProcessStartsSQL, selectSessionFirstHeardSQL,
        selectSessionUnreportedSQL, deleteSessionUnreportedSQL, insertUnreportedSQL, selectUnreportedRowsSQL,
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
    private static func migrateAndValidate(
        _ connection: SQLiteConnection, from version: Int64, now: @Sendable () -> Date
    ) throws {
        do {
            try migrate(connection, from: version, now: now)
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
    /// (index-against-table comparison) costs more for little gain here.
    ///
    /// A file that fails is moved aside. That loses its telemetry points
    /// for good (the version-1 tables can be rebuilt from the transcripts;
    /// the points, series and process starts cannot), but it is still the
    /// rule: a database that fails its integrity check cannot be trusted
    /// to answer at all.
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

    private static func openDatabase(in directory: URL, now: @Sendable () -> Date) throws -> SQLiteConnection {
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
            return try openAndMigrate(path: path, now: now)
        } catch where isUnusableDatabase(error) {
            try moveAside(path)
            try ensureOwnerOnlyFile(atPath: path)
            return try openAndMigrate(path: path, now: now)
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
    private static func openAndMigrate(path: String, now: @Sendable () -> Date) throws -> SQLiteConnection {
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
            try migrateAndValidate(connection, from: version, now: now)
            try checkIntegrity(connection)
            // WAL: readers (reports) do not block the per-turn writer.
            // NORMAL: in WAL mode a power loss can lose the last commits
            // but not corrupt the file. Lost version-1 rows are re-read
            // from the transcripts. For the telemetry tables, `apply`
            // moves a series' baseline (`last_value`) in the same
            // transaction as the points it adds to, so both roll back
            // together: the next accepted export of a still-running
            // process adds the lost increment again, in the minute it is
            // received. Two cases lose it for good: a process that has
            // exited sends no further export, and if the lost commit was
            // the first, baseline-only one of a process that predates
            // tracking, its next export is baseline-only again, so the
            // growth between the two is not added although the process
            // is still running.
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

    private static let selectSessionSQL =
        "SELECT session_id, transcript_path, project_root FROM usage_sessions WHERE session_id = ?1"

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

// MARK: - UsageBatchStoring

/// The actor's synchronous methods satisfy the protocol's `async`
/// requirements as they are; the ingestor reaches the store through this.
extension UsageStore: UsageBatchStoring {}

// MARK: - Token series (schema version 2)

/// The tokens of one session, minute and label group. `minute` is minutes
/// since the epoch of the time Calyx RECEIVED the export (floor-divided
/// by 60 s), never the sender's own timestamp.
struct UsagePointRow: Sendable, Equatable {
    let sessionID: String
    let minute: Int64
    let model: String
    let effort: String?
    let thread: String?
    let agent: String?
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
}

/// What one `apply(samples:processStarts:receivedAtNs:)` did.
struct UsageSeriesApplyOutcome: Sendable, Equatable {
    /// The whole call was ignored: it did not carry exactly one process
    /// start, was received before tracking started (both store nothing),
    /// or came from a process that predates tracking inside the settling
    /// window (only that process's retired digest is stored).
    var ignored = false
    /// First sample of a series that counts in full: its whole value was
    /// added.
    var newSeries = 0
    /// First sample of a series that may hold usage from before tracking:
    /// nothing added.
    var baselineOnly = 0
    /// A later sample with a larger value: the difference was added and
    /// the baseline moved.
    var advancedSeries = 0
    /// A later sample with the same value: nothing added, nothing written
    /// (the series keeps its `last_time_ns`).
    var unchangedSamples = 0
    /// `timeNs` <= the series' `last_time_ns`: ignored.
    var staleSamples = 0
    /// A later sample with a smaller value: nothing added, nothing written
    /// (the series keeps its largest value and its time).
    var regressions = 0
    /// Tokens added by this call (saturating at Int64.max); kinds with 0
    /// omitted.
    var added: [UsageTokenKind: Int64] = [:]
}

/// The stored baseline of one series.
struct UsageSeriesRow: Sendable, Equatable {
    let sessionID: String
    let seriesID: String
    let startNs: Int64
    let kind: UsageTokenKind
    let model: String
    /// The sender's values, used only to order samples of this series.
    let lastValue: Int64
    let lastTimeNs: Int64
    /// The receive time of the series' first sample; never moved.
    let firstHeardNs: Int64
}

extension UsageStore {
    /// How long after tracking (re)starts exports of processes that were
    /// already running are ignored: longer than the exporter's delivery
    /// timeout (10 s by default; it never retries a refused connection),
    /// so a late delivery of an old export cannot set a baseline.
    static let trackingSettleNs: Int64 = 15_000_000_000

    /// Applies one decoded export, received at `receivedAtNs` (Calyx's
    /// clock), in ONE transaction; any failure rolls back all of it and is
    /// rethrown. Both arrays empty is a no-op (not "ignored").
    ///
    /// - The whole call is ignored (`ignored`) when it does not carry
    ///   exactly one process start (every real export does) or was
    ///   received before `tracked_from_ns`; then nothing is stored. It is
    ///   also ignored when its process predates tracking and the call
    ///   arrived within `trackingSettleNs` of `tracked_from_ns` (it may
    ///   have been produced before tracking (re)started and delivered
    ///   late); then only the process's digest is retired, so a later
    ///   restart still knows it was heard, whatever the clock says then.
    /// - A process predates tracking when it is not active and either was
    ///   retired by a restart (identity, not clocks, decides) or started
    ///   before `tracked_from_ns`. Whether it was active is noted before
    ///   it is stored as active; a stored row keeps its first `startType`.
    /// - Each series reports a cumulative count, so only growth since the
    ///   stored baseline is new usage, and a sample at or before the
    ///   baseline's time is stale. Only growth is ever written: a later
    ///   sample with a larger value adds the difference and moves the
    ///   baseline; one with the same or a smaller value is left alone. So
    ///   the stored value is always the largest seen, what a series counts
    ///   can never exceed it whatever the order of arrival, and an idle
    ///   process re-sending its series every few seconds writes nothing.
    ///   Samples are applied in ascending `timeNs` (ties keep input order).
    /// - A series heard for the first time counts in full when its process
    ///   was already active (it appeared between two tracked exports) or
    ///   does not predate tracking; otherwise it only sets its baseline.
    /// - Increments land in the minute of `receivedAtNs`. Sums saturate at
    ///   Int64.max instead of failing, so one absurd series cannot block
    ///   every later export of its process.
    func apply(
        samples: [UsageSeriesSample], processStarts: [UsageProcessStart] = [], receivedAtNs: Int64
    ) throws -> UsageSeriesApplyOutcome {
        let connection = try openConnection()
        var outcome = UsageSeriesApplyOutcome()
        guard !samples.isEmpty || !processStarts.isEmpty else { return outcome }
        guard processStarts.count == 1, let process = processStarts.first else {
            outcome.ignored = true
            return outcome
        }

        let minute = Self.minute(ofNs: receivedAtNs)
        // `sorted` is not stable, so the input position breaks ties.
        let ordered = samples.enumerated()
            .sorted { ($0.element.timeNs, $0.offset) < ($1.element.timeNs, $1.offset) }
            .map(\.element)

        try connection.transaction {
            let trackedFrom = try Self.trackedFrom(connection: connection)
            guard receivedAtNs >= trackedFrom else {
                outcome.ignored = true
                return
            }
            // Noted before the process is stored as active.
            let wasActive = try Self.isActive(process, connection: connection)
            let predatesTracking = try !wasActive
                && (Self.isRetired(process, connection: connection) || process.startNs < trackedFrom)
            if predatesTracking, receivedAtNs < Self.saturatingSum(trackedFrom, Self.trackingSettleNs) {
                // Remembered by identity now: it may be heard only inside
                // this window before the next restart.
                try Self.retire(process, connection: connection)
                outcome.ignored = true
                return
            }

            try connection.withStatement(Self.insertProcessStartSQL) { statement in
                try statement.bind(process.sessionID, at: 1)
                try statement.bind(process.startNs, at: 2)
                try statement.bind(process.startType, at: 3)
                _ = try statement.step()
            }

            let countsInFull = wasActive || !predatesTracking
            for sample in ordered {
                let amount: Int64
                if let baseline = try Self.seriesBaseline(of: sample, connection: connection) {
                    guard sample.timeNs > baseline.lastTimeNs else {
                        outcome.staleSamples += 1
                        continue
                    }
                    if sample.value == baseline.lastValue {
                        outcome.unchangedSamples += 1
                        continue
                    } else if sample.value > baseline.lastValue {
                        amount = Self.saturatingDifference(sample.value, baseline.lastValue)
                        outcome.advancedSeries += 1
                    } else {
                        // Never written: the stored value stays the largest
                        // seen, so a late smaller sample cannot lower the
                        // baseline and let the same growth count twice.
                        outcome.regressions += 1
                        continue
                    }
                    try Self.updateSeries(with: sample, connection: connection)
                } else {
                    if countsInFull {
                        amount = sample.value
                        outcome.newSeries += 1
                    } else {
                        amount = 0
                        outcome.baselineOnly += 1
                    }
                    try Self.insertSeries(sample, firstHeardNs: receivedAtNs, connection: connection)
                }
                guard amount != 0 else { continue }
                try Self.addToPoint(amount, of: sample, minute: minute, connection: connection)
                outcome.added[sample.kind] = Self.saturatingSum(outcome.added[sample.kind] ?? 0, amount)
            }
        }
        return outcome
    }

    /// Every point row, ordered by (sessionID, minute, model, effort,
    /// thread, agent); nil sorts before any string (SQLite orders NULL
    /// first).
    func pointRows() throws -> [UsagePointRow] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectPointRowsSQL) { statement in
            var rows: [UsagePointRow] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0), let model = statement.text(at: 2) else {
                    throw UsageStoreError.malformedRow
                }
                rows.append(UsagePointRow(
                    sessionID: sessionID, minute: statement.int64(at: 1), model: model,
                    effort: statement.text(at: 3), thread: statement.text(at: 4), agent: statement.text(at: 5),
                    inputTokens: statement.int64(at: 6), outputTokens: statement.int64(at: 7),
                    cacheReadTokens: statement.int64(at: 8), cacheCreationTokens: statement.int64(at: 9)))
            }
            return rows
        }
    }

    /// Every series baseline, ordered by (sessionID, startNs, seriesID).
    func seriesRows() throws -> [UsageSeriesRow] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSeriesRowsSQL) { statement in
            var rows: [UsageSeriesRow] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0), let seriesID = statement.text(at: 1),
                      let kindName = statement.text(at: 3), let kind = UsageTokenKind(rawValue: kindName),
                      let model = statement.text(at: 4) else {
                    throw UsageStoreError.malformedRow
                }
                rows.append(UsageSeriesRow(
                    sessionID: sessionID, seriesID: seriesID, startNs: statement.int64(at: 2), kind: kind,
                    model: model, lastValue: statement.int64(at: 5), lastTimeNs: statement.int64(at: 6),
                    firstHeardNs: statement.int64(at: 7)))
            }
            return rows
        }
    }

    /// Every active process (heard since tracking last (re)started),
    /// ordered by (sessionID, startNs).
    func processStarts() throws -> [UsageProcessStart] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectProcessStartsSQL) { statement in
            var starts: [UsageProcessStart] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                starts.append(UsageProcessStart(
                    sessionID: sessionID, startNs: statement.int64(at: 1), startType: statement.text(at: 2)))
            }
            return starts
        }
    }

    /// The time tracking started from, in nanoseconds since the epoch.
    func trackedFromNs() throws -> Int64 {
        let connection = try openConnection()
        return try Self.trackedFrom(connection: connection)
    }

    /// How many retired processes are remembered (as digests).
    func retiredProcessCount() throws -> Int {
        let connection = try openConnection()
        return try connection.withStatement(Self.countRetiredSQL) { statement in
            guard try statement.step() else { throw UsageStoreError.malformedRow }
            return Int(statement.int64(at: 0))
        }
    }

    /// Restarts tracking at the store's clock (see `restartTracking`); the
    /// points and unreported rows are kept. Called when tracking is switched on, so usage from
    /// while it was off is never added.
    func resetTracking() throws {
        let connection = try openConnection()
        let trackedFrom = Self.nanoseconds(now())
        try connection.transaction {
            try Self.restartTracking(at: trackedFrom, connection: connection)
        }
    }

    // MARK: - Series helpers

    private static let nanosecondsPerMinute: Int64 = 60_000_000_000
    private static let trackedFromKey = "tracked_from_ns"

    /// `date` in whole nanoseconds since the epoch, truncated toward zero
    /// and saturated to Int64's range, so it never throws and never traps
    /// (`Date.distantFuture` / `distantPast` are legal clocks). A
    /// non-finite clock reads as `Int64.max`: nothing counts as tracked,
    /// the safe side for a clock that cannot be trusted. The single
    /// conversion for every place the store reads its clock.
    private static func nanoseconds(_ date: Date) -> Int64 {
        let nanoseconds = (date.timeIntervalSince1970 * 1_000_000_000).rounded(.towardZero)
        guard nanoseconds.isFinite else { return Int64.max }
        // Exact bounds: -2^63 is Int64.min, and 2^63 is the first double
        // above Int64.max (`Double(Int64.max)` rounds up to it), so the
        // conversion below only sees values it can represent.
        if nanoseconds < -9_223_372_036_854_775_808.0 { return Int64.min }
        if nanoseconds >= 9_223_372_036_854_775_808.0 { return Int64.max }
        return Int64(nanoseconds)
    }

    /// `lhs + rhs`, clamped to Int64's range instead of overflowing.
    private static func saturatingSum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int64.max : Int64.min
    }

    /// `lhs - rhs`, clamped to Int64's range instead of overflowing.
    private static func saturatingDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return difference }
        return rhs < 0 ? Int64.max : Int64.min
    }

    /// Floor division, so a time before the epoch falls in the minute that
    /// contains it (Swift's `/` truncates toward zero). Cannot overflow:
    /// the divisor is a positive constant above 1.
    private static func minute(ofNs timeNs: Int64) -> Int64 {
        let quotient = timeNs / nanosecondsPerMinute
        return timeNs % nanosecondsPerMinute < 0 ? quotient - 1 : quotient
    }

    private static func trackedFrom(connection: SQLiteConnection) throws -> Int64 {
        try connection.withStatement(selectTrackedFromSQL) { statement in
            try statement.bind(trackedFromKey, at: 1)
            guard try statement.step(), !statement.isNull(at: 0) else { throw UsageStoreError.malformedRow }
            return statement.int64(at: 0)
        }
    }

    private static func setTrackedFrom(_ nanoseconds: Int64, connection: SQLiteConnection) throws {
        try connection.withStatement(upsertTrackedFromSQL) { statement in
            try statement.bind(trackedFromKey, at: 1)
            try statement.bind(nanoseconds, at: 2)
            _ = try statement.step()
        }
    }

    /// The part of a restart shared by `resetTracking` and `deleteAll`, run
    /// inside their transaction: every active process is retired (its
    /// digest added; one already there stays) and the active rows and
    /// series baselines are deleted, then `tracked_from_ns` becomes
    /// `trackedFrom`, the clock, which may move back: it is the only
    /// input, so a value set under a wrong clock is corrected by the next
    /// restart. A retired process predates tracking whatever any clock
    /// says, so nothing already counted is added again and nothing
    /// deleted comes back.
    private static func restartTracking(at trackedFrom: Int64, connection: SQLiteConnection) throws {
        let active = try connection.withStatement(selectProcessStartsSQL) { statement in
            var starts: [UsageProcessStart] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                starts.append(UsageProcessStart(sessionID: sessionID, startNs: statement.int64(at: 1), startType: nil))
            }
            return starts
        }
        for start in active {
            try retire(start, connection: connection)
        }
        try connection.execute("DELETE FROM usage_process_starts; DELETE FROM usage_series;")
        try setTrackedFrom(trackedFrom, connection: connection)
    }

    /// Lowercase hex SHA-256 over the session id's UTF-8 bytes, one 0x00
    /// byte, and `startNs` in decimal ASCII: a process's identity without
    /// a readable identifier.
    private static func digest(of start: UsageProcessStart) -> String {
        var bytes = Array(start.sessionID.utf8)
        bytes.append(0)
        bytes.append(contentsOf: String(start.startNs).utf8)
        return SHA256.hash(data: bytes).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// Adds the process's digest; one already there stays.
    private static func retire(_ start: UsageProcessStart, connection: SQLiteConnection) throws {
        try connection.withStatement(insertRetiredSQL) { statement in
            try statement.bind(digest(of: start), at: 1)
            _ = try statement.step()
        }
    }

    private static func isActive(_ start: UsageProcessStart, connection: SQLiteConnection) throws -> Bool {
        try connection.withStatement(selectProcessStartSQL) { statement in
            try statement.bind(start.sessionID, at: 1)
            try statement.bind(start.startNs, at: 2)
            return try statement.step()
        }
    }

    private static func isRetired(_ start: UsageProcessStart, connection: SQLiteConnection) throws -> Bool {
        try connection.withStatement(selectRetiredSQL) { statement in
            try statement.bind(digest(of: start), at: 1)
            return try statement.step()
        }
    }

    private static func seriesBaseline(
        of sample: UsageSeriesSample, connection: SQLiteConnection
    ) throws -> (lastValue: Int64, lastTimeNs: Int64)? {
        try connection.withStatement(selectSeriesSQL) { statement in
            try statement.bind(sample.sessionID, at: 1)
            try statement.bind(sample.seriesID, at: 2)
            try statement.bind(sample.startNs, at: 3)
            guard try statement.step() else { return nil }
            return (statement.int64(at: 0), statement.int64(at: 1))
        }
    }

    private static func insertSeries(
        _ sample: UsageSeriesSample, firstHeardNs: Int64, connection: SQLiteConnection
    ) throws {
        try connection.withStatement(insertSeriesSQL) { statement in
            try statement.bind(sample.sessionID, at: 1)
            try statement.bind(sample.seriesID, at: 2)
            try statement.bind(sample.startNs, at: 3)
            try statement.bind(sample.kind.rawValue, at: 4)
            try statement.bind(sample.model, at: 5)
            try statement.bind(sample.value, at: 6)
            try statement.bind(sample.timeNs, at: 7)
            try statement.bind(firstHeardNs, at: 8)
            _ = try statement.step()
        }
    }

    /// Moves the baseline; `kind`, `model` and `first_heard_ns` stay those
    /// of the first sample.
    private static func updateSeries(with sample: UsageSeriesSample, connection: SQLiteConnection) throws {
        try connection.withStatement(updateSeriesSQL) { statement in
            try statement.bind(sample.sessionID, at: 1)
            try statement.bind(sample.seriesID, at: 2)
            try statement.bind(sample.startNs, at: 3)
            try statement.bind(sample.value, at: 4)
            try statement.bind(sample.timeNs, at: 5)
            _ = try statement.step()
        }
    }

    /// Adds `amount` to the sample's kind in its point row of `minute`,
    /// creating the row if needed. The sum is computed here, saturating,
    /// not in SQL: SQLite turns an overflowing integer sum into a REAL.
    private static func addToPoint(
        _ amount: Int64, of sample: UsageSeriesSample, minute: Int64, connection: SQLiteConnection
    ) throws {
        let existing = try connection.withStatement(selectPointSQL) { statement -> (rowID: Int64, tokens: [Int64])? in
            try bindGroup(of: sample, minute: minute, to: statement)
            guard try statement.step() else { return nil }
            return (statement.int64(at: 0), (1...4).map { statement.int64(at: Int32($0)) })
        }
        var tokens = existing?.tokens ?? [0, 0, 0, 0]
        let column: Int
        switch sample.kind {
        case .input: column = 0
        case .output: column = 1
        case .cacheRead: column = 2
        case .cacheCreation: column = 3
        }
        tokens[column] = saturatingSum(tokens[column], amount)

        if let existing {
            try connection.withStatement(updatePointSQL) { statement in
                try statement.bind(existing.rowID, at: 1)
                for (offset, value) in tokens.enumerated() {
                    try statement.bind(value, at: Int32(offset + 2))
                }
                _ = try statement.step()
            }
        } else {
            try connection.withStatement(insertPointSQL) { statement in
                try bindGroup(of: sample, minute: minute, to: statement)
                for (offset, value) in tokens.enumerated() {
                    try statement.bind(value, at: Int32(offset + 7))
                }
                _ = try statement.step()
            }
        }
    }

    private static func bindGroup(of sample: UsageSeriesSample, minute: Int64, to statement: SQLiteStatement) throws {
        try statement.bind(sample.sessionID, at: 1)
        try statement.bind(minute, at: 2)
        try statement.bind(sample.model, at: 3)
        try statement.bind(sample.effort, at: 4)
        try statement.bind(sample.thread, at: 5)
        try statement.bind(sample.agent, at: 6)
    }

    // MARK: - Series statements

    private static let selectSeriesSQL = """
        SELECT last_value, last_time_ns FROM usage_series \
        WHERE session_id = ?1 AND series_id = ?2 AND start_ns = ?3
        """

    private static let insertSeriesSQL = """
        INSERT INTO usage_series \
        (session_id, series_id, start_ns, kind, model, last_value, last_time_ns, first_heard_ns) \
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """

    private static let updateSeriesSQL = """
        UPDATE usage_series SET last_value = ?4, last_time_ns = ?5 \
        WHERE session_id = ?1 AND series_id = ?2 AND start_ns = ?3
        """

    /// `IS` rather than `=` so a NULL label matches the NULL group.
    private static let selectPointSQL = """
        SELECT rowid, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens FROM usage_points \
        WHERE session_id = ?1 AND minute = ?2 AND model = ?3 AND effort IS ?4 AND thread IS ?5 AND agent IS ?6
        """

    private static let insertPointSQL = """
        INSERT INTO usage_points (session_id, minute, model, effort, thread, agent, \
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens) \
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        """

    private static let updatePointSQL = """
        UPDATE usage_points SET input_tokens = ?2, output_tokens = ?3, cache_read_tokens = ?4, \
        cache_creation_tokens = ?5 WHERE rowid = ?1
        """

    /// The first stored start type wins.
    private static let insertProcessStartSQL = """
        INSERT INTO usage_process_starts (session_id, start_ns, start_type) VALUES (?1, ?2, ?3) \
        ON CONFLICT (session_id, start_ns) DO NOTHING
        """

    private static let selectProcessStartSQL =
        "SELECT 1 FROM usage_process_starts WHERE session_id = ?1 AND start_ns = ?2"

    private static let selectRetiredSQL = "SELECT 1 FROM usage_retired_processes WHERE digest = ?1"

    /// A digest already there stays.
    private static let insertRetiredSQL =
        "INSERT INTO usage_retired_processes (digest) VALUES (?1) ON CONFLICT (digest) DO NOTHING"

    private static let countRetiredSQL = "SELECT count(*) FROM usage_retired_processes"

    private static let selectTrackedFromSQL = "SELECT value FROM usage_meta WHERE key = ?1"

    private static let upsertTrackedFromSQL = """
        INSERT INTO usage_meta (key, value) VALUES (?1, ?2) \
        ON CONFLICT (key) DO UPDATE SET value = excluded.value
        """

    private static let selectPointRowsSQL = """
        SELECT session_id, minute, model, effort, thread, agent, \
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens FROM usage_points \
        ORDER BY session_id, minute, model, effort, thread, agent
        """

    private static let selectSeriesRowsSQL = """
        SELECT session_id, series_id, start_ns, kind, model, last_value, last_time_ns, first_heard_ns \
        FROM usage_series ORDER BY session_id, start_ns, series_id
        """

    private static let selectProcessStartsSQL =
        "SELECT session_id, start_ns, start_type FROM usage_process_starts ORDER BY session_id, start_ns"
}

// MARK: - Run logs (schema version 2)

/// The transcript a stored run log was read from, and where reading
/// stopped.
struct UsageRunLogFile: Sendable, Equatable {
    let path: String
    let checkpoint: TranscriptCheckpoint
}

extension UsageStore {
    /// The stored log of a session and where reading stopped; nil when
    /// nothing was stored for it. Runs come back in `sequence` order with
    /// the sequences as stored.
    func runLog(forSession sessionID: String) throws -> (log: UsageRunLog, file: UsageRunLogFile)? {
        let connection = try openConnection()
        return try Self.runLog(forSession: sessionID, connection: connection)
    }

    private static func runLog(
        forSession sessionID: String, connection: SQLiteConnection
    ) throws -> (log: UsageRunLog, file: UsageRunLogFile)? {
        let head = try connection.withStatement(Self.selectRunLogSQL) {
            statement -> (file: UsageRunLogFile, openBeginNs: Int64?, openEndNs: Int64?, cwd: String?)? in
            try statement.bind(sessionID, at: 1)
            guard try statement.step() else { return nil }
            guard let path = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
            let file = UsageRunLogFile(path: path, checkpoint: TranscriptCheckpoint(
                inode: UInt64(bitPattern: statement.int64(at: 1)), offset: UInt64(bitPattern: statement.int64(at: 2))))
            return (file, Self.optionalInt64(statement, at: 3), Self.optionalInt64(statement, at: 4), statement.text(at: 5))
        }
        guard let head else { return nil }

        var totals: [Int64: [String: UsageTokenTotals]] = [:]
        try connection.withStatement(Self.selectRunTotalsSQL) { statement in
            try statement.bind(sessionID, at: 1)
            while try statement.step() {
                guard let model = statement.text(at: 1) else { throw UsageStoreError.malformedRow }
                totals[statement.int64(at: 0), default: [:]][model] = UsageTokenTotals(
                    input: statement.int64(at: 2), output: statement.int64(at: 3),
                    cacheRead: statement.int64(at: 4), cacheCreation: statement.int64(at: 5))
            }
        }
        let runs = try connection.withStatement(Self.selectRunsSQL) { statement in
            try statement.bind(sessionID, at: 1)
            var runs: [UsageRun] = []
            while try statement.step() {
                let sequence = statement.int64(at: 0)
                guard let storedSequence = Int(exactly: sequence) else { throw UsageStoreError.malformedRow }
                runs.append(UsageRun(
                    sequence: storedSequence, beginNs: Self.optionalInt64(statement, at: 1),
                    endNs: Self.optionalInt64(statement, at: 2), totals: totals.removeValue(forKey: sequence) ?? [:]))
            }
            return runs
        }
        // A total whose run is not stored cannot be placed in the log.
        guard totals.isEmpty else { throw UsageStoreError.malformedRow }
        let log = UsageRunLog(runs: runs, openBeginNs: head.openBeginNs, openEndNs: head.openEndNs, cwd: head.cwd)
        return (log, head.file)
    }

    /// Replaces the session's stored log and checkpoint with these, in one
    /// transaction. The path is stored as given (it is not checked), and
    /// no `usage_sessions` row is created or changed.
    ///
    /// Only what changed is written, because the reader saves after every
    /// bounded read of every session it looks at, and most of those saves
    /// change little or nothing: an unchanged log and file write nothing at
    /// all (not a byte of the database or its WAL); otherwise the log row
    /// is written when its fields differ, and the runs and their totals
    /// from the first run that differs from the stored one on. What is
    /// stored afterwards equals replacing everything.
    func saveRunLog(_ log: UsageRunLog, file: UsageRunLogFile, forSession sessionID: String) throws {
        let connection = try openConnection()
        // Read, compare and write in one transaction, so the comparison is
        // against exactly the state the writes apply to. A transaction that
        // writes nothing leaves the database and its WAL untouched.
        try connection.transaction {
            let stored = try Self.runLog(forSession: sessionID, connection: connection)
            if let stored, stored.log == log, stored.file == file { return }
            let storedLog = stored?.log
            let headChanged = stored?.file != file || storedLog?.openBeginNs != log.openBeginNs
                || storedLog?.openEndNs != log.openEndNs || storedLog?.cwd != log.cwd
            if headChanged {
                try connection.withStatement(Self.upsertRunLogSQL) { statement in
                    try statement.bind(sessionID, at: 1)
                    try statement.bind(file.path, at: 2)
                    try statement.bind(Int64(bitPattern: file.checkpoint.inode), at: 3)
                    try statement.bind(Int64(bitPattern: file.checkpoint.offset), at: 4)
                    try Self.bind(log.openBeginNs, at: 5, to: statement)
                    try Self.bind(log.openEndNs, at: 6, to: statement)
                    try statement.bind(log.cwd, at: 7)
                    _ = try statement.step()
                }
            }
            let storedRuns = storedLog?.runs ?? []
            let firstChange = zip(storedRuns, log.runs).prefix { $0 == $1 }.count
            for run in storedRuns.dropFirst(firstChange) {
                for sql in [Self.deleteRunSQL, Self.deleteRunTotalsSQL] {
                    try connection.withStatement(sql) { statement in
                        try statement.bind(sessionID, at: 1)
                        try statement.bind(Int64(run.sequence), at: 2)
                        _ = try statement.step()
                    }
                }
            }
            for run in log.runs.dropFirst(firstChange) {
                let sequence = Int64(run.sequence)
                try connection.withStatement(Self.insertRunSQL) { statement in
                    try statement.bind(sessionID, at: 1)
                    try statement.bind(sequence, at: 2)
                    try Self.bind(run.beginNs, at: 3, to: statement)
                    try Self.bind(run.endNs, at: 4, to: statement)
                    _ = try statement.step()
                }
                for (model, totals) in run.totals {
                    try connection.withStatement(Self.insertRunTotalSQL) { statement in
                        try statement.bind(sessionID, at: 1)
                        try statement.bind(sequence, at: 2)
                        try statement.bind(model, at: 3)
                        try statement.bind(totals.input, at: 4)
                        try statement.bind(totals.output, at: 5)
                        try statement.bind(totals.cacheRead, at: 6)
                        try statement.bind(totals.cacheCreation, at: 7)
                        _ = try statement.step()
                    }
                }
            }
        }
    }

    /// Every session with at least one stored series, ascending: the
    /// sessions Calyx has heard from since tracking (re)started, whose
    /// transcripts are worth looking at (a read of an unchanged file
    /// costs one `fstat`).
    func sessionsWithSeries() throws -> [String] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSessionsWithSeriesSQL) { statement in
            var sessions: [String] = []
            while try statement.step() {
                guard let sessionID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                sessions.append(sessionID)
            }
            return sessions
        }
    }

    /// Sets the session's project root unless one is already stored (the
    /// first stored root wins), creating the session row when there is
    /// none. The same statement a version-1 batch uses, with no transcript
    /// path, so a stored path is kept and the rule has one definition.
    func setProjectRootIfUnset(_ root: String, forSession sessionID: String) throws {
        let connection = try openConnection()
        try connection.withStatement(Self.upsertSessionSQL) { statement in
            try statement.bind(sessionID, at: 1)
            try statement.bind(nil, at: 2)
            try statement.bind(root, at: 3)
            _ = try statement.step()
        }
    }

    // MARK: - Run log helpers

    /// `nil` binds SQL NULL.
    private static func bind(_ value: Int64?, at index: Int32, to statement: SQLiteStatement) throws {
        if let value {
            try statement.bind(value, at: index)
        } else {
            try statement.bind(nil as String?, at: index)
        }
    }

    private static func optionalInt64(_ statement: SQLiteStatement, at index: Int32) -> Int64? {
        statement.isNull(at: index) ? nil : statement.int64(at: index)
    }

    // MARK: - Run log statements

    private static let selectRunLogSQL = """
        SELECT path, inode, offset, open_begin_ns, open_end_ns, cwd FROM usage_run_logs WHERE session_id = ?1
        """

    private static let selectRunsSQL =
        "SELECT sequence, begin_ns, end_ns FROM usage_runs WHERE session_id = ?1 ORDER BY sequence"

    private static let selectRunTotalsSQL = """
        SELECT sequence, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens \
        FROM usage_run_totals WHERE session_id = ?1 ORDER BY sequence, model
        """

    private static let upsertRunLogSQL = """
        INSERT INTO usage_run_logs (session_id, path, inode, offset, open_begin_ns, open_end_ns, cwd) \
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) \
        ON CONFLICT (session_id) DO UPDATE SET path = excluded.path, inode = excluded.inode, \
        offset = excluded.offset, open_begin_ns = excluded.open_begin_ns, open_end_ns = excluded.open_end_ns, \
        cwd = excluded.cwd
        """

    private static let deleteRunSQL = "DELETE FROM usage_runs WHERE session_id = ?1 AND sequence = ?2"

    private static let deleteRunTotalsSQL = "DELETE FROM usage_run_totals WHERE session_id = ?1 AND sequence = ?2"

    private static let insertRunSQL =
        "INSERT INTO usage_runs (session_id, sequence, begin_ns, end_ns) VALUES (?1, ?2, ?3, ?4)"

    private static let insertRunTotalSQL = """
        INSERT INTO usage_run_totals (session_id, sequence, model, input_tokens, output_tokens, \
        cache_read_tokens, cache_creation_tokens) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """

    private static let selectSessionsWithSeriesSQL =
        "SELECT DISTINCT session_id FROM usage_series ORDER BY session_id"
}

// MARK: - Unreported usage (schema version 2)

/// One stored unreported amount: what Claude Code's totals for one run and
/// model hold beyond what was received.
struct UsageUnreportedStoredRow: Sendable, Equatable {
    let sessionID: String
    let sequence: Int
    let timeNs: Int64
    let model: String
    let totals: UsageTokenTotals
}

extension UsageStore {
    /// Recomputes the session's unreported rows from what is stored (run
    /// log, points, process starts, series, tracked_from) and replaces them,
    /// in ONE transaction: nothing can be applied between reading and
    /// writing.
    ///
    /// - A session with no stored run log, or one whose outcome has no
    ///   `firstSequence`, changes nothing.
    /// - Otherwise the session's rows with `sequence >= firstSequence` are
    ///   replaced by the outcome's rows. Rows of earlier runs are never
    ///   touched: they were computed while those runs were inside the
    ///   tracking period, and restarting tracking must not erase history.
    /// - When the stored rows already equal the outcome's, nothing is
    ///   written at all (the ledger reconciles after every export that
    ///   changed a session, so an unchanged result must cost no disk write);
    ///   a transaction that writes nothing leaves the database and its WAL
    ///   untouched.
    func reconcile(session sessionID: String) throws -> UsageReconcileOutcome {
        let connection = try openConnection()
        var outcome = UsageReconcileOutcome.empty
        try connection.transaction {
            guard let stored = try Self.runLog(forSession: sessionID, connection: connection) else { return }
            let input = UsageReconcileInput(
                runs: stored.log.runs,
                trackedFromNs: try Self.trackedFrom(connection: connection),
                processStarts: try Self.processStarts(ofSession: sessionID, connection: connection),
                firstHeardNs: try Self.firstHeardNs(ofSession: sessionID, connection: connection),
                heard: try Self.heardBuckets(ofSession: sessionID, connection: connection))
            outcome = UsageReconciliation.reconcile(input)
            guard let firstSequence = outcome.firstSequence else { return }

            let replacement = outcome.rows.map {
                UsageUnreportedStoredRow(
                    sessionID: sessionID, sequence: $0.sequence, timeNs: $0.timeNs, model: $0.model, totals: $0.totals)
            }
            let current = try Self.unreportedRows(
                ofSession: sessionID, fromSequence: firstSequence, connection: connection)
            guard current != replacement else { return }

            try connection.withStatement(Self.deleteSessionUnreportedSQL) { statement in
                try statement.bind(sessionID, at: 1)
                try statement.bind(Int64(firstSequence), at: 2)
                _ = try statement.step()
            }
            for row in replacement {
                try connection.withStatement(Self.insertUnreportedSQL) { statement in
                    try statement.bind(row.sessionID, at: 1)
                    try statement.bind(Int64(row.sequence), at: 2)
                    try statement.bind(row.model, at: 3)
                    try statement.bind(row.timeNs, at: 4)
                    try statement.bind(row.totals.input, at: 5)
                    try statement.bind(row.totals.output, at: 6)
                    try statement.bind(row.totals.cacheRead, at: 7)
                    try statement.bind(row.totals.cacheCreation, at: 8)
                    _ = try statement.step()
                }
            }
        }
        return outcome
    }

    /// Every stored row, ordered by (sessionID, sequence, model).
    func unreportedRows() throws -> [UsageUnreportedStoredRow] {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectUnreportedRowsSQL) { statement in
            var rows: [UsageUnreportedStoredRow] = []
            while try statement.step() {
                rows.append(try Self.decodeUnreported(statement))
            }
            return rows
        }
    }

    // MARK: - Unreported helpers

    /// The session's own active process starts, ordered by start.
    private static func processStarts(
        ofSession sessionID: String, connection: SQLiteConnection
    ) throws -> [UsageProcessStart] {
        try connection.withStatement(selectSessionProcessStartsSQL) { statement in
            try statement.bind(sessionID, at: 1)
            var starts: [UsageProcessStart] = []
            while try statement.step() {
                starts.append(UsageProcessStart(
                    sessionID: sessionID, startNs: statement.int64(at: 0), startType: statement.text(at: 1)))
            }
            return starts
        }
    }

    /// The smallest `first_heard_ns` among the session's series; nil when
    /// it has none (`MIN` over no rows is NULL).
    private static func firstHeardNs(ofSession sessionID: String, connection: SQLiteConnection) throws -> Int64? {
        try connection.withStatement(selectSessionFirstHeardSQL) { statement in
            try statement.bind(sessionID, at: 1)
            guard try statement.step() else { throw UsageStoreError.malformedRow }
            return optionalInt64(statement, at: 0)
        }
    }

    /// The session's points summed per (minute, model). Summed here,
    /// saturating, not in SQL: SQLite turns an overflowing integer sum into
    /// a REAL.
    private static func heardBuckets(
        ofSession sessionID: String, connection: SQLiteConnection
    ) throws -> [UsageHeardBucket] {
        try connection.withStatement(selectSessionPointTotalsSQL) { statement in
            try statement.bind(sessionID, at: 1)
            var buckets: [UsageHeardBucket] = []
            while try statement.step() {
                guard let model = statement.text(at: 1) else { throw UsageStoreError.malformedRow }
                let minute = statement.int64(at: 0)
                let totals = UsageTokenTotals(
                    input: statement.int64(at: 2), output: statement.int64(at: 3),
                    cacheRead: statement.int64(at: 4), cacheCreation: statement.int64(at: 5))
                // Rows arrive ordered by (minute, model), so a group's rows are adjacent.
                if let last = buckets.last, last.minute == minute, last.model == model {
                    buckets[buckets.count - 1] = UsageHeardBucket(
                        minute: minute, model: model, totals: UsageTokenTotals(
                            input: saturatingSum(last.totals.input, totals.input),
                            output: saturatingSum(last.totals.output, totals.output),
                            cacheRead: saturatingSum(last.totals.cacheRead, totals.cacheRead),
                            cacheCreation: saturatingSum(last.totals.cacheCreation, totals.cacheCreation)))
                } else {
                    buckets.append(UsageHeardBucket(minute: minute, model: model, totals: totals))
                }
            }
            return buckets
        }
    }

    private static func unreportedRows(
        ofSession sessionID: String, fromSequence firstSequence: Int, connection: SQLiteConnection
    ) throws -> [UsageUnreportedStoredRow] {
        try connection.withStatement(selectSessionUnreportedSQL) { statement in
            try statement.bind(sessionID, at: 1)
            try statement.bind(Int64(firstSequence), at: 2)
            var rows: [UsageUnreportedStoredRow] = []
            while try statement.step() {
                rows.append(try decodeUnreported(statement))
            }
            return rows
        }
    }

    /// Decodes a row selected with `unreportedColumns`.
    private static func decodeUnreported(_ statement: SQLiteStatement) throws -> UsageUnreportedStoredRow {
        guard let sessionID = statement.text(at: 0), let model = statement.text(at: 2),
              let sequence = Int(exactly: statement.int64(at: 1)) else {
            throw UsageStoreError.malformedRow
        }
        return UsageUnreportedStoredRow(
            sessionID: sessionID, sequence: sequence, timeNs: statement.int64(at: 3), model: model,
            totals: UsageTokenTotals(
                input: statement.int64(at: 4), output: statement.int64(at: 5),
                cacheRead: statement.int64(at: 6), cacheCreation: statement.int64(at: 7)))
    }

    // MARK: - Unreported statements

    private static let unreportedColumns = """
        session_id, sequence, model, time_ns, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens
        """

    private static let selectSessionPointTotalsSQL = """
        SELECT minute, model, input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens \
        FROM usage_points WHERE session_id = ?1 ORDER BY minute, model
        """

    private static let selectSessionProcessStartsSQL =
        "SELECT start_ns, start_type FROM usage_process_starts WHERE session_id = ?1 ORDER BY start_ns"

    private static let selectSessionFirstHeardSQL =
        "SELECT MIN(first_heard_ns) FROM usage_series WHERE session_id = ?1"

    private static let selectSessionUnreportedSQL = """
        SELECT \(unreportedColumns) FROM usage_unreported WHERE session_id = ?1 AND sequence >= ?2 \
        ORDER BY sequence, model
        """

    private static let deleteSessionUnreportedSQL =
        "DELETE FROM usage_unreported WHERE session_id = ?1 AND sequence >= ?2"

    private static let insertUnreportedSQL = """
        INSERT INTO usage_unreported (\(unreportedColumns)) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """

    private static let selectUnreportedRowsSQL =
        "SELECT \(unreportedColumns) FROM usage_unreported ORDER BY session_id, sequence, model"
}
