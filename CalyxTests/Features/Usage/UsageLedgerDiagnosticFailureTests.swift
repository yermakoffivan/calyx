//
//  UsageLedgerDiagnosticFailureTests.swift
//  CalyxTests
//
//  Pins UsageLedgerDiagnostic.Failure, what a ledger diagnostic says
//  about an error: `description` is the error's own text, which may name
//  a path and is therefore logged privately, and `domain` and `code` are
//  the error's NSError domain and code, which never contain a path and
//  tell a full disk from a permission error from a locked database in a
//  log that hides the text.
//

import SQLite3
import XCTest
@testable import Calyx

final class UsageLedgerDiagnosticFailureTests: XCTestCase {

    private enum PlainError: Error {
        case first
        case second
    }

    func test_sqliteError_domainIsSQLite_codeIsTheResultCode_descriptionIsTheErrorsText() {
        let error = SQLiteError(code: SQLITE_BUSY, message: "database is locked")

        let failure = UsageLedgerDiagnostic.Failure(error)

        XCTAssertEqual(failure.domain, "SQLite")
        XCTAssertEqual(failure.code, 5)
        XCTAssertEqual(failure.description, String(describing: error))
        XCTAssertTrue(failure.description.contains("database is locked"), failure.description)
    }

    func test_sqliteError_anotherCode_isCarried() {
        let failure = UsageLedgerDiagnostic.Failure(SQLiteError(code: SQLITE_FULL, message: "database or disk is full"))

        XCTAssertEqual(failure.domain, "SQLite")
        XCTAssertEqual(failure.code, 13)
    }

    func test_posixNSError_domainIsPOSIX_codeIsTheErrno() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))

        let failure = UsageLedgerDiagnostic.Failure(error)

        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.code, 28)
        XCTAssertEqual(failure.description, String(describing: error))
    }

    func test_posixError_bridgesToTheSameDomainAndErrno() {
        let failure = UsageLedgerDiagnostic.Failure(POSIXError(.EACCES))

        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.code, 13)
    }

    func test_cocoaError_domainAndCodeAreCarried_andThePathStaysInTheDescriptionOnly() {
        let path = "/synthetic/secret-project/usage.sqlite"
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSFilePathErrorKey: path])

        let failure = UsageLedgerDiagnostic.Failure(error)

        XCTAssertEqual(failure.domain, NSCocoaErrorDomain)
        XCTAssertEqual(failure.code, 513)
        XCTAssertEqual(failure.description, String(describing: error))
        XCTAssertTrue(failure.description.contains(path), "Fixture error: the text must name the path")
        XCTAssertFalse(failure.domain.contains("secret-project"))
    }

    func test_plainSwiftError_descriptionIsItsText_domainAndCodeAreWhatItBridgesTo() {
        let failure = UsageLedgerDiagnostic.Failure(PlainError.second)

        XCTAssertEqual(failure.description, "second")
        XCTAssertEqual(failure.domain, (PlainError.second as NSError).domain)
        // A payload-free enum bridges to its case's index.
        XCTAssertEqual(failure.code, 1)
        XCTAssertEqual(UsageLedgerDiagnostic.Failure(PlainError.first).code, 0)
    }

    func test_equality_comparesAllThreeParts() {
        let busy = UsageLedgerDiagnostic.Failure(SQLiteError(code: SQLITE_BUSY, message: "database is locked"))

        XCTAssertEqual(busy, UsageLedgerDiagnostic.Failure(SQLiteError(code: SQLITE_BUSY, message: "database is locked")))
        XCTAssertNotEqual(
            busy, UsageLedgerDiagnostic.Failure(SQLiteError(code: SQLITE_FULL, message: "database is locked")))
        XCTAssertNotEqual(busy, UsageLedgerDiagnostic.Failure(SQLiteError(code: SQLITE_BUSY, message: "other text")))
        XCTAssertNotEqual(
            UsageLedgerDiagnostic.Failure(NSError(domain: NSPOSIXErrorDomain, code: 5)),
            UsageLedgerDiagnostic.Failure(NSError(domain: NSCocoaErrorDomain, code: 5)))
    }

    func test_diagnostics_carryTheFailure() {
        let failure = UsageLedgerDiagnostic.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))

        XCTAssertEqual(
            UsageLedgerDiagnostic.runLogReadFailed(sessionID: "session-a", error: failure),
            .runLogReadFailed(sessionID: "session-a", error: failure))
        XCTAssertNotEqual(
            UsageLedgerDiagnostic.storeUnavailable(error: failure),
            .storeUnavailable(error: UsageLedgerDiagnostic.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))))
    }
}
