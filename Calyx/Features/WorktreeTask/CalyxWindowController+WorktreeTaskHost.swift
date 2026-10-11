// CalyxWindowController+WorktreeTaskHost.swift
// Calyx
//
// The window-side primitives WorktreeTaskCoordinator drives. Only
// presentation and pane plumbing live here; the orchestration (git
// work, ordering, in-flight tracking) is the coordinator's.

import AppKit
import GhosttyKit

extension CalyxWindowController: WorktreeTaskHost {

    var sessionRoot: String {
        SessionRootResolver().resolve()
    }

    /// The account's login shell (passwd entry), else `$SHELL`, else
    /// `/bin/zsh`; see `WorktreeTaskPlanner.loginShell`.
    var loginShell: String {
        let passwdShell = getpwuid(getuid()).flatMap { entry in
            entry.pointee.pw_shell.map { String(cString: $0) }
        }
        return WorktreeTaskPlanner.loginShell(
            passwdShell: passwdShell,
            environmentShell: ProcessInfo.processInfo.environment["SHELL"]
        )
    }

    /// Launch environment variable whose U+001F-separated fields replace
    /// the agent CLI argv, so the end-to-end test runs a dummy process
    /// instead of a real agent.
    static let worktreeTaskUITestLaunchArgvEnvironmentKey = "CALYX_UITEST_WORKTREE_TASK_ARGV"

    /// The UI-test agent argv override: honoured only under
    /// `--uitesting`; empty fields are dropped and an override with no
    /// fields is nil.
    static func worktreeTaskUITestLaunchArgvOverride(arguments: [String], environment: [String: String]) -> [String]? {
        guard arguments.contains("--uitesting"),
              let value = environment[worktreeTaskUITestLaunchArgvEnvironmentKey] else { return nil }
        let fields = value.components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
        return fields.isEmpty ? nil : fields
    }

    /// Presents the New Worktree Task sheet; ignored while one is up.
    func presentTaskSheet(
        cwd: String?,
        onCreate: @escaping (WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void
    ) {
        guard let window, worktreeTaskSheetController == nil else { return }
        let sheet = WorktreeTaskSheetController(
            cwd: cwd, onCreate: onCreate, onCancel: {}
        )
        guard let sheetWindow = sheet.window else { return }
        worktreeTaskSheetController = sheet
        window.beginSheet(sheetWindow) { [weak self, weak sheet] _ in
            guard let sheet else { return }
            self?.worktreeTaskSheetDidEnd(sheet)
        }
    }

    /// Forgets `sheet` when it is still the presented one. Its
    /// `beginSheet` completion runs asynchronously after the sheet ends,
    /// by which time `dismissTaskSheet` may have cleared it and a newer
    /// sheet may be up; that newer one must stay.
    func worktreeTaskSheetDidEnd(_ sheet: WorktreeTaskSheetController) {
        guard worktreeTaskSheetController === sheet else { return }
        worktreeTaskSheetController = nil
    }

    /// Ends the sheet and forgets it at once, so an error presented
    /// right after goes to the window, not the closing sheet.
    func dismissTaskSheet() {
        worktreeTaskSheetController?.dismiss()
        worktreeTaskSheetController = nil
    }

    func setTaskSheetBusy(_ busy: Bool) {
        worktreeTaskSheetController?.setBusy(busy)
    }

    @discardableResult
    func openTaskPane(cwd: String, spawnArgv: [String]) -> UUID? {
        guard let app = GhosttyAppController.shared.app else { return nil }
        return performOpenTaskPane(app: app, cwd: cwd, spawnArgv: spawnArgv)
    }

    /// `openTaskPane`'s body, taking `app` directly so a unit test can
    /// drive it (`performCreateNewTab`'s precedent). A pane created on
    /// the passthrough path (no `SessionSurfaceMap` entry) carries its
    /// argv as a surface `command`, for which ghostty forces
    /// `wait-after-command`; it is recorded in `CommandHostedSurfaces`
    /// so `processChildExited` closes it when the shell exits. A
    /// persistent-session pane is left to `SessionReconnectCoordinator`.
    @discardableResult
    func performOpenTaskPane(app: ghostty_app_t, cwd: String, spawnArgv: [String]) -> UUID? {
        guard let surfaceID = performCreateNewTab(app: app, spawnCwd: cwd, spawnArgv: spawnArgv) else { return nil }
        if SessionSurfaceMap.shared.sessionID(for: surfaceID) == nil {
            CommandHostedSurfaces.shared.register(surfaceID)
        }
        return surfaceID
    }

    func listPanes() -> [CockpitPaneInfo] {
        LiveCockpitAppAccess().listPanes()
    }

    /// Closes `surfaceIDs` in every window (killing their persistent
    /// sessions). A window that would lose all its panes first gets a
    /// tab at `replacementCwd` so it stays open.
    func closePanes(surfaceIDs: [UUID], replacementCwd: String) {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        for controller in appDelegate.allWindowControllers {
            let leafIDs = controller.windowSession.groups
                .flatMap(\.tabs)
                .flatMap { $0.splitTree.allLeafIDs() }
            if WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: leafIDs, closing: surfaceIDs) {
                controller.createNewTab(spawnCwd: replacementCwd)
            }
            for surfaceID in surfaceIDs {
                controller.closeSurfaceIfOwned(surfaceID)
            }
        }
    }

    func refreshGitSidebar() {
        refreshGitSidebar(trigger: .manualRefresh)
    }

    /// Shows `error` as a sheet over the task sheet when it is up,
    /// otherwise over this window (the error's `localizedDescription`; a
    /// failed merge carries git's stderr).
    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Worktree Task"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let target = worktreeTaskSheetController?.window ?? window {
            alert.beginSheetModal(for: target)
        } else {
            alert.runModal()
        }
    }

    func confirmDiscard(branch: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard worktree task \(branch)?"
        alert.informativeText = "The task's worktree, its uncommitted changes and the branch \(branch) will be deleted, and its panes closed."
        alert.alertStyle = .warning
        let discardButton = alert.addButton(withTitle: "Discard")
        discardButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard let window else { return false }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// Sidebar / Mission Map entry points.
    func mergeWorktreeTask(worktreeRoot: String) {
        Task { @MainActor [weak self] in
            await self?.worktreeTaskCoordinator.merge(worktreeRoot: worktreeRoot)
        }
    }

    func discardWorktreeTask(worktreeRoot: String) {
        Task { @MainActor [weak self] in
            await self?.worktreeTaskCoordinator.discard(worktreeRoot: worktreeRoot)
        }
    }
}
