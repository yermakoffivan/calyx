// IPCWakeCoordinator.swift
// Calyx
//
// Holds the suspended `POST /ipc-wake` long-polls (one "waiter" per
// surface) and hands a wake to a waiter when the peer bound to its
// surface has messages no waiter has been told about yet. The wake only
// nudges the pane's agent to call `receive_messages`; nothing here
// reads, moves or deletes a message. Same bridge-based await/resume
// mechanics as `ApprovalInboxStore.waitForDecision`, sharing its
// exactly-once resume via `AwaitBridge`. See
// CalyxTests/IPC/IPCWakeCoordinatorTests.swift for the specced contract.
//
// Invariants this type owns:
//
// - A wake is handed over only when, at that instant, the feature is
//   enabled (read when the check starts), the surface has a waiter, and
//   its bound peer's inbox holds at least one message with
//   `nudged == false`.
// - A message becomes `nudged` only when the wake that counted it was
//   actually received by a waiter: the taker handed to the store is
//   `bridge.resume`, whose `true` means this very call resumed the
//   suspended `awaitWake`. A waiter that already ended (timeout,
//   cancellation, supersede, release) makes it return `false`, and the
//   store then marks nothing.
// - Checking for un-nudged messages, handing over and marking happen
//   inside ONE `IPCStore.offerWakes(to:)` call, which is a single
//   actor-isolated synchronous section (see its doc comment). This type
//   never checks in one store call and marks in another, so a message
//   can never cause two wakes. That is also why checks may overlap: the
//   store runs them one after the other, and `resume` is exactly-once.
// - No notification state lives here. `waiters` is the only stored
//   state; which messages have been announced is the `nudged` field of
//   each `Message`, inside the store.
// - A check is requested on four events: (a) a waiter registers
//   (`awaitWake`); (b) a message enters an inbox, reported by the store
//   itself through its inbox-growth sink (installed by
//   `CalyxMCPServer.start()`), which calls `inboxGrew(peerID:)` for the
//   recipient whatever path wrote the message (`sendMessage`,
//   `broadcast`, `requeue`); (c) `AgentRegistry.bindSurface` sets or
//   changes a surface's bound peer (`.calyxAgentPeerBindingChanged`);
//   (d) the Settings switch turns the setting on, where
//   `SettingsWindowController.ipcWakeDidChange` calls
//   `reevaluateAllWaiters()`. `isEnabled` is read when a check starts.
// - One waiter per surface: a new `awaitWake` for a surface makes the
//   one already waiting return nil. Claude Code runs the hook of a new
//   turn's Stop while the previous turn's poll may still be open, so
//   two polls for one surface can be in flight at once; the newer one
//   supersedes the older, which gets 204. A wake handed over while a
//   turn is running is absorbed into that turn by Claude Code (no new
//   turn is created).
// - Timeout, cancellation, surface destruction and `releaseAllWaiters()`
//   (called by `CalyxMCPServer.stop()`, and by
//   `SettingsWindowController.ipcWakeDidChange` when the Settings switch
//   is turned off) end the affected waiters with nil and never touch a
//   message flag: none of them goes through the store. Cancellation is
//   what a dropped connection produces: the connection-drop watch in
//   `CalyxMCPServer.dispatchRoute` cancels the Task awaiting `awaitWake`.
// - While `isEnabled` is false, a check does nothing: it neither
//   wakes nor drops a waiter, so a waiter that was already registered
//   stays until it times out or is released. The Settings switch
//   releases every waiter when it turns the setting off; nothing here
//   does. (`CalyxMCPServer`'s `/ipc-wake` route answers 204 before
//   registering a waiter at all while the setting is off, or while the
//   current wake proof key has not been published to
//   agent-endpoint.json (spec D20: the key is created at each start and
//   the hook rejects a proof made with another key, so a wake handed
//   over then would be lost).)
//
// Boundary of the guarantee: a wake is committed the moment a waiter
// receives it. A failure after that point (the connection dropped before
// the response was written, `calyx-ipc-wake-hook` (`IPCWakeHookScript`),
// the client long-polling `/ipc-wake`, gone before it used the note) is
// not recovered, and the messages stay nudged -- the same boundary as
// the store's delete-on-read contract, described on `IPCStore.requeue`.
// The messages themselves are untouched and are still returned by the
// agent's next `receive_messages` call.
//
// The binding and the enabled flag are a snapshot taken when a check
// starts. A binding change, or `isEnabled` turning false, while the
// check is on its way to the store is not reflected in that check, so the old
// binding's waiter may still be woken for the peer it was bound to when
// the check started. The binding change requests a check of its own,
// which is what serves the new binding.
//
// Both notifications this type observes are posted from the main actor
// (`.calyxSurfaceDestroyed` by `SurfaceRegistry.destroySurface`,
// `.calyxAgentPeerBindingChanged` by the `@MainActor`
// `AgentRegistry.bindSurface`), and a selector-based observer runs
// synchronously on the posting thread, so the handlers do not hop.
//
// Subclasses NSObject solely so NotificationCenter's @objc
// selector-based addObserver can target it, matching every other
// notification observer in this codebase (e.g. SurfacePropertyStore).

import Foundation

@MainActor
final class IPCWakeCoordinator: NSObject {

    private let store: IPCStore
    private let agentRegistry: @MainActor () -> AgentRegistry?
    private let isEnabledProvider: @MainActor () -> Bool

    /// At most one live waiter bridge per surface -- see the type's
    /// header comment for the one-waiter-per-surface contract this
    /// backs. An entry exists exactly while its `awaitWake` call is
    /// suspended: every path that ends a waiter removes it, and
    /// `awaitWake` removes its own on the way out.
    private var waiters: [UUID: AwaitBridge<IPCWakeResponse?>] = [:]

    /// `agentRegistry` is a closure, not a registry: `CalyxMCPServer`'s
    /// own `agentRegistry` is swappable, and both the bindings a check
    /// reads and the registry a `.calyxAgentPeerBindingChanged` post is
    /// matched against must be whichever one is current.
    init(store: IPCStore,
         agentRegistry: @escaping @MainActor () -> AgentRegistry?,
         isEnabled: @escaping @MainActor () -> Bool = { IPCWakeSettings.enabled }) {
        self.store = store
        self.agentRegistry = agentRegistry
        self.isEnabledProvider = isEnabled
        super.init()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePeerBindingChanged(_:)), name: .calyxAgentPeerBindingChanged, object: nil
        )
    }

    /// Whether the feature is on, read from the injected provider on
    /// every access. The single reader of the setting: checks and
    /// `CalyxMCPServer`'s `/ipc-wake` route both ask this.
    var isEnabled: Bool {
        isEnabledProvider()
    }

    // MARK: - awaitWake

    /// Suspends until a check hands this surface's waiter a wake
    /// (returning it), or until this call's own timeout, the awaiting
    /// Task's cancellation, a newer `awaitWake` for the same surface,
    /// `release(surfaceID:)` or `releaseAllWaiters()` ends it (returning
    /// nil). Registering requests a check for this surface, so a message
    /// that is already waiting wakes it without any other trigger.
    ///
    /// Same shape as `ApprovalInboxStore.waitForDecision`; see
    /// `AwaitBridge` for the exactly-once resume mechanics.
    func awaitWake(surfaceID: UUID, timeoutMs: Int) async -> IPCWakeResponse? {
        release(surfaceID: surfaceID)

        let bridge = AwaitBridge<IPCWakeResponse?>()
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<IPCWakeResponse?, Never>) in
                waiters[surfaceID] = bridge
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(timeoutMs))
                    guard !Task.isCancelled else { return }
                    self.end(surfaceID: surfaceID, bridge: bridge)
                }
                let alreadyCancelled = bridge.register(continuation: continuation, timeoutTask: timeoutTask)
                if alreadyCancelled {
                    timeoutTask.cancel()
                    self.end(surfaceID: surfaceID, bridge: bridge)
                } else {
                    self.requestCheck(for: [surfaceID])
                }
            }
        } onCancel: {
            bridge.cancel(resumingWith: nil)
            Task { @MainActor in
                self.end(surfaceID: surfaceID, bridge: bridge)
            }
        }

        // A waiter woken by a check is resumed from inside the store
        // actor, which cannot reach `waiters`; this is where its entry
        // goes. Gated on identity like `end`: a newer `awaitWake` may
        // have taken this surface's slot by the time this call resumes.
        if waiters[surfaceID] === bridge {
            waiters.removeValue(forKey: surfaceID)
        }
        return response
    }

    /// Shared tail for the timeout, alreadyCancelled, and
    /// Task-cancellation paths. The `waiters` eviction is gated on
    /// `bridge` still being the surface's CURRENT bridge (`===` identity
    /// check): a newer `awaitWake` that has since registered a fresh
    /// bridge for the same surface must never have its live
    /// registration evicted by a stale, deferred call arriving late
    /// from the non-isolated `onCancel` hop or from an old timeout Task.
    /// `bridge.resume` is itself exactly-once, so this whole method is
    /// safe to call more than once for the same bridge.
    private func end(surfaceID: UUID, bridge: AwaitBridge<IPCWakeResponse?>) {
        if waiters[surfaceID] === bridge {
            waiters.removeValue(forKey: surfaceID)
        }
        bridge.resume(with: nil)
    }

    // MARK: - Checks

    /// Requests a check for every waiting surface.
    /// `SettingsWindowController.ipcWakeDidChange` calls this when the
    /// Settings switch is turned on. Returns the check's Task (an
    /// already finished one when there is nothing to check); once it has
    /// finished, the store call is over.
    @discardableResult
    func reevaluateAllWaiters() -> Task<Void, Never> {
        requestCheck(for: Array(waiters.keys))
    }

    /// Requests a check for the surface bound to `peerID`, if that
    /// surface has a waiter. Called on the main actor by the store's
    /// inbox-growth sink (installed by `CalyxMCPServer.start()`) each
    /// time a message enters `peerID`'s inbox. Returns the check's Task,
    /// with the same contract as `reevaluateAllWaiters()`.
    @discardableResult
    func inboxGrew(peerID: UUID) -> Task<Void, Never> {
        guard let registry = agentRegistry() else { return Task {} }
        let surfaceIDs = waiters.keys.filter { registry.boundPeerID(for: $0) == peerID }
        return requestCheck(for: surfaceIDs)
    }

    /// One check: for each of `surfaceIDs` that has a waiter and a bound
    /// peer, offers the store that waiter's `resume` as the peer's
    /// taker. Everything this reads (the enabled flag, the waiters, the
    /// bindings) is read synchronously here, before the Task below
    /// starts -- see the header comment for what that snapshot means.
    /// The store call's result is not needed: a woken waiter's
    /// `awaitWake` removes its own entry when it returns. Returns the
    /// Task that makes the store call, or an already finished Task when
    /// no store call is needed.
    @discardableResult
    private func requestCheck(for surfaceIDs: [UUID]) -> Task<Void, Never> {
        guard isEnabled, let registry = agentRegistry() else { return Task {} }

        var takers: [UUID: @Sendable (IPCWakeTicket) -> Bool] = [:]
        for surfaceID in surfaceIDs {
            guard let bridge = waiters[surfaceID],
                  let peerID = registry.boundPeerID(for: surfaceID) else { continue }
            // `AgentRegistry.bindSurface` keeps surface <-> peer a
            // bijection, so two surfaces can never map to one peer.
            if takers[peerID] != nil {
                assertionFailure("IPCWakeCoordinator: two waiting surfaces are bound to peer \(peerID)")
            }
            takers[peerID] = { ticket in
                bridge.resume(with: IPCWakeResponse(peerID: peerID, ticket: ticket))
            }
        }
        guard !takers.isEmpty else { return Task {} }

        #if DEBUG
        _testChecksInFlight += 1
        #endif
        return Task {
            #if DEBUG
            defer { self._testChecksInFlight -= 1 }
            if let beforeOffer = self._testBeforeOffer {
                await beforeOffer()
            }
            #endif
            _ = await self.store.offerWakes(to: takers)
        }
    }

    // MARK: - Release

    /// Ends every waiter: each suspended `awaitWake` returns nil and
    /// `waiters` is left empty. Never changes a message flag. Called by
    /// `CalyxMCPServer.stop()`, and by
    /// `SettingsWindowController.ipcWakeDidChange` when the Settings
    /// switch is turned off.
    func releaseAllWaiters() {
        let released = waiters
        waiters.removeAll()
        for bridge in released.values {
            bridge.resume(with: nil)
        }
    }

    /// Ends `surfaceID`'s waiter, if it has one, with nil. Never changes
    /// a message flag.
    func release(surfaceID: UUID) {
        waiters.removeValue(forKey: surfaceID)?.resume(with: nil)
    }

    /// Every surface whose `awaitWake` is currently suspended.
    var waitingSurfaceIDs: Set<UUID> {
        Set(waiters.keys)
    }

    // MARK: - Notifications

    /// A destroyed surface has no pane left to wake: its waiter
    /// returns nil.
    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        release(surfaceID: surfaceID)
    }

    /// Only a post from this coordinator's own registry counts: bindings
    /// are read from that registry alone, so another registry's change
    /// says nothing about any surface waiting here.
    @objc private func handlePeerBindingChanged(_ notification: Notification) {
        guard let registry = agentRegistry(),
              (notification.object as AnyObject?) === registry,
              let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        requestCheck(for: [surfaceID])
    }

    #if DEBUG
    /// Test seam: awaited by every check after it has built its takers
    /// and before it calls the store, so a test can reproduce a waiter
    /// ending, or a binding moving, inside exactly that window. DO NOT
    /// use from production code.
    var _testBeforeOffer: (@MainActor () async -> Void)?

    /// Test seam: the number of checks that have started their Task
    /// and have not yet returned from `store.offerWakes`. Kept for the
    /// checks requested by waiter registration and binding changes,
    /// which hand their Task to no caller. Counted only
    /// for a check that really calls the store (its takers were built
    /// and found non-empty): incremented synchronously where that
    /// check creates its Task, decremented when the Task finishes. A
    /// test waits for this to reach zero before asserting that a
    /// waiter was NOT woken, so the assertion cannot pass merely
    /// because a check was still on its way. Changes no behaviour. DO
    /// NOT use from production code.
    private(set) var _testChecksInFlight = 0
    #endif
}
