// SessionBrowserModel.swift
// Calyx
//
// UI-independent logic layer behind the session browser window:
// fetches the daemon's full session ledger
// (`SessionDaemonClient.listAll()`), keeps only its Running sessions
// (an Exited entry has no affordances here -- nothing to attach to,
// nothing to reconnect -- and the daemon ledger's own GC handles its
// eventual removal, so the browser is a view of attachable/killable
// sessions, not the raw ledger), flags orphaned running sessions
// (a session with no live ghostty surface attached in this Calyx
// process — `SessionSurfaceMap` has no entry for it), and exposes
// attach/kill actions. Kept separate from
// `SessionBrowserWindowController` (AppKit/SwiftUI chrome) so it's
// directly unit-testable — no window, no real daemon process — the
// same way `SessionBrowserModelTests` exercises it.
//
import Foundation

struct SessionBrowserRow: Identifiable, Equatable, Sendable {
    var id: String { info.id }
    let info: SessionInfo
    /// `true` for a running session with no current `SessionSurfaceMap`
    /// entry -- i.e. the daemon still has its child process alive, but
    /// no ghostty surface in this Calyx process is attached to it
    /// (orphaned by a crash, a `kill -9`'d Calyx process, or a session
    /// started by a different Calyx launch). Every `SessionBrowserRow`
    /// wraps a running session (`SessionBrowserModel.refresh()` never
    /// produces a row for an exited one), so this is the only case
    /// `isOrphan` distinguishes.
    let isOrphan: Bool
    /// `true` when `SessionSurfaceMap` currently has a surface for
    /// this session in this Calyx process — i.e. it's already visibly
    /// attached somewhere, so "Attach" in the browser should reveal
    /// that pane rather than open a second attach connection.
    let isAttachedHere: Bool

    /// User-visible label for the `isOrphan` badge (`SessionBrowserRowView`).
    /// Kept separate from the SwiftUI view so this string is testable
    /// without a snapshot/view-inspection dependency. Internal name
    /// (`isOrphan`) is unchanged -- only the user-visible
    /// wording moves from "Orphaned" to "Detached".
    static let orphanBadgeLabel = "Detached"

    /// User-visible label for the row's Attach/Show button
    /// (`SessionBrowserRowView`, `Button("Attach") { model.attach(row) }`
    /// today -- a literal, unconditional string, same one-line pattern
    /// as the `isOrphan` badge before `orphanBadgeLabel` existed). An
    /// already-attached row's button currently still reads "Attach",
    /// which is meaningless -- attaching a session that's already
    /// visibly attached somewhere in this process makes no sense; the
    /// action it actually performs (via `SessionAttachRoutingPolicy`'s
    /// `.focusExistingSurface` routing) is revealing/focusing that pane,
    /// so the label must read a focus verb instead. Exactly "Show" (team
    /// decision, not an implementer choice) once `isAttachedHere`;
    /// unchanged "Attach" otherwise.
    var attachButtonLabel: String {
        isAttachedHere ? "Show" : "Attach"
    }
}

/// Wraps `HerdrSessionInfo` the same way `SessionBrowserRow` wraps
/// `SessionInfo`, so the herdr section has its own row type independent
/// of whatever UI-only state `SessionBrowserRow` carries for
/// calyx-session rows (`isOrphan`/`isAttachedHere` have no herdr
/// server-level equivalent -- herdr identity never enters
/// `SessionSurfaceMap` by design; the herdr "attached here" flag lives
/// per workspace instead, on `HerdrWorkspaceRow.isAttachedHere`).
struct HerdrSessionRow: Identifiable, Equatable, Sendable {
    var id: String { info.id }
    let info: HerdrSessionInfo

    /// Row title text (`HerdrSessionRowView`'s bold line 1): the
    /// session's own name when discovery found one, falling back to its
    /// socket path (`info.id`) only when it didn't -- mirrors
    /// `SessionBrowserRowView`'s identical `row.info.name ?? row.info.id`
    /// fallback for a calyx-session row with no name. Factored onto this
    /// model type (not left inline in the view) so it's unit-testable
    /// without a SwiftUI view-inspection dependency, mirroring
    /// `SessionBrowserRow.attachButtonLabel`'s own precedent.
    var displayName: String { info.name ?? info.id }

    /// Tab title for the Command Palette's "Attach herdr TUI" action
    /// (`CalyxWindowController.setupCommandRegistry()`'s own
    /// `herdr.attachTUI` command, `AppDelegate.openHerdrAttachTab(command:
    /// title:)`) -- the one remaining caller of this property, since the
    /// session browser's own herdr rows open native tabs instead (never
    /// through `openHerdrAttachTab`). `"herdr: <name>"` when discovery
    /// found a name -- including
    /// herdr's own `"default"` term for the unnamed default session, so
    /// attaching it opens a tab titled "herdr: default" -- and plain
    /// `"herdr"` only when discovery found no name at all (`info.name
    /// == nil`, still live for the `HERDR_SOCKET_PATH` env-override
    /// candidate -- see `HerdrSessionDiscovery`'s own doc comment).
    /// Mirrors `displayName`'s identical name-or-fallback shape one
    /// property up; factored here for the same reason -- unit-testable
    /// without a test seam on `SessionBrowserWindowController` itself
    /// (that type's own header comment: "the logic worth testing lives
    /// in `SessionBrowserModel`, not this AppKit shell").
    var attachTabTitle: String {
        info.name.map { "herdr: \($0)" } ?? "herdr"
    }

    /// Row status text (`HerdrSessionRowView`'s short line-3 status
    /// line) -- delegates to the pure
    /// `HerdrAttachGate.decide(workspaceCount:paneCount:)` below, so the
    /// decision is testable independent of the view.
    var statusLineText: String {
        HerdrAttachGate.decide(workspaceCount: info.workspaceCount, paneCount: info.paneCount)
    }

    /// The server row's own trailing button title -- always `"New"`,
    /// unconditionally, regardless of `info.workspaceCount`. Pressing it
    /// always creates a new workspace and opens it
    /// (`HerdrAttachOrCreateFlow.createAndOpen`,
    /// `SessionBrowserWindowController.createHerdrWorkspace(_:)`); it
    /// never opens or attaches an existing one -- that is each
    /// `HerdrWorkspaceRow`'s own "Attach" button's job
    /// (`attachHerdrWorkspace(_:)` below), a fixed, unconditional label
    /// with no gate of its own to extract.
    static let createButtonLabel = "New"

    /// One row per workspace this session currently reports, in the
    /// order `session.snapshot` returned them
    /// (`HerdrSessionInfo.workspaces`'s own doc comment) --
    /// `HerdrWorkspaceRowView` nests these under this row in the session
    /// browser. STORED (built once in `init`), not derived from `info` on
    /// read, so each workspace's own `isAttachedHere` is part of this
    /// row's `Equatable` value: flipping it makes `refresh()`'s
    /// `herdrRows` reassignment unequal to the previous value, which is
    /// what makes `@Observable` fire and the "Attach"/"Show" label
    /// re-render.
    let workspaces: [HerdrWorkspaceRow]

    /// Every workspace row gets `isAttachedHere == false` -- for callers
    /// with no herdr tab coordinator to ask (tests, and the Command
    /// Palette's `attachTabTitle` path, which never reads `workspaces`).
    init(info: HerdrSessionInfo) {
        self.init(info: info, isAttachedHere: { _, _ in false })
    }

    /// Builds `workspaces` with each row's `isAttachedHere` answered by
    /// `isAttachedHere(workspaceID, socketPath)` -- the shape of
    /// `SessionBrowserModel.herdrWorkspaceIsAttachedHere`, which
    /// `refresh()` passes straight through. Evaluated once, here, per
    /// workspace; the result is stored on the row.
    init(info: HerdrSessionInfo, isAttachedHere: (String, String) -> Bool) {
        self.init(info: info, tuiSurfaceID: nil, isAttachedHere: isAttachedHere)
    }

    /// `tuiSurfaceID` is the surface of a pane in this process running a
    /// herdr TUI client attached to this session (resolved by
    /// `SessionBrowserModel.refresh()` from `info.tuiClients`). Each
    /// workspace row's attachment is decided per workspace, in this
    /// order: `.nativeTab` when `isAttachedHere(workspaceID, socketPath)`
    /// answers true -- that workspace's own open tab always wins, so
    /// "Show" reveals it rather than a TUI that may be displaying a
    /// different workspace; otherwise `.tuiPane(surfaceID:)` when
    /// `tuiSurfaceID` is non-nil -- the TUI can be switched to any of the
    /// session's workspaces (`SessionBrowserModel.attachHerdrWorkspace(_:)`
    /// sends `workspace.focus` first); otherwise `.none`.
    init(info: HerdrSessionInfo, tuiSurfaceID: UUID?, isAttachedHere: (String, String) -> Bool) {
        self.info = info
        self.workspaces = info.workspaces.map { workspace in
            let attachment: HerdrWorkspaceAttachment
            if isAttachedHere(workspace.workspaceID, info.id) {
                attachment = .nativeTab
            } else if let tuiSurfaceID {
                attachment = .tuiPane(surfaceID: tuiSurfaceID)
            } else {
                attachment = .none
            }
            return HerdrWorkspaceRow(socketPath: info.id, info: workspace, attachment: attachment)
        }
    }
}

/// Where a herdr workspace is already displayed in this process, if
/// anywhere -- decides both `HerdrWorkspaceRow.attachButtonLabel` and
/// what its button does (`SessionBrowserWindowController
/// .attachHerdrWorkspace(_:)`).
enum HerdrWorkspaceAttachment: Equatable, Sendable {
    /// Not displayed here: the button opens it as a native tab.
    case none
    /// Open as a native herdr tab (`HerdrTabCoordinator`). Takes
    /// precedence over `.tuiPane` for the same workspace.
    case nativeTab
    /// No native tab of its own, but a herdr TUI client attached to this
    /// workspace's session runs in the pane `surfaceID`: the button asks
    /// herdr to switch that TUI to this workspace (`workspace.focus`),
    /// then focuses the pane.
    case tuiPane(surfaceID: UUID)
}

/// One workspace nested under its own server row (`HerdrSessionRow
/// .workspaces` above) -- wraps `HerdrWorkspaceInfo`
/// (`HerdrTabCoordinator.swift`) the same way `HerdrSessionRow` wraps
/// `HerdrSessionInfo`. `socketPath` identifies which server this
/// workspace belongs to: both Attach and Kill need it alongside the
/// workspace's own id, since a workspace id alone is only unique WITHIN
/// one server.
struct HerdrWorkspaceRow: Identifiable, Equatable, Sendable {
    let socketPath: String
    let info: HerdrWorkspaceInfo
    /// Where this workspace is already displayed in this process -- a
    /// native tab, or a pane running a herdr TUI client. Stored on the
    /// row (answered once inside `SessionBrowserModel.refresh()`, via
    /// `HerdrSessionRow.init(info:tuiSurfaceID:isAttachedHere:)`) rather
    /// than read at render time: its sources
    /// (`HerdrTabCoordinator.activeTabIDs`, the process table) are not
    /// observable, so only a change to this stored,
    /// `Equatable`-participating value makes `@Observable` notice an
    /// Attach/close.
    let attachment: HerdrWorkspaceAttachment

    /// `true` when this workspace is already displayed in this process
    /// (`attachment != .none`) -- the herdr counterpart of
    /// `SessionBrowserRow.isAttachedHere`.
    var isAttachedHere: Bool { attachment != .none }

    init(socketPath: String, info: HerdrWorkspaceInfo, attachment: HerdrWorkspaceAttachment) {
        self.socketPath = socketPath
        self.info = info
        self.attachment = attachment
    }

    /// `isAttachedHere == true` means an open native tab (`.nativeTab`),
    /// `false` means `.none`.
    init(socketPath: String, info: HerdrWorkspaceInfo, isAttachedHere: Bool) {
        self.init(socketPath: socketPath, info: info, attachment: isAttachedHere ? .nativeTab : .none)
    }

    /// `isAttachedHere` defaults to `false` -- a workspace row built with
    /// no herdr tab coordinator to ask.
    init(socketPath: String, info: HerdrWorkspaceInfo) {
        self.init(socketPath: socketPath, info: info, isAttachedHere: false)
    }

    /// Combines `socketPath` with the workspace id: two different herdr
    /// servers can each report a workspace called e.g. "w1", so the
    /// socket path alone -- not the workspace id alone -- is what makes
    /// this globally unique across every server row's own nested list.
    var id: String { "\(socketPath)#\(info.workspaceID)" }

    /// Row title -- `HerdrTabTitlePolicy`'s own label-or-id fallback
    /// rule, the same policy `HerdrTabCoordinator.openWorkspace` already
    /// applies to a newly opened tab's own title.
    var displayLabel: String {
        HerdrTabTitlePolicy.title(label: info.label, workspaceID: info.workspaceID)
    }

    /// "N pane(s)" -- this row's own pane count only, same `"pane(s)"`
    /// vocabulary as the server row's own status line -- prefixed with
    /// the workspace id ("<id> · N pane(s)") whenever the label is
    /// non-blank after trimming whitespace -- the same rule
    /// `HerdrTabTitlePolicy` (and so `displayLabel`) uses -- even when
    /// that label happens to equal the id. herdr 0.8 replaces the last
    /// closed workspace with a new one under the same label, so the id
    /// is what distinguishes them. When the label is nil or blank,
    /// `displayLabel` already is the id, so it is not repeated.
    var paneCountText: String {
        let count = "\(info.paneCount) pane(s)"
        guard HerdrTabTitlePolicy.hasNonBlankLabel(info.label) else { return count }
        return "\(info.workspaceID) · \(count)"
    }

    /// Mirrors `SessionBrowserRow.attachButtonLabel`'s exact ternary and
    /// wording: "Show" once this workspace is already displayed in this
    /// process (an open native tab, or a pane running a herdr TUI client
    /// -- see `attachment`), unchanged "Attach" otherwise. Pressing the
    /// button on an already-displayed workspace focuses it
    /// (`SessionBrowserWindowController.attachHerdrWorkspace(_:)`: the
    /// TUI pane via `.calyxFocusSurface`, or the native tab via
    /// `HerdrTabCoordinator.openWorkspace`'s own double-open guard), so
    /// the label must read a focus verb instead.
    var attachButtonLabel: String {
        isAttachedHere ? "Show" : "Attach"
    }
}

/// Pure decision behind `HerdrSessionRow.statusLineText` -- extracted so
/// it is directly testable without mounting `HerdrSessionRowView`,
/// mirroring `AgentSidebarGate.decide`'s own extraction shape
/// (`AgentStatusView.swift`). The server row's own button no longer
/// varies with this decision -- it is a fixed `"New"`
/// (`HerdrSessionRow.createButtonLabel`) -- so this returns only the
/// status text.
///
/// `workspaceCount`/`paneCount` mirror `HerdrSessionInfo`'s own fields:
/// `HerdrCLISessionProvider` always populates both together (from the
/// same successful `session.snapshot`) or leaves both `nil` together (a
/// snapshot that failed or never answered). Three outcomes:
///   - either is `nil` ("unknown"): the socket's own liveness is still
///     proven (every `HerdrSessionRow` already passed a live `connect()`
///     probe), but its contents are not, so the status line stays the
///     unchanged "Running".
///   - both known, `workspaceCount == 0`: nothing on this socket to
///     attach to yet.
///   - both known, `workspaceCount > 0`: states the workspace/pane
///     counts, in the same "label · fact · fact" style
///     `SessionBrowserRowView.detailLine` uses for calyx-session rows
///     (same " · " separator).
enum HerdrAttachGate {
    static func decide(workspaceCount: Int?, paneCount: Int?) -> String {
        guard let workspaceCount, let paneCount else { return "Running" }
        guard workspaceCount > 0 else { return "Running · nothing to attach" }
        return "Running · \(workspaceCount) workspace(s) · \(paneCount) pane(s)"
    }
}

@MainActor
@Observable
final class SessionBrowserModel {

    private(set) var rows: [SessionBrowserRow] = []

    /// Daemon-reported failure message per row id (`SessionBrowserRow
    /// .id`) from the most recent `kill(_:)` of that row that came back
    /// `.failed` -- `kill(_:)` has no confirmation dialog, so this is
    /// the only user-visible signal that a Kill the daemon rejected did
    /// nothing. Cleared for a row when a later `kill(_:)` of it reports
    /// `.killed`, and pruned by every `refresh()` that assigns `rows`
    /// to the ids still present in the refreshed `rows`.
    private(set) var killFailures: [String: String] = [:]

    /// Populated by `refresh()` from the injected `herdrProvider`, gated
    /// on `herdrAvailability()` (binary resolution only -- see that
    /// property's own doc comment for why "is any session actually
    /// alive" is entirely `herdrProvider`'s own job, not this gate's).
    /// Reset to `[]` on every `refresh()` while herdr is unavailable, so
    /// a herdr that dies mid-session disappears from the browser on the
    /// next poll rather than leaving a frozen last-known list.
    private(set) var herdrRows: [HerdrSessionRow] = []

    private let daemonClient: SessionDaemonClientProtocol
    private let surfaceMap: SessionSurfaceMap
    private let hostCandidateProvider: SSHHostCandidateProvider
    /// Herdr session lister and workspace closer -- see
    /// `HerdrSessionProvider.swift`. Defaults to the production
    /// `HerdrCLISessionProvider`: discovery + liveness probe, then one
    /// `session.snapshot` per alive socket for the per-workspace list and
    /// its derived counts, plus `closeWorkspace(workspaceID:socketPath:)`
    /// for a workspace row's "Kill" button.
    private let herdrProvider: HerdrSessionProviderProtocol
    /// Reports whether the herdr integration should currently be
    /// treated as available: a CHEAP binary-resolution check only, no
    /// discovery, no socket probes. This must stay free of any per-tick
    /// cost heavier than reading a memoized resolver result, since
    /// `refresh()` calls it unconditionally on every poll. "Is any
    /// session actually alive" deliberately does NOT live here:
    /// `herdrProvider.listSessions()` already performs that discovery +
    /// liveness sweep and returns `[]` when nothing is alive, and
    /// `showHerdrSection` already hides the section from an empty
    /// `herdrRows` -- duplicating that check here would mean two
    /// discovery sweeps (and a second, redundant set of socket probes)
    /// per poll instead of one. A closure, mirroring
    /// `SSHHostCandidateProvider`'s own `loadConfig` closure-injection
    /// precedent, rather than a protocol, so this file never needs to
    /// depend on `HerdrBinaryResolver` directly -- a fake closure here
    /// lets tests fix the answer without touching real PATH state.
    /// `() async -> Bool`, not a plain `() -> Bool`: a memoized HIT is
    /// just a lock-guarded property read, but a MISS (herdr not
    /// installed) re-walks PATH via `FileManager.isExecutableFile` on
    /// every single call -- see `HerdrBinaryResolver`'s own doc comment
    /// for why a miss is deliberately never cached -- and
    /// `defaultHerdrAvailability()` below hops that walk onto
    /// `DispatchQueue.global()` so `refresh()`'s 1s poll never runs it on
    /// the caller's thread (this property is only ever called from
    /// `@MainActor` `refresh()`, so "the caller's thread" means the main
    /// thread).
    /// Defaults to `defaultHerdrAvailability()` (below); an undetected
    /// herdr still renders exactly like today, unchanged, since an
    /// unresolvable binary means `herdrProvider.listSessions()` is never
    /// even called (see `refresh()`'s own negative-invariant test).
    private let herdrAvailability: () async -> Bool

    /// Reports whether a herdr workspace (workspace id, socket path)
    /// currently has an open tab in this window -- the herdr counterpart
    /// of `isAttachedHere` on a calyx-session row (`SessionBrowserRow`,
    /// set in `refresh()` below from `surfaceMap`). `refresh()` evaluates
    /// it once per workspace while building `herdrRows` and stores the
    /// answer as `HerdrWorkspaceRow.attachment` -- `.nativeTab` when true
    /// (winning over any herdr TUI client resolved via
    /// `resolveTUISurface`), otherwise `.tuiPane`/`.none` -- which backs
    /// that row's `attachButtonLabel`. Injected the same
    /// way every other side-effectful dependency here is: a closure,
    /// default `{ _, _ in false }` so existing tests, and any
    /// construction with no herdr tab coordinator to ask, answer exactly
    /// like today. `SessionBrowserWindowController` wires it to
    /// `HerdrTabCoordinator.hasOpenTab(workspaceID:socketPath:)`.
    private let herdrWorkspaceIsAttachedHere: (String, String) -> Bool

    /// Resolves a herdr TUI client's `SurfaceHint`
    /// (`HerdrSessionInfo.tuiClients`) to a surface of THIS process, or
    /// nil when it names no surface here (e.g. a pane of another Calyx
    /// instance). Called on the main actor from `refresh()`; the first
    /// client of a session that resolves marks every workspace row of
    /// that session with no native tab of its own
    /// (`herdrWorkspaceIsAttachedHere` false) `.tuiPane(surfaceID:)`.
    /// Defaults to
    /// `defaultResolveTUISurface`.
    private let resolveTUISurface: (HerdrTUIClient.SurfaceHint) -> UUID?

    /// Remote host candidates for the "New Remote Session…" picker,
    /// populated by `refreshRemoteHostCandidates()` from the injected
    /// `hostCandidateProvider`, in its own declaration order.
    private(set) var remoteHostCandidates: [String] = []

    /// Invoked by `attachToRemoteHost(_:)` with the `SessionSpawnContext`
    /// a chosen remote host must turn into -- structurally identical to
    /// what `CalyxWindowController.remoteSessionSpawnContext(forHost:)`
    /// produces for the same host, so both entry points feed the same
    /// downstream spawn contract. Actual surface/window creation is a
    /// `CalyxWindowController` concern, kept out of this pure logic
    /// layer -- mirrors `onAttachRequested`'s injectable-closure
    /// pattern.
    var onRemoteSessionRequested: ((SessionSpawnContext) -> Void)?

    /// Serializes `refresh()` so at most one `listAllBounded()`
    /// round-trip is ever in flight -- the 1s poll timer must not stack
    /// an unbounded number of concurrent round-trips behind a slow/hung
    /// daemon. A `refresh()` issued while one is still in flight is NOT
    /// dropped: it parks in `refreshWaiters` until the in-flight one
    /// finishes, then runs its own full round-trip (its caller -- e.g.
    /// `SessionBrowserWindowController` right after opening a herdr
    /// workspace -- is owed a result that reflects state at or after
    /// the time it asked, which the already-running refresh may have
    /// sampled too early to see).
    private var isRefreshing = false

    /// Continuations of `refresh()` calls parked while another refresh
    /// is in flight. The finishing refresh resumes ALL of them at once;
    /// each re-checks `isRefreshing` on wake, so exactly one proceeds
    /// and the rest park again behind it.
    ///
    /// No deinit drain is needed: the model cannot be deallocated while
    /// any caller is parked here, because the parked `refresh()` is an
    /// instance method whose suspended frame retains `self`. So no
    /// continuation in this array can ever be leaked by deinit.
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// Invoked by `attach(_:)` with the row to attach to. Actual
    /// surface/window creation is a `SessionBrowserWindowController` /
    /// `CalyxWindowController` concern, deliberately kept out of this
    /// pure logic layer — tests inject a closure and assert it was
    /// called with the right row instead of driving real AppKit.
    var onAttachRequested: ((SessionBrowserRow) -> Void)?

    /// Invoked by `createHerdrWorkspace(_:)` with the server row whose
    /// "New" button was pressed -- mirrors `onAttachRequested`'s
    /// injectable-closure pattern exactly. Always means "create a new
    /// workspace and open it" (`HerdrAttachOrCreateFlow.createAndOpen`);
    /// never "attach to an existing one" -- that is
    /// `onHerdrWorkspaceAttachRequested` below.
    var onHerdrCreateRequested: ((HerdrSessionRow) -> Void)?

    /// Invoked by `attachHerdrWorkspace(_:)` with the workspace row to
    /// attach to -- mirrors `onAttachRequested`'s injectable-closure
    /// pattern exactly, for a single already-known workspace id.
    var onHerdrWorkspaceAttachRequested: ((HerdrWorkspaceRow) -> Void)?

    /// Invoked by `killHerdrWorkspace(_:)` with the workspace row whose
    /// "Kill" button was pressed, BEFORE `herdrProvider.closeWorkspace(
    /// workspaceID:socketPath:)` is sent -- mirrors
    /// `onHerdrWorkspaceAttachRequested`'s injectable-closure pattern
    /// exactly. The closure's job is closing the Calyx tab that bridges
    /// the workspace, which ends its `herdr terminal attach` process
    /// through that process's own normal exit path: sending
    /// `workspace.close` first would tear down the connection that
    /// process is still attached to, which aborts inside its own
    /// terminal-restore path instead of exiting cleanly. There is no
    /// herdr `pane.closed` event to wait on either way.
    var onHerdrWorkspaceKilled: ((HerdrWorkspaceRow) -> Void)?

    init(
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared,
        surfaceMap: SessionSurfaceMap = .shared,
        hostCandidateProvider: SSHHostCandidateProvider = SSHHostCandidateProvider(),
        herdrProvider: HerdrSessionProviderProtocol = HerdrCLISessionProvider(),
        herdrAvailability: @escaping () async -> Bool = SessionBrowserModel.defaultHerdrAvailability(),
        herdrWorkspaceIsAttachedHere: @escaping (String, String) -> Bool = { _, _ in false },
        resolveTUISurface: @escaping (HerdrTUIClient.SurfaceHint) -> UUID? = { SessionBrowserModel.defaultResolveTUISurface($0) }
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
        self.hostCandidateProvider = hostCandidateProvider
        self.herdrProvider = herdrProvider
        self.herdrAvailability = herdrAvailability
        self.herdrWorkspaceIsAttachedHere = herdrWorkspaceIsAttachedHere
        self.resolveTUISurface = resolveTUISurface
    }

    /// Production `resolveTUISurface`: `.sessionID` goes through
    /// `SessionSurfaceMap.shared`, `.surfaceID` is taken as-is, and in
    /// both cases the UUID is returned only when `SurfaceLocator.shared`
    /// knows a live controller for it -- i.e. the surface belongs to this
    /// process, not to another Calyx instance whose pane the client
    /// inherited its env from.
    static func defaultResolveTUISurface(_ hint: HerdrTUIClient.SurfaceHint) -> UUID? {
        let candidate: UUID?
        switch hint {
        case .sessionID(let sessionID):
            candidate = SessionSurfaceMap.shared.surfaceID(for: sessionID)
        case .surfaceID(let surfaceID):
            candidate = surfaceID
        }
        guard let candidate, SurfaceLocator.shared.controller(for: candidate) != nil else { return nil }
        return candidate
    }

    /// Builds the production `herdrAvailability` default: binary
    /// resolution only, no discovery, no socket probes (see
    /// `herdrAvailability`'s own doc comment for why that's the whole
    /// rule now). `resolver` is constructed ONCE here -- this factory
    /// runs once per `SessionBrowserModel` instance, exactly like any
    /// other default-parameter expression (Swift evaluates a default
    /// argument fresh per call that omits it, not once globally) -- and
    /// captured by the returned closure, so every later call the closure
    /// receives (e.g. `SessionBrowserView`'s 1s poll, indirectly through
    /// `refresh()`) reuses the SAME `HerdrBinaryResolver` instance
    /// instead of reconstructing one per poll. That reuse is what makes
    /// `HerdrBinaryResolver`'s own per-instance memoization of
    /// `resolve()` (see that type's doc comment) actually pay off here:
    /// repeated polls against an absent/present binary cost one property
    /// read after the first call, not a fresh PATH walk every second.
    ///
    /// The returned closure hops `resolver.resolve()` itself onto
    /// `DispatchQueue.global()` via `withCheckedContinuation`, mirroring
    /// `SystemCommandRunner.locate(_:)`'s identical "run blocking work on
    /// a background queue, resume a non-throwing continuation" shape --
    /// so we do not park the calling thread inside a blocking
    /// `FileManager.isExecutableFile` PATH walk. `refresh()` calls this
    /// unconditionally on every 1s poll while the herdr binary is
    /// undetected (a permanent miss, per `HerdrBinaryResolver`'s own
    /// never-cache-a-miss contract), and `refresh()` runs on `@MainActor`,
    /// so without this hop that walk would run on the main thread once a
    /// second for every user without herdr installed. `resolver` is
    /// `Sendable` (its cache lives behind `OSAllocatedUnfairLock`, see
    /// that type's own doc comment), so capturing it directly in the
    /// `@Sendable` dispatch closure is sound.
    private static func defaultHerdrAvailability() -> () async -> Bool {
        let resolver = HerdrBinaryResolver()
        return {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async {
                    continuation.resume(returning: resolver.resolve() != nil)
                }
            }
        }
    }

    /// Refreshes `rows` from `daemonClient.listAll()`, for Running
    /// sessions only.
    ///
    /// The daemon ledger never removes `Exited` entries on its own (its
    /// retention GC runs on its own schedule); a `listAll()` result
    /// mixing Running and Exited sessions is the ledger's normal shape,
    /// not an edge case. An Exited session has zero affordances here --
    /// nothing to attach to, nothing to reconnect -- so keeping a row
    /// for one would accumulate as a permanent dead row in the browser
    /// (observed in production: 7 stale `Exited(137)` rows) rather than
    /// disappearing once the ledger eventually GCs it. Filtering here
    /// keeps the browser a view of sessions you can actually attach to
    /// or kill.
    ///
    /// Routed through `listAllBounded()`
    /// rather than `listAll()` directly, since a hung daemon used to
    /// freeze the whole session browser forever. Shares the same 5s
    /// bound `AppDelegate`'s agent-resume path already applied to itself
    /// (see `SessionDaemonClientProtocol.listAllBounded()`'s own doc
    /// comment).
    ///
    /// Guards on `Task.isCancelled` before assigning `rows`, mirroring
    /// `AppDelegate.listAllSessionsBounded`'s identical
    /// guard. Without this, a closed-window poll cancellation (once
    /// cancellation reaches `listAllBounded()`'s own race) could
    /// still resolve early with a result that arrives after the
    /// caller gave up, wiping this SHARED model's rows with a stale
    /// value -- an empty flash on reopen.
    ///
    /// After the calyx-session block above, gates the herdr step on
    /// `herdrAvailability()` -- an unresolvable binary clears
    /// `herdrRows` to `[]` and returns WITHOUT ever calling
    /// `herdrProvider.listSessions()` (undetected herdr costs zero
    /// work, checked as a permanent structural invariant by
    /// `SessionBrowserModelHerdrTests`'s own negative test). That
    /// clearing assignment gets the identical `Task.isCancelled` guard
    /// as the `rows` and available-branch `herdrRows` assignments above
    /// it, for the same reason: a late-resolving cancellation must not
    /// let a stale result (here, the unconditional `[]`) overwrite a
    /// previously-populated `herdrRows`
    /// (`SessionBrowserModelHerdrTests`'s own cancellation-guard test).
    /// Clearing unconditionally (not just leaving stale rows alone) is
    /// what makes the herdr section actually disappear on the next poll
    /// after herdr dies, rather than showing a frozen last-known list.
    /// When available, routes through `boundedHerdrListSessions()`
    /// rather than a bare `await`, for the identical reason
    /// `listAllBounded()` exists above: a provider call now genuinely
    /// performs a `session.snapshot` network round trip per alive
    /// socket (`HerdrCLISessionProvider.fetchCounts(socketPath:)`, worst
    /// case a handful of sequential `oneShotRequestTimeout` expiries
    /// against a stalled server), so this bound is load-bearing, not
    /// future-proofing: it must never freeze this shared poll loop.
    ///
    /// Serialized, not deduplicated: see `isRefreshing`. The wait runs on
    /// the caller's own task (no unstructured `Task`), so the
    /// `Task.isCancelled` guards below still observe the caller's
    /// cancellation.
    func refresh() async {
        // Cancellation tradeoff: a parked caller is NOT woken early when
        // its task is cancelled (`withCheckedContinuation` is not
        // cancellation-aware). It wakes when the in-flight refresh
        // finishes -- bounded by the daemon/herdr query time limits --
        // and the `Task.isCancelled` guard below then returns without a
        // round-trip. Chosen over `withTaskCancellationHandler`, whose
        // `onCancel` runs outside this actor and would have to find and
        // remove one specific continuation from `refreshWaiters` from
        // there.
        while isRefreshing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                refreshWaiters.append(continuation)
            }
        }
        // A caller cancelled while parked must not issue its own round-trip.
        guard !Task.isCancelled else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        let sessions = await daemonClient.listAllBounded()
        guard !Task.isCancelled else { return }
        rows = sessions.filter { $0.state == .running }.map { info in
            let isAttached = surfaceMap.surfaceID(for: info.id) != nil
            return SessionBrowserRow(
                info: info,
                isOrphan: !isAttached,
                isAttachedHere: isAttached
            )
        }
        let rowIDs = Set(rows.map(\.id))
        killFailures = killFailures.filter { rowIDs.contains($0.key) }

        guard await herdrAvailability() else {
            guard !Task.isCancelled else { return }
            herdrRows = []
            return
        }
        let herdrSessions = await boundedHerdrListSessions()
        guard !Task.isCancelled else { return }
        herdrRows = herdrSessions.map { info in
            let tuiSurfaceID = info.tuiClients.lazy.compactMap { self.resolveTUISurface($0.surfaceHint) }.first
            return HerdrSessionRow(info: info, tuiSurfaceID: tuiSurfaceID, isAttachedHere: herdrWorkspaceIsAttachedHere)
        }
    }

    /// Races `herdrProvider.listSessions()` against the shared
    /// `daemonQueryBoundTimeoutSeconds` bound, degrading to `[]` on
    /// timeout, by reusing `SessionDaemonClientProtocol`'s own
    /// `bounded(operation:onTimeout:timeoutSeconds:)` through
    /// `daemonClient` -- the identical winner-cancels-loser race
    /// `listAllBounded()` uses (promoted from `private` to `internal` in
    /// `SessionDaemonClient.swift` so this file can call it directly
    /// instead of duplicating its own ~80-line bridge). Omitting
    /// `timeoutSeconds:` lets the default `daemonQueryBoundTimeoutSeconds`
    /// bind, so this shares the exact same constant (its `#if DEBUG`
    /// override seam included) as every other bounded daemon call,
    /// rather than inventing a second one.
    private func boundedHerdrListSessions() async -> [HerdrSessionInfo] {
        let herdrProvider = self.herdrProvider
        return await daemonClient.bounded(operation: { await herdrProvider.listSessions() }, onTimeout: { [] })
    }

    /// Requests attaching to `row`'s session.
    func attach(_ row: SessionBrowserRow) {
        onAttachRequested?(row)
    }

    /// Requests creating a new workspace on `row`'s herdr server (the
    /// server row's own "New" button). Mirrors `attach(_:)` exactly --
    /// herdr identity flows through the same injected-closure seam, just
    /// its own closure/row type.
    func createHerdrWorkspace(_ row: HerdrSessionRow) {
        onHerdrCreateRequested?(row)
    }

    /// Requests attaching to `row`'s already-existing herdr workspace
    /// through the same injected-closure seam as `attach(_:)`, just its
    /// own closure/row type. For a `.tuiPane(surfaceID:)` row it first
    /// sends `workspace.focus` for the row's workspace
    /// (`herdrProvider.focusWorkspace(workspaceID:socketPath:)`) and only
    /// then invokes the closure: the pane runs a herdr TUI client that
    /// displays whichever workspace herdr has focused, so herdr must
    /// switch it to this row's workspace before the window controller
    /// focuses the pane -- otherwise "Show" would reveal a different
    /// workspace. `.nativeTab`/`.none` rows invoke the closure directly;
    /// no TUI is involved.
    func attachHerdrWorkspace(_ row: HerdrWorkspaceRow) async {
        if case .tuiPane = row.attachment {
            await herdrProvider.focusWorkspace(workspaceID: row.info.workspaceID, socketPath: row.socketPath)
        }
        onHerdrWorkspaceAttachRequested?(row)
    }

    /// Kills `row`'s session via the daemon, records the outcome in
    /// `killFailures` (the daemon's message on `.failed`, the row's
    /// entry removed on `.killed`), then refreshes.
    func kill(_ row: SessionBrowserRow) async {
        switch await daemonClient.kill(id: row.info.id) {
        case .killed:
            killFailures.removeValue(forKey: row.id)
        case .failed(let message):
            killFailures[row.id] = message
        }
        await refresh()
    }

    /// Invokes `onHerdrWorkspaceKilled` with `row` first, closing the
    /// Calyx tab bridging that workspace, then closes `row`'s herdr
    /// workspace via the injected `herdrProvider`'s own `closeWorkspace(
    /// workspaceID:socketPath:)`, then refreshes. Closing the Calyx tab
    /// first ends its `herdr terminal attach` process through that
    /// process's own normal exit path; sending `workspace.close` first
    /// would tear down the connection that process is still attached to,
    /// which aborts inside its own terminal-restore path instead.
    /// Mirrors `kill(_:)` exactly: no confirmation dialog, and the
    /// refresh runs unconditionally, whether or not the close itself
    /// succeeded (see that method's own doc comment for why).
    func killHerdrWorkspace(_ row: HerdrWorkspaceRow) async {
        onHerdrWorkspaceKilled?(row)
        await herdrProvider.closeWorkspace(workspaceID: row.info.workspaceID, socketPath: row.socketPath)
        await refresh()
    }

    /// Populates `remoteHostCandidates` from the injected
    /// `hostCandidateProvider`. Gated on
    /// `SessionSettings.persistentSessionsEnabled`: `SessionSpawnPlanner
    /// .plan(for:)` silently downgrades a host-carrying spawn to a local
    /// `.passthrough` while that flag is off, so offering a remote host to
    /// attach to here would be a silent lie about what "Attach" is about
    /// to do. Leaves `remoteHostCandidates` untouched (not cleared) while
    /// the flag is off -- `showRemoteHostsSection` is what actually hides
    /// the section, independent of whatever this array holds.
    func refreshRemoteHostCandidates() {
        guard SessionSettings.persistentSessionsEnabled else { return }
        remoteHostCandidates = hostCandidateProvider.hostCandidates()
    }

    /// Whether the Remote Hosts section should render at all. Reads
    /// `SessionSettings.persistentSessionsEnabled` live (not a cached
    /// snapshot), so flipping the setting off hides the section
    /// immediately, even if `remoteHostCandidates` still holds a stale
    /// non-empty list from an earlier refresh taken while the setting was
    /// on.
    var showRemoteHostsSection: Bool {
        SessionSettings.persistentSessionsEnabled && !remoteHostCandidates.isEmpty
    }

    /// Whether the herdr section should render at all. Mirrors
    /// `showRemoteHostsSection`'s shape: an empty/undetected herdr (no
    /// binary, no live socket, or a live-but-session-less herdr) must
    /// stay pixel-identical to today, so this is purely `herdrRows`'s
    /// own emptiness, not a separate "is herdr detected" flag.
    var showHerdrSection: Bool {
        !herdrRows.isEmpty
    }

    /// Whether the calyx-session list's own "Calyx Sessions" header
    /// should render. A header exists to distinguish this list from a
    /// sibling section, so it renders only when a sibling section is
    /// actually visible (`showRemoteHostsSection || showHerdrSection`)
    /// AND `rows` is non-empty: with no sibling section visible, the
    /// window's own "Sessions" title already identifies the list, so
    /// adding this header would be redundant for every user with
    /// neither herdr nor SSH hosts configured (the common case, and one
    /// this property must leave visually unchanged); and gating on
    /// non-empty `rows` keeps the header from dangling over an empty
    /// list -- the herdr-rows-but-zero-calyx-rows case `SessionBrowser
    /// View`'s own empty-state guard already handles by rendering that
    /// empty state instead of the row list this header sits above.
    var showSessionsHeader: Bool {
        (showRemoteHostsSection || showHerdrSection) && !rows.isEmpty
    }

    /// Requests spawning a new remote session against `host`.
    func attachToRemoteHost(_ host: String) {
        onRemoteSessionRequested?(SessionSpawnContext(host: host, origin: .tab))
    }

    /// Per-host install status for the Remote Hosts row's Install button
    /// (`installStatus(forHost:)`), mirroring `isRefreshing`'s existing
    /// in-flight-flag precedent but keyed per host, since different
    /// hosts' installs are independent of each other.
    enum RemoteInstallStatus: Equatable, Sendable {
        case idle
        case installing
        case succeeded
        /// The failing `CommandResult`'s stderr; `nil` when
        /// `installRemote(host:)` itself returned `nil`.
        case failed(String?)
    }

    private(set) var remoteInstallStatuses: [String: RemoteInstallStatus] = [:]

    /// A host with no install attempted yet reports `.idle`.
    func installStatus(forHost host: String) -> RemoteInstallStatus {
        remoteInstallStatuses[host] ?? .idle
    }

    /// Deploys the daemon to `host` via the injected `daemonClient`'s
    /// own `installRemote(host:)`, returning its result -- mirrors
    /// `kill(_:)`'s existing injectable-client pattern. Also drives
    /// `installStatus(forHost:)` around that same call: `.installing`
    /// while the daemon round-trip is in flight, then `.succeeded` or
    /// `.failed` once it resolves. Return value/signature unchanged --
    /// this only adds a status side effect.
    func installRemote(host: String) async -> CommandResult? {
        remoteInstallStatuses[host] = .installing
        let result = await daemonClient.installRemote(host: host)
        if let result, result.exitCode == 0 {
            remoteInstallStatuses[host] = .succeeded
        } else {
            remoteInstallStatuses[host] = .failed(result?.stderr)
        }
        return result
    }
}
