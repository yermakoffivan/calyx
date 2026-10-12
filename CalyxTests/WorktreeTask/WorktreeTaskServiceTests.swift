// WorktreeTaskServiceTests.swift
// CalyxTests
//
// End-to-end tests for WorktreeTaskService against real scratch
// repositories: create, merge + finishMerge, discard, and the refusals
// (invalid name, existing branch, dirty task, base not checked out,
// conflicting merge).

import Foundation
import Testing
@testable import Calyx

struct WorktreeTaskServiceTests {

    private struct Fixture {
        let scratch: URL
        let repo: URL
        let description: WorktreeTaskRepositoryDescription
        func taskPath(_ name: String) -> String {
            scratch.appendingPathComponent("worktrees/\(name)").path
        }
    }

    private func makeFixture() async throws -> Fixture {
        let scratch = try GitScratch.makeDirectory("WorktreeTaskServiceTests")
        let repo = scratch.appendingPathComponent("myrepo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.configureIdentity(in: repo)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        let description = try await WorktreeTaskService.describeRepository(cwd: repo.path)
        return Fixture(scratch: scratch, repo: repo, description: description)
    }

    private func createTask(_ fixture: Fixture, branch: String = "task/demo") async throws -> WorktreeTask {
        try await WorktreeTaskService.create(
            request: WorktreeTaskRequest(branch: branch, base: "main", agent: .claudeCode, prompt: "hi"),
            location: fixture.description.location,
            repoDisplayName: fixture.description.displayName,
            path: fixture.taskPath(branch.replacingOccurrences(of: "/", with: "-"))
        )
    }

    private func branchExists(_ branch: String, in repo: URL) throws -> Bool {
        !(try GitScratch.run(["branch", "--list", branch], in: repo)).isEmpty
    }

    // MARK: - describeRepository

    @Test func test_describeRepository_fromMainAndFromLinkedWorktree() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        try GitScratch.run(["branch", "zeta"], in: fixture.repo)
        let linked = fixture.scratch.appendingPathComponent("linked")
        try GitScratch.run(["worktree", "add", "-q", "-b", "alpha", linked.path, "main"], in: fixture.repo)

        let fromMain = try await WorktreeTaskService.describeRepository(cwd: fixture.repo.path)
        #expect(fromMain.displayName == "myrepo")
        #expect(fromMain.headBranch == "main")
        #expect(fromMain.location.workTree == fixture.repo.path)
        #expect(Set(fromMain.localBranches) == ["alpha", "main", "zeta"])
        #expect(fromMain.localBranches.count == 3)

        let fromLinked = try await WorktreeTaskService.describeRepository(cwd: linked.path)
        #expect(fromLinked.displayName == "myrepo", "displayName names the MAIN worktree")
        #expect(fromLinked.headBranch == "alpha")
        #expect(fromLinked.location.workTree == linked.path)
    }

    // MARK: - create

    @Test func test_create_addsWorktreeRecordsBaseAndReturnsTask() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("task-demo")

        let task = try await createTask(fixture)

        #expect(task == WorktreeTask(
            repositoryLocation: fixture.description.location,
            repoDisplayName: "myrepo",
            branch: "task/demo",
            base: "main",
            path: path
        ))
        #expect(FileManager.default.fileExists(atPath: path + "/base.txt"))
        #expect(try GitScratch.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: path)) == "task/demo")
        #expect(try GitScratch.run(["config", "branch.task/demo.calyxbase"], in: fixture.repo) == "main")
    }

    @Test func test_create_invalidBranchName_throwsWithoutTouchingRepo() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("bad")

        do {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "bad..name", base: "main", agent: .codex, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: path
            )
            Issue.record("expected .invalidBranchName")
        } catch WorktreeTaskError.invalidBranchName(let name) {
            #expect(name == "bad..name")
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try GitScratch.run(["worktree", "list", "--porcelain"], in: fixture.repo)
            .components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
    }

    @Test func test_create_existingBranch_throwsBranchExists() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        try GitScratch.run(["branch", "taken"], in: fixture.repo)
        let path = fixture.taskPath("taken")

        do {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "taken", base: "main", agent: .pi, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: path
            )
            Issue.record("expected .branchExists")
        } catch WorktreeTaskError.branchExists(let name) {
            #expect(name == "taken")
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func test_create_existingPath_throwsPathExistsWithoutTouchingRepo() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("leftover")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        do {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "leftover", base: "main", agent: .codex, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: path
            )
            Issue.record("expected .pathExists")
        } catch WorktreeTaskError.pathExists(let reported) {
            #expect(reported == path)
            #expect(WorktreeTaskError.pathExists(reported).errorDescription?.contains("Remove it or choose another branch name") == true)
        }
        #expect(try branchExists("leftover", in: fixture.repo) == false)
    }

    @Test func test_create_missingBase_throwsBaseMissing() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("nobase")

        do {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "nobase", base: "ghost", agent: .codex, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: path
            )
            Issue.record("expected .baseMissing")
        } catch WorktreeTaskError.baseMissing(let base) {
            #expect(base == "ghost")
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try branchExists("nobase", in: fixture.repo) == false)
    }

    @Test func test_create_atSignBranchName_isInvalid() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        await #expect(throws: WorktreeTaskError.invalidBranchName("@{-1}")) {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "@{-1}", base: "main", agent: .codex, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: fixture.taskPath("at")
            )
        }
    }

    private struct MarkerWriteFailed: Error {}

    @Test func test_create_markerWriteFails_rollsBackWorktreeAndBranch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("rollback")

        await #expect(throws: MarkerWriteFailed.self) {
            _ = try await WorktreeTaskService.create(
                request: WorktreeTaskRequest(branch: "rollback", base: "main", agent: .codex, prompt: ""),
                location: fixture.description.location, repoDisplayName: "myrepo", path: path,
                recordBase: { _, _, _ in throw MarkerWriteFailed() }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try branchExists("rollback", in: fixture.repo) == false)
        #expect(try GitScratch.run(["worktree", "list", "--porcelain"], in: fixture.repo)
            .components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
    }

    // MARK: - merge + finishMerge

    @Test func test_merge_thenFinishMerge_endToEnd() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        let taskTree = URL(fileURLWithPath: task.path)
        let taskCommit = try GitScratch.commit(file: "work.txt", contents: "work\n", message: "work", in: taskTree)
        let mainBefore = try GitScratch.run(["rev-parse", "main"], in: fixture.repo)

        let basePath = try await WorktreeTaskService.merge(task: task)

        #expect(basePath == fixture.repo.path)
        let parents = try GitScratch.run(["rev-list", "--parents", "-n", "1", "main"], in: fixture.repo)
            .split(separator: " ").map(String.init)
        #expect(Array(parents.dropFirst()) == [mainBefore, taskCommit])
        #expect(FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent("work.txt").path))

        try await WorktreeTaskService.finishMerge(task: task, basePath: basePath)

        #expect(!FileManager.default.fileExists(atPath: task.path))
        #expect(try branchExists("task/demo", in: fixture.repo) == false)
    }

    @Test func test_merge_dirtyTaskWorktree_throwsBeforeMerging() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        let taskTree = URL(fileURLWithPath: task.path)
        try GitScratch.commit(file: "work.txt", contents: "work\n", message: "work", in: taskTree)
        try "uncommitted\n".write(to: taskTree.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let mainBefore = try GitScratch.run(["rev-parse", "main"], in: fixture.repo)

        do {
            _ = try await WorktreeTaskService.merge(task: task)
            Issue.record("expected .taskWorktreeDirty")
        } catch WorktreeTaskError.taskWorktreeDirty(let path) {
            #expect(path == task.path)
        }
        #expect(try GitScratch.run(["rev-parse", "main"], in: fixture.repo) == mainBefore)
    }

    @Test func test_merge_baseNotCheckedOutAnywhere_throwsBaseNotCheckedOut() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        try GitScratch.commit(file: "work.txt", contents: "work\n", message: "work", in: URL(fileURLWithPath: task.path))
        try GitScratch.run(["checkout", "-q", "-b", "elsewhere"], in: fixture.repo)
        let mainBefore = try GitScratch.run(["rev-parse", "main"], in: fixture.repo)

        do {
            _ = try await WorktreeTaskService.merge(task: task)
            Issue.record("expected .baseNotCheckedOut")
        } catch WorktreeTaskError.baseNotCheckedOut(let base) {
            #expect(base == "main")
        }
        #expect(try GitScratch.run(["rev-parse", "main"], in: fixture.repo) == mainBefore)
        #expect(try GitScratch.run(["rev-parse", "HEAD"], in: fixture.repo) == mainBefore)
    }

    @Test func test_merge_conflict_abortsAndLeavesWorktreeAndCleanBase() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        try GitScratch.commit(file: "base.txt", contents: "task side\n", message: "task", in: URL(fileURLWithPath: task.path))
        let mainBefore = try GitScratch.commit(file: "base.txt", contents: "main side\n", message: "main", in: fixture.repo)

        do {
            _ = try await WorktreeTaskService.merge(task: task)
            Issue.record("expected .mergeFailed")
        } catch WorktreeTaskError.mergeFailed {
            // stderr content is git's wording; its presence is enough.
        }
        #expect(FileManager.default.fileExists(atPath: task.path))
        #expect(try branchExists("task/demo", in: fixture.repo))
        #expect(try GitScratch.run(["status", "--porcelain"], in: fixture.repo).isEmpty)
        #expect(try GitScratch.run(["rev-parse", "HEAD"], in: fixture.repo) == mainBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.repo.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test func test_merge_baseMergeAlreadyInProgress_throwsAndLeavesUsersMergeAlone() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        try GitScratch.commit(file: "work.txt", contents: "work\n", message: "work", in: URL(fileURLWithPath: task.path))
        // The user's own conflicted merge in the base worktree.
        try GitScratch.run(["branch", "side"], in: fixture.repo)
        try GitScratch.commit(file: "base.txt", contents: "main side\n", message: "main", in: fixture.repo)
        try GitScratch.run(["checkout", "-q", "side"], in: fixture.repo)
        try GitScratch.commit(file: "base.txt", contents: "side side\n", message: "side", in: fixture.repo)
        try GitScratch.run(["checkout", "-q", "main"], in: fixture.repo)
        _ = try? GitScratch.run(["merge", "side"], in: fixture.repo)
        let mergeHead = fixture.repo.appendingPathComponent(".git/MERGE_HEAD").path
        try #require(FileManager.default.fileExists(atPath: mergeHead), "precondition: user merge in progress")

        do {
            _ = try await WorktreeTaskService.merge(task: task)
            Issue.record("expected .baseMergeInProgress")
        } catch WorktreeTaskError.baseMergeInProgress(let path) {
            #expect(path == fixture.repo.path)
        }
        #expect(FileManager.default.fileExists(atPath: mergeHead))
        #expect(FileManager.default.fileExists(atPath: task.path))
    }

    // MARK: - discard

    @Test func test_discard_removesDirtyWorktreeAndUnmergedBranch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let task = try await createTask(fixture)
        let taskTree = URL(fileURLWithPath: task.path)
        try GitScratch.commit(file: "work.txt", contents: "work\n", message: "work", in: taskTree)
        try "wip\n".write(to: taskTree.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let mainBefore = try GitScratch.run(["rev-parse", "main"], in: fixture.repo)

        try await WorktreeTaskService.discard(task: task, workDir: fixture.repo.path)

        #expect(!FileManager.default.fileExists(atPath: task.path))
        #expect(try branchExists("task/demo", in: fixture.repo) == false)
        #expect(try GitScratch.run(["rev-parse", "main"], in: fixture.repo) == mainBefore)
    }

    // MARK: - task(forWorktreeRoot:)

    @Test func test_taskForWorktreeRoot_returnsTaskForTaskWorktree() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let created = try await createTask(fixture)

        let found = try await WorktreeTaskService.task(forWorktreeRoot: created.path)

        let task = try #require(found)
        #expect(task.branch == "task/demo")
        #expect(task.base == "main")
        #expect(task.path == created.path)
        #expect(task.repoDisplayName == "myrepo")
    }

    @Test func test_taskForWorktreeRoot_nilForPlainWorktreeAndMainRepo() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let plain = fixture.scratch.appendingPathComponent("plain")
        try GitScratch.run(["worktree", "add", "-q", "-b", "plain", plain.path, "main"], in: fixture.repo)

        #expect(try await WorktreeTaskService.task(forWorktreeRoot: plain.path) == nil)
        #expect(try await WorktreeTaskService.task(forWorktreeRoot: fixture.repo.path) == nil)
    }
}
