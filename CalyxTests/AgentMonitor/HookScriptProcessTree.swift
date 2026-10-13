//
//  HookScriptProcessTree.swift
//  CalyxTests
//
//  Process helpers shared by the hook-script pipeline tests
//  (ApprovalHookPipelineIntegrationTests,
//  IPCWakeHookPipelineIntegrationTests): starting an installed hook
//  script as a real child `/bin/sh` process (`startHookScript`), locating
//  the real `curl` process it spawned, and waiting until a process is
//  gone. Both suites signal either the script or its curl mid-long-poll,
//  so both need the script's pid at once and its curl by walking the
//  script's descendants.
//
//  Every function is `nonisolated static` and takes plain Sendable values,
//  so a `@MainActor` test can await it without sending itself anywhere.
//

import Foundation
import Darwin

enum HookScriptProcessTree {

    typealias ScriptResult = (exitCode: Int32, stdout: String, stderr: String)

    /// A started hook script: its pid, known as soon as `Process.run()`
    /// returns (well before its curl has even started), and a Task that
    /// yields its exit code, stdout and stderr once it and everything
    /// holding its pipes has exited.
    struct RunningScript: Sendable {
        let pid: Int32
        let result: Task<ScriptResult, Never>
    }

    /// Starts `/bin/sh <scriptPath>` with exactly `environment` (nothing
    /// inherited), writes `stdin` to it and closes its stdin before
    /// returning. Closing stdin first matters to the signal tests: a
    /// script blocked in `cat > /dev/null` defers a trapped signal until
    /// its stdin closes, so a signal sent while stdin is open would test
    /// the wrong window.
    ///
    /// SIGINT is set to its default disposition in this process while the
    /// child is spawned, and restored afterwards: a child whose parent
    /// ignores SIGINT starts with SIGINT ignored, and a non-interactive
    /// shell cannot trap a signal that was ignored on entry, so a SIGINT
    /// test run under an ignoring parent would test nothing.
    ///
    /// `Process`, `Pipe` and `FileHandle` are Sendable in this SDK, so the
    /// detached Task may capture them; nothing else is captured.
    nonisolated static func startHookScript(
        scriptPath: String, environment: [String: String], stdin: String
    ) throws -> RunningScript {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let previousSIGINT = signal(SIGINT, SIG_DFL)
        defer { signal(SIGINT, previousSIGINT) }
        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let pid = process.processIdentifier
        let resultTask = Task.detached(priority: .userInitiated) { () -> ScriptResult in
            // Both pipes to EOF before waitUntilExit(); neither stream of
            // any script driven through this ever carries more than a
            // short note, far below one pipe buffer.
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
        return RunningScript(pid: pid, result: resultTask)
    }

    /// Whether a child spawned the way `startHookScript` spawns it starts
    /// with SIGINT ignored. The probe traps INT with `exit 7` and sends
    /// itself INT: a shell that started with INT ignored cannot install
    /// that trap and exits 0 instead. Returns nil when the probe could
    /// not be run.
    nonisolated static func spawnedChildIgnoresSIGINT() async -> Bool? {
        let probeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigint-probe-" + UUID().uuidString).path
        guard (try? FileManager.default.createDirectory(atPath: probeDir, withIntermediateDirectories: true)) != nil
        else { return nil }
        defer { try? FileManager.default.removeItem(atPath: probeDir) }
        let probePath = probeDir + "/probe.sh"
        let probe = "trap 'exit 7' INT\nkill -INT $$\nexit 0\n"
        guard (try? probe.write(toFile: probePath, atomically: true, encoding: .utf8)) != nil else { return nil }
        guard let running = try? startHookScript(
            scriptPath: probePath, environment: ["PATH": "/usr/bin:/bin"], stdin: ""
        ) else { return nil }
        let result = await running.result.value
        switch result.exitCode {
        case 7: return false
        case 0: return true
        default: return nil
        }
    }

    /// Breadth-first search of `ancestorPID`'s process-tree descendants
    /// for the first process whose `comm` (bare executable name, no
    /// arguments) is `processName`, polling up to `timeout` since the
    /// descendant may not have forked yet the instant this is first
    /// called. The walk covers the whole descendant tree, so the process
    /// is found at any depth below `ancestorPID`: the tests that use
    /// this do not depend on how a hook script starts its curl.
    nonisolated static func findDescendantProcess(
        ofAncestor ancestorPID: Int32, commandName processName: String, timeout: TimeInterval = 3.0
    ) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = descendantMatching(ofAncestor: ancestorPID, commandName: processName) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    nonisolated static func descendantMatching(ofAncestor ancestorPID: Int32, commandName processName: String) -> Int32? {
        var frontier = childPIDs(ofParent: ancestorPID)
        var visited = Set<Int32>()
        while !frontier.isEmpty {
            let current = frontier.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if processCommandName(ofPID: current) == processName {
                return current
            }
            frontier.append(contentsOf: childPIDs(ofParent: current))
        }
        return nil
    }

    nonisolated static func childPIDs(ofParent pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { Int32($0) }
    }

    nonisolated static func processCommandName(ofPID pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).lastPathComponent
    }

    /// Polls until `pid` no longer identifies a live process (either
    /// exited or reaped). The pipeline tests use it to confirm that a
    /// hook script's curl does not live on as an orphan once the script
    /// was signalled.
    nonisolated static func waitUntilProcessGone(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }
}
