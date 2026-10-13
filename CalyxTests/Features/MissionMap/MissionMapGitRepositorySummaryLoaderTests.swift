// MissionMapGitRepositorySummaryLoaderTests.swift
// CalyxTests
//
// Pins MissionMapGitPoller.loadRepositorySummary(at:), the static loader
// spec B.2 extracts from MissionMapGitPoller.refresh so agent_status and
// the poller compute a cwd's git badge and worktree-task badge the same
// way: a repository root, a subdirectory of it (via the location
// GitService resolves for that subdirectory), a task worktree, and a
// main work tree whose branch carries a marker (no task).
//
// A non-repository cwd has no GitRepositoryLocation to pass, so that case
// is pinned at the agent_status level (MCPCockpitBridgeTests) instead.

import Foundation
import Testing
@testable import Calyx

struct MissionMapGitRepositorySummaryLoaderTests {

    private func makeRepo() throws -> (scratch: URL, repo: URL) {
        let scratch = try GitScratch.makeDirectory("MissionMapGitRepositorySummaryLoaderTests")
        let repo = scratch.appendingPathComponent("repo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        return (scratch, repo)
    }

    private func location(of path: String) async throws -> GitRepositoryLocation {
        try await GitService.repositoryLocation(workDir: path).standardized
    }

    @Test func test_load_repositoryRoot_reportsBranchHashAndChangedFiles_noTask() async throws {
        let (scratch, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try "changed\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let shortHash = try GitScratch.run(["rev-parse", "--short", "HEAD"], in: repo)

        let summary = try await MissionMapGitPoller.loadRepositorySummary(at: location(of: repo.path))

        #expect(summary.badge == MissionMapGitBadge(branch: "main", shortHash: shortHash, changedFileCount: 2))
        #expect(summary.worktreeTask == nil)
    }

    @Test func test_load_subdirectoryLocation_reportsTheRepositorysBadge() async throws {
        let (scratch, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let subdirectory = repo.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try "new\n".write(to: subdirectory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let shortHash = try GitScratch.run(["rev-parse", "--short", "HEAD"], in: repo)

        let summary = try await MissionMapGitPoller.loadRepositorySummary(at: location(of: subdirectory.path))

        #expect(summary.badge == MissionMapGitBadge(branch: "main", shortHash: shortHash, changedFileCount: 1))
        #expect(summary.worktreeTask == nil)
    }

    @Test func test_load_taskWorktree_reportsTaskBadgeWithWorktreeRoot() async throws {
        let (scratch, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let task = scratch.appendingPathComponent("task-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "task/demo", task.path, "main"], in: repo)
        try GitScratch.run(["config", "branch.task/demo.calyxbase", "main"], in: repo)
        let subdirectory = task.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let shortHash = try GitScratch.run(["rev-parse", "--short", "HEAD"], in: task)

        let summary = try await MissionMapGitPoller.loadRepositorySummary(at: location(of: subdirectory.path))

        #expect(summary.badge == MissionMapGitBadge(branch: "task/demo", shortHash: shortHash, changedFileCount: 0))
        #expect(summary.worktreeTask == MissionMapWorktreeTaskBadge(branch: "task/demo", base: "main", worktreePath: task.path))
    }

    @Test func test_load_mainWorkTreeWithMarker_hasNoTask() async throws {
        let (scratch, repo) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try GitScratch.run(["config", "branch.main.calyxbase", "develop"], in: repo)

        let summary = try await MissionMapGitPoller.loadRepositorySummary(at: location(of: repo.path))

        #expect(summary.badge.branch == "main")
        #expect(summary.worktreeTask == nil)
    }
}
