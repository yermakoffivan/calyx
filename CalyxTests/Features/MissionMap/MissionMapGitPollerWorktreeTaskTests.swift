// MissionMapGitPollerWorktreeTaskTests.swift
// CalyxTests
//
// Pins MissionMapGitPoller.worktreeTasks: a cwd inside a task worktree
// gets a badge keyed by that cwd, pointing at the worktree root.

import Foundation
import Testing
@testable import Calyx

@MainActor
struct MissionMapGitPollerWorktreeTaskTests {

    /// Waits for the poller's first refresh to publish, bounded so a
    /// broken implementation fails instead of hanging.
    private func waitForBadges(_ poller: MissionMapGitPoller, count: Int) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while poller.badges.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func test_refresh_publishesTaskBadgeKeyedByCwd_withWorktreeRoot() async throws {
        let scratch = try GitScratch.makeDirectory("MissionMapGitPollerWorktreeTaskTests")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repo = scratch.appendingPathComponent("repo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        let task = scratch.appendingPathComponent("task-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "task/demo", task.path, "main"], in: repo)
        try GitScratch.run(["config", "branch.task/demo.calyxbase", "main"], in: repo)
        let subdirectory = task.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let poller = MissionMapGitPoller()
        let cwds = [subdirectory.path, repo.path]
        poller.start { cwds }
        defer { poller.stop() }
        await waitForBadges(poller, count: 2)

        #expect(poller.badges.count == 2, "precondition: the refresh must have published")
        #expect(poller.worktreeTasks == [
            subdirectory.path: MissionMapWorktreeTaskBadge(branch: "task/demo", base: "main", worktreePath: task.path),
        ])
    }

    @Test func test_refresh_twoCwdsInOneTaskWorktree_shareTheRootsTaskBadge() async throws {
        let scratch = try GitScratch.makeDirectory("MissionMapGitPollerWorktreeTaskTests")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repo = scratch.appendingPathComponent("repo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        let task = scratch.appendingPathComponent("task-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "task/demo", task.path, "main"], in: repo)
        try GitScratch.run(["config", "branch.task/demo.calyxbase", "main"], in: repo)
        let a = task.appendingPathComponent("a")
        let b = task.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)

        let poller = MissionMapGitPoller()
        let cwds = [a.path, b.path]
        poller.start { cwds }
        defer { poller.stop() }
        await waitForBadges(poller, count: 2)

        let badge = MissionMapWorktreeTaskBadge(branch: "task/demo", base: "main", worktreePath: task.path)
        #expect(poller.worktreeTasks == [a.path: badge, b.path: badge])
    }
}
