//
//  UsageErrorDescriptionTests.swift
//  CalyxTests
//
//  Pins what a failure of the usage store says when it is shown to a
//  person or an agent (`localizedDescription`): a fixed plain sentence
//  per UsageStoreError case, and for a SQLiteError the result code with
//  SQLite's fixed text for that code (`sqlite3_errstr`). Neither ever
//  contains a path or a stored label: SQLite's per-call message can quote
//  a file name, so it is never part of the description.
//
//  `String(describing:)` and the NSError domain / code are pinned as they
//  were, because the ledger's diagnostics log those separately.
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageErrorDescriptionTests: XCTestCase {

    /// Every case with the sentence it must read as. The switch makes a
    /// new case a compile error here until its sentence is pinned too.
    private func expectedDescription(_ error: UsageStoreError) -> String {
        switch error {
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

    private let everyCase: [UsageStoreError] = [
        .closed, .invalidQuery, .unsupportedSchemaVersion(7), .incompatibleSchema,
        .integrityCheckFailed, .malformedRow, .dayBoundaryUnavailable,
    ]

    // MARK: - UsageStoreError

    func test_usageStoreError_everyCase_hasItsSentence() {
        for error in everyCase {
            XCTAssertEqual(error.errorDescription, expectedDescription(error), "\(error)")
            XCTAssertEqual((error as any Error).localizedDescription, expectedDescription(error), "\(error)")
        }
    }

    func test_usageStoreError_descriptions_containNoPath_andDiffer() {
        let descriptions = everyCase.map { ($0 as any Error).localizedDescription }

        for description in descriptions {
            XCTAssertFalse(description.contains("/"), description)
            XCTAssertFalse(description.contains("operation couldn"), description)
        }
        XCTAssertEqual(Set(descriptions).count, everyCase.count)
    }

    func test_usageStoreError_stringDescribing_isUnchanged() {
        XCTAssertEqual(String(describing: UsageStoreError.closed), "closed")
        XCTAssertEqual(String(describing: UsageStoreError.unsupportedSchemaVersion(7)), "unsupportedSchemaVersion(7)")
        XCTAssertEqual(String(describing: UsageStoreError.dayBoundaryUnavailable), "dayBoundaryUnavailable")
    }

    func test_usageStoreError_bridgedDomainAndCode_areUnchanged() {
        // Swift's default bridging: the type's qualified name, and codes
        // numbering the case with a payload first, then the others in
        // declaration order.
        let expected: [(UsageStoreError, Int)] = [
            (.unsupportedSchemaVersion(7), 0), (.closed, 1), (.invalidQuery, 2), (.incompatibleSchema, 3),
            (.integrityCheckFailed, 4), (.malformedRow, 5), (.dayBoundaryUnavailable, 6),
        ]
        for (error, code) in expected {
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, "Calyx.UsageStoreError", "\(error)")
            XCTAssertEqual(bridged.code, code, "\(error)")
        }
    }

    // MARK: - SQLiteError

    func test_sqliteError_busy_namesTheCodeAndSQLitesFixedText() {
        let error = SQLiteError(code: SQLITE_BUSY, message: "database is locked")

        XCTAssertEqual(
            (error as any Error).localizedDescription,
            "The usage database reported SQLite error 5 (database is locked).")
    }

    // An extended code is shown whole; the library's text for it is that
    // of its primary code.
    func test_sqliteError_extendedCode517_namesTheWholeCodeAndSQLitesFixedText() {
        let error = SQLiteError(code: 517, message: "synthetic")

        XCTAssertEqual(
            (error as any Error).localizedDescription,
            "The usage database reported SQLite error 517 (database is locked).")
        XCTAssertEqual(String(cString: sqlite3_errstr(517)), "database is locked", "Fixture error")
    }

    // The per-call message may quote a path; it is not part of the text.
    func test_sqliteError_description_neverContainsTheCallsMessage() {
        let error = SQLiteError(code: SQLITE_CANTOPEN, message: "cannot open /synthetic/home/usage/usage.sqlite")

        let description = (error as any Error).localizedDescription

        XCTAssertEqual(description, "The usage database reported SQLite error 14 (unable to open database file).")
        XCTAssertFalse(description.contains("/"), description)
        XCTAssertFalse(description.contains("synthetic"), description)
    }

    func test_sqliteError_stringDescribing_isUnchanged() {
        let error = SQLiteError(code: 5, message: "database is locked")

        XCTAssertEqual(String(describing: error), #"SQLiteError(code: 5, message: "database is locked")"#)
    }

    func test_sqliteError_bridgedDomainAndCode_areUnchanged() {
        let bridged = SQLiteError(code: 517, message: "synthetic") as NSError

        XCTAssertEqual(bridged.domain, "SQLite")
        XCTAssertEqual(bridged.code, 517)
    }
}
