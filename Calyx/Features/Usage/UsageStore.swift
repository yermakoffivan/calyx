// UsageStore.swift
// Calyx
//
// The ledger's database: per-series baselines of Claude Code's cumulative
// token metric, the per-minute token points their increments are added
// to, the process starts, the time tracking started from, per-session
// project roots, the run logs read from Claude Code's own `cost-state`
// lines, and the unreported amounts the two sources' comparison yields,
// in a SQLite database. SQLite rather than the JSON documents used
// elsewhere because each export must commit atomically with the
// baselines it moves, and the data only grows. The store touches nothing
// outside its own directory; callers resolve paths and project roots and
// pass them in.

import CryptoKit
import Foundation
import SQLite3

// MARK: - Session

struct UsageSessionMeta: Sendable, Equatable {
    let sessionID: String
    /// The repository root the session is attributed to, resolved by the
    /// caller; nil while unknown.
    let projectRoot: String?
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
    /// The database's layout is not the one this build creates: a version
    /// below this build's, a version-0 file that already holds tables, or
    /// this version with other tables or columns. Raised while opening,
    /// where it makes the file be moved aside.
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

    /// The store's clock: read when tracking starts (a new database,
    /// `deleteAll`, a restart). Injected so tests can pin it.
    private let now: @Sendable () -> Date

    /// Opens the database in `directory`, creating both as needed.
    ///
    /// - The directory is created (with intermediates) and set to 0700
    ///   even if it already existed with looser permissions.
    /// - `usage.sqlite` is created, or tightened, to 0600 BEFORE SQLite
    ///   opens it: SQLite gives `-wal` / `-shm` the main file's mode, so
    ///   this is what keeps those owner-only too.
    /// - A file that is not a SQLite database, is reported corrupt, has a
    ///   newer schema version, does not have exactly the layout this build
    ///   creates (see `createAndValidate`), fails `PRAGMA quick_check`, or
    ///   is a symbolic link (never followed) is moved aside to
    ///   `usage.sqlite.corrupt-<suffix>` and a fresh database is created.
    ///   The telemetry tables (series, points, process starts) cannot be
    ///   rebuilt: their source is exports Claude Code sends once, so what
    ///   a moved-aside file held is lost from the ledger (it stays in the
    ///   moved file). Refusing to start would still be worse than
    ///   starting empty.
    /// - A new database gets `tracked_from_ns` = `now()` at that moment.
    init(directory: URL, now: @escaping @Sendable () -> Date) throws {
        self.now = now
        connection = try Self.openDatabase(in: directory, now: now)
    }

    /// As `init(directory:now:)` with the system clock.
    init(directory: URL) throws {
        try self.init(directory: directory, now: { Date() })
    }

    /// The stored metadata of one session; nil if none was stored.
    func session(_ sessionID: String) throws -> UsageSessionMeta? {
        let connection = try openConnection()
        return try connection.withStatement(Self.selectSessionSQL) { statement in
            try statement.bind(sessionID, at: 1)
            guard try statement.step() else { return nil }
            guard let storedID = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
            return UsageSessionMeta(sessionID: storedID, projectRoot: statement.text(at: 1))
        }
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

    /// Removes every session, point, series baseline, run log (with its
    /// runs and totals) and unreported row in one transaction and restarts
    /// tracking at the store's clock (see `restartTracking`). The
    /// processes heard so far are retired, so their later exports only set
    /// baselines and deleted usage never comes back; only their digests
    /// remain. The store stays open and usable.
    func deleteAll() throws {
        let connection = try openConnection()
        let trackedFrom = UsageClock.nanoseconds(now())
        try connection.transaction {
            try connection.execute("""
                DELETE FROM usage_sessions; DELETE FROM usage_points; DELETE FROM usage_run_logs; \
                DELETE FROM usage_runs; DELETE FROM usage_run_totals; DELETE FROM usage_unreported;
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
    /// Schema version 2, the only layout this build reads and writes.
    ///
    /// - `usage_sessions`: the project root each session is attributed to
    ///   (`setProjectRootIfUnset`; the first stored root wins).
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
    ///   open run and the first cwd.
    /// - `usage_runs`: the closed runs of a session, by `sequence`.
    /// - `usage_run_totals`: each closed run's totals per model.
    /// - `usage_unreported`: per session, run and model, the tokens Claude
    ///   Code's totals hold beyond what was received (`reconcile(session:)`);
    ///   `time_ns` is the run's end. The token columns are named as in
    ///   `usage_points` so one aggregate can read both.
    /// - `usage_points_minute` / `usage_unreported_time`: the time-range
    ///   indexes of the token Gold query. A version-2 file created before
    ///   they existed lacks them; that is only slower, never incompatible,
    ///   so no fixed statement depends on them and the open-time layout
    ///   check compares tables and columns only.
    private static let schema = """
        CREATE TABLE usage_sessions (
            session_id TEXT NOT NULL PRIMARY KEY,
            project_root TEXT
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

    /// Every fixed statement the store runs. Together they name every
    /// table and every column the store (and the Gold query, which reads
    /// the same columns) depends on.
    private static let fixedStatements = [
        upsertSessionSQL, selectSessionSQL,
        selectSeriesSQL, insertSeriesSQL, updateSeriesSQL, selectPointSQL, insertPointSQL, updatePointSQL,
        insertProcessStartSQL, selectProcessStartSQL, selectRetiredSQL, insertRetiredSQL, countRetiredSQL, selectTrackedFromSQL, upsertTrackedFromSQL,
        selectPointRowsSQL, selectSeriesRowsSQL, selectProcessStartsSQL,
        selectRunLogSQL, selectRunsSQL, selectRunTotalsSQL, upsertRunLogSQL, deleteRunSQL, deleteRunTotalsSQL,
        insertRunSQL, insertRunTotalSQL, selectSessionsWithSeriesSQL,
        selectSessionPointTotalsSQL, selectSessionProcessStartsSQL, selectSessionFirstHeardSQL,
        selectSessionUnreportedSQL, deleteSessionUnreportedSQL, insertUnreportedSQL, selectUnreportedRowsSQL,
    ]

    /// A database's layout: each table's column names in column order,
    /// by table name. SQLite's own tables (`sqlite_*`, e.g. the
    /// `sqlite_stat1` an ANALYZE adds) are not part of it, nor are
    /// indexes, views and triggers. The table name is bound, never
    /// spliced into SQL, since a foreign file may name tables anything.
    private static func layout(of connection: SQLiteConnection) throws -> [String: [String]] {
        let tables = try connection.withTransientStatement(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name"
        ) { statement in
            var names: [String] = []
            while try statement.step() {
                guard let name = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                names.append(name)
            }
            return names
        }
        var layout: [String: [String]] = [:]
        for table in tables {
            layout[table] = try connection.withTransientStatement(
                "SELECT name FROM pragma_table_info(?1) ORDER BY cid"
            ) { statement in
                try statement.bind(table, at: 1)
                var columns: [String] = []
                while try statement.step() {
                    guard let column = statement.text(at: 0) else { throw UsageStoreError.malformedRow }
                    columns.append(column)
                }
                return columns
            }
        }
        return layout
    }

    /// The layout `schema` produces, read back with `layout(of:)` from a
    /// private in-memory database: both sides of the open-time comparison
    /// come from the same statements and the same reader, so a file this
    /// build created always compares equal.
    private static func finalLayout() throws -> [String: [String]] {
        let scratch = try SQLiteConnection(path: ":memory:")
        defer { scratch.close() }
        try scratch.execute(schema)
        return try layout(of: scratch)
    }

    /// Creates the schema in a new database, or accepts an existing one
    /// only if it is exactly this build's layout, then proves the result
    /// by PREPARING every fixed statement (which also caches them).
    ///
    /// - Version 0 holding no table (a new or zero-byte file): `schema`,
    ///   `tracked_from_ns` = `now()` and the version are written in one
    ///   transaction, so a crash cannot leave a half-created file that
    ///   claims the version. Tracking starts now: whatever running
    ///   processes counted before this moment only sets their baselines.
    /// - Version 2: accepted only if `layout(of:)` equals `finalLayout()`
    ///   (same table names; per table the same column names in the same
    ///   order). Missing indexes are no reason to reject (they only slow
    ///   the Gold query).
    /// - Anything else -- a version-0 file that holds a table, or any
    ///   other version below 2 -- is `incompatibleSchema`.
    ///
    /// Reading the reference layout (`finalLayout()`, in memory) maps no
    /// error: its failure is a programming error and propagates, so it
    /// never moves the user's file aside. Reading the opened file's layout
    /// maps exactly SQLITE_ERROR (primary code) to `incompatibleSchema`;
    /// every other code (I/O, busy, locked, ...) propagates untouched.
    ///
    /// SQLITE_ERROR from creating or preparing ("no such table", "no such
    /// column") becomes `incompatibleSchema`. An I/O or lock error has its
    /// own code and propagates untouched; it must never cost a healthy
    /// database.
    private static func createAndValidate(
        _ connection: SQLiteConnection, version: Int64, now: @Sendable () -> Date
    ) throws {
        let expected = try finalLayout()
        let actual: [String: [String]]
        do {
            actual = try layout(of: connection)
        } catch let error as SQLiteError where error.primaryCode == SQLITE_ERROR {
            // SQLITE_ERROR here means the file's schema cannot even be
            // described, e.g. a virtual table of a module this build does
            // not register ("no such module" from `pragma_table_info`): a
            // file this build did not write, so it is incompatible like
            // any other foreign shape and is moved aside.
            throw UsageStoreError.incompatibleSchema
        }
        switch version {
        case 0 where actual.isEmpty:
            break
        case schemaVersion where actual == expected:
            break
        default:
            throw UsageStoreError.incompatibleSchema
        }
        do {
            if version == 0 {
                try connection.transaction {
                    try connection.execute(schema)
                    try setTrackedFrom(UsageClock.nanoseconds(now()), connection: connection)
                    try connection.execute("PRAGMA user_version = \(schemaVersion)")
                }
            }
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
    /// at open instead: one scan per launch, cheap next to never
    /// recovering. `quick_check`
    /// rather than `integrity_check` because the latter's extra work
    /// (index-against-table comparison) costs more for little gain here.
    ///
    /// A file that fails is moved aside. That loses its telemetry points,
    /// series and process starts for good, but it is still the rule: a
    /// database that fails its integrity check cannot be trusted to answer
    /// at all.
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
            return try openAndCheck(path: path, now: now)
        } catch where isUnusableDatabase(error) {
            try moveAside(path)
            try ensureOwnerOnlyFile(atPath: path)
            return try openAndCheck(path: path, now: now)
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
    /// schema is then created or checked, the content is checked, and
    /// only a database that passed is switched to WAL, so a file about to
    /// be moved aside is not rewritten first.
    private static func openAndCheck(path: String, now: @Sendable () -> Date) throws -> SQLiteConnection {
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
            try createAndValidate(connection, version: version, now: now)
            try checkIntegrity(connection)
            // WAL: readers (reports) do not block the per-export writer.
            // NORMAL: in WAL mode a power loss can lose the last commits
            // but not corrupt the file. `apply` moves a series' baseline
            // (`last_value`) in the same
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

    private static let upsertSessionSQL = """
        INSERT INTO usage_sessions (session_id, project_root) VALUES (?1, ?2) \
        ON CONFLICT (session_id) DO UPDATE SET \
        project_root = COALESCE(project_root, excluded.project_root)
        """

    private static let selectSessionSQL =
        "SELECT session_id, project_root FROM usage_sessions WHERE session_id = ?1"
}

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
    /// The sessions for which this call stored a new series (also one
    /// that only sets a baseline, and one whose value is 0) or added
    /// tokens. Not: stale samples, zero increments, regressions. Empty for
    /// an ignored call.
    var changedSessions: Set<String> = []
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
                    outcome.changedSessions.insert(sample.sessionID)
                }
                guard amount != 0 else { continue }
                outcome.changedSessions.insert(sample.sessionID)
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
        let trackedFrom = UsageClock.nanoseconds(now())
        try connection.transaction {
            try Self.restartTracking(at: trackedFrom, connection: connection)
        }
    }

    /// Records whether tracking is active (`usage_meta.tracking_active`,
    /// 0 / 1). Paused -> active restarts tracking (`restartTracking`) in
    /// the same transaction and returns true. Active -> active and
    /// paused -> paused write nothing and return false.
    @discardableResult
    func setTrackingActive(_ active: Bool) throws -> Bool {
        let connection = try openConnection()
        guard try Self.trackingActive(connection: connection) != active else { return false }
        let trackedFrom = UsageClock.nanoseconds(now())
        var restarted = false
        try connection.transaction {
            // Read again inside the transaction: the answer above is only
            // a shortcut that keeps the steady state free of writes.
            guard try Self.trackingActive(connection: connection) != active else { return }
            if active {
                try Self.restartTracking(at: trackedFrom, connection: connection)
                restarted = true
            }
            try Self.setMeta(Self.trackingActiveKey, to: active ? 1 : 0, connection: connection)
        }
        return restarted
    }

    /// Whether tracking is active; a database without the row is active
    /// (a database is only ever created while tracking is on).
    func isTrackingActive() throws -> Bool {
        let connection = try openConnection()
        return try Self.trackingActive(connection: connection)
    }

    // MARK: - Series helpers

    private static let trackingActiveKey = "tracking_active"

    private static func trackingActive(connection: SQLiteConnection) throws -> Bool {
        try connection.withStatement(selectTrackedFromSQL) { statement in
            try statement.bind(trackingActiveKey, at: 1)
            guard try statement.step(), !statement.isNull(at: 0) else { return true }
            return statement.int64(at: 0) != 0
        }
    }

    private static func setMeta(_ key: String, to value: Int64, connection: SQLiteConnection) throws {
        try connection.withStatement(upsertTrackedFromSQL) { statement in
            try statement.bind(key, at: 1)
            try statement.bind(value, at: 2)
            _ = try statement.step()
        }
    }

    private static let nanosecondsPerMinute: Int64 = 60_000_000_000
    private static let trackedFromKey = "tracked_from_ns"

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
    /// none.
    func setProjectRootIfUnset(_ root: String, forSession sessionID: String) throws {
        let connection = try openConnection()
        try connection.withStatement(Self.upsertSessionSQL) { statement in
            try statement.bind(sessionID, at: 1)
            try statement.bind(root, at: 2)
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
