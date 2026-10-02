//
//  SQLiteErrorBridgingTests.swift
//  CalyxTests
//
//  Pins how a SQLiteError looks as an NSError: domain "SQLite" and the
//  SQLite result code as its code. The usage ledger reports a failure's
//  domain and code separately from its text, because only those two are
//  safe to log publicly; without a domain and code of its own every
//  SQLite failure would bridge to the same pair.
//

import SQLite3
import XCTest
@testable import Calyx

final class SQLiteErrorBridgingTests: XCTestCase {

    func test_sqliteError_isACustomNSError() {
        let error: any Error = SQLiteError(code: SQLITE_BUSY, message: "database is locked")

        XCTAssertTrue(error is any CustomNSError)
    }

    func test_bridgedDomain_isSQLite_whateverTheCode() {
        for code in [SQLITE_BUSY, SQLITE_FULL, SQLITE_CORRUPT] {
            let bridged = SQLiteError(code: code, message: "synthetic") as NSError

            XCTAssertEqual(bridged.domain, "SQLite", "code \(code)")
        }
    }

    func test_bridgedCode_isTheResultCode() {
        // SQLITE_BUSY 5, SQLITE_READONLY 8, SQLITE_FULL 13, SQLITE_CORRUPT 11.
        let expected: [(Int32, Int)] = [(SQLITE_BUSY, 5), (SQLITE_READONLY, 8), (SQLITE_FULL, 13), (SQLITE_CORRUPT, 11)]
        for (code, bridgedCode) in expected {
            let bridged = SQLiteError(code: code, message: "synthetic") as NSError

            XCTAssertEqual(bridged.code, bridgedCode)
        }
    }

    func test_bridgedCode_keepsAnExtendedResultCodeWhole() {
        // SQLITE_BUSY_SNAPSHOT is SQLITE_BUSY | (2 << 8) = 517: the code
        // the error holds, not only its primary part.
        let error = SQLiteError(code: 517, message: "synthetic")
        XCTAssertEqual(error.primaryCode, SQLITE_BUSY, "Fixture error")

        XCTAssertEqual((error as NSError).code, 517)
    }

    func test_bridging_doesNotDependOnTheMessage() {
        let first = SQLiteError(code: SQLITE_FULL, message: "database or disk is full") as NSError
        let second = SQLiteError(code: SQLITE_FULL, message: "/synthetic/path/usage.sqlite") as NSError

        XCTAssertEqual(first.domain, second.domain)
        XCTAssertEqual(first.code, second.code)
    }
}
