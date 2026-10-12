//
//  FakeCurlScriptFixture.swift
//  CalyxTests
//
//  Shared fake-curl PATH-shim + /bin/sh execution harness for driving an
//  installed hook script (calyx-agent-hook / calyx-approval-hook /
//  calyx-ipc-wake-hook) as a real child process, without a real network
//  round trip. Consolidates
//  three independent copies (ApprovalHookScriptTests,
//  ApprovalHookScriptHerdrGuardTests, AgentHookScriptHerdrGuardTests each
//  carried their own fake-curl generator and script-runner) that each had
//  to independently reimplement the real script's own contract: draining
//  whatever stdin it's given (harmless either way -- calyx-agent-hook
//  still forwards the caller's own stdin to curl via `--data-binary @-`;
//  calyx-approval-hook's curl instead reads a temp file and its
//  backgrounded stdin is /dev/null under POSIX job control, so this fake
//  curl's own stdin is empty for it), prepending PATH so the fake curl
//  resolves ahead of the real one, and building a HOME whose
//  `Library/Application Support/Calyx` layout matches exactly what the
//  script itself reads at invocation time. Without this, a future change
//  to any of those (e.g. the script's own curl invocation shape, or the
//  endpoint file's location) only gets caught by whichever copy a test
//  author happened to update, leaving the other two silently passing
//  against a stale harness. Mirrors TwoPaneSessionFixture.swift /
//  ReconnectFixture.swift's own precedent for extracting a
//  verbatim-duplicated test shape into one shared file.
//
//  calyx-ipc-wake-hook decides its exit code from the bytes curl printed
//  and reports on its own stderr, which the two older scripts never do.
//  Two additions serve it: `makeFakeCurl(stdoutBody:)` makes the fake curl
//  print a chosen response body, and
//  `runFakeCurlHookScriptCapturingStderr` returns the script's stderr
//  next to its exit code and stdout. `runFakeCurlHookScript` delegates to
//  it, so the process-spawning code exists once. A third,
//  `makeFakeMktemp`, writes a `mktemp` shim that creates its file inside
//  a directory the test owns (or fails), so a test can watch the temp
//  file of a script that calls bare `mktemp`: on macOS that call ignores
//  TMPDIR in favour of the per-user temporary directory.
//
//  Each call site still owns its own cleanup (matching
//  TwoPaneSessionFixture.swift's established discipline): this file only
//  builds the fixture and its fake curl, it does not manage any
//  XCTestCase's tearDown.
//

import Foundation
@testable import Calyx

/// A temp HOME with a working `agent-endpoint.json` under
/// `Library/Application Support/Calyx` and `install`'s script installed
/// into its `bin/` -- the exact HOME-relative layout every hook script
/// itself reads at invocation time (`$HOME/Library/Application
/// Support/Calyx/agent-endpoint.json`). `fakeBinDir` is a second,
/// separate directory a caller installs its own fake `curl` into (see
/// `makeFakeCurl`), then `runFakeCurlHookScript` prepends to PATH.
struct FakeCurlScriptFixture {
    let rootDir: String
    let home: String
    let appSupportDir: String
    let fakeBinDir: String
    let scriptPath: String
}

/// Builds a `FakeCurlScriptFixture`. `rootDirectory` defaults to a fresh
/// temp directory; pass an explicit path (e.g. nested under a test
/// class's own already-cleaned-up tempDir) when the caller wants to own
/// cleanup itself rather than track this fixture's `rootDir` separately.
/// `port`/`token` are arbitrary -- nothing in this harness ever reads
/// `agent-endpoint.json` back through a real server, so any
/// distinct-enough values will do.
func makeFakeCurlScriptFixture(
    rootDirectory: String = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path,
    port: Int,
    token: String,
    install: (String) throws -> String
) throws -> FakeCurlScriptFixture {
    let home = rootDirectory + "/home"
    let appSupportDir = home + "/Library/Application Support/Calyx"
    let fakeBinDir = rootDirectory + "/fakebin"
    try AgentEndpointFile.write(port: port, token: token, directory: appSupportDir)
    let scriptPath = try install(appSupportDir + "/bin")
    return FakeCurlScriptFixture(
        rootDir: rootDirectory, home: home, appSupportDir: appSupportDir,
        fakeBinDir: fakeBinDir, scriptPath: scriptPath
    )
}

/// Writes a fake `curl` executable at `<dir>/curl` that drains its own
/// stdin (whatever it is -- see this file's header comment for why that
/// differs between calyx-agent-hook and calyx-approval-hook -- so nothing
/// is ever left unread), optionally appends one "invoked" line to
/// `recordPath` per call, optionally prints `stdoutBody` on its stdout,
/// and exits with `exitCode` (0 by default).
///
/// `stdoutBody`, when non-nil, is printed byte for byte with no newline
/// added: it is written to `<dir>/curl-stdout-body` and the fake curl
/// `cat`s that file, so no character of the body is ever interpreted by
/// the shell. `nil` prints nothing, exactly as before this parameter
/// existed.
func makeFakeCurl(
    atDirectory dir: String,
    exitCode: Int32 = 0,
    recordingTo recordPath: String? = nil,
    stdoutBody: String? = nil
) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let curlPath = dir + "/curl"
    let recordLine = recordPath.map { "printf 'invoked\\n' >> \"\($0)\"\n" } ?? ""
    var stdoutLine = ""
    if let stdoutBody {
        let stdoutBodyPath = dir + "/curl-stdout-body"
        try Data(stdoutBody.utf8).write(to: URL(fileURLWithPath: stdoutBodyPath))
        stdoutLine = "cat \"\(stdoutBodyPath)\"\n"
    }
    let body = """
    #!/bin/sh
    cat > /dev/null
    \(recordLine)\(stdoutLine)exit \(exitCode)
    """
    try body.write(toFile: curlPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curlPath)
}

/// Writes a `mktemp` shim executable at `<dir>/mktemp`, for a script
/// that calls `mktemp` with no arguments. Put `dir` ahead of `/usr/bin`
/// on the script's PATH and the script's temp file lands where the test
/// can see it.
///
/// With `tempFileDir` non-nil the shim creates that directory's file
/// with the real `/usr/bin/mktemp` (template `response.XXXXXX` inside
/// `tempFileDir`, which this function creates if needed) and passes its
/// output and exit status through. With `tempFileDir` nil the shim
/// creates nothing, prints an error on stderr and exits 1: a failing
/// `mktemp`. Either way it first appends one "invoked" line to
/// `recordPath` when that is non-nil. Whatever arguments the shim is
/// given are ignored.
func makeFakeMktemp(
    atDirectory dir: String,
    creatingFilesIn tempFileDir: String?,
    recordingTo recordPath: String? = nil
) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let recordLine = recordPath.map { "printf 'invoked\\n' >> \"\($0)\"\n" } ?? ""
    let action: String
    if let tempFileDir {
        try FileManager.default.createDirectory(atPath: tempFileDir, withIntermediateDirectories: true)
        action = "exec /usr/bin/mktemp \"\(tempFileDir)/response.XXXXXX\""
    } else {
        action = "printf 'mktemp: simulated failure\\n' >&2\nexit 1"
    }
    let body = """
    #!/bin/sh
    \(recordLine)\(action)
    """
    let mktempPath = dir + "/mktemp"
    try body.write(toFile: mktempPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mktempPath)
}

/// Runs `fixture.scriptPath` as a real child `/bin/sh` process, with
/// `fixture.fakeBinDir` prepended to PATH (ahead of the real system PATH,
/// so `curl` resolves to the fake one while `sed` etc. still resolve
/// normally), `extraEnv` merged on top of the base HOME/PATH environment
/// (e.g. `CALYX_SURFACE_ID` so the script's own early guard doesn't
/// short-circuit before ever reaching curl, or `HERDR_PANE_ID` to drive
/// the herdr guard), and `kindArgument` passed as `$1` when non-nil.
/// Returns the script's exit code and stdout; see
/// `runFakeCurlHookScriptCapturingStderr` for its stderr as well.
@discardableResult
func runFakeCurlHookScript(
    _ fixture: FakeCurlScriptFixture,
    stdinJSON: String,
    extraEnv: [String: String] = [:],
    kindArgument: String? = nil
) throws -> (exitCode: Int32, stdout: String) {
    let result = try runFakeCurlHookScriptCapturingStderr(
        fixture, stdinJSON: stdinJSON, extraEnv: extraEnv, kindArgument: kindArgument
    )
    return (result.exitCode, result.stdout)
}

/// `runFakeCurlHookScript` with the script's stderr returned too. The
/// child's environment is exactly HOME, PATH and `extraEnv`, nothing
/// inherited. Both pipes are read to EOF before `waitUntilExit()`, stdout
/// first: every script driven through this harness writes far less than
/// one pipe buffer to either stream, so the sequential reads cannot
/// block the child.
@discardableResult
func runFakeCurlHookScriptCapturingStderr(
    _ fixture: FakeCurlScriptFixture,
    stdinJSON: String,
    extraEnv: [String: String] = [:],
    kindArgument: String? = nil
) throws -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = kindArgument.map { [fixture.scriptPath, $0] } ?? [fixture.scriptPath]
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
    var env = ["HOME": fixture.home, "PATH": "\(fixture.fakeBinDir):\(inheritedPath)"]
    for (key, value) in extraEnv { env[key] = value }
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
    stdinPipe.fileHandleForWriting.closeFile()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: stdoutData, encoding: .utf8) ?? "",
        String(data: stderrData, encoding: .utf8) ?? ""
    )
}
