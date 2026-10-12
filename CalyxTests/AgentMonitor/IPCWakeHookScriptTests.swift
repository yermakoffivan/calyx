//
//  IPCWakeHookScriptTests.swift
//  CalyxTests
//
//  Covers IPCWakeHookScript: the generated `calyx-ipc-wake-hook` /bin/sh
//  script, which long-polls `POST /ipc-wake` for its pane and turns a wake
//  into exit code 2 with the server's note on stderr. Every other outcome
//  is exit code 0 with nothing printed.
//
//  Two kinds of test:
//
//  1. String invariants over `IPCWakeHookScript.scriptBody`, read as
//     "executable lines": each line trimmed of whitespace, with blank
//     lines and `#` comment lines dropped (the same reading
//     AgentHookScriptPrologueTests uses). They pin what cannot be seen
//     from outside a run: the single `exit 2`, the curl command's exact
//     flags, headers and URL, the two traps, and the order of the steps
//     that keeps a signal from ever leaving curl running.
//  2. Behaviour, through FakeCurlScriptFixture: the installed script run
//     as a real `/bin/sh` child with a fake `curl` first on PATH that
//     prints a chosen body and exits with a chosen code, plus a recording
//     file that counts how often curl ran. The temp-file tests also put
//     a fake `mktemp` first on PATH, one that creates its file inside a
//     directory the test owns: macOS's `mktemp` without a template puts
//     its file in the per-user temp directory whatever TMPDIR says, so
//     TMPDIR cannot be used to watch the script's temp file.
//
//  Coverage:
//  - fileName, shebang
//  - exactly one `exit 2`; every other exit is `exit 0`; no bare `exit`
//  - no executable line mentions `stop_hook_active`
//  - one curl command: `-s`, `-m IPCWakeHookTiming.curlTimeoutSeconds`,
//    `--fail`, `-X POST`, the three headers, the `/ipc-wake` URL, output
//    redirected to the response file, backgrounded, and no request body
//  - one `mktemp`, on a line that is exactly
//    `response_file=$(mktemp) || exit 0`; the note prefix is
//    IPCWakeResponse.notePrefix
//  - the EXIT trap and the TERM HUP INT trap, each pinned as an exact
//    line, and nothing else trapped
//  - the order of the steps, the signalled check between mktemp and
//    curl, and the two "very next line" pairs
//  - curl exit 0 with a note: exit 2, stderr equal to the note, stdout
//    empty
//  - curl exit 0 with an empty body, or a body that does not start with
//    the prefix: exit 0, stderr empty
//  - curl exit 6, 7, 22, 28 while printing a note: exit 0, stderr empty
//  - the prologue's guards (no surface or session id, HERDR_PANE_ID, no
//    agent-endpoint.json) never reach curl even though curl would hand
//    back a note; a pane with only CALYX_SESSION_ID does reach it
//  - one mktemp call per run; its file exists while curl runs and is
//    gone once the script has exited, on the exit 2 path and on the
//    exit 0 path
//  - a failing mktemp: exit 0, curl never runs
//

import XCTest
@testable import Calyx

final class IPCWakeHookScriptTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    /// A real note, as `POST /ipc-wake` answers it: it starts with
    /// `IPCWakeResponse.notePrefix`.
    private let note = IPCWakeResponse(
        peerID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
        ticket: IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)
    ).note

    /// What the script is handed on stdin. It discards it unread.
    private let sampleStdin = #"{"hook_event_name":"Stop","session_id":"claude-1"}"#

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPCWakeHookScriptTests-" + UUID().uuidString).path
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - String helpers

    /// The lines of the script a shell would execute: each line trimmed
    /// of leading/trailing whitespace, with blank lines and `#` comment
    /// lines dropped. Order is preserved.
    private var executableLines: [String] {
        IPCWakeHookScript.scriptBody
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// `executableLines` joined by newlines.
    private var executableText: String {
        executableLines.joined(separator: "\n")
    }

    /// Number of non-overlapping occurrences of `needle` in `haystack`.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Index of the first executable line at or after `start` that
    /// satisfies `predicate`; throws (failing the test) when there is
    /// none.
    private func firstIndex(
        of description: String,
        from start: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: (String) -> Bool
    ) throws -> Int {
        let lines = executableLines
        let found = start <= lines.count ? lines[start...].firstIndex(where: predicate) : nil
        return try XCTUnwrap(
            found, "the script must have an executable line that is \(description)", file: file, line: line
        )
    }

    /// The script's curl command as one string: the executable line that
    /// starts with `curl ` plus its backslash continuation lines, each
    /// with its trailing backslash removed, joined by single spaces.
    private func curlCommand(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let lines = executableLines
        var index = try firstIndex(of: "the curl invocation", file: file, line: line) { $0.hasPrefix("curl ") }
        var parts: [String] = []
        while index < lines.count {
            let current = lines[index]
            guard current.hasSuffix("\\") else {
                parts.append(current)
                break
            }
            parts.append(String(current.dropLast()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Behaviour helpers

    private struct WakeRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let curlInvocations: Int
    }

    /// Installs the script into a fresh fixture under `tempDir`, puts a
    /// fake curl first on PATH that prints `curlStdout` and exits with
    /// `curlExitCode`, runs the script once with exactly `env` on top of
    /// HOME and PATH, and returns what it did plus how often curl ran.
    /// `removingEndpointFile` deletes the fixture's agent-endpoint.json
    /// before the run.
    private func runWakeScript(
        curlExitCode: Int32 = 0,
        curlStdout: String?,
        env: [String: String],
        removingEndpointFile: Bool = false
    ) throws -> WakeRun {
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/" + UUID().uuidString,
            port: 41_834, token: "ipc-wake-hook-script-test-token",
            install: IPCWakeHookScript.install(toDirectory:)
        )
        let recordPath = fixture.rootDir + "/curl-invocations.log"
        try makeFakeCurl(
            atDirectory: fixture.fakeBinDir, exitCode: curlExitCode,
            recordingTo: recordPath, stdoutBody: curlStdout
        )
        if removingEndpointFile {
            try FileManager.default.removeItem(atPath: fixture.appSupportDir + "/agent-endpoint.json")
        }

        let result = try runFakeCurlHookScriptCapturingStderr(fixture, stdinJSON: sampleStdin, extraEnv: env)

        let log = (try? String(contentsOfFile: recordPath, encoding: .utf8)) ?? ""
        return WakeRun(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
            curlInvocations: log.split(separator: "\n").count
        )
    }

    /// The environment of an ordinary Calyx pane: `CALYX_SURFACE_ID` set.
    private var paneEnv: [String: String] {
        ["CALYX_SURFACE_ID": "0E0C6C1B-5F0B-4C5E-9E3A-7C1B5D2F8A11"]
    }

    // MARK: - fileName and shebang

    func test_fileName_isCalyxIPCWakeHook() {
        XCTAssertEqual(IPCWakeHookScript.fileName, "calyx-ipc-wake-hook")
    }

    func test_scriptBody_startsWithTheShShebangLine() {
        XCTAssertTrue(IPCWakeHookScript.scriptBody.hasPrefix("#!/bin/sh\n"),
                      "the script is run by /bin/sh and its shebang has to be line 1")
    }

    // MARK: - Exit statuses

    func test_scriptBody_hasExactlyOneExit2_andEveryOtherExitIsExit0() throws {
        let lines = executableLines
        let text = executableText

        XCTAssertEqual(lines.filter { $0 == "exit 2" }.count, 1,
                       "exactly one executable line must be `exit 2`: the wake is the only path that " +
                       "may hand the CLI a nonzero status")
        XCTAssertEqual(occurrences(of: "exit 2", in: text), 1,
                       "`exit 2` must not also hide inside another line (a trap, a one-line `if`)")

        // `exit` as a whole word (so neither `curl_exit` nor `EXIT`),
        // followed by its status when it has one.
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])exit(?![A-Za-z0-9_])(?:[ \t]+([0-9]+))?"#)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        let statuses: [String?] = matches.map { match in
            let range = match.range(at: 1)
            return range.location == NSNotFound ? nil : nsText.substring(with: range)
        }

        XCTAssertEqual(statuses.filter { $0 == nil }.count, 0,
                       "no bare `exit`: it would pass on the status of whatever command ran last")
        XCTAssertEqual(statuses.compactMap { $0 }.filter { $0 != "0" && $0 != "2" }, [String](),
                       "every exit status in the script must be 0 or 2")
        XCTAssertEqual(statuses.filter { $0 == "2" }.count, 1,
                       "counted as whole words too, `exit 2` occurs exactly once")
    }

    func test_scriptBody_neverMentionsStopHookActiveInAnExecutableLine() {
        XCTAssertEqual(executableLines.filter { $0.contains("stop_hook_active") }, [String](),
                       "the script discards its stdin unread, so it must not test stop_hook_active")
    }

    // MARK: - The curl command

    func test_scriptBody_hasExactlyOneCurlCommand_withTheSpeccedFlagsHeadersAndURL_andNoBody() throws {
        XCTAssertEqual(executableLines.filter { $0.hasPrefix("curl ") }.count, 1,
                       "the script makes exactly one request")
        XCTAssertTrue(IPCWakeHookScript.scriptBody.contains("\ncurl "),
                      "the curl line starts at column 0, like in the other hook scripts")
        let command = try curlCommand()
        let tokens = command.split(separator: " ").map(String.init)

        XCTAssertTrue(tokens.contains("-s"), "curl must be silent (-s). Command: \(command)")
        XCTAssertTrue(command.contains("-m \(IPCWakeHookTiming.curlTimeoutSeconds) "),
                      "curl's deadline must be IPCWakeHookTiming.curlTimeoutSeconds. Command: \(command)")
        XCTAssertTrue(tokens.contains("--fail"),
                      "--fail turns a non-2xx answer into a curl error. Command: \(command)")
        XCTAssertTrue(command.contains("-X POST"), "the route is POST /ipc-wake. Command: \(command)")
        for header in [
            #"-H "Authorization: Bearer $token""#,
            #"-H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}""#,
            #"-H "X-Calyx-Agent-Kind: $kind""#,
        ] {
            XCTAssertTrue(command.contains(header), "curl must send \(header). Command: \(command)")
        }
        XCTAssertEqual(occurrences(of: "-H ", in: command), 3,
                       "exactly those three headers are sent. Command: \(command)")
        XCTAssertTrue(command.contains(#""http://127.0.0.1:$port/ipc-wake""#),
                      "curl must post to the /ipc-wake URL on loopback. Command: \(command)")
        XCTAssertTrue(command.contains(#"> "$response_file""#),
                      "curl's stdout must go to the response file. Command: \(command)")
        XCTAssertTrue(command.hasSuffix("&"),
                      "curl must be backgrounded so the script can react to a signal. Command: \(command)")

        XCTAssertFalse(command.contains("--data"), "the request has no body. Command: \(command)")
        XCTAssertFalse(command.contains("-d ") || tokens.contains("-d"),
                       "the request has no body. Command: \(command)")
        XCTAssertFalse(command.contains("Content-Type"),
                       "a request without a body has no Content-Type. Command: \(command)")
    }

    // MARK: - Temp file and note prefix

    func test_scriptBody_callsMktempOnExactlyOneExecutableLine() {
        XCTAssertEqual(executableLines.filter { $0.contains("mktemp") }.count, 1,
                       "the script uses one temp file, the response file")
    }

    func test_scriptBody_containsTheNotePrefixOfIPCWakeResponse() {
        XCTAssertTrue(executableText.contains(IPCWakeResponse.notePrefix),
                      "the script recognises a note by IPCWakeResponse.notePrefix " +
                      "(\"\(IPCWakeResponse.notePrefix)\"), the literal the server's notes start with")
    }

    // MARK: - Traps

    func test_scriptBody_trapsExitAndTermHupInt_andNothingElse() throws {
        let traps = executableLines.filter { $0.hasPrefix("trap ") }
        XCTAssertEqual(traps.count, 2, "exactly two traps: EXIT, and TERM HUP INT. Got: \(traps)")

        let exitTrap = try XCTUnwrap(traps.first { $0.hasSuffix(" EXIT") },
                                     "one trap must be on EXIT. Got: \(traps)")
        XCTAssertTrue(exitTrap.contains(#"rm -f "$response_file""#),
                      "the EXIT trap removes the response file. Got: \(exitTrap)")
        XCTAssertTrue(exitTrap.contains(#"if [ -n "$response_file" ]; then rm -f "$response_file"; fi"#),
                      "the EXIT trap is written as an `if`, so that its own status cannot replace " +
                      "the script's exit status. Got: \(exitTrap)")

        let signalTrap = try XCTUnwrap(traps.first { $0.hasSuffix(" TERM HUP INT") },
                                       "one trap must be on TERM HUP INT, and on nothing else. Got: \(traps)")
        for piece in ["signalled=1", #"if [ -n "$curl_pid" ]; then"#, #"kill "$curl_pid""#, "exit 0"] {
            XCTAssertTrue(signalTrap.contains(piece),
                          "the TERM HUP INT trap must contain `\(piece)`. Got: \(signalTrap)")
        }
        XCTAssertEqual(traps.filter { $0.contains("QUIT") }, [String](), "QUIT is not trapped")

        XCTAssertEqual(
            exitTrap, #"trap 'if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT"#,
            "the EXIT trap must be exactly this line: its body is one `if` and nothing else, so the " +
            "trap's own status can never replace the script's exit status (a `[ -n ... ] && rm` body, " +
            "or any command after the `fi`, could turn the wake's exit 2 into something else)")
        XCTAssertEqual(
            signalTrap,
            #"trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT"#,
            "the TERM HUP INT trap must be exactly this line, with `exit 0` INSIDE the `if`: a trap " +
            "that exits while curl_pid is still empty ends the script before it knows which curl to " +
            "kill, and can leave that curl running. Before the pid is known the trap only records " +
            "signalled=1")
    }

    func test_scriptBody_mktempLineIsExactlyTheAssignmentThatExitsZeroOnFailure() throws {
        let mktempLine = try XCTUnwrap(executableLines.first { $0.contains("mktemp") },
                                       "the script must have an executable line that calls mktemp")
        XCTAssertEqual(
            mktempLine, "response_file=$(mktemp) || exit 0",
            "the mktemp line must be exactly this: `|| exit 0` ends the script before curl is started " +
            "when no file could be created, and bare `mktemp` (no template) is what the tests' mktemp " +
            "shim stands in for")
    }

    // MARK: - Order of the steps

    func test_scriptBody_runsItsStepsInTheSpeccedOrder() throws {
        let responseFileInit = try firstIndex(of: "the bare `response_file=`") { $0 == "response_file=" }
        let signalledInit = try firstIndex(of: "`signalled=0`") { $0 == "signalled=0" }
        let curlPIDInit = try firstIndex(of: "the bare `curl_pid=`") { $0 == "curl_pid=" }
        let firstTrap = try firstIndex(of: "a trap") { $0.hasPrefix("trap ") }
        let drainStdin = try firstIndex(of: "`cat > /dev/null`") { $0 == "cat > /dev/null" }
        let mktemp = try firstIndex(of: "the mktemp call") { $0.contains("mktemp") }
        let curl = try firstIndex(of: "the curl invocation") { $0.hasPrefix("curl ") }
        let curlPIDAssign = try firstIndex(of: "`curl_pid=$!`") { $0 == "curl_pid=$!" }
        let wait = try firstIndex(of: #"`wait "$curl_pid"`"#) { $0 == #"wait "$curl_pid""# }
        let curlExit = try firstIndex(of: "`curl_exit=$?`") { $0 == "curl_exit=$?" }
        let curlPIDReset = try firstIndex(of: "the bare `curl_pid=` reset after `curl_exit=$?`", from: curlExit) {
            $0 == "curl_pid="
        }
        let exit2 = try firstIndex(of: "`exit 2`") { $0 == "exit 2" }

        for (name, index) in [
            ("response_file=", responseFileInit), ("signalled=0", signalledInit), ("curl_pid=", curlPIDInit),
        ] {
            XCTAssertLessThan(index, firstTrap,
                              "`\(name)` must be initialised before the first trap is set: a trap that " +
                              "fires early must not read a value inherited from the environment")
        }
        let ordered: [(name: String, index: Int)] = [
            ("the first trap", firstTrap),
            ("cat > /dev/null", drainStdin),
            ("the mktemp line", mktemp),
            ("the curl line", curl),
            ("curl_pid=$!", curlPIDAssign),
            (#"wait "$curl_pid""#, wait),
            ("curl_exit=$?", curlExit),
            ("the curl_pid= reset", curlPIDReset),
            ("exit 2", exit2),
        ]
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(earlier.index, later.index,
                              "\(earlier.name) must come before \(later.name)")
        }
    }

    func test_scriptBody_signalledCheckSitsBetweenMktempAndCurl() throws {
        let lines = executableLines
        let mktemp = try firstIndex(of: "the mktemp call") { $0.contains("mktemp") }

        XCTAssertEqual(
            Array(lines.dropFirst(mktemp + 1).prefix(3)),
            [#"if [ "$signalled" = 1 ]; then"#, "exit 0", "fi"],
            "the three executable lines right after the mktemp line must be the signalled check: a " +
            "signal that arrived while stdin was drained or the temp file was created must end the " +
            "script before curl is started"
        )
        XCTAssertTrue(lines.dropFirst(mktemp + 4).first?.hasPrefix("curl ") ?? false,
                      "the curl line must be the very next executable line after that check. Got: " +
                      "\(lines.dropFirst(mktemp + 4).first ?? "(nothing)")")
    }

    func test_scriptBody_recheckFollowsCurlPIDAssignment_andCurlExitFollowsWait() throws {
        let lines = executableLines
        let curlPIDAssign = try firstIndex(of: "`curl_pid=$!`") { $0 == "curl_pid=$!" }
        let wait = try firstIndex(of: #"`wait "$curl_pid"`"#) { $0 == #"wait "$curl_pid""# }

        XCTAssertEqual(lines.dropFirst(curlPIDAssign + 1).first, #"if [ "$signalled" = 1 ]; then"#,
                       "the signalled re-check must be the very next line after curl_pid=$!: a signal " +
                       "that arrived before the pid was known is acted on as soon as it is")
        XCTAssertEqual(lines.dropFirst(wait + 1).first, "curl_exit=$?",
                       "curl's status must be read on the very next line after wait, before any other " +
                       "command replaces $?")
    }

    // MARK: - Behaviour: a wake

    func test_run_curlSucceedsWithANote_exitsTwo_printsTheNoteOnStderrOnly() throws {
        XCTAssertTrue(note.hasPrefix(IPCWakeResponse.notePrefix), "precondition: the body is a note")

        let run = try runWakeScript(curlStdout: note, env: paneEnv)

        XCTAssertEqual(run.exitCode, 2, "a note from the server is the one outcome that exits 2")
        XCTAssertEqual(run.stderr, note, "stderr must be the note byte for byte, with no newline added")
        XCTAssertEqual(run.stdout, "", "nothing is ever printed on stdout")
        XCTAssertEqual(run.curlInvocations, 1, "one request per run")
    }

    // MARK: - Behaviour: no wake

    func test_run_curlSucceedsWithAnEmptyBody_exitsZero_printsNothing() throws {
        let run = try runWakeScript(curlStdout: "", env: paneEnv)

        XCTAssertEqual(run.exitCode, 0, "an empty answer (the server's 204) is not a wake")
        XCTAssertEqual(run.stderr, "")
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.curlInvocations, 1, "the script must have asked the server")
    }

    func test_run_curlSucceedsWithABodyThatDoesNotStartWithThePrefix_exitsZero_printsNothing() throws {
        let bodies: [(label: String, body: String)] = [
            ("prefix in the middle", "x Calyx IPC: 1 new message"),
            ("prefix without its trailing space", "Calyx IPC:1"),
            ("lowercase", note.lowercased()),
        ]

        for testCase in bodies {
            XCTAssertFalse(testCase.body.hasPrefix(IPCWakeResponse.notePrefix),
                           "[\(testCase.label)] precondition: the body does not start with the prefix")

            let run = try runWakeScript(curlStdout: testCase.body, env: paneEnv)

            XCTAssertEqual(run.exitCode, 0,
                           "[\(testCase.label)] only a body that STARTS with the exact prefix is a note")
            XCTAssertEqual(run.stderr, "", "[\(testCase.label)] a body that is not a note is not printed")
            XCTAssertEqual(run.stdout, "", "[\(testCase.label)]")
            XCTAssertEqual(run.curlInvocations, 1, "[\(testCase.label)] the script must have asked the server")
        }
    }

    func test_run_curlFailsWhilePrintingANote_exitsZero_printsNothing() throws {
        // Could not resolve host, connection refused, a non-2xx answer
        // rejected by --fail, timeout.
        let curlExitCodes: [Int32] = [6, 7, 22, 28]

        for curlExitCode in curlExitCodes {
            let run = try runWakeScript(curlExitCode: curlExitCode, curlStdout: note, env: paneEnv)

            XCTAssertEqual(run.exitCode, 0,
                           "[curl exit \(curlExitCode)] a failed curl is never a wake, whatever it printed")
            XCTAssertEqual(run.stderr, "", "[curl exit \(curlExitCode)] the body of a failed curl is not printed")
            XCTAssertEqual(run.stdout, "", "[curl exit \(curlExitCode)]")
            XCTAssertEqual(run.curlInvocations, 1, "[curl exit \(curlExitCode)] the script must have asked the server")
        }
    }

    // MARK: - Behaviour: the prologue's guards
    //
    // In each guard test the fake curl would print a note and exit 0, so a
    // script that got past the guard would exit 2.

    func test_run_neitherSurfaceNorSessionIDSet_exitsZero_neverRunsCurl() throws {
        let run = try runWakeScript(curlStdout: note, env: [:])

        XCTAssertEqual(run.exitCode, 0, "a pane Calyx did not launch must be left alone")
        XCTAssertEqual(run.curlInvocations, 0,
                       "with neither CALYX_SURFACE_ID nor CALYX_SESSION_ID the script must exit before curl")
    }

    func test_run_herdrPaneIDSet_exitsZero_neverRunsCurl() throws {
        var env = paneEnv
        env["HERDR_PANE_ID"] = "herdr-pane-1"

        let run = try runWakeScript(curlStdout: note, env: env)

        XCTAssertEqual(run.exitCode, 0, "a herdr-managed shell carries a stale Calyx surface id")
        XCTAssertEqual(run.curlInvocations, 0, "with HERDR_PANE_ID set the script must exit before curl")
    }

    func test_run_noEndpointFile_exitsZero_neverRunsCurl() throws {
        let run = try runWakeScript(curlStdout: note, env: paneEnv, removingEndpointFile: true)

        XCTAssertEqual(run.exitCode, 0, "without agent-endpoint.json there is no server to ask")
        XCTAssertEqual(run.curlInvocations, 0, "without agent-endpoint.json the script must exit before curl")
    }

    func test_run_onlySessionIDSet_runsCurlOnce_andExitsTwoOnANote() throws {
        let run = try runWakeScript(
            curlStdout: note, env: ["CALYX_SESSION_ID": "calyx-session-7"]
        )

        XCTAssertEqual(run.curlInvocations, 1,
                       "CALYX_SESSION_ID alone identifies a Calyx pane: the first guard needs BOTH ids " +
                       "unset. This is also the proof that a zero-invocation result in the guard tests " +
                       "above means suppression, not a broken fixture")
        XCTAssertEqual(run.exitCode, 2, "and a note still wakes that pane")
        XCTAssertEqual(run.stderr, note)
    }

    // MARK: - Behaviour: the temp file

    private struct TempFileRun {
        let exitCode: Int32
        let stderr: String
        let curlInvocations: Int
        let mktempInvocations: Int
        /// The entries of the temp directory at the moment curl ran.
        let entriesWhileCurlRan: [String]
        /// The entries of the temp directory after the script exited.
        let entriesAfterExit: [String]
    }

    /// Like `runWakeScript`, with a fake `mktemp` first on PATH as well
    /// (`makeFakeMktemp`). When `mktempSucceeds` the fake creates its file
    /// inside a dedicated, initially empty directory; otherwise it prints
    /// an error on stderr and exits 1. Both fakes record every call, and this helper's
    /// own fake curl also records `ls -A` of that directory before it
    /// prints `curlStdout` and exits 0.
    private func runWakeScriptWatchingItsTempFile(
        curlStdout: String, mktempSucceeds: Bool = true
    ) throws -> TempFileRun {
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/" + UUID().uuidString,
            port: 41_834, token: "ipc-wake-hook-script-test-token",
            install: IPCWakeHookScript.install(toDirectory:)
        )
        let scriptTempDir = fixture.rootDir + "/script-tmp"
        let curlRecordPath = fixture.rootDir + "/curl-invocations.log"
        let mktempRecordPath = fixture.rootDir + "/mktemp-invocations.log"
        let listingPath = fixture.rootDir + "/tmp-listing-while-curl-ran.txt"
        let curlBodyPath = fixture.rootDir + "/curl-stdout-body"
        try FileManager.default.createDirectory(atPath: scriptTempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fixture.fakeBinDir, withIntermediateDirectories: true)
        try Data(curlStdout.utf8).write(to: URL(fileURLWithPath: curlBodyPath))

        let fakeCurl = """
        #!/bin/sh
        cat > /dev/null
        printf 'invoked\\n' >> "\(curlRecordPath)"
        ls -A "\(scriptTempDir)" > "\(listingPath)"
        cat "\(curlBodyPath)"
        exit 0
        """
        let fakeCurlPath = fixture.fakeBinDir + "/curl"
        try fakeCurl.write(toFile: fakeCurlPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurlPath)
        try makeFakeMktemp(
            atDirectory: fixture.fakeBinDir,
            creatingFilesIn: mktempSucceeds ? scriptTempDir : nil,
            recordingTo: mktempRecordPath
        )

        let result = try runFakeCurlHookScriptCapturingStderr(fixture, stdinJSON: sampleStdin, extraEnv: paneEnv)

        func lines(ofFileAt path: String) -> [String] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        return TempFileRun(
            exitCode: result.exitCode, stderr: result.stderr,
            curlInvocations: lines(ofFileAt: curlRecordPath).count,
            mktempInvocations: lines(ofFileAt: mktempRecordPath).count,
            entriesWhileCurlRan: lines(ofFileAt: listingPath),
            entriesAfterExit: try FileManager.default.contentsOfDirectory(atPath: scriptTempDir)
        )
    }

    func test_run_wake_keepsOneTempFileWhileCurlRuns_andRemovesItOnExit() throws {
        let run = try runWakeScriptWatchingItsTempFile(curlStdout: note)

        XCTAssertEqual(run.exitCode, 2, "precondition: this is the exit 2 path")
        XCTAssertEqual(run.stderr, note, "precondition: the note went through the temp file intact")
        XCTAssertEqual(run.curlInvocations, 1)
        XCTAssertEqual(run.mktempInvocations, 1, "the script creates exactly one temp file")
        XCTAssertEqual(run.entriesWhileCurlRan.count, 1,
                       "while curl runs the script's one temp file exists, and nothing else. " +
                       "Got: \(run.entriesWhileCurlRan)")
        XCTAssertEqual(run.entriesAfterExit, [String](),
                       "the temp file must be gone once the script has exited with 2")
    }

    func test_run_noWake_keepsOneTempFileWhileCurlRuns_andRemovesItOnExit() throws {
        let run = try runWakeScriptWatchingItsTempFile(curlStdout: "")

        XCTAssertEqual(run.exitCode, 0, "precondition: this is the exit 0 path")
        XCTAssertEqual(run.curlInvocations, 1)
        XCTAssertEqual(run.mktempInvocations, 1, "the script creates exactly one temp file")
        XCTAssertEqual(run.entriesWhileCurlRan.count, 1,
                       "while curl runs the script's one temp file exists, and nothing else. " +
                       "Got: \(run.entriesWhileCurlRan)")
        XCTAssertEqual(run.entriesAfterExit, [String](),
                       "the temp file must be gone once the script has exited with 0")
    }

    func test_run_mktempFails_exitsZero_neverRunsCurl() throws {
        // stderr is not asserted: mktemp prints its own error there.
        let run = try runWakeScriptWatchingItsTempFile(curlStdout: note, mktempSucceeds: false)

        XCTAssertEqual(run.exitCode, 0, "a script that cannot create its temp file gives up quietly")
        XCTAssertEqual(run.curlInvocations, 0,
                       "without a response file there is nowhere to put the answer: curl must not run, " +
                       "even though it would have handed back a note")
    }
}
