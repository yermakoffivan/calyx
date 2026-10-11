// WorktreeTaskCoordinator.swift
// Calyx
//
// Orchestrates Worktree Tasks outside the window controller (the
// HerdrTabCoordinator precedent): presents the New Worktree Task sheet,
// creates the task worktree and spawns the agent CLI as the new pane's
// process, and merges or discards a task -- git work first, then closing
// the panes inside the removed worktree. Every window-side effect goes
// through `WorktreeTaskHost` (CalyxWindowController in the app,
// FakeWorktreeTaskHost in WorktreeTaskCoordinatorTests).

import Foundation

/// The window-side primitives `WorktreeTaskCoordinator` drives.
@MainActor
protocol WorktreeTaskHost: AnyObject {
    /// The focused pane's live cwd, or nil.
    var focusedPaneCwd: String? { get }
    /// Root under which task worktrees live (`SessionRootResolver`).
    var sessionRoot: String { get }
    /// The user's login shell, used to exec the agent CLI.
    var loginShell: String { get }

    /// Presents the New Worktree Task sheet.
    func presentTaskSheet(
        cwd: String?,
        onCreate: @escaping (WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void
    )
    func dismissTaskSheet()
    func setTaskSheetBusy(_ busy: Bool)
    /// Opens a tab at `cwd` whose process is `spawnArgv`; returns its
    /// surface ID, or nil when no tab was created.
    @discardableResult
    func openTaskPane(cwd: String, spawnArgv: [String]) -> UUID?
    func listPanes() -> [CockpitPaneInfo]
    /// Closes `surfaceIDs` in every window, first opening a tab at
    /// `replacementCwd` in any window that would otherwise lose all panes.
    func closePanes(surfaceIDs: [UUID], replacementCwd: String)
    func refreshGitSidebar()
    func presentError(_ error: Error)
    /// Asks whether to discard the task on `branch`.
    func confirmDiscard(branch: String) async -> Bool
}

/// Standardized worktree roots with a Merge or Discard running, shared
/// by every window's coordinator so two windows cannot race on one task.
@MainActor
final class WorktreeTaskOperationLedger {
    static let shared = WorktreeTaskOperationLedger()

    private(set) var inFlightRoots: Set<String> = []

    /// Marks `root` in flight; false when it already is.
    func begin(_ root: String) -> Bool {
        inFlightRoots.insert(root).inserted
    }

    func end(_ root: String) {
        inFlightRoots.remove(root)
    }
}

@MainActor
final class WorktreeTaskCoordinator {

    private weak var host: (any WorktreeTaskHost)?
    private let ledger: WorktreeTaskOperationLedger
    /// Replaces the agent CLI argv when non-nil (the UI tests' dummy
    /// process; resolved by the app side, see
    /// `CalyxWindowController.worktreeTaskUITestLaunchArgvOverride`).
    private let launchArgvOverride: [String]?

    /// True while `create` runs; a second `create` from the sheet in that
    /// time is ignored.
    private var isCreating = false

    /// Roots with a Merge or Discard running (in the shared ledger).
    var inFlightRoots: Set<String> { ledger.inFlightRoots }

    init(
        host: any WorktreeTaskHost,
        ledger: WorktreeTaskOperationLedger = .shared,
        launchArgvOverride: [String]? = nil
    ) {
        self.host = host
        self.ledger = ledger
        self.launchArgvOverride = launchArgvOverride
    }

    /// Opens the New Worktree Task sheet against the focused pane's cwd.
    func presentSheet() {
        guard let host else { return }
        host.presentTaskSheet(cwd: host.focusedPaneCwd) { [weak self] request, repository in
            Task { @MainActor in
                await self?.create(request: request, repository: repository)
            }
        }
    }

    /// Creates the task worktree, then opens a tab in it running the
    /// agent CLI. A failure to create the worktree is presented and the
    /// sheet stays open so the request can be corrected. A failure to
    /// open the pane is presented after the sheet closed; the worktree
    /// is kept (it is valid and the sidebar lists it). A `create` while
    /// one is running (a double submit) is ignored.
    func create(request: WorktreeTaskRequest, repository: WorktreeTaskRepositoryDescription) async {
        guard let host, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        let path = WorktreeTaskPlanner.worktreePath(
            sessionRoot: host.sessionRoot,
            repoDisplayName: repository.displayName,
            branch: request.branch
        )
        host.setTaskSheetBusy(true)
        let task: WorktreeTask
        do {
            task = try await WorktreeTaskService.create(
                request: request,
                location: repository.location,
                repoDisplayName: repository.displayName,
                path: path
            )
        } catch {
            host.setTaskSheetBusy(false)
            host.presentError(error)
            return
        }
        host.dismissTaskSheet()
        let spawnArgv = WorktreeTaskPlanner.spawnArgv(
            launchArgv: launchArgvOverride
                ?? WorktreeTaskPlanner.launchPlan(
                    agent: request.agent, arguments: request.arguments, prompt: request.prompt
                ).argv,
            loginShell: host.loginShell
        )
        if host.openTaskPane(cwd: task.path, spawnArgv: spawnArgv) == nil {
            host.presentError(WorktreeTaskError.paneCreationFailed(task.path))
        }
        host.refreshGitSidebar()
    }

    /// Merges the task rooted at `worktreeRoot` into its base, removes
    /// the worktree and deletes the branch, and only then closes the
    /// task's panes (a failed git step leaves the agent running).
    func merge(worktreeRoot: String) async {
        // The host is the window; once it is gone there is nothing to
        // present into or close, so the operation is not started.
        guard let host else { return }
        do {
            guard let task = try await WorktreeTaskService.task(forWorktreeRoot: worktreeRoot) else {
                throw WorktreeTaskError.notATask(worktreeRoot)
            }
            let key = GitRepositoryLocation.standardize(worktreeRoot)
            guard ledger.begin(key) else {
                throw WorktreeTaskError.operationInProgress(task.branch)
            }
            defer { ledger.end(key) }
            let basePath = try await WorktreeTaskService.merge(task: task)
            try await WorktreeTaskService.finishMerge(task: task, basePath: basePath)
            closePanes(host: host, insideWorktree: task.path, replacementCwd: basePath)
            host.refreshGitSidebar()
        } catch {
            host.presentError(error)
        }
    }

    /// After confirmation, force-removes the task's worktree and
    /// force-deletes its branch, then closes its panes. The root is
    /// marked in flight before asking, so a second request while the
    /// confirmation is up is reported as in progress.
    func discard(worktreeRoot: String) async {
        // The host is the window; once it is gone there is no one to
        // confirm with, so the operation is not started.
        guard let host else { return }
        do {
            guard let task = try await WorktreeTaskService.task(forWorktreeRoot: worktreeRoot) else {
                throw WorktreeTaskError.notATask(worktreeRoot)
            }
            let key = GitRepositoryLocation.standardize(worktreeRoot)
            guard ledger.begin(key) else {
                throw WorktreeTaskError.operationInProgress(task.branch)
            }
            defer { ledger.end(key) }
            guard await host.confirmDiscard(branch: task.branch) else { return }
            guard let mainWorktree = try await GitService.worktreeList(workDir: worktreeRoot).first else {
                throw WorktreeTaskError.notATask(worktreeRoot)
            }
            try await WorktreeTaskService.discard(task: task, workDir: mainWorktree.path)
            closePanes(host: host, insideWorktree: task.path, replacementCwd: mainWorktree.path)
            host.refreshGitSidebar()
        } catch {
            host.presentError(error)
        }
    }

    // MARK: - Private

    private func closePanes(host: any WorktreeTaskHost, insideWorktree path: String, replacementCwd: String) {
        let closing = WorktreeTaskPlanner.surfacesInside(path: path, panes: host.listPanes())
        guard !closing.isEmpty else { return }
        host.closePanes(surfaceIDs: closing, replacementCwd: replacementCwd)
    }
}
