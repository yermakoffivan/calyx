// SQLiteConnection.swift
// Calyx
//
// A thin wrapper over one SQLite database handle (the system libsqlite3):
// just what UsageStore needs -- open, execute, prepared statements with
// Int64 / text binding, a transaction helper, close. Deliberately NOT
// Sendable: the handle is opened with SQLITE_OPEN_NOMUTEX, so exactly one
// owner may use it, and that owner is `actor UsageStore`, which holds it
// privately and never hands it out.

import Foundation
import SQLite3

/// A failed SQLite call: the result code and SQLite's own message.
struct SQLiteError: Error, Equatable {
    let code: Int32
    let message: String

    /// The primary result code (extended codes carry it in the low byte).
    var primaryCode: Int32 { code & 0xFF }
}

/// As an `NSError`: domain `SQLite` and the result code, extended part
/// included. Neither can name a path, so a log may show them where the
/// message has to stay hidden.
extension SQLiteError: CustomNSError {
    static var errorDomain: String { "SQLite" }
    var errorCode: Int { Int(code) }
}

/// A prepared statement, valid only inside the `withStatement` /
/// `withTransientStatement` closure that provided it. It does not own the
/// handle; the connection finalizes it.
struct SQLiteStatement {
    fileprivate let handle: OpaquePointer
    fileprivate let database: OpaquePointer

    /// `SQLITE_TRANSIENT` is a C cast macro Swift does not import. It
    /// tells SQLite to copy the bound bytes, which is required because a
    /// Swift String's buffer is only valid for the duration of the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Parameter indexes are 1-based, as in SQLite.
    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    /// `nil` binds SQL NULL.
    func bind(_ value: String?, at index: Int32) throws {
        guard let value else {
            try check(sqlite3_bind_null(handle, index))
            return
        }
        try check(sqlite3_bind_text(handle, index, value, Int32(value.utf8.count), Self.transient))
    }

    /// Advances one step; `true` while a row is available.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteConnection.error(code, database: database)
        }
    }

    /// Clears the row cursor and the bindings so the statement can be
    /// bound and stepped again within one closure.
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Column indexes are 0-based, as in SQLite.
    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    /// `nil` for SQL NULL. Reads the value's full byte length, as `bind`
    /// writes it, so text round-trips byte-exactly; reading it as a C
    /// string would cut it at an embedded NUL. `sqlite3_column_bytes` is
    /// called after `sqlite3_column_text`, the order SQLite documents as
    /// safe (the text call may convert the value and change its length).
    func text(at index: Int32) -> String? {
        guard !isNull(at: index), let bytes = sqlite3_column_text(handle, index) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw SQLiteConnection.error(code, database: database) }
    }
}

final class SQLiteConnection {
    private var database: OpaquePointer?
    /// Statements prepared once and reused, keyed by their SQL text. Owned
    /// here, not by the caller, because `sqlite3_close` refuses to close
    /// (SQLITE_BUSY) while any statement is alive, which would also leave
    /// the `-wal` / `-shm` files behind; `close()` finalizes these first.
    private var cachedStatements: [String: OpaquePointer] = [:]

    /// Opens (creating if absent) the database at `path`. NOMUTEX: the
    /// single owner already guarantees one thread at a time. NOFOLLOW:
    /// SQLite refuses the open if ANY component of `path` is a symbolic
    /// link, so the caller must pass a path whose directory is already
    /// resolved (`realpath`); what remains guarded is the file name
    /// itself, which must never be followed to another file.
    init(path: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil)
        guard code == SQLITE_OK, let handle else {
            // SQLite may hand back a handle even on failure; it still has
            // to be closed.
            let failure = handle.map { Self.error(code, database: $0) }
                ?? SQLiteError(code: code, message: String(cString: sqlite3_errstr(code)))
            sqlite3_close(handle)
            throw failure
        }
        database = handle
    }

    deinit {
        close()
    }

    /// Finalizes every cached statement, then closes the handle.
    /// Idempotent. `sqlite3_close` can only refuse while a statement is
    /// alive; cached ones are finalized here and every other statement is
    /// scoped to a `withTransientStatement` closure, so none can be.
    /// Closing the last connection of a WAL database checkpoints it and,
    /// after `disablePersistentWAL()`, removes the `-wal` / `-shm` files.
    func close() {
        guard let database else { return }
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        cachedStatements = [:]
        sqlite3_close(database)
        self.database = nil
    }

    /// Makes closing the last connection remove the `-wal` / `-shm` files.
    /// That is stock SQLite's behaviour, but Apple's system build turns
    /// "persistent WAL" ON by default (verified: the file control reports
    /// 1 on a fresh handle and both files survive `sqlite3_close`), which
    /// would leave side files next to a closed database.
    func disablePersistentWAL() throws {
        let database = try openDatabase()
        var persist: Int32 = 0
        let code = sqlite3_file_control(database, nil, SQLITE_FCNTL_PERSIST_WAL, &persist)
        guard code == SQLITE_OK else { throw Self.error(code, database: database) }
    }

    /// Runs one or more SQL statements that take no parameters and whose
    /// result rows, if any, are not needed (DDL, PRAGMA, BEGIN / COMMIT).
    func execute(_ sql: String) throws {
        let database = try openDatabase()
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Self.error(code, database: database) }
    }

    /// Runs `body` with the statement for `sql`, prepared on first use and
    /// kept for the connection's lifetime. Use for the fixed statements on
    /// hot paths. The statement is reset and its bindings cleared when
    /// `body` returns OR throws: a statement left mid-step after an error
    /// would otherwise hold its transaction open and poison the next use.
    func withStatement<Result>(_ sql: String, _ body: (SQLiteStatement) throws -> Result) throws -> Result {
        let database = try openDatabase()
        let handle: OpaquePointer
        if let cached = cachedStatements[sql] {
            handle = cached
        } else {
            handle = try prepare(sql, database: database)
            cachedStatements[sql] = handle
        }
        let statement = SQLiteStatement(handle: handle, database: database)
        defer { statement.reset() }
        return try body(statement)
    }

    /// Like `withStatement`, but the statement is finalized when `body`
    /// returns. Use for SQL whose text varies with the request (report
    /// queries), so the cache cannot grow with the number of query shapes.
    func withTransientStatement<Result>(
        _ sql: String, _ body: (SQLiteStatement) throws -> Result
    ) throws -> Result {
        let database = try openDatabase()
        let handle = try prepare(sql, database: database)
        defer { sqlite3_finalize(handle) }
        return try body(SQLiteStatement(handle: handle, database: database))
    }

    /// Runs `body` inside one transaction: committed if it returns, rolled
    /// back if it (or the commit) throws, in which case that error is
    /// rethrown. IMMEDIATE takes the write lock up front, so a
    /// read-then-write body cannot fail halfway on a lock upgrade.
    func transaction(_ body: () throws -> Void) throws {
        let database = try openDatabase()
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            // SQLite has already rolled back by itself for some errors
            // (autocommit is then back on) and a second ROLLBACK would
            // fail. If this ROLLBACK itself fails, the error that caused
            // it is the one worth reporting, so that one is thrown.
            if sqlite3_get_autocommit(database) == 0 {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            }
            throw error
        }
    }

    // MARK: - Private

    private func openDatabase() throws -> OpaquePointer {
        guard let database else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "connection is closed")
        }
        return database
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_finalize(handle)
            throw Self.error(code, database: database)
        }
        return handle
    }

    fileprivate static func error(_ code: Int32, database: OpaquePointer) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(database)))
    }
}
