//
//  SessionBrowserModelHerdrTests.swift
//  CalyxTests
//
//  Exercises the herdr-session section `SessionBrowserModel` carries
//  alongside its existing calyx-session `rows`: `herdrRows`, fed by an
//  injected `HerdrSessionProviderProtocol` and gated on an injected
//  availability closure (mirroring `daemonClient`'s own
//  injectable-protocol shape and `SSHHostCandidateProvider`'s own
//  closure-injection precedent, respectively) -- exercised with fakes,
//  no real herdr binary/socket, no window, matching
//  `SessionBrowserModelTests`'s direct-call style.
//
//  Availability semantics under test: `herdrAvailability()` reports
//  ONLY whether the herdr binary itself resolves -- no discovery, no
//  socket probes. Whether any session is actually alive is entirely
//  `herdrProvider.listSessions()`'s own job (it discovers candidates,
//  probes liveness, and returns `[]` when nothing is running), and
//  `showHerdrSection == !herdrRows.isEmpty` is what actually hides the
//  section for an available-but-idle herdr.
//
//  `herdrAvailability` is `() async -> Bool`, not a plain `() -> Bool`:
//  the production default (`SessionBrowserModel.defaultHerdrAvailability()`)
//  hops `HerdrBinaryResolver.resolve()`'s PATH scan onto
//  `DispatchQueue.global()` so `refresh()`'s 1s poll never runs that
//  blocking filesystem walk on the main thread. Every fake closure below
//  is still written as a plain, non-suspending closure literal (Swift
//  infers `async` for an unmarked closure literal against an `async`
//  expected type), except one dedicated test that awaits a real
//  suspension point to prove `refresh()` actually awaits the result
//  instead of merely happening to work with closures that never suspend.
//
//  Coverage:
//  - refresh() populates `herdrRows` from the injected `herdrProvider`
//    once herdr is available, and `showHerdrSection` becomes true
//  - refresh() with a herdr provider that returns zero sessions (herdr
//    available, but nothing running) leaves `showHerdrSection` false --
//    an empty/undetected herdr must render exactly like today
//  - createHerdrWorkspace(_:) invokes `onHerdrCreateRequested` with the
//    server row (the "New" button, always create-and-open)
//  - attachHerdrWorkspace(_:) invokes `onHerdrWorkspaceAttachRequested`
//    with the workspace row (a single already-known workspace's own
//    "Attach" button)
//  - killHerdrWorkspace(_:) invokes `onHerdrWorkspaceKilled` exactly
//    once with that row FIRST, closing the Calyx panes before herdr's
//    own workspace.close is sent, then sends `workspace.close` for
//    exactly the given workspace via the injected `herdrProvider`, then
//    triggers a refresh
//  - CRITICAL negative invariant (undetected herdr = zero work):
//    refresh() must NEVER call `herdrProvider.listSessions()` while the
//    herdr binary itself is unresolvable -- asserted via the fake
//    provider's own call counter, not just its return value. A
//    permanent structural regression guard, asserted unconditionally on
//    every run, not a one-time Red/Green transition test.
//  - A refresh() cancelled at the exact moment its own
//    `herdrAvailability()` check reports unavailable must not overwrite
//    a previously-populated `herdrRows` with that branch's `[]` --
//    mirrors the `Task.isCancelled` guard already protecting the
//    `rows` assignment (`SessionBrowserModelRefreshCancellationGuardTests`)
//    and the available-branch `herdrRows` assignment right next to it
//  - refresh() bounds `herdrProvider.listSessions()` by the same shared
//    `daemonQueryBoundTimeoutSeconds` `SessionDaemonClient
//    .listAllBounded()` uses, degrading `herdrRows` to `[]` rather than
//    hanging forever when the provider call never completes
//  - HerdrSessionRow.displayName: the pure name-or-socket-path title
//    derivation HerdrSessionRowView's line 1 renders
//  - HerdrSessionRow.createButtonLabel is always "New", across all three
//    count states -- unknown, known with zero workspaces, known with at
//    least one -- since the server row's own button no longer varies by
//    count (see HerdrAttachOrCreateFlowTests.swift for the create wire
//    flow this file does not cover)
//  - HerdrAttachGate.decide (and HerdrSessionRow.statusLineText, which
//    delegates to it): the pure status-text decision for those same
//    three count states
//  - HerdrSessionRow.workspaces maps HerdrSessionInfo.workspaces into
//    HerdrWorkspaceRow, carrying the owning socketPath alongside each;
//    HerdrWorkspaceRow.displayLabel/.paneCountText: the pure
//    label-or-id-fallback and "N pane(s)" derivations HerdrWorkspaceRowView
//    renders
//  - HerdrSessionRow.attachTabTitle: the pure "herdr: <name>" / "herdr"
//    derivation the Command Palette's "Attach herdr TUI" action uses for
//    its own tab's title -- pinned for both a named session and the
//    default session now that discovery names it "default" instead of
//    leaving it nameless
//

import Observation
import XCTest
@testable import Calyx

/// Minimal `SessionDaemonClientProtocol` fake -- most of this file's
/// tests exercise no calyx-session daemon interaction at all, so
/// `sessionsToReturn` defaults to `[]` (this file's original behavior,
/// unchanged for every test that never sets it). A local duplicate of
/// `SessionBrowserModelTests`'/`SessionBrowserModelRemoteHostsGateTests`'s
/// own fake shape (this codebase's established per-file
/// fixture-duplication convention), narrowed to inert stubs plus the one
/// settable field the `showSessionsHeader` tests below need to put a
/// non-empty `SessionBrowserModel.rows` on the board.
private final class FakeDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var sessionsToReturn: [SessionInfo] = []
    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { sessionsToReturn }
    func setMeta(id: String, key: String, value: String) async {}
}

/// Records every `listSessions()` call (for the CRITICAL negative
/// invariant below, and for `killHerdrWorkspace(_:)`'s own
/// "then triggers a refresh" assertion) and every `closeWorkspace(
/// workspaceID:socketPath:)` call, replaying a canned `[HerdrSessionInfo]`
/// -- a process boundary stand-in, no real herdr binary/socket involved.
private final class FakeHerdrSessionProvider: HerdrSessionProviderProtocol, @unchecked Sendable {
    var sessionsToReturn: [HerdrSessionInfo] = []
    private(set) var listSessionsCallCount = 0
    private(set) var closeWorkspaceCalls: [(workspaceID: String, socketPath: String)] = []
    /// `listSessionsCallCount` AT the moment each `closeWorkspace` call
    /// arrives -- lets `test_killHerdrWorkspace_sendsCloseForExactlyThatWorkspace_thenRefreshes`
    /// pin close-before-refresh directly, the same way it pins
    /// closure-before-close via `closeWorkspaceCalls.count` read inside
    /// `onHerdrWorkspaceKilled`.
    private(set) var listSessionsCallCountAtCloseCall: [Int] = []
    /// Every `focusWorkspace(workspaceID:socketPath:)` call, in order --
    /// added ahead of `HerdrSessionProviderProtocol` actually declaring
    /// this requirement, so the fake is ready once production adds it
    /// (`SessionBrowserModel.attachHerdrWorkspace(_:)`'s new `.tuiPane`
    /// path). See `test_attachHerdrWorkspace_tuiPaneRow_sendsWorkspaceFocusThenRequestsAttach`.
    private(set) var focusWorkspaceCalls: [(workspaceID: String, socketPath: String)] = []

    func listSessions() async -> [HerdrSessionInfo] {
        listSessionsCallCount += 1
        return sessionsToReturn
    }

    func closeWorkspace(workspaceID: String, socketPath: String) async {
        listSessionsCallCountAtCloseCall.append(listSessionsCallCount)
        closeWorkspaceCalls.append((workspaceID: workspaceID, socketPath: socketPath))
    }

    /// Not yet part of `HerdrSessionProviderProtocol` -- see this
    /// property's own doc comment. Once production declares the
    /// requirement, this conformance starts satisfying it with no
    /// further change needed here.
    func focusWorkspace(workspaceID: String, socketPath: String) async {
        focusWorkspaceCalls.append((workspaceID: workspaceID, socketPath: socketPath))
    }
}

/// Never resumes -- stands in for a herdr provider whose
/// `listSessions()` call hangs forever, mirroring
/// `SessionDaemonClientBoundedListTests`'s own `NeverCompletingCommandRunner`.
/// Harmless to leave suspended for the rest of the process's life:
/// `refresh()`'s own bounded race must reach a terminal `[]` regardless.
/// `closeWorkspace(workspaceID:socketPath:)` is inert (returns
/// immediately) -- no test below exercises a hung close, only a hung
/// `listSessions()`.
private final class NeverCompletingHerdrSessionProvider: HerdrSessionProviderProtocol, @unchecked Sendable {
    func listSessions() async -> [HerdrSessionInfo] {
        await withCheckedContinuation { (_: CheckedContinuation<[HerdrSessionInfo], Never>) in
            // Deliberately never resumed.
        }
    }

    func closeWorkspace(workspaceID: String, socketPath: String) async {}

    /// Inert, mirroring `closeWorkspace(workspaceID:socketPath:)` above --
    /// not yet part of `HerdrSessionProviderProtocol`; see
    /// `FakeHerdrSessionProvider.focusWorkspace(workspaceID:socketPath:)`'s
    /// own doc comment.
    func focusWorkspace(workspaceID: String, socketPath: String) async {}
}

/// MainActor-isolated box letting a `herdrAvailability` closure reach
/// back into the very `Task` that's running the `refresh()` call
/// evaluating it, and cancel that task from inside the closure itself.
/// `herdrAvailability` is `() async -> Bool`, but this closure's own
/// body has no internal suspension point (no `await` anywhere in it),
/// so `await herdrAvailability()` never actually yields the thread here
/// -- control stays on the same synchronous call stack, and
/// `refresh()`'s unavailable branch still has nothing separating the
/// check from the assignment right after it. That is what keeps this
/// the only way to deterministically land a cancellation inside that
/// branch: nothing outside the closure could ever interleave a
/// cancellation between the two with reliable timing.
@MainActor
private final class HerdrAvailabilityCancelBox {
    var task: Task<Void, Never>?
    var available = true
    var cancelOnNextCheck = false
}

@MainActor
final class SessionBrowserModelHerdrTests: XCTestCase {

    private func makeModel(
        daemonClient: FakeDaemonClient = FakeDaemonClient(),
        herdrProvider: HerdrSessionProviderProtocol,
        herdrAvailability: @escaping () async -> Bool,
        herdrWorkspaceIsAttachedHere: @escaping (String, String) -> Bool = { _, _ in false },
        resolveTUISurface: @escaping (HerdrTUIClient.SurfaceHint) -> UUID? = { _ in nil }
    ) -> SessionBrowserModel {
        SessionBrowserModel(
            daemonClient: daemonClient,
            surfaceMap: SessionSurfaceMap(),
            herdrProvider: herdrProvider,
            herdrAvailability: herdrAvailability,
            herdrWorkspaceIsAttachedHere: herdrWorkspaceIsAttachedHere,
            resolveTUISurface: resolveTUISurface
        )
    }

    override func tearDown() {
        // Mirrors `SessionDaemonClientBoundedListTests`' own tearDown --
        // no override must leak into a later test.
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = nil
        super.tearDown()
    }

    // MARK: - refresh() populates herdrRows once herdr is available

    func test_refresh_herdrAvailableWithSessions_populatesHerdrRowsAndShowsSection() async {
        let provider = FakeHerdrSessionProvider()
        let info = HerdrSessionInfo(id: "test-herdr-socket-1", name: "work", workspaceCount: 2, paneCount: 3, agentCount: 1, workspaces: [])
        provider.sessionsToReturn = [info]
        let model = makeModel(herdrProvider: provider, herdrAvailability: { true })

        await model.refresh()

        XCTAssertEqual(
            model.herdrRows.map(\.id), [info.id],
            "refresh() must populate herdrRows from the injected herdrProvider once herdr is available"
        )
        XCTAssertTrue(
            model.showHerdrSection,
            "With at least one herdr row, showHerdrSection must be true"
        )
    }

    // MARK: - herdrAvailability() that genuinely suspends is still awaited correctly

    /// Every other fake `herdrAvailability` closure in this file (`{ true }`,
    /// `{ false }`) has no internal suspension point, so it would keep
    /// passing even if `refresh()` accidentally called it without `await`
    /// on some code path that never actually needs to suspend. This one
    /// awaits a real suspension point (`Task.yield()`) before answering,
    /// proving `refresh()` genuinely awaits `herdrAvailability()` rather
    /// than merely happening to work with closures that return
    /// synchronously -- the production default
    /// (`SessionBrowserModel.defaultHerdrAvailability()`) is exactly this
    /// shape, hopping `HerdrBinaryResolver.resolve()` onto
    /// `DispatchQueue.global()`.
    func test_refresh_herdrAvailabilityGenuinelySuspends_stillGatesCorrectly() async {
        let provider = FakeHerdrSessionProvider()
        let info = HerdrSessionInfo(id: "test-herdr-socket-1", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        provider.sessionsToReturn = [info]
        let model = makeModel(herdrProvider: provider, herdrAvailability: {
            await Task.yield()
            return true
        })

        await model.refresh()

        XCTAssertEqual(
            model.herdrRows.map(\.id), [info.id],
            "refresh() must correctly await a herdrAvailability() closure that genuinely suspends " +
            "before answering, not just one that happens to return synchronously"
        )
    }

    // MARK: - Empty herdr session list keeps the section hidden

    func test_refresh_herdrAvailableButNoSessions_showHerdrSectionStaysFalse() async {
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = []
        let model = makeModel(herdrProvider: provider, herdrAvailability: { true })

        await model.refresh()

        XCTAssertFalse(
            model.showHerdrSection,
            "With zero herdr rows, showHerdrSection must stay false -- an empty/undetected herdr must " +
            "render exactly like today"
        )
    }

    // MARK: - createHerdrWorkspace(_:) requests creating via the injected callback

    func test_createHerdrWorkspace_invokesOnHerdrCreateRequested_withTheRow() {
        let model = makeModel(herdrProvider: FakeHerdrSessionProvider(), herdrAvailability: { false })
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "test-herdr-socket-1", name: nil, workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        var requestedRow: HerdrSessionRow?
        model.onHerdrCreateRequested = { requestedRow = $0 }

        model.createHerdrWorkspace(row)

        XCTAssertEqual(
            requestedRow?.id, row.id,
            "createHerdrWorkspace(_:) must invoke onHerdrCreateRequested with the row it was given"
        )
    }

    // MARK: - attachHerdrWorkspace(_:) requests attaching via the injected callback

    func test_attachHerdrWorkspace_invokesOnHerdrWorkspaceAttachRequested_withTheRow() async {
        let model = makeModel(herdrProvider: FakeHerdrSessionProvider(), herdrAvailability: { false })
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1)
        )

        var requestedRow: HerdrWorkspaceRow?
        model.onHerdrWorkspaceAttachRequested = { requestedRow = $0 }

        await model.attachHerdrWorkspace(row)

        XCTAssertEqual(
            requestedRow?.id, row.id,
            "attachHerdrWorkspace(_:) must invoke onHerdrWorkspaceAttachRequested with the row it was given"
        )
    }

    // MARK: - killHerdrWorkspace(_:) sends workspace.close for exactly that workspace, then refreshes

    func test_killHerdrWorkspace_sendsCloseForExactlyThatWorkspace_thenRefreshes() async {
        let provider = FakeHerdrSessionProvider()
        let model = makeModel(herdrProvider: provider, herdrAvailability: { true })
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1)
        )

        // Captured AT closure-invocation time (not after killHerdrWorkspace
        // returns) so the assertions below can pin the full ordering the
        // spec requires -- panes closed first, workspace.close not yet
        // sent, refresh() not yet run -- not merely that all three
        // eventually happened.
        var killedRows: [HerdrWorkspaceRow] = []
        var closeCallCountWhenInvoked: [Int] = []
        var listSessionsCallCountWhenInvoked: [Int] = []
        model.onHerdrWorkspaceKilled = { killedRow in
            killedRows.append(killedRow)
            closeCallCountWhenInvoked.append(provider.closeWorkspaceCalls.count)
            listSessionsCallCountWhenInvoked.append(provider.listSessionsCallCount)
        }

        await model.killHerdrWorkspace(row)

        XCTAssertEqual(
            provider.closeWorkspaceCalls.map { $0.workspaceID }, ["w1"],
            "killHerdrWorkspace(_:) must send workspace.close for exactly the given workspace id, no other"
        )
        XCTAssertEqual(provider.closeWorkspaceCalls.map { $0.socketPath }, ["test-herdr-socket-1"])
        XCTAssertEqual(
            killedRows.map(\.id), [row.id],
            "killHerdrWorkspace(_:) must invoke onHerdrWorkspaceKilled exactly once, with the row it was given"
        )
        XCTAssertEqual(
            closeCallCountWhenInvoked, [0],
            "onHerdrWorkspaceKilled must fire BEFORE workspace.close is sent, not after"
        )
        XCTAssertEqual(
            listSessionsCallCountWhenInvoked, [0],
            "onHerdrWorkspaceKilled must fire BEFORE refresh() runs, not after"
        )
        XCTAssertEqual(
            provider.listSessionsCallCountAtCloseCall, [0],
            "workspace.close must be sent BEFORE refresh() runs, not after"
        )
        XCTAssertEqual(
            provider.listSessionsCallCount, 1,
            "killHerdrWorkspace(_:) must trigger a refresh() afterward -- observed here as listSessions() " +
            "being called once, since refresh() is what calls it"
        )
    }

    // MARK: - CRITICAL negative invariant: unavailable herdr does zero work

    func test_refresh_herdrUnavailable_neverCallsHerdrProviderListSessions() async {
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(id: "test-herdr-socket-1", name: nil, workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        ]
        let model = makeModel(herdrProvider: provider, herdrAvailability: { false })

        await model.refresh()

        XCTAssertEqual(
            provider.listSessionsCallCount, 0,
            "refresh() must never call herdrProvider.listSessions() while the herdr binary itself is " +
            "unresolvable -- a structural, permanent invariant (undetected herdr costs zero work), not a " +
            "Red/Green transition. (An available binary with zero live sockets is a different case: " +
            "listSessions() legitimately runs there and returns [] -- see the sibling 'no sessions' test.)"
        )
    }

    // MARK: - A cancelled refresh() must not overwrite herdrRows from the unavailable branch

    /// A `refresh()` cancelled exactly at the moment its own
    /// `herdrAvailability()` check reports unavailable must not wipe a
    /// previously-populated `herdrRows` -- mirrors the `Task.isCancelled`
    /// guard already protecting the `rows` assignment
    /// (`SessionBrowserModelRefreshCancellationGuardTests`) and the
    /// available-branch `herdrRows` assignment right above it in
    /// `refresh()`. `HerdrAvailabilityCancelBox` lets this test land the
    /// cancellation inside that exact synchronous window, since no
    /// `await` separates the check from the assignment.
    func test_refresh_cancelledDuringUnavailableCheck_doesNotOverwriteHerdrRows() async {
        let provider = FakeHerdrSessionProvider()
        let info = HerdrSessionInfo(id: "test-herdr-socket-1", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        provider.sessionsToReturn = [info]
        let box = HerdrAvailabilityCancelBox()
        let model = makeModel(
            herdrProvider: provider,
            herdrAvailability: {
                if box.cancelOnNextCheck { box.task?.cancel() }
                return box.available
            }
        )

        // Baseline: herdr available with one session, fully resolved
        // (never cancelled).
        await model.refresh()
        XCTAssertEqual(
            model.herdrRows.map(\.id), [info.id],
            "Precondition: baseline herdrRows must be populated before the cancellation below"
        )

        // Second refresh(): herdr goes unavailable, and the
        // availability check itself cancels this very refresh()'s Task
        // from inside the closure -- landing cancellation exactly
        // inside the unavailable branch's own synchronous window.
        box.available = false
        box.cancelOnNextCheck = true
        box.task = Task { await model.refresh() }
        await box.task!.value

        XCTAssertEqual(
            model.herdrRows.map(\.id), [info.id],
            "A refresh() cancelled at its own herdrAvailability() check must not overwrite herdrRows with " +
            "the unavailable branch's [] -- mirrors the guard already protecting the rows/herdrRows " +
            "assignments elsewhere in refresh()"
        )
        XCTAssertEqual(
            provider.listSessionsCallCount, 1,
            "The second refresh() must never reach listSessions() once herdrAvailability() reports " +
            "unavailable, cancelled or not"
        )
    }

    // MARK: - refresh() bounds herdrProvider.listSessions(), degrading to [] on timeout

    /// Characterization/regression guard for the herdr step's bounded
    /// race: against a herdr provider whose `listSessions()` never
    /// completes, `refresh()` must still reach a terminal empty
    /// `herdrRows` within a generous margin over its own bound, exactly
    /// like `SessionDaemonClient.listAllBounded()` already does for the
    /// calyx-session ledger (`SessionDaemonClientBoundedListTests`).
    /// Overrides `daemonQueryBoundTimeoutSeconds` to 1s via the shared
    /// DEBUG timeout seam so this test runs in ~1s instead of burning
    /// the real ~5s default, and doubles as proof that the herdr step
    /// shares that SAME constant rather than a second, invented one.
    func test_refresh_herdrProviderNeverCompletes_herdrRowsDegradeToEmptyWithinBound() async {
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = 1
        let model = makeModel(herdrProvider: NeverCompletingHerdrSessionProvider(), herdrAvailability: { true })

        let start = Date()
        await model.refresh()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            model.herdrRows, [],
            "refresh() must degrade herdrRows to [] rather than hang forever when herdrProvider.listSessions" +
            "() never completes"
        )
        XCTAssertLessThan(
            elapsed, 3.0,
            "The herdr step must be bounded by the shared daemonQueryBoundTimeoutSeconds (overridden to 1s " +
            "here), not the unbounded provider call"
        )
    }

    // MARK: - HerdrSessionRow.displayName (row title, HerdrSessionRowView line 1)
    //
    // Pure display-string derivation factored onto HerdrSessionRow itself
    // (not left inline in the view) so it's testable without a SwiftUI
    // view-inspection dependency -- mirrors SessionBrowserRow
    // .attachButtonLabel/.orphanBadgeLabel's own precedent. No window, no
    // view, exactly this file's own existing style.

    func test_displayName_returnsNameWhenPresent() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr/sessions/work/herdr.sock", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(row.displayName, "work")
    }

    func test_displayName_fallsBackToSocketPathWhenNameIsNil() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr-env-override/herdr.sock", name: nil, workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(row.displayName, "/fixture/config/herdr-env-override/herdr.sock")
    }

    /// The default herdr session's `HerdrSessionInfo.name` is "default" --
    /// herdr's own term for it (`herdr session list --json` reports
    /// "default":true,"name":"default" for exactly this session). This
    /// row's bold title must show that short label, never fall back to
    /// its long, hard-to-read config-root socket path the way an
    /// unnamed (`nil`) row would.
    func test_displayName_defaultSessionRow_showsDefaultLabel_notRawSocketPath() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr/herdr.sock", name: "default", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(row.displayName, "default")
    }

    // MARK: - HerdrAttachGate.decide (status text)
    //
    // Pure decision behind HerdrSessionRowView's status line (line 3),
    // mirroring AgentSidebarGate.decide's own extraction shape
    // (AgentSidebarGateTests.swift). Three cases: counts unknown, counts
    // known with zero workspaces, counts known with at least one
    // workspace. The server row's own button no longer varies with this
    // decision -- see the `createButtonLabel` coverage below.

    func test_decide_countsUnknown_keepsRunningTextUnchanged() {
        XCTAssertEqual(HerdrAttachGate.decide(workspaceCount: nil, paneCount: nil), "Running")
    }

    func test_decide_zeroWorkspaces_statesNothingToAttach() {
        XCTAssertEqual(HerdrAttachGate.decide(workspaceCount: 0, paneCount: 0), "Running · nothing to attach")
    }

    func test_decide_atLeastOneWorkspace_statesWorkspaceAndPaneCounts() {
        XCTAssertEqual(HerdrAttachGate.decide(workspaceCount: 2, paneCount: 5), "Running · 2 workspace(s) · 5 pane(s)")
    }

    // MARK: - HerdrSessionRow.statusLineText (HerdrSessionRowView line 3)
    //
    // Delegates to HerdrAttachGate.decide -- pinned here too, mirroring
    // displayName/attachTabTitle's own row-level precedent above, so a
    // caller reading only this row type (not the gate directly) still
    // sees the delegation covered.

    func test_statusLineText_delegatesToHerdrAttachGate() {
        let rowWithUnknownCounts = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-a", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )
        let rowWithZeroWorkspaces = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-b", name: "empty", workspaceCount: 0, paneCount: 0, agentCount: 0, workspaces: [])
        )
        let rowWithWorkspaces = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-c", name: "personal", workspaceCount: 3, paneCount: 5, agentCount: 2, workspaces: [])
        )

        XCTAssertEqual(rowWithUnknownCounts.statusLineText, "Running")
        XCTAssertEqual(rowWithZeroWorkspaces.statusLineText, "Running · nothing to attach")
        XCTAssertEqual(rowWithWorkspaces.statusLineText, "Running · 3 workspace(s) · 5 pane(s)")
    }

    // MARK: - HerdrSessionRow.createButtonLabel is always "New"
    //
    // Unlike statusLineText above, the server row's own trailing button
    // no longer varies with info.workspaceCount at all -- pressing it
    // always creates a new workspace and opens it, regardless of how
    // many already exist (HerdrAttachOrCreateFlow.createAndOpen). Pinned
    // across the identical three count states statusLineText covers
    // above, to make that independence explicit rather than assumed.

    func test_createButtonLabel_isAlwaysNew_acrossEveryCountState() {
        let rowWithUnknownCounts = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-a", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )
        let rowWithZeroWorkspaces = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-b", name: "empty", workspaceCount: 0, paneCount: 0, agentCount: 0, workspaces: [])
        )
        let rowWithWorkspaces = HerdrSessionRow(
            info: HerdrSessionInfo(id: "socket-c", name: "personal", workspaceCount: 3, paneCount: 5, agentCount: 2, workspaces: [])
        )

        for row in [rowWithUnknownCounts, rowWithZeroWorkspaces, rowWithWorkspaces] {
            XCTAssertEqual(
                HerdrSessionRow.createButtonLabel, "New",
                "the server row's own button must read \"New\" regardless of \(row.info.workspaceCount as Any) " +
                "workspaces"
            )
        }
    }

    // MARK: - HerdrSessionRow.workspaces / HerdrWorkspaceRow
    //
    // HerdrSessionRow.workspaces maps HerdrSessionInfo.workspaces into
    // HerdrWorkspaceRow, carrying the owning socketPath (info.id)
    // alongside each entry, in the SAME order -- never sorted or
    // filtered (HerdrSessionInfo.workspaces's own doc comment already
    // guarantees the order; this only pins that the mapping itself
    // preserves it).

    func test_workspaces_mapsHerdrSessionInfoWorkspaces_carryingTheOwningSocketPath() {
        let workspaceA = HerdrWorkspaceInfo(workspaceID: "w2", activeTabID: "w2:t1", label: "personal", paneCount: 1)
        let workspaceB = HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 2)
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 2, paneCount: 3, agentCount: 0,
                workspaces: [workspaceA, workspaceB]
            )
        )

        XCTAssertEqual(
            row.workspaces.map(\.info.workspaceID), ["w2", "w1"],
            "must preserve HerdrSessionInfo.workspaces's own order"
        )
        XCTAssertEqual(row.workspaces.map(\.socketPath), ["test-herdr-socket-1", "test-herdr-socket-1"])
    }

    // MARK: - HerdrWorkspaceRow.displayLabel (HerdrWorkspaceRowView line 1)

    func test_displayLabel_returnsLabelWhenNonBlank() {
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "Calyx", paneCount: 2)
        )

        XCTAssertEqual(row.displayLabel, "Calyx")
    }

    /// Mirrors `HerdrTabTitlePolicy`'s own blank-after-trimming rule
    /// (`HerdrTabTitlePolicyTests`, not duplicated here) -- a blank label
    /// falls back to the bare workspace id, never an empty title.
    func test_displayLabel_fallsBackToWorkspaceIDWhenLabelIsBlank() {
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "   ", paneCount: 2)
        )

        XCTAssertEqual(row.displayLabel, "w1")
    }

    // MARK: - HerdrWorkspaceRow.paneCountText (HerdrWorkspaceRowView line 2)

    func test_paneCountText_statesThisWorkspacesOwnPaneCount() {
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "Calyx", paneCount: 2)
        )

        XCTAssertEqual(row.paneCountText, "2 pane(s)")
    }

    /// TDD Red (Test 3, see task spec): `paneCountText` must disambiguate
    /// WHICH workspace the pane count belongs to once more than one
    /// workspace can appear in the browser at once, by prefixing the
    /// workspace id whenever `displayLabel` differs from the bare id
    /// (non-blank label) -- same " · " separator
    /// `HerdrAttachGate.decide` already uses for its own workspace/pane
    /// summary line, copied verbatim so a differing dot codepoint can
    /// never cause a false Red here. When the label IS blank,
    /// `displayLabel` already equals the workspace id, so prefixing it
    /// again would just repeat the id -- that branch stays exactly
    /// "N pane(s)", asserted in the same test function (not a separate
    /// one) so this whole function is Red today: the non-blank-label
    /// half fails on `HerdrWorkspaceRow(socketPath:info:)` returning the
    /// current unprefixed "1 pane(s)" instead of "w2F · 1 pane(s)".
    func test_paneCountText_prefixesWorkspaceIDWhenLabelIsNonBlank() {
        let labeled = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w2F", activeTabID: "w2F:t1", label: "work", paneCount: 1)
        )
        XCTAssertEqual(labeled.paneCountText, "w2F · 1 pane(s)")

        let unlabeled = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w2F", activeTabID: "w2F:t1", label: "   ", paneCount: 1)
        )
        XCTAssertEqual(unlabeled.paneCountText, "1 pane(s)")
    }

    // MARK: - HerdrWorkspaceRow.attachButtonLabel / SessionBrowserModel.herdrWorkspaceIsAttachedHere
    //
    // Mirrors SessionBrowserRowAttachButtonLabelTests' own coverage of
    // SessionBrowserRow.attachButtonLabel, for the herdr workspace row's
    // own "Attach"/"Show" button: "Show" once HerdrTabCoordinator already
    // has this workspace open in this window, unchanged "Attach"
    // otherwise -- pressing "Attach" on an already-open workspace still
    // calls the same open path (SessionBrowserWindowController
    // .attachHerdrWorkspace(_:)), which focuses the existing tab rather
    // than opening a second one. The injected herdrWorkspaceIsAttachedHere
    // closure is evaluated by refresh() and stored on each workspace row,
    // so these tests drive it through refresh().

    /// One server ("test-herdr-socket-1") reporting one workspace ("w1").
    private func makeOneWorkspaceProvider() -> FakeHerdrSessionProvider {
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 1, paneCount: 1, agentCount: 0,
                workspaces: [
                    HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1)
                ]
            )
        ]
        return provider
    }

    func test_attachButtonLabel_whenIsHerdrWorkspaceAttachedHereAnswersTrue_isShow() async {
        let model = makeModel(
            herdrProvider: makeOneWorkspaceProvider(), herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in true }
        )

        await model.refresh()

        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].attachButtonLabel, "Show",
            "an already-open workspace's button must read a focus verb (\"Show\"), not \"Attach\""
        )
    }

    /// Sanity/regression companion, mirroring
    /// `SessionBrowserRowAttachButtonLabelTests`' own precedent: passes
    /// already, but catches a future regression that over-broadens the
    /// label (e.g. always "Show").
    func test_attachButtonLabel_whenIsHerdrWorkspaceAttachedHereAnswersFalse_isAttach() async {
        let model = makeModel(
            herdrProvider: makeOneWorkspaceProvider(), herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in false }
        )

        await model.refresh()

        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].attachButtonLabel, "Attach",
            "a not-yet-open workspace's button must keep reading \"Attach\""
        )
    }

    /// Pins the DEFAULT (no `herdrWorkspaceIsAttachedHere` argument
    /// supplied at all): must answer exactly like an unopened workspace,
    /// so every construction with no herdr tab coordinator to ask
    /// behaves exactly like today.
    func test_isHerdrWorkspaceAttachedHere_defaultAnswersFalse() async {
        let model = SessionBrowserModel(
            daemonClient: FakeDaemonClient(), surfaceMap: SessionSurfaceMap(),
            herdrProvider: makeOneWorkspaceProvider(), herdrAvailability: { true }
        )

        await model.refresh()

        XCTAssertFalse(model.herdrRows[0].workspaces[0].isAttachedHere)
    }

    /// Kills swapped-argument/wrong-field bugs the two boolean tests
    /// above cannot see: the injected closure must receive EXACTLY the
    /// row's own workspace id and socket path, in that order.
    func test_isHerdrWorkspaceAttachedHere_passesWorkspaceIDAndSocketPath_inOrder() async {
        var received: (workspaceID: String, socketPath: String)?
        let model = makeModel(
            herdrProvider: makeOneWorkspaceProvider(), herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { workspaceID, socketPath in
                received = (workspaceID: workspaceID, socketPath: socketPath)
                return false
            }
        )

        await model.refresh()

        XCTAssertEqual(received?.workspaceID, "w1")
        XCTAssertEqual(received?.socketPath, "test-herdr-socket-1")
    }

    // MARK: - HerdrSessionRow.attachTabTitle (the Command Palette's "Attach herdr TUI" tab title)
    //
    // Pure derivation factored onto HerdrSessionRow (mirroring
    // displayName/statusLineText's own precedent above) because
    // SessionBrowserWindowController has no test file of its own -- see
    // that type's header comment. Pins the tab-title behavior for both a
    // named session and the default session now that
    // HerdrSessionDiscovery names the latter "default" instead of
    // leaving it nameless (HerdrSessionDiscoveryTests): attaching to it
    // must deliberately open a tab titled "herdr: default", not the
    // bare "herdr" fallback.

    func test_attachTabTitle_namedSession_returnsHerdrPrefixedName() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr/sessions/work/herdr.sock", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(row.attachTabTitle, "herdr: work")
    }

    /// The default herdr session discovers with `name: "default"`
    /// (`HerdrSessionDiscoveryTests`), so attaching to it must open a
    /// tab titled "herdr: default" rather than the bare "herdr"
    /// fallback -- an intentional, informative, consistent-with-named-
    /// sessions side effect of that rename, pinned here rather than left
    /// as an unreviewed accident.
    func test_attachTabTitle_defaultSession_returnsHerdrPrefixedDefaultLabel() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr/herdr.sock", name: "default", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(
            row.attachTabTitle, "herdr: default",
            "Attaching to the default herdr session must open a tab titled \"herdr: default\", not the " +
            "bare \"herdr\" fallback -- deliberate now that the default session carries a real discovered " +
            "name"
        )
    }

    /// `info.name == nil` stays live for the `HERDR_SOCKET_PATH`
    /// env-override candidate (`HerdrSessionDiscovery`'s own doc
    /// comment) -- unlike the default session, that candidate is never
    /// discovery-named, so the bare "herdr" fallback still has a real
    /// row to apply to.
    func test_attachTabTitle_noName_fallsBackToBareHerdr() {
        let row = HerdrSessionRow(
            info: HerdrSessionInfo(id: "/fixture/config/herdr-env-override/herdr.sock", name: nil, workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        )

        XCTAssertEqual(row.attachTabTitle, "herdr")
    }

    // MARK: - showSessionsHeader visibility rule
    //
    // Truth table (`SessionBrowserModel.showSessionsHeader`):
    // `(showRemoteHostsSection || showHerdrSection) && !rows.isEmpty`.
    // `showRemoteHostsSection` needs no separate exercising here -- it's
    // `SessionSettings.persistentSessionsEnabled && !remoteHostCandidates
    // .isEmpty`, and `remoteHostCandidates` stays `[]` unless
    // `refreshRemoteHostCandidates()` is called, which none of these
    // tests do -- so "no sibling section visible" falls out for free
    // without touching `SessionSettings` at all.

    private func makeRunningSessionInfo(id: String) -> SessionInfo {
        SessionInfo(
            id: id, name: nil, cwd: nil, state: .running,
            createdAtMs: 0, attachedClients: 1, pid: 0, meta: [:]
        )
    }

    func test_showSessionsHeader_herdrVisibleAndRowsNonEmpty_isTrue() async {
        let herdrProvider = FakeHerdrSessionProvider()
        herdrProvider.sessionsToReturn = [
            HerdrSessionInfo(id: "test-herdr-socket-1", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        ]
        let daemonClient = FakeDaemonClient()
        daemonClient.sessionsToReturn = [makeRunningSessionInfo(id: "session-a")]
        let model = makeModel(daemonClient: daemonClient, herdrProvider: herdrProvider, herdrAvailability: { true })

        await model.refresh()

        XCTAssertTrue(
            model.showSessionsHeader,
            "With the herdr section visible and at least one calyx-session row, showSessionsHeader must be true"
        )
    }

    func test_showSessionsHeader_noSiblingSectionVisible_isFalse() async {
        let daemonClient = FakeDaemonClient()
        daemonClient.sessionsToReturn = [makeRunningSessionInfo(id: "session-a")]
        let model = makeModel(
            daemonClient: daemonClient, herdrProvider: FakeHerdrSessionProvider(), herdrAvailability: { false }
        )

        await model.refresh()

        XCTAssertFalse(
            model.showSessionsHeader,
            "With no sibling section visible (herdr unavailable, no remote host candidates loaded), " +
            "showSessionsHeader must stay false even with non-empty rows -- the window's own title " +
            "already identifies the list"
        )
    }

    func test_showSessionsHeader_siblingVisibleButRowsEmpty_isFalse() async {
        let herdrProvider = FakeHerdrSessionProvider()
        herdrProvider.sessionsToReturn = [
            HerdrSessionInfo(id: "test-herdr-socket-1", name: "work", workspaceCount: nil, paneCount: nil, agentCount: nil, workspaces: [])
        ]
        // daemonClient omitted -- defaults to an empty FakeDaemonClient(), so rows stays [].
        let model = makeModel(herdrProvider: herdrProvider, herdrAvailability: { true })

        await model.refresh()

        XCTAssertFalse(
            model.showSessionsHeader,
            "With a sibling section visible but zero calyx-session rows, showSessionsHeader must stay " +
            "false -- this is exactly the herdr-rows-but-zero-calyx-rows case where the empty ScrollView " +
            "still renders (SessionBrowserView's friendly emptyState only shows when no sibling section " +
            "is visible either), and a header must never sit above zero rows"
        )
    }

    // MARK: - TDD Red (Test 1, see task spec): HerdrWorkspaceRow carries its own
    // isAttachedHere, and refresh() must produce an OBSERVABLE change when it
    // flips, even though HerdrWorkspaceRow/HerdrSessionRow are Equatable and
    // @Observable does not fire for a reassignment that is `==` to the old
    // value. Today `isAttachedHere` is not a stored property on
    // `HerdrWorkspaceRow` at all -- the caller reads it via
    // `SessionBrowserModel.isHerdrWorkspaceAttachedHere(_:)` instead -- so this
    // test fails to COMPILE (expected failure kind for this test: two unknown
    // members, `HerdrWorkspaceRow.isAttachedHere` and the zero-argument
    // `HerdrWorkspaceRow.attachButtonLabel`, plus `attachButtonLabel` no
    // longer matching the one-argument `attachButtonLabel(isAttachedHere:)`
    // that exists today).

    /// `withObservationTracking`'s `onChange` closure is `@Sendable`; this
    /// class's own `@MainActor` isolation cannot be relied on inside it, so
    /// `fired` is a lock-guarded `@unchecked Sendable` box (mirrors
    /// `SuspendingCountingDaemonClient`'s own `NSLock`-guarded counter in
    /// `SessionBrowserModelRefreshDedupeTests.swift`) rather than a
    /// `@MainActor`-isolated var.
    private final class ObservationFiredBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        var fired: Bool {
            lock.lock(); defer { lock.unlock() }
            return _fired
        }
        func markFired() {
            lock.lock(); defer { lock.unlock() }
            _fired = true
        }
    }

    /// Plain (non-Sendable) box the injected `herdrWorkspaceIsAttachedHere`
    /// closure reads -- mirrors this file's existing `received`-capture
    /// precedent above (`test_isHerdrWorkspaceAttachedHere_passesWorkspaceIDAndSocketPath_inOrder`);
    /// no isolation crossing, since the closure itself runs on the main
    /// actor inside `refresh()`.
    private final class AttachedBox {
        var attached = false
    }

    func test_herdrWorkspaceRow_isAttachedHere_isStoredAndObservablyChanges() async {
        let box = AttachedBox()
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 1, paneCount: 1, agentCount: 0,
                workspaces: [
                    HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1)
                ]
            )
        ]
        let model = makeModel(
            herdrProvider: provider, herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in box.attached }
        )

        await model.refresh()

        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].isAttachedHere, false,
            "before HerdrTabCoordinator has this workspace open, the row's own isAttachedHere must be false"
        )
        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].attachButtonLabel, "Attach",
            "the zero-argument attachButtonLabel must read the row's own stored isAttachedHere"
        )

        let firedBox = ObservationFiredBox()
        withObservationTracking(
            { _ = model.herdrRows },
            onChange: { firedBox.markFired() }
        )

        box.attached = true
        await model.refresh()

        XCTAssertTrue(
            firedBox.fired,
            "flipping isAttachedHere on an otherwise-identical workspace must fire @Observable's own " +
            "change notification -- Equatable reassignment-to-an-equal-value does NOT fire it, so " +
            "isAttachedHere must live on the row itself, not be derived from an external closure at " +
            "read time"
        )
        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].isAttachedHere, true,
            "after refresh() re-evaluates herdrWorkspaceIsAttachedHere, the row's own isAttachedHere " +
            "must reflect the new answer"
        )
        XCTAssertEqual(
            model.herdrRows[0].workspaces[0].attachButtonLabel, "Show",
            "once isAttachedHere is true, the zero-argument attachButtonLabel must read \"Show\""
        )
    }

    // MARK: - TDD Red (herdr TUI-client integration): a herdr TUI client running
    // inside one of THIS Calyx instance's own panes must mark every workspace
    // row of that client's session as attached via `.tuiPane(surfaceID:)`, even
    // though `herdrWorkspaceIsAttachedHere` (the native-tab closure) has no
    // opinion on it at all. `HerdrWorkspaceRow.attachment`/
    // `SessionBrowserModel.init(resolveTUISurface:)` do not exist yet -- this
    // fails to COMPILE (unresolved `HerdrTUIClient`, `attachment`,
    // `resolveTUISurface` argument).

    func test_refresh_tuiClientResolvesToOwnSurface_marksEveryWorkspaceRowAttachedViaTUIPane() async {
        let surfaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 2, paneCount: 2, agentCount: 0,
                workspaces: [
                    HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1),
                    HerdrWorkspaceInfo(workspaceID: "w2", activeTabID: "w2:t1", label: "personal", paneCount: 1),
                ],
                tuiClients: [
                    HerdrTUIClient(socketPath: "test-herdr-socket-1", surfaceHint: .surfaceID(surfaceID))
                ]
            )
        ]
        let model = makeModel(
            herdrProvider: provider, herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in false },
            resolveTUISurface: { hint in
                hint == .surfaceID(surfaceID) ? surfaceID : nil
            }
        )

        await model.refresh()

        let workspaces = model.herdrRows[0].workspaces
        XCTAssertEqual(workspaces.count, 2)
        for workspace in workspaces {
            XCTAssertEqual(
                workspace.attachment, .tuiPane(surfaceID: surfaceID),
                "every workspace row of a session with a resolving herdr TUI client must be marked " +
                ".tuiPane(surfaceID:), regardless of which workspace the TUI client itself is attached to"
            )
            XCTAssertTrue(workspace.isAttachedHere)
            XCTAssertEqual(workspace.attachButtonLabel, "Show")
        }
    }

    func test_refresh_tuiClientDoesNotResolve_fallsBackToNativeTabClosure() async {
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 2, paneCount: 2, agentCount: 0,
                workspaces: [
                    HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1),
                    HerdrWorkspaceInfo(workspaceID: "w2", activeTabID: "w2:t1", label: "personal", paneCount: 1),
                ],
                tuiClients: [
                    HerdrTUIClient(
                        socketPath: "test-herdr-socket-1",
                        surfaceHint: .surfaceID(UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)
                    )
                ]
            )
        ]

        // Resolver returns nil for every hint, and the native-tab closure
        // also answers false -- rows must fall back to `.none` / "Attach".
        let modelFalling = makeModel(
            herdrProvider: provider, herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in false },
            resolveTUISurface: { _ in nil }
        )
        await modelFalling.refresh()
        for workspace in modelFalling.herdrRows[0].workspaces {
            XCTAssertEqual(workspace.attachment, .none)
            XCTAssertFalse(workspace.isAttachedHere)
            XCTAssertEqual(workspace.attachButtonLabel, "Attach")
        }

        // Same non-resolving TUI client, but the native-tab closure now
        // answers true -- rows must fall back to `.nativeTab` / "Show".
        let modelNativeTab = makeModel(
            herdrProvider: provider, herdrAvailability: { true },
            herdrWorkspaceIsAttachedHere: { _, _ in true },
            resolveTUISurface: { _ in nil }
        )
        await modelNativeTab.refresh()
        for workspace in modelNativeTab.herdrRows[0].workspaces {
            XCTAssertEqual(workspace.attachment, .nativeTab)
            XCTAssertTrue(workspace.isAttachedHere)
            XCTAssertEqual(workspace.attachButtonLabel, "Show")
        }
    }

    // MARK: - TDD Red (defect A): a native tab must win over the session's
    // shared .tuiPane attachment, PER WORKSPACE -- today, once ANY herdr TUI
    // client resolves to a surface in this process, `HerdrSessionRow.init(
    // info:tuiSurfaceID:isAttachedHere:)` marks EVERY workspace row
    // `.tuiPane(surfaceID:)` unconditionally, even one that also has its own
    // open native tab (`herdrWorkspaceIsAttachedHere` answering true for it).
    // That is wrong: Show on that workspace's row must reveal its own native
    // tab, not the (possibly different) workspace the TUI happens to be
    // showing. Required precedence: `.nativeTab` wins per workspace; `.tuiPane`
    // applies only to a workspace with no native tab of its own. This is a
    // runtime assertion failure today, not a compile failure -- the shape
    // already exists, just with the wrong precedence.

    func test_refresh_nativeTabWinsOverTUIPane_perWorkspace() async {
        let surfaceID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let provider = FakeHerdrSessionProvider()
        provider.sessionsToReturn = [
            HerdrSessionInfo(
                id: "test-herdr-socket-1", name: "work", workspaceCount: 2, paneCount: 2, agentCount: 0,
                workspaces: [
                    HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1),
                    HerdrWorkspaceInfo(workspaceID: "w2", activeTabID: "w2:t1", label: "personal", paneCount: 1),
                ],
                tuiClients: [
                    HerdrTUIClient(socketPath: "test-herdr-socket-1", surfaceHint: .surfaceID(surfaceID))
                ]
            )
        ]
        let model = makeModel(
            herdrProvider: provider, herdrAvailability: { true },
            // Only w1 has an open native tab; w2 has none.
            herdrWorkspaceIsAttachedHere: { workspaceID, _ in workspaceID == "w1" },
            resolveTUISurface: { hint in hint == .surfaceID(surfaceID) ? surfaceID : nil }
        )

        await model.refresh()

        let workspaces = model.herdrRows[0].workspaces
        XCTAssertEqual(workspaces.count, 2)
        guard
            let w1 = workspaces.first(where: { $0.info.workspaceID == "w1" }),
            let w2 = workspaces.first(where: { $0.info.workspaceID == "w2" })
        else {
            XCTFail("expected both w1 and w2 rows")
            return
        }
        XCTAssertEqual(
            w1.attachment, .nativeTab,
            "w1 has its own open native tab -- that must win over the session's shared TUI-pane " +
            "attachment, so Show on w1 reveals w1's own tab, not the TUI pane"
        )
        XCTAssertEqual(
            w2.attachment, .tuiPane(surfaceID: surfaceID),
            "w2 has no native tab of its own -- it falls back to the session's TUI-pane attachment"
        )
        XCTAssertEqual(w1.attachButtonLabel, "Show")
        XCTAssertEqual(w2.attachButtonLabel, "Show")
    }

    // MARK: - TDD Red (defect B): attaching a .tuiPane workspace row must send
    // herdr workspace.focus before asking the window controller to focus the
    // pane -- today `attachHerdrWorkspace(_:)` is synchronous and only ever
    // invokes `onHerdrWorkspaceAttachRequested`; it never sends anything to
    // the herdr provider first, and is not `async` at all. Fails to COMPILE
    // today: no `HerdrSessionProviderProtocol.focusWorkspace(workspaceID:
    // socketPath:)` requirement exists yet (only the fake's own extra method
    // above), and `SessionBrowserModel.attachHerdrWorkspace(_:)` is not
    // `async`, so `await model.attachHerdrWorkspace(row)` fails to type-check
    // against a synchronous, non-throwing method.

    func test_attachHerdrWorkspace_tuiPaneRow_sendsWorkspaceFocusThenRequestsAttach() async {
        let surfaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let provider = FakeHerdrSessionProvider()
        let model = makeModel(herdrProvider: provider, herdrAvailability: { false })
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1),
            attachment: .tuiPane(surfaceID: surfaceID)
        )

        // Captured AT closure-invocation time (not after attachHerdrWorkspace
        // returns), mirroring test_killHerdrWorkspace_sendsCloseForExactlyThatWorkspace_thenRefreshes's
        // own ordering-proof shape: pins that workspace.focus was already
        // sent BEFORE onHerdrWorkspaceAttachRequested fires, not merely that
        // both eventually happened.
        var requestedRow: HerdrWorkspaceRow?
        var focusCallCountWhenClosureInvoked: [Int] = []
        model.onHerdrWorkspaceAttachRequested = { attachedRow in
            requestedRow = attachedRow
            focusCallCountWhenClosureInvoked.append(provider.focusWorkspaceCalls.count)
        }

        await model.attachHerdrWorkspace(row)

        XCTAssertEqual(
            provider.focusWorkspaceCalls.map(\.workspaceID), ["w1"],
            "attaching a .tuiPane row must send workspace.focus for exactly that workspace"
        )
        XCTAssertEqual(provider.focusWorkspaceCalls.map(\.socketPath), ["test-herdr-socket-1"])
        XCTAssertEqual(
            focusCallCountWhenClosureInvoked, [1],
            "onHerdrWorkspaceAttachRequested must fire AFTER workspace.focus was sent, not before"
        )
        XCTAssertEqual(
            requestedRow?.id, row.id,
            "onHerdrWorkspaceAttachRequested must still be invoked with the row, so the window " +
            "controller can go on to focus the pane"
        )
    }

    /// Sanity/regression companion: a `.nativeTab` (or `.none`) row must not
    /// send `workspace.focus` at all -- that RPC only makes sense for a herdr
    /// TUI client, which only ever backs `.tuiPane`.
    func test_attachHerdrWorkspace_nativeTabRow_doesNotSendWorkspaceFocus() async {
        let provider = FakeHerdrSessionProvider()
        let model = makeModel(herdrProvider: provider, herdrAvailability: { false })
        let row = HerdrWorkspaceRow(
            socketPath: "test-herdr-socket-1",
            info: HerdrWorkspaceInfo(workspaceID: "w1", activeTabID: "w1:t1", label: "work", paneCount: 1),
            attachment: .nativeTab
        )

        var requestedRow: HerdrWorkspaceRow?
        model.onHerdrWorkspaceAttachRequested = { requestedRow = $0 }

        await model.attachHerdrWorkspace(row)

        XCTAssertTrue(
            provider.focusWorkspaceCalls.isEmpty,
            "a .nativeTab row must never send workspace.focus"
        )
        XCTAssertEqual(requestedRow?.id, row.id)
    }
}
