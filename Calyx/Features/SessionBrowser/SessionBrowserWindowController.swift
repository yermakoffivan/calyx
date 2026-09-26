// SessionBrowserWindowController.swift
// Calyx
//
// Independent window (same shape as `SettingsWindowController`) that
// shows the session browser (every calyx-session the daemon knows
// about, across all Calyx windows and launches, not just this
// process's currently-live panes). No dedicated test file: the logic
// worth testing lives in `SessionBrowserModel`, or, for the herdr
// workspace-create wire flow, `HerdrAttachOrCreateFlow`
// (HerdrAttachOrCreateFlow.swift), or, for opening an already-known
// workspace, `HerdrTabCoordinatorTests.swift` (this file's own
// `attachHerdrWorkspace(_:)`/`closeHerdrWorkspaceTabs(_:)` are each a
// direct, untested-here call into that coordinator), not this AppKit
// shell.

import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SessionBrowserWindowController")

@MainActor
final class SessionBrowserWindowController: NSWindowController {

    static let shared = SessionBrowserWindowController()

    let model: SessionBrowserModel

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.center()
        window.isReleasedWhenClosed = false

        // Wires the herdr workspace row's own "Attach"/"Show" query to
        // HerdrTabCoordinator.hasOpenTab(workspaceID:socketPath:) --
        // evaluated fresh on every call, so this always reads whichever
        // coordinator AppDelegate currently holds, never a value baked
        // in at construction time. `nil` (herdr itself was never
        // resolvable) answers false, same as the model's own default.
        self.model = SessionBrowserModel(
            herdrWorkspaceIsAttachedHere: { workspaceID, socketPath in
                (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator?.hasOpenTab(
                    workspaceID: workspaceID, socketPath: socketPath
                ) ?? false
            }
        )

        super.init(window: window)

        window.contentView = NSHostingView(rootView: SessionBrowserView(model: model))

        // "Attach" on a row already visible somewhere in this process
        // (`isAttachedHere`) reveals that pane via the same
        // `.calyxFocusSurface` notification every window controller
        // already observes (`AgentStatusView`'s identical pattern) — a
        // second attach connection to an already-live session makes no
        // sense. Otherwise (an orphaned, running session with no local
        // surface) opens a brand-new window that reattaches to it.
        model.onAttachRequested = { [weak self] row in
            self?.attach(row)
        }

        // Remote sessions: mirrors the onAttachRequested wiring
        // immediately above -- reaches a window controller the same
        // way attach(_:) does (via AppDelegate), for a chosen remote
        // host's SessionSpawnContext instead of an existing session
        // row.
        model.onRemoteSessionRequested = { [weak self] context in
            self?.attachRemote(context)
        }

        // Herdr server row "New": mirrors onAttachRequested's wiring
        // immediately above, for a herdr server row instead of a
        // calyx-session one.
        model.onHerdrCreateRequested = { [weak self] row in
            self?.createHerdrWorkspace(row)
        }

        // Herdr workspace row "Attach": mirrors onAttachRequested's
        // wiring immediately above, for a single already-known herdr
        // workspace instead of a calyx-session row.
        model.onHerdrWorkspaceAttachRequested = { [weak self] row in
            self?.attachHerdrWorkspace(row)
        }

        // Herdr workspace row "Kill": mirrors onHerdrWorkspaceAttachRequested's
        // wiring immediately above -- closes the Calyx tab bridging the
        // workspace BEFORE herdr's own workspace.close is sent, so the
        // attach process inside it exits through its normal path instead
        // of racing herdr's connection teardown.
        model.onHerdrWorkspaceKilled = { [weak self] row in
            self?.closeHerdrWorkspaceTabs(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func attach(_ row: SessionBrowserRow) {
        if row.isAttachedHere, let surfaceID = SessionSurfaceMap.shared.surfaceID(for: row.id) {
            NotificationCenter.default.post(
                name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID]
            )
            return
        }
        (NSApp.delegate as? AppDelegate)?.attachSessionAsTab(sessionID: row.id, cwd: row.info.cwd)
    }

    private func attachRemote(_ context: SessionSpawnContext) {
        (NSApp.delegate as? AppDelegate)?.spawnRemoteSessionTab(host: context.host)
    }

    /// A herdr server row's "New" button always creates a new workspace
    /// and opens it NATIVELY as a Calyx tab, iTerm2 tmux -CC semantics --
    /// instead of the old single TUI-attach tab (that old behavior moved
    /// to the Command Palette's `herdr.attachTUI` action,
    /// `CalyxWindowController.setupCommandRegistry()`, which still calls
    /// `AppDelegate.openHerdrAttachTab(command:title:)` directly,
    /// unchanged), and instead of the old "open every existing workspace
    /// at once" behavior (moved to `attachHerdrWorkspace(_:)` below,
    /// one workspace row at a time).
    ///
    /// Delegates the wire sequence to `HerdrAttachOrCreateFlow
    /// .createAndOpen` (HerdrAttachOrCreateFlow.swift). `openWorkspace`
    /// wraps `AppDelegate.herdrTabCoordinator`'s own entry point; this
    /// file's `logger` is passed straight through, so every failure path
    /// (a `workspace.create`, or opening the workspace it created) still
    /// logs exactly as it always has. A `herdrTabCoordinator` that is
    /// `nil` (herdr itself was never resolvable) does nothing, same as
    /// today. Refreshes `model` once the flow finishes so the new
    /// workspace row -- and its "Show" label -- appears immediately
    /// instead of at the next 1s poll.
    private func createHerdrWorkspace(_ row: HerdrSessionRow) {
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator else { return }
        let socketPath = row.info.id
        let model = self.model

        Task {
            await HerdrAttachOrCreateFlow.createAndOpen(
                socketPath: socketPath,
                transportFactory: LiveHerdrTransportFactory(),
                logger: logger,
                openWorkspace: { workspaceID, socketPath in
                    await coordinator.openWorkspace(workspaceID: workspaceID, socketPath: socketPath)
                }
            )
            await model.refresh()
        }
    }

    /// A herdr workspace row's "Attach"/"Show" button. When the row is
    /// `.tuiPane(surfaceID:)` -- the workspace has no native tab of its
    /// own, but a herdr TUI client attached to its server runs in one of
    /// this process's panes -- `SessionBrowserModel.attachHerdrWorkspace(_:)`
    /// has already sent `workspace.focus` so that TUI displays this
    /// workspace, and this method focuses that pane by posting
    /// `.calyxFocusSurface`, exactly like
    /// `attach(_:)` above does for an attached calyx-session row, and
    /// opens nothing. Known limitation: Quick Terminal panes are not
    /// reached by that notification (only window controllers observe
    /// it), so "Show" on a TUI client running there does nothing
    /// visible.
    ///
    /// Otherwise it opens THAT workspace NATIVELY as a Calyx tab, through the exact same
    /// `AppDelegate.herdrTabCoordinator.openWorkspace(workspaceID:
    /// socketPath:)` entry point `createHerdrWorkspace(_:)` above already
    /// uses for a newly created one -- there is exactly one place that
    /// opens a workspace as a native Calyx tab. A `herdrTabCoordinator`
    /// that is `nil` (herdr itself was never resolvable) does nothing,
    /// same as today. Refreshes `model` once the open finishes so the
    /// row's label flips to "Show" immediately instead of at the next 1s
    /// poll (`HerdrTabCoordinator.activeTabIDs` is not observable; only
    /// `refresh()` carries the new answer into `herdrRows`).
    private func attachHerdrWorkspace(_ row: HerdrWorkspaceRow) {
        if case .tuiPane(let surfaceID) = row.attachment {
            NotificationCenter.default.post(
                name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID]
            )
            return
        }
        guard let coordinator = (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator else { return }
        let model = self.model
        Task {
            await coordinator.openWorkspace(workspaceID: row.info.workspaceID, socketPath: row.socketPath)
            await model.refresh()
        }
    }

    /// A herdr workspace row's "Kill" button, invoked by
    /// `SessionBrowserModel.killHerdrWorkspace(_:)` BEFORE
    /// `herdrProvider.closeWorkspace(workspaceID:socketPath:)` is sent
    /// -- closes the Calyx tab bridging `row`'s workspace through
    /// `HerdrTabCoordinator.handleWorkspaceKilled(workspaceID:socketPath:)`,
    /// the coordinator's own entry point for closing a herdr-bridged
    /// pane's Calyx side without sending herdr a request, so the
    /// terminal-attach process inside it exits through its normal path
    /// before herdr's own connection tears down. A `herdrTabCoordinator`
    /// that is `nil` (herdr itself was never resolvable) does nothing,
    /// same as `createHerdrWorkspace(_:)`/`attachHerdrWorkspace(_:)`
    /// above.
    private func closeHerdrWorkspaceTabs(_ row: HerdrWorkspaceRow) {
        (NSApp.delegate as? AppDelegate)?.herdrTabCoordinator?.handleWorkspaceKilled(
            workspaceID: row.info.workspaceID, socketPath: row.socketPath
        )
    }

    func showBrowser() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshRemoteHostCandidates()
        Task { await model.refresh() }
    }
}
