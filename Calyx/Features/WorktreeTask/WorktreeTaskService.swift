// WorktreeTaskService.swift
// Calyx
//
// The git half of Worktree Tasks: describe the repository a sheet opens
// against, create a task worktree, merge it back, and discard it. Every
// write goes through `GitService.runMutating`.

import Foundation

enum WorktreeTaskError: Error, Equatable, LocalizedError {
    case invalidBranchName(String)
    case branchExists(String)
    case taskWorktreeDirty(String)
    case baseNotCheckedOut(String)
    case mergeFailed(stderr: String)
    case notATask(String)
    case baseMergeInProgress(String)
    case pathExists(String)
    case baseMissing(String)

    var errorDescription: String? {
        switch self {
        case .invalidBranchName(let name):
            "\"\(name)\" is not a valid branch name."
        case .branchExists(let name):
            "A branch named \"\(name)\" already exists."
        case .taskWorktreeDirty(let path):
            "The task worktree has uncommitted changes. Commit or discard them before merging.\n\(path)"
        case .baseNotCheckedOut(let base):
            "The base branch \"\(base)\" is not checked out in any worktree, so there is nowhere to merge into."
        case .mergeFailed(let stderr):
            "The merge failed and was aborted.\n\(stderr)"
        case .notATask(let path):
            "\(path) is not a worktree task."
        case .baseMergeInProgress(let path):
            "A merge is already in progress in the base worktree. Finish or abort it before merging this task.\n\(path)"
        case .pathExists(let path):
            "The worktree directory already exists. Remove it or choose another branch name.\n\(path)"
        case .baseMissing(let base):
            "The base branch \"\(base)\" does not exist."
        }
    }
}

enum WorktreeTaskService {

    /// The repository containing `cwd`: its location, the main worktree's
    /// name, its local branches, and the branch checked out at `cwd`.
    static func describeRepository(cwd: String) async throws -> WorktreeTaskRepositoryDescription {
        let location = try await GitService.repositoryLocation(workDir: cwd)
        async let worktrees = GitService.worktreeList(workDir: cwd)
        async let refs = GitService.refList(location: location)
        async let head = GitService.headSummary(workDir: cwd)
        let displayName = try await repoDisplayName(worktrees: worktrees)
        let localBranches = try await refs
            .filter { $0.kind == .localBranch }
            .map(\.shortName)
            .sorted()
        return try await WorktreeTaskRepositoryDescription(
            location: location,
            displayName: displayName,
            localBranches: localBranches,
            headBranch: head.branch
        )
    }

    /// Validates the branch name, refuses an existing branch, a missing
    /// base and an existing directory at `path`, adds the worktree at
    /// `path` on a new branch from `request.base`, and records the base as
    /// the task marker. If recording the marker fails, the new worktree
    /// and branch are force-removed before the error is rethrown, so a
    /// failed create leaves nothing behind.
    ///
    /// `recordBase` writes the marker; it is a parameter only so tests can
    /// make that step fail deterministically.
    static func create(
        request: WorktreeTaskRequest,
        location: GitRepositoryLocation,
        repoDisplayName: String,
        path: String,
        recordBase: (_ branch: String, _ base: String, _ workDir: String) async throws -> Void = { branch, base, workDir in
            try await GitService.setBranchConfig(
                branch: branch, key: GitService.worktreeTaskBaseConfigKey, value: base, workDir: workDir
            )
        }
    ) async throws -> WorktreeTask {
        let workDir = location.workTree
        guard await GitService.checkRefFormat(branch: request.branch, workDir: workDir) else {
            throw WorktreeTaskError.invalidBranchName(request.branch)
        }
        let refs = try await GitService.refList(location: location)
        if refs.contains(where: { $0.kind == .localBranch && $0.shortName == request.branch }) {
            throw WorktreeTaskError.branchExists(request.branch)
        }
        guard try await GitService.localBranchExists(request.base, workDir: workDir) else {
            throw WorktreeTaskError.baseMissing(request.base)
        }
        guard !FileManager.default.fileExists(atPath: path) else {
            throw WorktreeTaskError.pathExists(path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try await GitService.worktreeAdd(path: path, newBranch: request.branch, base: request.base, workDir: workDir)
        do {
            try await recordBase(request.branch, request.base, workDir)
        } catch {
            // Rollback is best-effort: the marker failure is the error the
            // caller must see, so a rollback failure must not replace it.
            try? await GitService.worktreeRemove(path: path, force: true, workDir: workDir)
            try? await GitService.branchDelete(branch: request.branch, force: true, workDir: workDir)
            throw error
        }
        return WorktreeTask(
            repositoryLocation: location,
            repoDisplayName: repoDisplayName,
            branch: request.branch,
            base: request.base,
            path: path
        )
    }

    /// Merges the task branch into the worktree that has the base checked
    /// out and returns that worktree's path. Requires a clean task
    /// worktree and no merge already in progress in the base worktree
    /// (that merge belongs to the user and is never touched). Our own
    /// merge, if it fails for any reason (conflict, timeout), is aborted
    /// before throwing, so the base is left as it was.
    static func merge(task: WorktreeTask) async throws -> String {
        guard try await GitService.isWorkingTreeClean(workDir: task.path) else {
            throw WorktreeTaskError.taskWorktreeDirty(task.path)
        }
        let worktrees = try await GitService.worktreeList(workDir: task.path)
        guard let basePath = WorktreeTaskPlanner.worktreeHosting(branch: task.base, in: worktrees) else {
            throw WorktreeTaskError.baseNotCheckedOut(task.base)
        }
        guard try await !GitService.hasMergeInProgress(workDir: basePath) else {
            throw WorktreeTaskError.baseMergeInProgress(basePath)
        }
        do {
            try await GitService.merge(branch: task.branch, workDir: basePath)
        } catch GitService.GitError.commandFailed(_, let stderr, _) {
            await GitService.mergeAbort(workDir: basePath)
            throw WorktreeTaskError.mergeFailed(stderr: stderr)
        } catch {
            await GitService.mergeAbort(workDir: basePath)
            throw error
        }
        return basePath
    }

    /// After a successful merge: removes the task worktree and deletes
    /// its (now merged) branch.
    static func finishMerge(task: WorktreeTask, basePath: String) async throws {
        try await GitService.worktreeRemove(path: task.path, force: false, workDir: basePath)
        try await GitService.branchDelete(branch: task.branch, force: false, workDir: basePath)
    }

    /// Force-removes the task worktree and force-deletes its branch.
    /// `workDir` must be a worktree of the same repository other than the
    /// task's own.
    static func discard(task: WorktreeTask, workDir: String) async throws {
        try await GitService.worktreeRemove(path: task.path, force: true, workDir: workDir)
        try await GitService.branchDelete(branch: task.branch, force: true, workDir: workDir)
    }

    /// The task whose linked worktree is rooted at `root`, or nil when it
    /// is the main worktree, detached, or carries no task marker.
    static func task(forWorktreeRoot root: String) async throws -> WorktreeTask? {
        let location = try await GitService.repositoryLocation(workDir: root)
        let standardized = location.standardized
        guard standardized.gitDirectory != standardized.gitCommonDirectory else { return nil }
        guard let branch = try await GitService.headSummary(workDir: root).branch else { return nil }
        guard let base = try await GitService.getBranchConfig(
            branch: branch, key: GitService.worktreeTaskBaseConfigKey, workDir: root
        ) else { return nil }
        let worktrees = try await GitService.worktreeList(workDir: root)
        return WorktreeTask(
            repositoryLocation: location,
            repoDisplayName: try repoDisplayName(worktrees: worktrees),
            branch: branch,
            base: base,
            path: root
        )
    }

    /// `git worktree list` always lists the main worktree first.
    private static func repoDisplayName(worktrees: [GitWorktreeInfo]) throws -> String {
        guard let main = worktrees.first else {
            throw GitService.GitError.commandFailed(
                exitCode: -1, stderr: "git worktree list returned no worktrees", command: "worktree"
            )
        }
        return (main.path as NSString).lastPathComponent
    }
}
