//
//  HookScriptProcessTree.swift
//  CalyxTests
//
//  Process-tree helpers shared by the hook-script pipeline tests
//  (ApprovalHookPipelineIntegrationTests,
//  IPCWakeHookPipelineIntegrationTests): locating the real `curl` process
//  an installed hook script spawned, and waiting until a process is gone.
//  Both suites run a real script as a real child `/bin/sh` process and
//  then signal either the script or its curl mid-long-poll, so both need
//  to find that curl by walking the script's descendants.
//
//  Every function is `nonisolated static` and takes plain Sendable values,
//  so a `@MainActor` test can await it without sending itself anywhere.
//

import Foundation
import Darwin

enum HookScriptProcessTree {

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
