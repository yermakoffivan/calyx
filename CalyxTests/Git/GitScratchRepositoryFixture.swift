// GitScratchRepositoryFixture.swift
// CalyxTests
//
// Builds throwaway repositories with the real git binary.

import Foundation

enum GitScratch {
    /// Creates an empty scratch directory.
    ///
    /// Scratch repositories live under Caches instead of the temporary
    /// directory because `/var/folders` is a symlink into
    /// `/private/var/folders`: git reports the resolved form while
    /// Foundation's path standardization drops the `/private` prefix, so
    /// the two spellings of the same directory disagree. The Caches path
    /// is already canonical under both, which keeps expected paths literal.
    static func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalyxTests-GitScratch")
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Runs git with a fixed identity and no user configuration, so the
    /// fixture is unaffected by the developer's global git settings.
    @discardableResult
    static func run(_ arguments: [String], in workDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.environment = [
            "GIT_AUTHOR_DATE": "2001-02-03T04:05:06+0000",
            "GIT_AUTHOR_EMAIL": "calyx-tests@example.invalid",
            "GIT_AUTHOR_NAME": "Calyx Tests",
            "GIT_COMMITTER_DATE": "2001-02-03T04:05:06+0000",
            "GIT_COMMITTER_EMAIL": "calyx-tests@example.invalid",
            "GIT_COMMITTER_NAME": "Calyx Tests",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
        ]

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: outputData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw GitScratchError(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorData, as: UTF8.self)
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sets a repository-local identity and disables commit signing.
    /// Production write paths (`GitService.runMutating`) inherit the
    /// developer's HOME, so without this a global `user.*` or
    /// `commit.gpgsign` setting would leak into merge commits they make.
    static func configureIdentity(in repository: URL) throws {
        try run(["config", "user.name", "Calyx Tests"], in: repository)
        try run(["config", "user.email", "calyx-tests@example.invalid"], in: repository)
        try run(["config", "commit.gpgsign", "false"], in: repository)
    }

    /// Writes `contents`, commits it, and returns the resulting full SHA.
    @discardableResult
    static func commit(
        file: String,
        contents: String,
        message: String,
        in repository: URL
    ) throws -> String {
        try contents.write(
            to: repository.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
        try run(["add", "--", file], in: repository)
        try run(["commit", "-q", "-m", message], in: repository)
        return try run(["rev-parse", "HEAD"], in: repository)
    }
}

struct GitScratchError: Error, CustomStringConvertible {
    let arguments: [String]
    let exitCode: Int32
    let stderr: String

    var description: String {
        "git \(arguments.joined(separator: " ")) failed (exit \(exitCode)): \(stderr)"
    }
}
