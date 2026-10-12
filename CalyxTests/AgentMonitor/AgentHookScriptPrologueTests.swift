//
//  AgentHookScriptPrologueTests.swift
//  CalyxTests
//
//  Covers AgentHookScriptPrologue: the opening section shared by the
//  generated `calyx-agent-hook` and `calyx-approval-hook` /bin/sh scripts
//  (see AgentHookScriptTests.swift and ApprovalHookScriptTests.swift).
//  That section used to be written out twice, once per script; it is one
//  constant now, and both scripts interpolate it. These tests check that
//  each script's text contains the prologue's text verbatim exactly once,
//  that the prologue's executable lines are the pinned ones in order, and
//  where the prologue sits relative to the shebang and the first curl
//  call. They compare text only, so they cannot tell an interpolation
//  from a byte-identical pasted copy.
//
//  Coverage:
//  - the prologue's executable lines (comments and blank lines dropped,
//    indentation ignored) are exactly the surface/session guard, the
//    herdr guard, the kind default, the Grok guard, the endpoint-file
//    read, and the port/token extraction with its empty check, in order
//  - AgentHookScript.scriptBody and ApprovalHookScript.scriptBody each
//    contain the prologue verbatim, exactly once
//  - in both scripts the prologue sits after the shebang line and ends
//    before the first curl invocation line
//  - the prologue itself runs no curl, sets no trap, and creates no temp
//    file: it is only guards and endpoint resolution
//

import XCTest
@testable import Calyx

final class AgentHookScriptPrologueTests: XCTestCase {

    // MARK: - Helpers

    /// The lines of `script` a shell would execute: each line trimmed of
    /// leading/trailing whitespace, with blank lines and `#` comment
    /// lines dropped. Order is preserved.
    private func executableLines(of script: String) -> [String] {
        script
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Number of non-overlapping occurrences of `needle` in `haystack`.
    /// An empty needle counts as zero occurrences, so an empty prologue
    /// can never satisfy an "exactly once" assertion.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    /// Asserts that the prologue lies strictly after the shebang line of
    /// `script` and ends at or before the start of its first curl
    /// invocation line (a line that begins with `curl `, as opposed to a
    /// comment that merely mentions curl).
    private func assertPrologueSitsBetweenShebangAndFirstCurl(
        in script: String,
        scriptName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"),
                      "\(scriptName) must start with the #!/bin/sh shebang line",
                      file: file, line: line)

        guard let prologueRange = script.range(of: AgentHookScriptPrologue.body) else {
            XCTFail("\(scriptName) must contain AgentHookScriptPrologue.body verbatim",
                    file: file, line: line)
            return
        }
        guard let shebangLineEnd = script.range(of: "\n") else {
            XCTFail("\(scriptName) must have more than one line", file: file, line: line)
            return
        }
        guard let firstCurlLine = script.range(of: "\ncurl ") else {
            XCTFail("\(scriptName) must contain a line that invokes curl", file: file, line: line)
            return
        }

        // Index of the `c` of that curl line, just past the newline before it.
        let firstCurlLineStart = script.index(after: firstCurlLine.lowerBound)

        XCTAssertGreaterThanOrEqual(
            prologueRange.lowerBound, shebangLineEnd.upperBound,
            "\(scriptName): the prologue must start after the shebang line, which has to stay line 1",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            prologueRange.upperBound, firstCurlLineStart,
            "\(scriptName): the prologue must end before the first curl invocation, which depends " +
            "on the port and token the prologue resolves",
            file: file, line: line
        )
    }

    // MARK: - Prologue content

    func test_body_executableLinesAreExactlyTheGuardsAndEndpointResolutionInOrder() {
        let expected: [String] = [
            #"if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then"#,
            "exit 0",
            "fi",
            #"if [ -n "$HERDR_PANE_ID" ]; then"#,
            "exit 0",
            "fi",
            #"kind="${1:-claude-code}""#,
            #"if [ "$kind" = "claude-code" ] && [ -n "$GROK_HOOK_EVENT" ]; then"#,
            "exit 0",
            "fi",
            "endpoint_file=\"${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}\"",
            #"if [ ! -f "$endpoint_file" ]; then"#,
            "exit 0",
            "fi",
            #"port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$endpoint_file")"#,
            #"token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"if [ -z "$port" ] || [ -z "$token" ]; then"#,
            "exit 0",
            "fi",
        ]

        XCTAssertEqual(
            executableLines(of: AgentHookScriptPrologue.body), expected,
            "The shared prologue must execute exactly the lines both hook scripts opened with " +
            "before it was extracted, in the same order"
        )
    }

    func test_body_runsNoCurlSetsNoTrapAndCreatesNoTempFile() {
        let lines = executableLines(of: AgentHookScriptPrologue.body)

        XCTAssertFalse(lines.isEmpty, "The prologue must not be empty")
        for forbidden in ["curl", "trap", "mktemp"] {
            XCTAssertEqual(
                lines.filter { $0.contains(forbidden) }, [String](),
                "The prologue is only guards and endpoint resolution, so it must not use \(forbidden); " +
                "each script does its own posting, signal handling and temp files after it"
            )
        }
    }

    // MARK: - Both scripts interpolate the prologue

    func test_agentHookScriptBody_containsThePrologueVerbatimExactlyOnce() {
        XCTAssertEqual(
            occurrences(of: AgentHookScriptPrologue.body, in: AgentHookScript.scriptBody), 1,
            "calyx-agent-hook must contain the shared prologue verbatim, exactly once"
        )
    }

    func test_approvalHookScriptBody_containsThePrologueVerbatimExactlyOnce() {
        XCTAssertEqual(
            occurrences(of: AgentHookScriptPrologue.body, in: ApprovalHookScript.scriptBody), 1,
            "calyx-approval-hook must contain the shared prologue verbatim, exactly once"
        )
    }

    // MARK: - Prologue position inside each script

    func test_agentHookScriptBody_placesThePrologueAfterTheShebangAndBeforeTheFirstCurl() {
        assertPrologueSitsBetweenShebangAndFirstCurl(
            in: AgentHookScript.scriptBody, scriptName: "calyx-agent-hook"
        )
    }

    func test_approvalHookScriptBody_placesThePrologueAfterTheShebangAndBeforeTheFirstCurl() {
        assertPrologueSitsBetweenShebangAndFirstCurl(
            in: ApprovalHookScript.scriptBody, scriptName: "calyx-approval-hook"
        )
    }
}
