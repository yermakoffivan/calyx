// CommandHostedSurfaces.swift
// Calyx
//
// Records which ghostty surface IDs are passthrough command-hosted
// panes that must close when their child exits -- today only a
// worktree-task pane opened on the passthrough path
// (`CalyxWindowController.openTaskPane`). ghostty forces
// `wait-after-command` on for any surface created with a `command`
// (ghostty/src/apprt/embedded.zig), so without this record such a pane
// would sit on ghostty's "[Process exited]" banner after `exit` instead
// of closing like a plain Cmd+T pane. Persistent-session task panes are
// never registered: their exit already goes through
// `SessionReconnectCoordinator`.
//
// Same shape as `HerdrHostedSurfaces`: pruned via `.calyxSurfaceDestroyed`
// (posted by `SurfaceRegistry.destroySurface`) with the NSObject/
// @objc-selector wiring, and "shared singleton + injectable" (`init()`
// is not private so a test can use a throwaway instance).

import Foundation

@MainActor
final class CommandHostedSurfaces: NSObject {

    static let shared = CommandHostedSurfaces()

    private var surfaceIDs: Set<UUID> = []
    private var isObserving = false

    override init() {
        super.init()
    }

    /// Idempotent: a second call is a no-op.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    /// Records `surfaceID` as a command-hosted surface that must
    /// auto-close on child exit. Idempotent.
    func register(_ surfaceID: UUID) {
        surfaceIDs.insert(surfaceID)
    }

    /// Whether `surfaceID` is currently recorded.
    func contains(_ surfaceID: UUID) -> Bool {
        surfaceIDs.contains(surfaceID)
    }

    /// Forgets `surfaceID`; a never-registered ID is a no-op.
    func unregister(_ surfaceID: UUID) {
        surfaceIDs.remove(surfaceID)
    }

    /// Prunes the destroyed surface's ID (`SurfaceRegistry
    /// .destroySurface`'s `userInfo["surfaceID"]` post shape).
    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        unregister(id)
    }

    #if DEBUG
    /// Test-only: clears every registration. DO NOT use from production code.
    func _testReset() {
        surfaceIDs.removeAll()
    }

    /// Test-only: undoes `startObserving()`. DO NOT use from production code.
    func _stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }
    #endif
}
