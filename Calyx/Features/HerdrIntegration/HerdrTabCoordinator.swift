// HerdrTabCoordinator.swift
// Calyx
//
// Opens a herdr workspace as a native Calyx tab
// (one ghostty surface per herdr pane, bridged via `herdr agent attach`
// through HerdrAttachBridgeCommand), keeps the tab's own split ratios in
// sync with herdr's own layout.updated events via handleLayoutUpdated,
// and tears surfaces down on either side's own initiative
// (handlePaneClosed for a herdr-side pane.closed; HerdrPaneRegistry's
// own .calyxSurfaceDestroyed observation for a Calyx-side close). Every
// side-effectful dependency is injected (transportFactory,
// surfaceFactory, attacher, registry) so this file never opens a real
// socket or touches a real ghostty surface on its own -- see
// HerdrTabCoordinatorTests.swift.
//
// OPEN SEQUENCE (openWorkspace): workspace.get -> session.snapshot ->
// layout.export, three one-shot request/responses (HerdrConnection.swift's
// own header, fact 2). The tab id is RESOLVED, never string-derived:
// openWorkspace first sends a one-shot workspace.get (params EXACTLY
// {"workspace_id": ...} -- WorkspaceTarget's own schema shape, `herdr
// api schema --json`), reads its response's own "active_tab_id"
// (WorkspaceInfo's own required field), and uses that value VERBATIM as
// layout.export's own "tab_id" -- a prior "<workspaceID>:t1"
// string-derivation was WRONG (unverified against a live server, and
// killed outright by HerdrTabCoordinatorTests.swift's own
// test_openWorkspace_activeTabIDFromWorkspaceGet_notDerivedFromWorkspaceIDString_usedExactlyForLayoutExport,
// which uses a deliberately non-"<workspaceID>:t1"-shaped active_tab_id).
// That same workspace.get response also carries the workspace's own
// "label" (WorkspaceInfo's own OTHER required, non-nullable field),
// which HerdrTabTitlePolicy.title turns into the plan's own title below,
// falling back to the bare workspace id only when the label is blank
// after trimming whitespace.
// Next, a one-shot session.snapshot (params "{}" -- HerdrConnection.swift's
// own header, fact 1) builds a paneID -> terminalID map from its own
// "panes[]" (each PaneInfo's own required "pane_id"/"terminal_id") --
// HerdrAttachBridgeCommand.build now takes a herdr
// TERMINAL id, not a pane id (that file's own header: `herdr agent
// attach <paneID>` fails outright for any pane with no agent running;
// `herdr terminal attach <terminalID>` is the measured, working
// replacement), and a terminal id is not carried by layout.export's own
// pane nodes at all (only "pane_id"), so this SEPARATE lookup is the
// only way to obtain one. Finally, layout.export (params carrying
// exactly one of "pane_id"/"tab_id" -- herdr's schema never accepts
// "workspace_id" there, and a workspace's active tab is unambiguously a
// TAB, so this file always sends "tab_id", exactly `activeTabID` above).
// ANY of the three steps failing (a transport failure or an RPC error)
// fails the whole open with the same discipline: zero surfaces, zero
// registrations, no attach.
//
// TWO-PHASE SURFACE CREATION (openWorkspace): HerdrLayoutImporter
// .convert(_:) first turns the decoded layout into a SplitNode tree plus
// a flat, wire-ordered list of HerdrPaneDescriptor. Phase 1 builds EVERY
// pane's HerdrAttachBridgeCommand up front, resolving each descriptor's
// own terminalID through the session.snapshot map above FIRST -- a
// paneID absent from that map (the pane has no known terminal id at
// all) is total failure, identically to an invalid wire pane id or a
// terminalID HerdrAttachBridgeCommand.build itself rejects: any of the
// three aborts before Phase 2 ever runs a single createSurface call.
// Phase 2 then creates one ghostty surface per descriptor, in wire
// order (a split's first child before its second); a nil mid-sequence
// rolls back every surface already created (reverse order), touches the
// registry not at all (nothing was registered until every surface
// exists), and never calls attachTab. Only once every surface exists are
// they registered, the importer's own leaf UUIDs remapped to the REAL
// surface UUIDs (remapLeafIDs(_:mapping:)), and HerdrNativeTabPlan.root/
// focusedLeafID/paneRefs built from that remapped tree -- focusedLeafID
// resolves from the wire's own focused_pane_id, never defaulting to the
// tree's first leaf.
//
// ATTACHTAB FAILURE (undisclosed by any test -- attachTabResult is never
// set false in HerdrTabCoordinatorTests.swift): treated identically to a
// Phase 2 createSurface failure -- every already-registered surface is
// unregistered and destroyed (reverse order), openWorkspace returns
// false. Not rolling back here would leave live `herdr agent attach`
// processes, and registry entries, behind a tab that was never actually
// presented -- exactly the state HerdrPaneRegistry's own single-
// controller invariant and this file's own "nothing may remain
// registered after a rolled-back open" test assertion (test 3) both
// guard against.
//
// RATIO SYNC (handleLayoutUpdated): re-exports using the active_tab_id
// openWorkspace already RESOLVED and stored for this (workspaceID,
// socketPath) pair -- never a fresh workspace.get of its own; see that
// method's own doc comment for why. Tracks the last-applied layout per
// (workspaceID, socketPath) as an AppliedLayoutNode -- a shape identical
// to SplitNode/SplitData except leaves carry the herdr pane id (stable
// across re-exports) rather than HerdrLayoutImporter's own fresh
// UUID-per-call leaf ids, so two exports of a genuinely unchanged layout
// compare Equatable-equal regardless of import-time UUID churn. Every
// successful openWorkspace or handleLayoutUpdated stores its own fresh
// AppliedLayoutNode unconditionally, whether or not anything changed --
// it is simply the newest known-applied state either way.
// collectRatioChanges(old:new:socketPath:into:) walks both trees in
// lockstep: identical -> no call at all; a split node whose own ratio
// differs while its direction and both children are otherwise identical
// -> exactly one attacher.updateRatio(leafA:leafB:direction:ratio:) call,
// with leafA/leafB resolved through registry.surfaceID(forPaneID:
// socketPath:) (the REAL, already-tracked surface ids, never fresh
// import-time ones); any node whose shape genuinely diverges (a
// different leaf paneID, a different direction, leaf-vs-split itself)
// abandons the WHOLE diff for that call, applying nothing -- structural
// layout changes are out of scope for this file, which owns only the
// ratio-mutation seam. KNOWN LIMITATION, disclosed rather than silently
// guessed at: a differing split whose own immediate children are NOT
// both leaves (a nested split) is treated as unresolvable and silently
// skipped for that one node only -- "the split's first/second child
// panes" names a single pane per side,
// which a nested subtree is not; inventing a leftmost-leaf substitute
// would be a fabricated contract this file has no authority to assert.
//
// HANDLEPANECLOSED / .calyxSurfaceDestroyed: the former asks `attacher`
// to close the tracked leaf and prunes the registry, WITHOUT ever
// sending herdr any request -- the herdr-side pane must never be killed
// by Calyx (HerdrTabCoordinatorTests.swift's own test 7 asserts every
// transport's sent lines stay byte-for-byte unchanged across the call).
// The latter needs no bespoke handling here at all FOR THE REGISTRY:
// HerdrPaneRegistry already prunes ITS OWN (surfaceID <-> ref) maps on
// `.calyxSurfaceDestroyed` once observing is enabled (registry
// .startObserving(), idempotent, called once from `init`) -- this file
// only needs to make sure that switch is on, never re-implement that
// registry-level pruning.
//
// PRUNING ON LAST PANE CLOSE: `activeTabIDs`/
// `lastAppliedLayouts`/`remainingPaneIDs` are this file's OWN state,
// which `HerdrPaneRegistry`'s self-pruning above knows nothing about --
// left untouched, a stale `activeTabIDs` entry means
// `herdrLayoutUpdated(socketPath:)` keeps spawning a wasted
// `layout.export` round trip for a workspace whose Calyx tab no longer
// exists, for as long as this coordinator lives. `handlePaneClosed`
// (herdr-initiated) and the new `handleCalyxSurfaceClosed(surfaceID:)`
// (Calyx-initiated -- wired from `CalyxWindowController
// .closeSurfaceAndCleanUp`/`tearDownSurfaces` via `AppDelegate`, since
// neither ever generates a herdr-side `pane.closed` event) both funnel
// into `pruneIfLastPaneClosed(paneID:socketPath:)`, which prunes once a
// workspace's `remainingPaneIDs` entry reaches empty. Both callers can
// fire for the SAME close (a herdr-initiated close routes through
// `closeSurfaceAndCleanUp` too, via `attacher.closeLeaf`), so the
// underlying removal is `Set`-based and idempotent rather than a bare
// decrementing count, which a double-fire would corrupt.
//
// WORKSPACE KILLED (Session Browser-initiated): `handleWorkspaceKilled
// (workspaceID:socketPath:)` closes every pane `remainingPaneIDs` still
// tracks for that workspace, each through the same `closeTrackedPane
// (paneID:socketPath:)` helper `handlePaneClosed` itself calls -- run
// BEFORE `workspace.close` reaches herdr (`SessionBrowserModel
// .killHerdrWorkspace(_:)`), so each pane's own `herdr terminal attach`
// process exits through its normal path instead of racing herdr's
// connection teardown. Never waits on a `pane.closed` event either way:
// the structure event stream is not necessarily subscribed at kill time,
// so this is the only reliable way the Calyx tab closes and its
// bookkeeping gets pruned.
//
// WORKSPACE CLOSED (herdr-initiated): the SAME `handleWorkspaceKilled`
// above is also this file's own `HerdrStructureEventObserver
// .herdrWorkspaceClosed(workspaceID:socketPath:)` conformance (below) --
// herdr itself already closed the whole workspace server-side (its own
// TUI, the CLI, or another client) by the time this fires, and does NOT
// push `pane.closed` for that workspace's own panes either (the measured
// wire fact this event exists for), so this is the only path that tears
// down the Calyx tab and prunes bookkeeping for that close.
// `herdrWorkspaceClosed` calls `handleWorkspaceKilled` directly, with no
// `Task` wrapper: unlike `herdrPaneClosed`/`herdrLayoutUpdated` (both
// async underneath), `handleWorkspaceKilled` is itself synchronous.
//
// RESTORE ADOPTION (adoptRestoredTab): AppDelegate.restoreTabSurfaces'
// own counterpart to openWorkspace for a tab that came back from a
// snapshot restore instead of this session's own openWorkspace call --
// its surfaces and HerdrPaneRegistry entries already exist by the time
// this runs (createSurfaceWithPwd's own .bridgeCommand case did both),
// so this only populates activeTabIDs/remainingPaneIDs, the SAME two
// maps openWorkspace's own tail populates, sending herdr nothing and
// creating no surface. activeTabIDs[key] stores the Calyx tab's OWN id
// (tabID.uuidString) rather than herdr's real active_tab_id: restore has
// no workspace.get response to read one from, and issuing one here would
// make the restore path asynchronous, which it must not become. A
// subsequent handleLayoutUpdated for this workspace therefore sends
// layout.export a tab_id herdr does not recognize and fails harmlessly
// (caught, returns false, before ever touching lastAppliedLayouts) until
// a fresh openWorkspace for the same workspace resolves and stores the
// real value. lastAppliedLayouts itself is left untouched here for the
// identical reason -- restore carries no ratio tree to seed one with,
// and every reader already treats a missing entry as "nothing applied
// yet". Idempotent: a workspace already tracked, by either this method
// or openWorkspace, is untouched by a second call.
//
// `sleep` mirrors HerdrIntegrationCoordinator's own injection seam
// (stored, never invoked here): no method here currently races
// a wait against a duration, and this coordinator's own interface carries no
// timeout/duration parameter to pair one with -- inventing a hardcoded
// deadline here would be an unrequested timeout, not something this
// design calls for. Retained purely so a later addition that
// DOES need a bounded wait (matching the sibling coordinator's own
// "HANDSHAKE DEADLINE" convention) can add one without changing this
// initializer's shape.
//

import Foundation

// MARK: - HerdrNativeTabPlan

struct HerdrNativeTabPlan: Equatable {
    let root: SplitNode
    let focusedLeafID: UUID
    let paneRefs: [UUID: HerdrPaneRef]
    let title: String
}

// MARK: - HerdrNativeSurfaceFactory

/// Creates/destroys the ghostty surface behind ONE bridged herdr pane.
/// `createSurface(command:)` runs `command` (HerdrAttachBridgeCommand's
/// own output) as the surface's shell command; `nil` means the surface
/// could not be created at all -- nothing exists for that one call to
/// roll back.
protocol HerdrNativeSurfaceFactory {
    @MainActor func createSurface(command: String) -> UUID?
    @MainActor func destroySurface(_ id: UUID)
}

// MARK: - HerdrNativeTabAttacher

/// Presents a fully-built plan as a Calyx tab, or mutates/tears down an
/// already-presented one. `focusExistingTab` is openWorkspace's own
/// FIRST check (this file's header) -- a `true` short-circuits the
/// entire wire round trip.
protocol HerdrNativeTabAttacher {
    @MainActor func attachTab(plan: HerdrNativeTabPlan) -> Bool
    @MainActor func focusExistingTab(withWorkspaceID: String, socketPath: String) -> Bool
    @MainActor func updateRatio(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double)
    @MainActor func closeLeaf(_ id: UUID)
}

// MARK: - Wire params/result (HerdrConnection.swift stays method-agnostic)

/// `WorkspaceTarget`'s own schema shape (`herdr api schema --json`),
/// exactly one property -- the request `params` for both `workspace.get`
/// (see this file's header "OPEN SEQUENCE") and `workspace.close`
/// (`HerdrSessionProvider.swift`'s own `closeWorkspace(workspaceID:
/// socketPath:)`, the session browser's Kill action for a herdr
/// workspace row). Not `private`: shared across both files rather than
/// declaring a second, identical struct.
struct HerdrWorkspaceTargetParams: Encodable {
    let workspaceID: String

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }
}

/// `workspace.get`'s own RPC result wrapper --
/// {"type":"workspace_info","workspace":{...WorkspaceInfo...}}. Mirrors
/// `HerdrLayoutExportRPCResult`'s own "the wire result is a wrapper the
/// caller requests and unwraps" shape below.
private struct HerdrWorkspaceGetRPCResult: Sendable, Decodable {
    let workspace: HerdrWorkspaceInfo
}

/// `WorkspaceInfo` -- the fields this file and `HerdrSessionProvider.swift`
/// actually read ("workspace_id", "active_tab_id", "label", "pane_count"),
/// per this project's own "define the minimal Decodable you need: only
/// the fields you read" rule. A keyed decoding container only ever reads
/// the keys it asks for, so this tolerates every OTHER schema-required
/// field ("number", "focused", "tab_count", "agent_status") without
/// modeling them. All four modeled fields are themselves required by the
/// schema, and none is nullable (`herdr api schema --json`'s own
/// success_response.$defs.WorkspaceInfo), so all decode as non-optional,
/// never `String?`/`Int?`. Not `private` like this section's other wire
/// types: decode-tested directly (see HerdrTabCoordinatorTests.swift),
/// and reused as-is for `HerdrSessionInfo.workspaces`
/// (`HerdrSessionProvider.swift`) -- the SAME `WorkspaceInfo` schema
/// shape appears in both `workspace.get`'s result and
/// `session.snapshot`'s own `workspaces[]` array
/// (`HerdrSessionSnapshot.workspaces`, HerdrEvent.swift), so this stays
/// one Swift type for one wire shape rather than two.
struct HerdrWorkspaceInfo: Sendable, Equatable, Decodable {
    let workspaceID: String
    let activeTabID: String
    let label: String
    let paneCount: Int

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case activeTabID = "active_tab_id"
        case label
        case paneCount = "pane_count"
    }
}

/// `layout.export`'s own request `params` -- see this file's header for
/// why "tab_id" (not "pane_id"), and openWorkspace's own doc comment for
/// where the value it carries comes from.
/// Deliberately NOT marked `Sendable` explicitly, mirroring
/// `HerdrEmptyParams`/`HerdrSubscribeParams`'s own precedent in
/// HerdrConnection.swift: a `private` struct whose only stored property
/// is itself `Sendable` (`String`) qualifies for the compiler's own
/// implicit Sendable inference without an explicit annotation.
private struct HerdrLayoutExportParams: Encodable {
    let tabID: String

    private enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

/// `layout.export`'s own RPC result wrapper --
/// {"type":"layout_export","layout":{...LayoutDescription...}}. Mirrors
/// HerdrConnection.swift's own `HerdrSnapshotRPCResult` (the identical
/// "the wire result is a wrapper the caller requests and unwraps" shape).
private struct HerdrLayoutExportRPCResult: Sendable, Decodable {
    let layout: HerdrLayoutExportResult
}

// MARK: - HerdrTabCoordinator

@MainActor
final class HerdrTabCoordinator {

    /// Key for `activeTabIDs`/`lastAppliedLayouts`/`remainingPaneIDs`/
    /// `opensInFlight` -- see this file's header "OPEN SEQUENCE" and
    /// "RATIO SYNC".
    private struct WorkspaceKey: Hashable {
        let workspaceID: String
        let socketPath: String
    }

    /// A SplitNode/SplitData-shaped tree whose leaves carry the herdr
    /// pane id instead of a leaf UUID -- see this file's header "RATIO
    /// SYNC" for why.
    private indirect enum AppliedLayoutNode: Equatable {
        case leaf(paneID: String)
        case split(direction: SplitDirection, ratio: Double, first: AppliedLayoutNode, second: AppliedLayoutNode)
    }

    private typealias RatioChange = (leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double)

    private let transportFactory: any HerdrTransportFactory
    private let herdrBinPath: String
    private let registry: HerdrPaneRegistry
    private let surfaceFactory: any HerdrNativeSurfaceFactory
    private let attacher: any HerdrNativeTabAttacher
    /// Reserved injection seam -- see this file's header for why this
    /// coordinator never calls it.
    private let sleep: @Sendable (Duration) async -> Void

    /// The active_tab_id openWorkspace resolved (via workspace.get) per
    /// (workspaceID, socketPath) -- see this file's header "OPEN
    /// SEQUENCE". handleLayoutUpdated reads this rather than resolving
    /// its own. Pruned once a workspace's last tracked pane closes
    /// -- see `pruneIfLastPaneClosed(paneID:socketPath:)`.
    private var activeTabIDs: [WorkspaceKey: String] = [:]

    /// The most recently applied layout per (workspaceID, socketPath) --
    /// see this file's header "RATIO SYNC". Pruned alongside
    /// `activeTabIDs`.
    private var lastAppliedLayouts: [WorkspaceKey: AppliedLayoutNode] = [:]

    /// Pane ids Calyx still believes are open for a given (workspaceID,
    /// socketPath) -- see `pruneIfLastPaneClosed(paneID:
    /// socketPath:)`. Populated with the pane ids `openWorkspace`
    /// actually created; a `Set` (not a bare count) so `handlePaneClosed`
    /// (herdr-initiated) and `handleCalyxSurfaceClosed` (Calyx-initiated)
    /// can each remove the SAME paneID idempotently without
    /// double-pruning when both fire for the one close -- see each
    /// method's own doc comment for why that happens routinely for a
    /// herdr-initiated close. Structural pane ADDITIONS from a later
    /// layout_updated are out of scope here (this file's
    /// header "RATIO SYNC"), so this set can only ever shrink. Also the
    /// enumeration source `handleWorkspaceKilled(workspaceID:socketPath:)`
    /// reads directly, to learn which panes it needs to close.
    private var remainingPaneIDs: [WorkspaceKey: Set<String>] = [:]

    /// IN-FLIGHT OPENS: claimed synchronously by
    /// `openWorkspace`, before its own first `await`, and released via
    /// `defer` -- mirrors `HerdrIntegrationCoordinator
    /// .isRebuildOrReconnectInFlight`'s identical shape for the sibling
    /// coordinator's own analogous "two callers must never both start a
    /// second, redundant [connection/open]" race.
    private var opensInFlight: Set<WorkspaceKey> = []

    init(
        transportFactory: any HerdrTransportFactory,
        herdrBinPath: String,
        registry: HerdrPaneRegistry,
        surfaceFactory: any HerdrNativeSurfaceFactory,
        attacher: any HerdrNativeTabAttacher,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.transportFactory = transportFactory
        self.herdrBinPath = herdrBinPath
        self.registry = registry
        self.surfaceFactory = surfaceFactory
        self.attacher = attacher
        self.sleep = sleep
        // Idempotent (HerdrPaneRegistry.swift's own doc comment) -- see
        // this file's header for why nothing else here needs to observe
        // .calyxSurfaceDestroyed itself.
        registry.startObserving()
    }

    // MARK: - Open

    /// Opens `workspaceID` on `socketPath` as a native Calyx tab -- see
    /// this file's header "OPEN SEQUENCE" for the workspace.get ->
    /// layout.export wire sequence, "TWO-PHASE SURFACE CREATION" and
    /// "ATTACHTAB FAILURE" for the surface-creation sequence and every
    /// rollback path.
    ///
    /// DOUBLE-OPEN GUARD: `focusExistingTab` above only
    /// de-duplicates an ALREADY-attached workspace -- a second concurrent
    /// call for the SAME (workspaceID, socketPath), racing this one
    /// before it has attached anything yet (e.g. a double-clicked
    /// "Attach" button), would also see `focusExistingTab` return `false`
    /// and run this entire open a second, redundant time, creating two
    /// independent surface sets bridging the same herdr panes. Guarded by
    /// `opensInFlight`, claimed synchronously below (before this
    /// function's first `await`) and released via `defer`, mirroring
    /// `HerdrIntegrationCoordinator.isRebuildOrReconnectInFlight`'s
    /// identical "claim first, defer release" shape for the sibling
    /// coordinator's own analogous race.
    @discardableResult
    func openWorkspace(workspaceID: String, socketPath: String) async -> Bool {
        if attacher.focusExistingTab(withWorkspaceID: workspaceID, socketPath: socketPath) {
            return true
        }

        let key = WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)
        guard !opensInFlight.contains(key) else { return false }
        opensInFlight.insert(key)
        defer { opensInFlight.remove(key) }

        let workspaceInfo: HerdrWorkspaceInfo
        do {
            workspaceInfo = try await fetchWorkspaceInfo(workspaceID: workspaceID, socketPath: socketPath)
        } catch {
            return false
        }
        let activeTabID = workspaceInfo.activeTabID

        // See this file's header "OPEN SEQUENCE" -- resolved BEFORE
        // layout.export, since Phase 1 below needs every pane's own
        // terminalID to build its bridge command.
        let terminalIDByPaneID: [String: String]
        do {
            let snapshot = try await fetchSessionSnapshot(socketPath: socketPath)
            // `uniquingKeysWith:` (never `uniqueKeysWithValues:`):
            // pane_id is SERVER-SUPPLIED wire data, not a locally
            // generated key this file can itself guarantee unique -- a
            // malformed/duplicated snapshot must not crash this process
            // by trapping on a duplicate key.
            terminalIDByPaneID = Dictionary(
                snapshot.panes.map { ($0.paneID, $0.terminalID) }, uniquingKeysWith: { _, latest in latest }
            )
        } catch {
            return false
        }

        let layout: HerdrLayoutExportResult
        do {
            layout = try await fetchLayout(tabID: activeTabID, socketPath: socketPath)
        } catch {
            return false
        }

        guard let (root, panes) = HerdrLayoutImporter.convert(layout),
              let focusedDescriptor = panes.first(where: { $0.paneID == layout.focusedPaneID }) else {
            return false
        }

        // Phase 1: every pane's bridge command, up front -- a single nil
        // (an invalid wire pane id, a paneID with no terminalID in the
        // session.snapshot map, or a terminalID HerdrAttachBridgeCommand
        // .build itself rejects) aborts before Phase 2 ever creates a
        // surface.
        var commands: [(descriptor: HerdrPaneDescriptor, command: String)] = []
        for descriptor in panes {
            guard HerdrPaneRef.isValidPaneID(descriptor.paneID),
                  let terminalID = terminalIDByPaneID[descriptor.paneID],
                  let command = HerdrAttachBridgeCommand.build(
                      herdrBin: herdrBinPath, socketPath: socketPath, terminalID: terminalID
                  ) else {
                return false
            }
            commands.append((descriptor: descriptor, command: command))
        }

        // Phase 2: one surface per pane, in wire order; roll back
        // everything already created on the first nil.
        var created: [(descriptor: HerdrPaneDescriptor, surfaceID: UUID)] = []
        for (descriptor, command) in commands {
            guard let surfaceID = surfaceFactory.createSurface(command: command) else {
                for entry in created.reversed() {
                    surfaceFactory.destroySurface(entry.surfaceID)
                }
                return false
            }
            created.append((descriptor: descriptor, surfaceID: surfaceID))
        }

        var leafIDBySurfaceLeaf: [UUID: UUID] = [:]
        for entry in created {
            leafIDBySurfaceLeaf[entry.descriptor.leafID] = entry.surfaceID
        }

        guard let mappedRoot = Self.remapLeafIDs(root, mapping: leafIDBySurfaceLeaf),
              let focusedLeafID = leafIDBySurfaceLeaf[focusedDescriptor.leafID] else {
            // Unreachable given every descriptor above was created and
            // mapped one-to-one; fails the same way a mid-sequence
            // createSurface failure does, rather than attaching a plan
            // built from a partial mapping.
            for entry in created.reversed() {
                surfaceFactory.destroySurface(entry.surfaceID)
            }
            return false
        }

        var paneRefs: [UUID: HerdrPaneRef] = [:]
        for entry in created {
            let ref = HerdrPaneRef(socketPath: socketPath, paneID: entry.descriptor.paneID)
            registry.register(surfaceID: entry.surfaceID, ref: ref)
            paneRefs[entry.surfaceID] = ref
        }

        let plan = HerdrNativeTabPlan(
            root: mappedRoot, focusedLeafID: focusedLeafID, paneRefs: paneRefs,
            title: HerdrTabTitlePolicy.title(label: workspaceInfo.label, workspaceID: workspaceID)
        )
        guard attacher.attachTab(plan: plan) else {
            // See this file's header "ATTACHTAB FAILURE".
            for entry in created.reversed() {
                registry.unregister(surfaceID: entry.surfaceID)
                surfaceFactory.destroySurface(entry.surfaceID)
            }
            return false
        }

        activeTabIDs[key] = activeTabID
        let paneIDByLeafID = Dictionary(uniqueKeysWithValues: panes.map { ($0.leafID, $0.paneID) })
        if let tree = Self.appliedLayoutNode(root, paneIDByLeafID: paneIDByLeafID) {
            lastAppliedLayouts[key] = tree
        }
        remainingPaneIDs[key] = Set(panes.map(\.paneID))
        return true
    }

    // MARK: - Restore Adoption

    /// Adopts a tab `AppDelegate.restoreTabSurfaces` already built for a
    /// herdr-bridged leaf that survived a snapshot restore -- see this
    /// file's header "RESTORE ADOPTION" for what it stores, why, and the
    /// documented handleLayoutUpdated consequence of not having herdr's
    /// own active_tab_id. `paneRefs` mirrors `Tab.herdrPaneRefs`'s own
    /// shape (surfaceID -> HerdrPaneRef); only its `.paneID` values are
    /// read here, the same as `openWorkspace`'s own `remainingPaneIDs`
    /// population.
    ///
    /// Idempotent: a `(workspaceID, socketPath)` already tracked --
    /// adopted before, or already opened via `openWorkspace` -- is left
    /// untouched.
    func adoptRestoredTab(workspaceID: String, socketPath: String, tabID: UUID, paneRefs: [UUID: HerdrPaneRef]) {
        let key = WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)
        guard activeTabIDs[key] == nil else { return }
        activeTabIDs[key] = tabID.uuidString
        remainingPaneIDs[key] = Set(paneRefs.values.map(\.paneID))
    }

    // MARK: - Refresh

    /// Re-exports `workspaceID`'s current layout and reconciles it
    /// against the last-applied one -- see this file's header "RATIO
    /// SYNC".
    ///
    /// TAB ID SOURCING: reuses the active_tab_id `openWorkspace` already
    /// RESOLVED and stored for this (workspaceID, socketPath) pair,
    /// rather than resolving a fresh one via its own workspace.get.
    /// DELIBERATE: layout.updated events can arrive frequently, and
    /// paying for an extra one-shot round trip on every single one, to
    /// re-resolve a tab id that has already been established by the
    /// open, would be wasted wire traffic for a value that is not
    /// expected to change between an open and its own subsequent
    /// refreshes. Returns `false` (touching no transport at all) when
    /// this workspace has no stored active_tab_id -- i.e. it was never
    /// successfully opened on this socket.
    @discardableResult
    func handleLayoutUpdated(workspaceID: String, socketPath: String) async -> Bool {
        let key = WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)
        guard let activeTabID = activeTabIDs[key] else { return false }

        let layout: HerdrLayoutExportResult
        do {
            layout = try await fetchLayout(tabID: activeTabID, socketPath: socketPath)
        } catch {
            return false
        }

        guard let (root, panes) = HerdrLayoutImporter.convert(layout) else { return false }
        let paneIDByLeafID = Dictionary(uniqueKeysWithValues: panes.map { ($0.leafID, $0.paneID) })
        guard let newTree = Self.appliedLayoutNode(root, paneIDByLeafID: paneIDByLeafID) else { return false }

        let oldTree = lastAppliedLayouts[key]
        lastAppliedLayouts[key] = newTree

        guard let oldTree, oldTree != newTree else { return true }

        var changes: [RatioChange] = []
        guard collectRatioChanges(old: oldTree, new: newTree, socketPath: socketPath, into: &changes) else {
            return true
        }
        for change in changes {
            attacher.updateRatio(leafA: change.leafA, leafB: change.leafB, direction: change.direction, ratio: change.ratio)
        }
        return true
    }

    // MARK: - Query

    /// Whether `workspaceID` on `socketPath` currently has an open tab in
    /// this window -- read-only, derived from `activeTabIDs` (the same
    /// per-workspace key `openWorkspace` populates on a successful open
    /// and `pruneIfLastPaneClosed` removes once the workspace's last
    /// tracked pane closes). Adds no state of its own and sends herdr
    /// nothing. Backs the herdr workspace row's own "Attach"/"Show"
    /// button label (`HerdrWorkspaceRow.isAttachedHere`, stored by
    /// `SessionBrowserModel.refresh()` via `herdrWorkspaceIsAttachedHere`),
    /// the herdr counterpart of `SessionBrowserRow.isAttachedHere` for a
    /// calyx-session row.
    func hasOpenTab(workspaceID: String, socketPath: String) -> Bool {
        activeTabIDs[WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)] != nil
    }

    // MARK: - Pane closed (herdr-initiated)

    /// The herdr-side pane behind `paneID` is gone -- close the tracked
    /// leaf and prune the registry, WITHOUT ever sending herdr a request
    /// of its own: see this file's header. Also prunes
    /// `activeTabIDs`/`lastAppliedLayouts` once this was the workspace's
    /// LAST tracked pane -- see
    /// `pruneIfLastPaneClosed(paneID:socketPath:)`.
    func handlePaneClosed(paneID: String, socketPath: String) async {
        closeTrackedPane(paneID: paneID, socketPath: socketPath)
    }

    // MARK: - Workspace killed / closed

    /// Closes every Calyx leaf currently registered for `workspaceID` on
    /// `socketPath` -- called from TWO places (this file's header
    /// "WORKSPACE KILLED"/"WORKSPACE CLOSED"): the Session Browser's Kill
    /// action for a herdr workspace row (`SessionBrowserModel
    /// .killHerdrWorkspace(_:)`), BEFORE it sends herdr `workspace.close`,
    /// so each pane's own `herdr terminal attach` process exits through
    /// its normal path instead of racing herdr's connection teardown; and
    /// this file's own `herdrWorkspaceClosed(workspaceID:socketPath:)`
    /// conformance, AFTER herdr has already closed the workspace
    /// server-side on its own initiative. Neither caller relies on a
    /// `pane.closed` event reaching `handlePaneClosed` --
    /// `HerdrIntegrationCoordinator`'s own event-stream connection is not
    /// necessarily subscribed at Session Browser kill time, and herdr's
    /// own workspace close does not push `pane.closed` for that
    /// workspace's panes at all (measured against a real herdr 0.8.0
    /// server). Closes each tracked pane through the
    /// exact same `closeTrackedPane(paneID:socketPath:)` helper
    /// `handlePaneClosed` itself calls, so a herdr-bridged pane's Calyx
    /// side keeps exactly one close path: the workspace's tab ends up
    /// closed, and `activeTabIDs`/`lastAppliedLayouts`/`remainingPaneIDs`
    /// pruned, identically to what closing every one of its panes one by
    /// one via `handlePaneClosed` already leaves. NEVER sends herdr a
    /// request of its own either way: for the Session Browser caller,
    /// `workspace.close` is sent separately, by `killHerdrWorkspace(_:)`
    /// right after this returns; for the herdr-initiated caller, herdr
    /// has already closed the workspace, so there is nothing left to
    /// send it at all. A no-op for a `workspaceID` with no pane currently
    /// tracked on `socketPath` (never opened in this window, or already
    /// fully closed).
    func handleWorkspaceKilled(workspaceID: String, socketPath: String) {
        let key = WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)
        // A value-type snapshot, not a live view: closeTrackedPane below
        // can reentrantly prune remainingPaneIDs[key] itself (attacher
        // .closeLeaf routes through Calyx's own close path, which calls
        // back into this coordinator's handleCalyxSurfaceClosed before
        // returning), so iterating the dictionary's own live entry here
        // would mutate out from under this loop.
        guard let paneIDs = remainingPaneIDs[key] else { return }
        for paneID in paneIDs {
            closeTrackedPane(paneID: paneID, socketPath: socketPath)
        }
    }

    /// Shared close path for a single tracked pane: closes the
    /// attacher's own leaf, prunes the registry, then prunes this
    /// coordinator's own per-workspace bookkeeping once the workspace's
    /// last pane is gone (`pruneIfLastPaneClosed`). Called by
    /// `handlePaneClosed` (one pane, herdr-initiated) and
    /// `handleWorkspaceKilled` (every tracked pane, Session Browser OR
    /// herdr-initiated) -- the only two paths through which this
    /// COORDINATOR ITSELF closes a herdr-bridged leaf (a Calyx-initiated
    /// close, e.g. Cmd+W, arrives via `handleCalyxSurfaceClosed` instead,
    /// with nothing left for this method to close -- see that method's
    /// own doc comment). A `paneID` with no currently registered
    /// surfaceID is a no-op.
    private func closeTrackedPane(paneID: String, socketPath: String) {
        guard let surfaceID = registry.surfaceID(forPaneID: paneID, socketPath: socketPath) else { return }
        attacher.closeLeaf(surfaceID)
        registry.unregister(surfaceID: surfaceID)
        pruneIfLastPaneClosed(paneID: paneID, socketPath: socketPath)
    }

    // MARK: - Surface closed (Calyx-initiated)

    /// Calyx-side counterpart to `handlePaneClosed` above: prunes
    /// `activeTabIDs`/`lastAppliedLayouts` for `surfaceID`'s
    /// own workspace when the USER closes a herdr-bridged leaf locally
    /// (Cmd+W, the tab close button, closing the whole window, ...) --
    /// none of which ever generates a herdr-side `pane.closed` event for
    /// `handlePaneClosed` to react to. Wired from
    /// `CalyxWindowController.closeSurfaceAndCleanUp`/`tearDownSurfaces`
    /// via `AppDelegate`, called BEFORE `SurfaceRegistry.destroySurface`
    /// runs, so `registry.paneRef(forSurfaceID:)` still resolves. A
    /// no-op for a `surfaceID` this coordinator's own `registry` has no
    /// ref for (an ordinary, non-herdr surface).
    ///
    /// Idempotent with `handlePaneClosed`'s own pruning for the SAME
    /// close: a herdr-initiated close routes through this exact same
    /// `closeSurfaceAndCleanUp` call (via `attacher.closeLeaf`), so both
    /// this method and `handlePaneClosed` fire for the one pane --
    /// `pruneIfLastPaneClosed`'s own `Set`-based removal absorbs the
    /// duplicate harmlessly.
    func handleCalyxSurfaceClosed(surfaceID: UUID) {
        guard let ref = registry.paneRef(forSurfaceID: surfaceID) else { return }
        pruneIfLastPaneClosed(paneID: ref.paneID, socketPath: ref.socketPath)
    }

    /// Shared by `closeTrackedPane` (herdr-initiated via `handlePaneClosed`,
    /// or Session Browser/herdr-initiated via `handleWorkspaceKilled`) and
    /// `handleCalyxSurfaceClosed` (Calyx-initiated) above -- removes
    /// `paneID` from its own workspace's `remainingPaneIDs` entry, and,
    /// once that reaches empty (this was the workspace's LAST tracked
    /// pane), also prunes `activeTabIDs`/`lastAppliedLayouts` for that
    /// same `WorkspaceKey`: without this, `herdrLayoutUpdated(
    /// socketPath:)` keeps spawning a wasted `layout.export` round trip
    /// for a workspace whose Calyx tab no longer exists, for as long as
    /// this coordinator lives. Idempotent: removing an
    /// already-absent `paneID`, or looking up an already-pruned (or
    /// never-tracked) `WorkspaceKey`, is a harmless no-op -- see both
    /// callers' own doc comments for why that matters.
    private func pruneIfLastPaneClosed(paneID: String, socketPath: String) {
        guard let workspaceID = Self.workspaceID(fromPaneID: paneID) else { return }
        let key = WorkspaceKey(workspaceID: workspaceID, socketPath: socketPath)
        guard var remaining = remainingPaneIDs[key] else { return }
        remaining.remove(paneID)
        if remaining.isEmpty {
            remainingPaneIDs.removeValue(forKey: key)
            activeTabIDs.removeValue(forKey: key)
            lastAppliedLayouts.removeValue(forKey: key)
        } else {
            remainingPaneIDs[key] = remaining
        }
    }

    /// The "w9" of a "w9:p1"-shaped pane id -- see `HerdrPaneRef
    /// .isValidPaneID`'s own header for the schema shape this is pinned
    /// to. `nil` for a paneID with no ":" at all -- never actually
    /// reachable here in practice: every paneID `remainingPaneIDs` can
    /// possibly hold, or a registered `HerdrPaneRef` can carry, already
    /// passed `openWorkspace`'s own explicit `HerdrPaneRef.isValidPaneID`
    /// gate (Phase 1) or `HerdrRestoreCommandPolicy.decide`'s identical
    /// explicit gate during restore.
    private static func workspaceID(fromPaneID paneID: String) -> String? {
        guard let colonIndex = paneID.firstIndex(of: ":") else { return nil }
        return String(paneID[..<colonIndex])
    }

    // MARK: - Wire

    /// One-shot `workspace.get`, scoped to `workspaceID` -- resolves its
    /// CURRENT WorkspaceInfo: active_tab_id (read from the response,
    /// never derived -- see this file's header "OPEN SEQUENCE") and
    /// label (see openWorkspace's own call site for how it feeds
    /// HerdrTabTitlePolicy.title).
    private func fetchWorkspaceInfo(workspaceID: String, socketPath: String) async throws -> HerdrWorkspaceInfo {
        let transport = await transportFactory.makeTransport()
        let request = HerdrOneShotRequest(transport: transport)
        let params = HerdrWorkspaceTargetParams(workspaceID: workspaceID)
        let response: HerdrWorkspaceGetRPCResult = try await request.send(
            method: "workspace.get", params: params, socketPath: socketPath
        )
        return response.workspace
    }

    /// One-shot `session.snapshot` (argument-less -- HerdrConnection.swift's
    /// own header, fact 1, still encodes `"params":{}`) -- see this
    /// file's header "OPEN SEQUENCE" for why `openWorkspace` needs this
    /// at all (a terminal id per pane, which layout.export's own pane
    /// nodes never carry).
    private func fetchSessionSnapshot(socketPath: String) async throws -> HerdrSessionSnapshot {
        let transport = await transportFactory.makeTransport()
        let request = HerdrOneShotRequest(transport: transport)
        let result: HerdrSnapshotRPCResult = try await request.send(method: "session.snapshot", socketPath: socketPath)
        return result.snapshot
    }

    /// One-shot `layout.export`, scoped to `tabID` -- see this file's
    /// header "OPEN SEQUENCE" for where `tabID` itself comes from at each
    /// of this method's two call sites.
    private func fetchLayout(tabID: String, socketPath: String) async throws -> HerdrLayoutExportResult {
        let transport = await transportFactory.makeTransport()
        let request = HerdrOneShotRequest(transport: transport)
        let params = HerdrLayoutExportParams(tabID: tabID)
        let response: HerdrLayoutExportRPCResult = try await request.send(
            method: "layout.export", params: params, socketPath: socketPath
        )
        return response.layout
    }

    // MARK: - Tree helpers

    /// Rebuilds `node` with every leaf UUID replaced via `mapping` --
    /// `nil` if any leaf has no entry (see openWorkspace's own call site
    /// for why this is unreachable in practice).
    private static func remapLeafIDs(_ node: SplitNode, mapping: [UUID: UUID]) -> SplitNode? {
        switch node {
        case .leaf(let id):
            guard let mapped = mapping[id] else { return nil }
            return .leaf(id: mapped)
        case .split(let data):
            guard let first = remapLeafIDs(data.first, mapping: mapping),
                  let second = remapLeafIDs(data.second, mapping: mapping) else {
                return nil
            }
            return .split(SplitData(direction: data.direction, ratio: data.ratio, first: first, second: second))
        }
    }

    /// Rebuilds `node` as an `AppliedLayoutNode` -- every leaf UUID
    /// replaced by its own herdr pane id via `paneIDByLeafID` (built
    /// directly from HerdrLayoutImporter.convert(_:)'s own flat
    /// descriptor list, so every leaf in `node` is guaranteed an entry).
    private static func appliedLayoutNode(_ node: SplitNode, paneIDByLeafID: [UUID: String]) -> AppliedLayoutNode? {
        switch node {
        case .leaf(let id):
            guard let paneID = paneIDByLeafID[id] else { return nil }
            return .leaf(paneID: paneID)
        case .split(let data):
            guard let first = appliedLayoutNode(data.first, paneIDByLeafID: paneIDByLeafID),
                  let second = appliedLayoutNode(data.second, paneIDByLeafID: paneIDByLeafID) else {
                return nil
            }
            return .split(direction: data.direction, ratio: data.ratio, first: first, second: second)
        }
    }

    /// Walks `old`/`new` in lockstep -- see this file's header "RATIO
    /// SYNC" for the full contract, including the disclosed nested-split
    /// limitation. Returns `false` the moment any node's own shape
    /// diverges (a leaf's paneID, a split's direction, or leaf-vs-split
    /// itself); the caller applies nothing in `changes` when this
    /// happens, even if some were already collected from an unaffected
    /// sibling subtree.
    private func collectRatioChanges(
        old: AppliedLayoutNode, new: AppliedLayoutNode, socketPath: String, into changes: inout [RatioChange]
    ) -> Bool {
        switch (old, new) {
        case (.leaf(let oldPaneID), .leaf(let newPaneID)):
            return oldPaneID == newPaneID

        case (.split(let oldDirection, let oldRatio, let oldFirst, let oldSecond),
              .split(let newDirection, let newRatio, let newFirst, let newSecond)):
            guard oldDirection == newDirection,
                  collectRatioChanges(old: oldFirst, new: newFirst, socketPath: socketPath, into: &changes),
                  collectRatioChanges(old: oldSecond, new: newSecond, socketPath: socketPath, into: &changes) else {
                return false
            }
            if oldRatio != newRatio,
               case .leaf(let firstPaneID) = newFirst, case .leaf(let secondPaneID) = newSecond,
               let leafA = registry.surfaceID(forPaneID: firstPaneID, socketPath: socketPath),
               let leafB = registry.surfaceID(forPaneID: secondPaneID, socketPath: socketPath) {
                changes.append((leafA: leafA, leafB: leafB, direction: newDirection, ratio: newRatio))
            }
            return true

        default:
            return false
        }
    }
}

// MARK: - HerdrStructureEventObserver

/// Wires HerdrIntegrationCoordinator's existing pane.closed/pane.exited/
/// layout.updated/workspace.closed events
/// (HerdrIntegrationCoordinator.swift's own HerdrStructureEventObserver
/// protocol) into this type's already-existing handleLayoutUpdated/
/// handlePaneClosed/handleWorkspaceKilled methods. Every protocol method
/// is synchronous per HerdrStructureEventObserver's own signature;
/// handleLayoutUpdated/handlePaneClosed are async, so herdrLayoutUpdated/
/// herdrPaneClosed below each fan out via an internally-spawned Task
/// rather than awaiting anything themselves. handleWorkspaceKilled is
/// itself synchronous, so herdrWorkspaceClosed below calls it directly,
/// with no Task.
extension HerdrTabCoordinator: HerdrStructureEventObserver {

    /// Triggers handleLayoutUpdated for EVERY workspace currently opened
    /// on `socketPath` -- one freshly-spawned Task per matching
    /// `activeTabIDs` key, each using that workspace's own STORED active
    /// tab id (handleLayoutUpdated resolves it internally from
    /// `activeTabIDs`, never a fresh workspace.get of its own -- see that
    /// method's own doc comment). Spawning one Task per workspace (rather
    /// than a single Task looping sequentially) lets every matching
    /// workspace's own refresh proceed independently: none is made to
    /// wait for another's wire round trip to settle first. A workspace
    /// opened on a DIFFERENT socketPath is left completely untouched.
    func herdrLayoutUpdated(socketPath: String) {
        for key in activeTabIDs.keys where key.socketPath == socketPath {
            let workspaceID = key.workspaceID
            Task { [weak self] in
                await self?.handleLayoutUpdated(workspaceID: workspaceID, socketPath: socketPath)
            }
        }
    }

    /// Delegates to handlePaneClosed via a freshly-spawned Task -- see
    /// this extension's own header for why a Task is needed here at all.
    func herdrPaneClosed(paneID: String, socketPath: String) {
        Task { [weak self] in
            await self?.handlePaneClosed(paneID: paneID, socketPath: socketPath)
        }
    }

    /// Delegates to handleWorkspaceKilled directly -- see this
    /// extension's own header for why no Task is needed here, unlike
    /// herdrPaneClosed/herdrLayoutUpdated above. This is the SAME shared
    /// close path `handleWorkspaceKilled`'s Session Browser caller uses
    /// (this type's own header "WORKSPACE CLOSED (herdr-initiated)");
    /// sends herdr no request of its own, and is a no-op for a
    /// `workspaceID` with no pane currently tracked on `socketPath`.
    func herdrWorkspaceClosed(workspaceID: String, socketPath: String) {
        handleWorkspaceKilled(workspaceID: workspaceID, socketPath: socketPath)
    }
}
