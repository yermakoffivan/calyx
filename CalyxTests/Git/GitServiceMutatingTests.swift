// GitServiceMutatingTests.swift
// CalyxTests
//
// Integration tests for GitService's write path (`runMutating` and the
// worktree-task operations built on it), against real scratch
// repositories.

import Foundation
import Testing
@testable import Calyx

struct GitServiceMutatingTests {

    /// A scratch directory holding `repo` on `main` with one commit and a
    /// local identity.
    private func makeRepository() throws -> (scratch: URL, repo: URL) {
        let scratch = try GitScratch.makeDirectory("GitServiceMutatingTests")
        let repo = scratch.appendingPathComponent("repo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.configureIdentity(in: repo)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        return (scratch, repo)
    }

    private func stderr(of error: Error) -> String? {
        if case GitService.GitError.commandFailed(_, let stderr, _) = error { return stderr }
        return nil
    }

    // MARK: - checkRefFormat

    @Test func test_checkRefFormat_acceptsValidAndRejectsInvalidNames() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(await GitService.checkRefFormat(branch: "task/demo", workDir: repo.path) == true)
        #expect(await GitService.checkRefFormat(branch: "feature-1", workDir: repo.path) == true)
        #expect(await GitService.checkRefFormat(branch: "bad..name", workDir: repo.path) == false)
        #expect(await GitService.checkRefFormat(branch: "-x", workDir: repo.path) == false)
        #expect(await GitService.checkRefFormat(branch: "", workDir: repo.path) == false)
        #expect(await GitService.checkRefFormat(branch: "@{-1}", workDir: repo.path) == false)
    }

    @Test func test_localBranchExists() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(try await GitService.localBranchExists("main", workDir: repo.path) == true)
        #expect(try await GitService.localBranchExists("ghost", workDir: repo.path) == false)
    }

    @Test func test_hasMergeInProgress() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(try await GitService.hasMergeInProgress(workDir: repo.path) == false)
        try GitScratch.run(["branch", "side"], in: repo)
        try GitScratch.commit(file: "base.txt", contents: "main\n", message: "main", in: repo)
        try GitScratch.run(["checkout", "-q", "side"], in: repo)
        try GitScratch.commit(file: "base.txt", contents: "side\n", message: "side", in: repo)
        try GitScratch.run(["checkout", "-q", "main"], in: repo)
        _ = try? GitScratch.run(["merge", "side"], in: repo)
        #expect(try await GitService.hasMergeInProgress(workDir: repo.path) == true)
    }

    @Test func test_gitProcessPATH_includesHomebrew() {
        #expect(GitService.gitProcessPATH.split(separator: ":").contains("/opt/homebrew/bin"))
    }

    // MARK: - runMutating

    @Test func test_runMutating_returnsStdoutAndThrowsCommandFailedWithStderr() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let output = try await GitService.runMutating(args: ["rev-parse", "--abbrev-ref", "HEAD"], workDir: repo.path)
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "main")

        do {
            _ = try await GitService.runMutating(args: ["checkout", "no-such-branch"], workDir: repo.path)
            Issue.record("checkout of a missing branch must throw")
        } catch {
            let message = try #require(stderr(of: error), "expected .commandFailed, got \(error)")
            #expect(message.contains("no-such-branch"))
        }
    }

    // MARK: - worktreeAdd / branch config

    @Test func test_worktreeAdd_createsBranchAndConfigRoundTrips() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let worktree = scratch.appendingPathComponent("wt/task-demo")

        try await GitService.worktreeAdd(path: worktree.path, newBranch: "task/demo", base: "main", workDir: repo.path)

        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("base.txt").path))
        #expect(try GitScratch.run(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree) == "task/demo")

        let list = try await GitService.worktreeList(workDir: repo.path)
        let entry = try #require(list.first { $0.branchRef == "refs/heads/task/demo" })
        #expect(entry.path == worktree.path)

        try await GitService.setBranchConfig(
            branch: "task/demo", key: GitService.worktreeTaskBaseConfigKey, value: "main", workDir: repo.path
        )
        #expect(try await GitService.getBranchConfig(
            branch: "task/demo", key: GitService.worktreeTaskBaseConfigKey, workDir: repo.path
        ) == "main")
        #expect(try GitScratch.run(["config", "branch.task/demo.calyxbase"], in: repo) == "main")
    }

    @Test func test_worktreeTaskBaseConfigKey() {
        #expect(GitService.worktreeTaskBaseConfigKey == "calyxbase")
    }

    @Test func test_getBranchConfig_nilWhenUnset() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(try await GitService.getBranchConfig(branch: "main", key: "calyxbase", workDir: repo.path) == nil)
    }

    // MARK: - isWorkingTreeClean

    @Test func test_isWorkingTreeClean_tracksModifiedAndUntrackedFiles() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(try await GitService.isWorkingTreeClean(workDir: repo.path) == true)

        try "changed\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        #expect(try await GitService.isWorkingTreeClean(workDir: repo.path) == false)

        try GitScratch.run(["checkout", "--", "base.txt"], in: repo)
        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        #expect(try await GitService.isWorkingTreeClean(workDir: repo.path) == false)
    }

    // MARK: - merge / branchDelete

    @Test func test_merge_noFastForwardCreatesMergeCommit_thenBranchDelete() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try GitScratch.run(["checkout", "-q", "-b", "feature"], in: repo)
        let featureCommit = try GitScratch.commit(file: "f.txt", contents: "f\n", message: "feature", in: repo)
        try GitScratch.run(["checkout", "-q", "main"], in: repo)
        let mainBefore = try GitScratch.run(["rev-parse", "HEAD"], in: repo)

        try await GitService.merge(branch: "feature", workDir: repo.path)

        // A fast-forward would leave HEAD == featureCommit with one parent.
        let parents = try GitScratch.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo)
            .split(separator: " ").map(String.init)
        #expect(parents.count == 3)
        #expect(Array(parents.dropFirst()) == [mainBefore, featureCommit])

        try await GitService.branchDelete(branch: "feature", force: false, workDir: repo.path)
        #expect(try GitScratch.run(["branch", "--list", "feature"], in: repo).isEmpty)
    }

    @Test func test_merge_conflictThrowsWithStderr_andMergeAbortRestoresCleanTree() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try GitScratch.run(["checkout", "-q", "-b", "feature"], in: repo)
        try GitScratch.commit(file: "base.txt", contents: "feature side\n", message: "feature", in: repo)
        try GitScratch.run(["checkout", "-q", "main"], in: repo)
        let mainBefore = try GitScratch.commit(file: "base.txt", contents: "main side\n", message: "main", in: repo)

        do {
            try await GitService.merge(branch: "feature", workDir: repo.path)
            Issue.record("a conflicting merge must throw")
        } catch {
            let message = try #require(stderr(of: error), "expected .commandFailed, got \(error)")
            _ = message
        }
        #expect(try await GitService.isWorkingTreeClean(workDir: repo.path) == false)

        await GitService.mergeAbort(workDir: repo.path)

        #expect(try await GitService.isWorkingTreeClean(workDir: repo.path) == true)
        #expect(try GitScratch.run(["rev-parse", "HEAD"], in: repo) == mainBefore)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test func test_mergeAbort_withoutMergeInProgress_doesNotThrowOrChangeAnything() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let head = try GitScratch.run(["rev-parse", "HEAD"], in: repo)

        await GitService.mergeAbort(workDir: repo.path)

        #expect(try GitScratch.run(["rev-parse", "HEAD"], in: repo) == head)
    }

    // MARK: - worktreeRemove

    @Test func test_worktreeRemove_refusesDirtyWithoutForce_succeedsWithForce() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let worktree = scratch.appendingPathComponent("wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "side", worktree.path, "main"], in: repo)
        try "dirty\n".write(to: worktree.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        do {
            try await GitService.worktreeRemove(path: worktree.path, force: false, workDir: repo.path)
            Issue.record("removing a dirty worktree without force must throw")
        } catch {
            #expect(stderr(of: error) != nil, "expected .commandFailed, got \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try await GitService.worktreeRemove(path: worktree.path, force: true, workDir: repo.path)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        let list = try await GitService.worktreeList(workDir: repo.path)
        #expect(list.map(\.path) == [repo.path])
    }

    @Test func test_worktreeRemove_cleanWorktreeWithoutForce() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let worktree = scratch.appendingPathComponent("wt")
        try GitScratch.run(["worktree", "add", "-q", "-b", "side", worktree.path, "main"], in: repo)

        try await GitService.worktreeRemove(path: worktree.path, force: false, workDir: repo.path)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    // MARK: - branchDelete

    @Test func test_branchDelete_missingBranchThrowsCommandFailedWithStderr() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }

        do {
            try await GitService.branchDelete(branch: "nope", force: false, workDir: repo.path)
            Issue.record("deleting a missing branch must throw")
        } catch {
            let message = try #require(stderr(of: error), "expected .commandFailed, got \(error)")
            #expect(message.contains("nope"))
        }
    }

    @Test func test_branchDelete_unmergedRequiresForce() async throws {
        let (scratch, repo) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try GitScratch.run(["checkout", "-q", "-b", "side"], in: repo)
        try GitScratch.commit(file: "s.txt", contents: "s\n", message: "side", in: repo)
        try GitScratch.run(["checkout", "-q", "main"], in: repo)

        await #expect(throws: GitService.GitError.self) {
            try await GitService.branchDelete(branch: "side", force: false, workDir: repo.path)
        }
        try await GitService.branchDelete(branch: "side", force: true, workDir: repo.path)
        #expect(try GitScratch.run(["branch", "--list", "side"], in: repo).isEmpty)
    }
}
