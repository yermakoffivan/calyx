//
//  IPCWakeHookScriptPatternTests.swift
//  CalyxTests
//
//  The one string invariant of IPCWakeHookScript that needs the planned
//  `IPCWakeResponse.notePattern` (spec A.3 script listing, I10): the note
//  shape check is `LC_ALL=C grep -Eqx '<notePattern>'`, interpolated rather
//  than retyped. Kept apart from IPCWakeHookScriptTests so that file
//  compiles before the planned API exists.
//

import XCTest
@testable import Calyx

final class IPCWakeHookScriptPatternTests: XCTestCase {

    func test_scriptBody_noteShapeCheck_usesNotePatternVerbatim() {
        let lines = IPCWakeHookScript.scriptBody.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(
            lines.contains(#"if ! printf '%s\n' "$note" | LC_ALL=C grep -Eqx '"# + IPCWakeResponse.notePattern + "'; then"),
            "the note shape check must be `LC_ALL=C grep -Eqx '` + IPCWakeResponse.notePattern + `'`"
        )
    }
}
