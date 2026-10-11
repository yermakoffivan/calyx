// GitRepoDiscoveryWorktreeTaskTests.swift
// CalyxTests
//
// Pins `GitRepoDescriptor.taskBase`: discovery fills it from
// `branch.<b>.calyxbase` for linked worktrees only.

import Foundation
import Testing
@testable import Calyx

struct GitRepoDiscoveryWorktreeTaskTests {

    @Test func test_discover_taskWorktreeCarriesTaskBase_plainAndMainDoNot() async throws {
        let scratch = try GitScratch.makeDirectory("GitRepoDiscoveryWorktreeTaskTests")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repo = scratch.appendingPathComponent("repo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        let task = scratch.appendingPathComponent("task-wt")
        let plain = scratch.appendingPathComponent("plain-wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "task/demo", task.path, "main"], in: repo)
        try GitScratch.run(["worktree", "add", "-q", "-b", "plain", plain.path, "main"], in: repo)
        try GitScratch.run(["config", "branch.task/demo.calyxbase", "main"], in: repo)
        // A calyxbase on the main worktree's own branch must not mark it.
        try GitScratch.run(["config", "branch.main.calyxbase", "other"], in: repo)

        let result = await GitRepoDiscovery.discover(seedWorkDirs: [repo.path])
        let byRoot = Dictionary(uniqueKeysWithValues: result.sections.map { ($0.rootPath, $0) })

        #expect(byRoot.count == 3)
        #expect(try #require(byRoot[task.path]).taskBase == "main")
        #expect(try #require(byRoot[plain.path]).taskBase == nil)
        #expect(try #require(byRoot[repo.path]).taskBase == nil)
    }

    @Test func test_descriptor_taskBaseDefaultsToNil() {
        let descriptor = GitRepoDescriptor(
            rootPath: "/r", displayName: "r", kind: .repository, branch: "main", headShortHash: nil,
            location: GitRepositoryLocation(workTree: "/r", gitDirectory: "/r/.git", gitCommonDirectory: "/r/.git")
        )
        #expect(descriptor.taskBase == nil)
    }
}
