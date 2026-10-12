// SessionCommandSynthesizerArgvTests.swift
// CalyxTests
//
// Pins the `--argv` suffix `attachCommand` appends when a persistent
// session is spawned with an explicit program (Worktree Tasks spawn the
// agent CLI as the pane's process): one ` --argv '<tok>'` per element,
// after `--cwd`, each through `shSafeToken`.

import XCTest
@testable import Calyx

private struct FixedRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

final class SessionCommandSynthesizerArgvTests: XCTestCase {

    private let root = FixedRootResolver(root: "/Users/dev")
    private let base = "'/bin/calyx-session' --runtime-dir '/Users/dev/.calyx/run' --state-dir '/Users/dev/.calyx/state' attach 'SID' --create --cwd '/w/t'"

    func test_attachCommand_argvAbsent_unchanged() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/bin/calyx-session", sessionID: "SID", cwd: "/w/t", rootResolver: root
        )
        XCTAssertEqual(command, base)
        let explicitNil = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/bin/calyx-session", sessionID: "SID", cwd: "/w/t", argv: nil, rootResolver: root
        )
        XCTAssertEqual(explicitNil, base)
    }

    func test_attachCommand_emptyArgv_unchanged() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/bin/calyx-session", sessionID: "SID", cwd: "/w/t", argv: [], rootResolver: root
        )
        XCTAssertEqual(command, base)
    }

    func test_attachCommand_argvPresent_appendsOneQuotedArgvFlagPerElementAfterCwd() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/bin/calyx-session", sessionID: "SID", cwd: "/w/t",
            argv: ["/bin/zsh", "-l", "-c", "exec 'claude'"], rootResolver: root
        )
        XCTAssertEqual(
            command,
            base + " --argv '/bin/zsh' --argv '-l' --argv '-c' --argv 'exec '\\''claude'\\'''"
        )
    }

    func test_attachCommand_argvElementWithSingleQuote_isQuoted() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/bin/calyx-session", sessionID: "SID", cwd: "/w/t",
            argv: ["it's"], rootResolver: root
        )
        XCTAssertEqual(command, base + " --argv 'it'\\''s'")
    }

    // MARK: - remoteAttachCommand

    private struct FixedSSHResolver: SSHBinaryResolverProtocol {
        let path: String
        func resolve() -> String { path }
    }

    func test_remoteAttachCommand_argvAbsentOrEmpty_unchanged() {
        let ssh = FixedSSHResolver(path: "/usr/bin/ssh")
        let expected = "'/usr/bin/ssh' -t -- 'box' '$HOME/.calyx/bin/calyx-session attach '\\''SID'\\'' --create --cwd '\\''/w/t'\\'''"
        XCTAssertEqual(SessionCommandSynthesizer.remoteAttachCommand(host: "box", sessionID: "SID", cwd: "/w/t", sshResolver: ssh), expected)
        XCTAssertEqual(SessionCommandSynthesizer.remoteAttachCommand(host: "box", sessionID: "SID", cwd: "/w/t", argv: [], sshResolver: ssh), expected)
    }

    /// Both quoting layers, decoded by real shells: the local `/bin/sh -c`
    /// hands ssh the remote command as one word, and the remote shell
    /// (here a second `/bin/sh -c` with `$HOME` pointed at a stub
    /// `calyx-session`) yields `--argv <tok>` per element, intact.
    func test_remoteAttachCommand_argvPresent_survivesBothShellLayers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-remote-argv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binDir = dir.appendingPathComponent(".calyx/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("out").path
        // Stub ssh: runs its last argument (the remote command) with sh.
        let sshStub = dir.appendingPathComponent("ssh").path
        try "#!/bin/sh\nfor a; do last=$a; done\nexec /bin/sh -c \"$last\"\n"
            .write(toFile: sshStub, atomically: true, encoding: .utf8)
        // Stub calyx-session: writes each argument NUL-terminated to `out`.
        let sessionStub = binDir.appendingPathComponent("calyx-session").path
        try "#!/bin/sh\nfor a; do printf '%s\\0' \"$a\"; done > \"$CALYX_TEST_OUT\"\n"
            .write(toFile: sessionStub, atomically: true, encoding: .utf8)
        for path in [sshStub, sessionStub] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let argv = ["/bin/zsh", "-i", "-l", "-c", "exec 'claude' 'it'\\''s'"]
        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "box", sessionID: "SID", cwd: "/w/t", argv: argv,
            sshResolver: FixedSSHResolver(path: sshStub)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin", "CALYX_TEST_OUT": out]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        var received = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        XCTAssertEqual(received.popLast(), "")
        XCTAssertEqual(received, [
            "attach", "SID", "--create", "--cwd", "/w/t",
            "--argv", "/bin/zsh", "--argv", "-i", "--argv", "-l", "--argv", "-c",
            "--argv", "exec 'claude' 'it'\\''s'",
        ])
    }
}
