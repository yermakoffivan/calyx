// GitProjectRootResolver.swift
// Calyx
//
// The project root the usage ledger attributes a session to: the work
// tree of the git repository containing the session's cwd.

import Foundation

/// Maps a working directory to the repository root usage is attributed
/// to; nil when the directory is not inside a repository.
protocol ProjectRootResolving: Sendable {
    func projectRoot(forCWD cwd: String) async throws -> String?
}

struct GitProjectRootResolver: ProjectRootResolving {
    /// The work tree containing `cwd`, or nil when `cwd` is outside any
    /// repository. Every other git failure is thrown. Same rule as
    /// `MissionMapGitPoller.repositoryRoot(for:generation:)`, so a
    /// session's usage and its Mission Map card name the same root.
    func projectRoot(forCWD cwd: String) async throws -> String? {
        do {
            return try await GitService.repositoryLocation(workDir: cwd).standardized.workTree
        } catch GitService.GitError.notARepository {
            return nil
        }
    }
}
