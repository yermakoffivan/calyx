//
//  CockpitTabCreateCwdWiringTests.swift
//  CalyxTests
//
//  Regression coverage for GitHub issue #43: MCP `tab_create`'s `cwd`
//  argument used to be silently dropped whenever persistent sessions
//  were OFF (the default, i.e. the common case). Pre-fix,
//  `CalyxWindowController.createManagedSurface` took THREE
//  independently-settable cwd parameters -- `passthroughPwd`,
//  `spawnCwd`, `inheritedCwd` -- and every call site hardcoded
//  `passthroughPwd: nil` unconditionally while threading its real cwd
//  only into `spawnCwd`; the `.passthrough` branch (persistent sessions
//  off) read ONLY `passthroughPwd`, and never read `spawnCwd` again once
//  it had fed the `SessionSpawnContext` used to DECIDE passthrough vs.
//  persistent -- so an explicit override an MCP caller passed to
//  `tab_create` never reached the spawned shell.
//
//  This file was written for that bug, driving
//  `performCreateNewTab` end-to-end via `resolveNewTabSpawnCwd
//  (override:)`, an INSTANCE method with its own `?? activeTab?.pwd`
//  fallback. Both are gone: `resolveNewTabSpawnCwd(override:)` became
//  the `static func normalizedCwdOverride(_ override: String?) ->
//  String?` exercised directly (with its own dedicated unit tests) in
//  `CockpitAppAccessSeamTests.swift`, and `createManagedSurface`
//  collapsed to the two-parameter `explicitCwd`/`sessionFallbackCwd`
//  API described below. Cases a-e below describe and pin that CURRENT,
//  post-fix API -- none of `resolveNewTabSpawnCwd`, `passthroughPwd`,
//  `spawnCwd`-as-a-`createManagedSurface`-parameter, or `inheritedCwd`
//  exist anywhere in the codebase any more. Full pre/post-fix history
//  and reasoning lives in `createManagedSurface`'s own doc comment in
//  CalyxWindowController.swift; deliberately not reproduced here beyond
//  the summary above -- a copy of that formula would rot the moment the
//  real body's parameters change again, exactly as this bug's own
//  parameter collapse just proved (see this same diff's edit to
//  `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests.swift` for
//  the identical lesson learned about a verbatim body copy).
//
//  An override-less new tab observing `nil` (today, `explicitCwd ==
//  nil`) is NOT itself a bug -- it means "let libghostty inherit the
//  currently-focused surface's own live OSC 7 pwd"
//  (ghostty/src/apprt/surface.zig's `window-inherit-working-directory`
//  default), the correct behavior for an ordinary override-less
//  Cmd+T/`tab_create`. The bug was narrower: an EXPLICIT override had no
//  way to reach the shell at all. See test b's own doc comment below for
//  why turning that `nil` into a resolved path unconditionally would
//  itself be a regression, not a fix.
//
//  CURRENT API: `createManagedSurface(tab:app:config:explicitCwd:
//  sessionFallbackCwd:origin:host:)` combines its two cwd parameters
//  ONCE into `sessionCwd = explicitCwd ?? sessionFallbackCwd ??
//  NSHomeDirectory()`, fed to BOTH branches -- a caller can no longer
//  wire one branch and forget the other, because neither branch has its
//  own independent cwd parameter left to forget.
//  - `explicitCwd`: an explicit directive, honored by both branches when
//    non-nil; `nil` means "no directive" (`.passthrough` leaves
//    ghostty's `working_directory` unset, so libghostty performs the
//    live OSC-7 inheritance described above). `performCreateNewTab`
//    passes `Self.normalizedCwdOverride(spawnCwd)` here.
//  - `sessionFallbackCwd`: deliberately ignored by `.passthrough` (which
//    has the real FFI-level inheritance above instead); exists only to
//    give a `.persistent` plan a concrete `--cwd` when there is no
//    explicit directive. `performCreateNewTab`/`performSplit`/
//    `performCreateNewGroup` all pass `livePaneCwd(of:in:)` here -- the
//    FOCUSED/SOURCE pane's own live `SurfacePropertyStore` cwd, NOT
//    `tab.pwd` directly -- so that turning persistent sessions on
//    doesn't change which directory a new tab/split opens in relative to
//    `.passthrough`'s own live-inheritance answer. Test e below pins
//    exactly this distinction for `performCreateNewTab`.
//
//  SEAMS DRIVEN (both already exist in this worktree; see their own doc
//  comments in CalyxWindowController.swift for the full rationale):
//  - `performCreateNewTab(app:inheritedConfig:host:spawnCwd:)` --
//    `createNewTab`'s body taking `app` explicitly rather than
//    resolving `GhosttyAppController.shared.app` internally (`nil` in
//    this test host), mirrors `CockpitAppAccessSeamTests`'
//    `performSplit`.
//  - `_createManagedSurfaceHookForTesting: (() -> UUID?)?` --
//    substitutes the created surface's id and short-circuits BEFORE the
//    real ghostty FFI call. Installed in EVERY test below, even the
//    `.passthrough` ones: without it, an uninstalled hook falls through
//    to a REAL `tab.registry.createSurface(app: dummyApp, ...)` call
//    against a fake pointer, confirmed elsewhere in this codebase to
//    hang/crash the XCTest process (see `AppDelegateAttachWindowTests`'
//    header).
//  - `_createManagedSurfacePwdObserverForTesting: ((String?) -> Void)?`
//    -- THE ASSERTION TARGET. Fires immediately before that same hook
//    short-circuit, in BOTH branches: `explicitCwd` on `.passthrough`,
//    `sessionCwd` on `.persistent` (branch-dependent; see "CURRENT API"
//    above) -- i.e. exactly the pwd value that would otherwise reach
//    `SurfaceRegistry.createSurface`, whichever branch fires.
//
//  CRITICAL: reaching `.persistent` needs BOTH the settings flag AND a
//  non-nil `host`. `SessionSpawnPlanner.plan` first guards
//  `SessionSettings.persistentSessionsEnabled`, then -- for a LOCAL
//  context (`context.host == nil`) ONLY -- guards
//  `SessionBinaryResolver().resolve()`. In `CalyxTests`, `resolve()`
//  ALWAYS returns `nil`: this scheme has no `CALYX_SESSION_BIN`
//  environment variable (only `CalyxUITests` does, see project.yml),
//  and the `CalyxTests` target has no `TEST_HOST`, so `Bundle.main`
//  resolves to the `xctest` runner's own bundle, which has no
//  `Resources/bin/calyx-session`. A LOCAL context therefore ALWAYS
//  falls through to `.passthrough` in this test host, even with
//  `persistentSessionsEnabled = true`. A non-nil `host` skips that
//  local-resolver guard entirely (see `SessionSpawnPlanner.plan`'s own
//  doc comment), so it is the ONLY way to reach `.persistent` here.
//  Tests d and e below therefore both set `persistentSessionsEnabled =
//  true` AND pass `host: "devbox.example.com"` -- either one alone
//  silently falls back to `.passthrough`, exercising the WRONG branch
//  while still (mis)reporting a pass. This is not a hypothetical risk:
//  `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests
//  .test_createManagedSurface_localHost_sessionRefsEntryCarriesNilHost`
//  (this file's own required-reading precedent) sets
//  `persistentSessionsEnabled = true` but passes no `host`, silently
//  falls through to `.passthrough` (which never touches `sessionRefs`
//  at all), and its `XCTAssertNil(tab.sessionRefs[createdID]?.host)`
//  then passes VACUOUSLY -- an empty-dictionary lookup is `nil`
//  regardless of whether the host-threading logic under test works at
//  all. DO NOT "simplify" `host` away from tests d/e below for the same
//  reason.
//
//  `performSplit` and `performCreateNewGroup` gained the identical
//  `sessionFallbackCwd: livePaneCwd(of:in:)` wiring in this same diff,
//  covered instead by `CockpitSplitAndGroupCwdWiringTests.swift` -- see
//  that file for both. Both branches are reachable, and covered, for
//  both call sites: unlike this file's own tests d/e, which reach
//  `.persistent` by giving `context.host` a non-nil value (neither
//  method has a `host:` parameter to do the same), that file's own
//  `.persistent` coverage for both instead reaches it via a
//  `CALYX_SESSION_BIN` environment-variable override -- the same
//  production `SessionBinaryResolver` test-injection idiom several
//  other files in this suite already rely on -- rather than a `host:`
//  argument, since neither method has one. (An earlier version of that
//  file's coverage instead gave `performSplit`/`performCreateNewGroup`
//  their own `resolver:` DI parameter; that parameter existed on no
//  production call path and has since been removed, exactly the kind
//  of test-only production surface this project's rules forbid.) See
//  that file's own header for the full mechanism.
//
//  Coverage (table from the issue #43 investigation; a/c/e were the
//  failing cases -- all now pass, and pin the fix against regression):
//  a. `persistentSessionsEnabled = false`,
//     `performCreateNewTab(spawnCwd: "/tmp")` -> observed pwd must be
//     `"/tmp"`. THE BUG: failed pre-fix, observing `nil`.
//  b. `persistentSessionsEnabled = false`,
//     `performCreateNewTab()` (no override) -> observed pwd must stay
//     `nil` (libghostty inheritance). REGRESSION PIN: already passed
//     pre-fix, must keep passing.
//  c. `persistentSessionsEnabled = false`,
//     `performCreateNewTab(spawnCwd: "  /tmp \n")` -> observed pwd must
//     be the TRIMMED `"/tmp"`. Failed pre-fix, same reason as (a).
//     `MCPCockpitBridge.handleTabCreate` already trims/expands/stat-
//     validates its own `cwd` argument before ever reaching
//     `normalizedCwdOverride`, so this specific raw-whitespace shape
//     can't actually arrive via a live MCP `tab_create` call today --
//     this pins `normalizedCwdOverride`'s own trimming contract for
//     other in-module callers instead of a live MCP scenario.
//  d. `persistentSessionsEnabled = true`, `host: "devbox.example.com"`,
//     `performCreateNewTab(spawnCwd: "/tmp")` -> observed pwd must be
//     `"/tmp"`. REGRESSION PIN: already passed pre-fix (this path was
//     never hardcoded the way `.passthrough`'s was).
//  e. `persistentSessionsEnabled = true`, `host: "devbox.example.com"`,
//     active tab's `pwd = "/Users/dev/stale-tab-pwd"`, its
//     `splitTree.focusedLeafID`'s own `SurfacePropertyStore.shared` cwd
//     = `"/Users/dev/live-pane-cwd"`, `performCreateNewTab()` (no
//     override) -> observed pwd must be the focused pane's own live
//     cwd, `"/Users/dev/live-pane-cwd"`, NOT the tab's stale `pwd`.
//     Failed pre-fix, observing `"/Users/dev/stale-tab-pwd"`: turning
//     persistent sessions on must not change which directory an
//     override-less new tab opens in relative to `.passthrough`, which
//     gets the focused pane's LIVE OSC 7 cwd straight from libghostty,
//     not Calyx's own possibly-stale `Tab.pwd` snapshot.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CockpitTabCreateCwdWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.CockpitTabCreateCwdWiringTests"

    /// Never dereferenced: `_createManagedSurfaceHookForTesting`
    /// intercepts every surface creation this test drives through
    /// `performCreateNewTab` (via `createManagedSurface`) before the
    /// real ghostty FFI call that would otherwise use this value --
    /// mirrors `CockpitAppAccessSeamTests`'/
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'
    /// identical `dummyApp`.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    /// `persistentSessionsEnabled` itself is deliberately NOT set here:
    /// this file's five cases split between `false` (a/b/c) and `true`
    /// (d/e), so each test sets it explicitly at the top of its own
    /// body instead -- see this file's header table.
    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    /// `SurfacePropertyStore.shared._stopObserving()` below is NOT
    /// optional, unlike most of this suite's teardowns: case (e) below
    /// calls `SurfacePropertyStore.shared.startObserving()` directly on
    /// the real, process-wide singleton, rather than a private
    /// `SurfacePropertyStore()` instance the way
    /// `SurfacePropertyStoreTests.swift` does specifically so it can
    /// `_stopObserving()` safely (see that file's own tearDown comment
    /// for the identical hazard). `CockpitSplitAndGroupCwdWiringTests`'s
    /// two tests share this exact pattern and cross-reference this same
    /// comment for the same reason.
    /// `_testReset()` only clears `entries` -- it does NOT touch the
    /// `NotificationCenter` registration or `isObserving`; only
    /// `_stopObserving()` does. Without it, `SurfacePropertyStore.shared`
    /// would stay subscribed to `.ghosttySetTitle`/`.ghosttySetPwd`/
    /// `.calyxSurfaceDestroyed` for the rest of the `CalyxTests`
    /// process: any LATER, unrelated test that fabricates a
    /// `SurfaceView` via `SurfaceRegistry._testInsert`/`createSurface`
    /// (both register into the same global `SurfaceLocator.shared` this
    /// store's handlers resolve views through) and posts its own
    /// `.ghosttySetPwd`/`.ghosttySetTitle` for its own, unrelated
    /// purpose would silently populate `SurfacePropertyStore.shared
    /// .entries` -- the exact store production `CalyxWindowController
    /// .livePaneCwd` reads with NO injection seam -- producing an
    /// order-dependent, hard-to-reproduce failure in whichever test
    /// happens to run after this one.
    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        SurfacePropertyStore.shared._stopObserving()
        SurfacePropertyStore.shared._testReset()
        SurfaceLocator.shared._testReset()
        super.tearDown()
    }

    private func makeController() -> (controller: CalyxWindowController, tab: Tab) {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return (controller, tab)
    }

    /// `performCreateNewTab` creates its new tab as a private, freshly
    /// constructed `Tab()` and never hands a reference back to the
    /// caller -- this recovers it via `windowSession.activeGroup
    /// .activeTab`, which IS that new tab once `performCreateNewTab`
    /// has run to completion (`group.activeTabID = tab.id` is one of
    /// its last steps), purely so a `.persistent`-branch test can look
    /// up the `sessionRefs` entry keyed by the surfaceID its own
    /// `_createManagedSurfaceHookForTesting` hook returned, to
    /// unregister it from `SessionSurfaceMap.shared` afterward --
    /// mirrors `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'
    /// identical cleanup shape. Returns `nil` harmlessly if
    /// `performCreateNewTab` never actually reached that point (e.g. an
    /// early-return bug), since a never-run `.persistent` branch never
    /// registered anything to clean up either.
    private func createdSessionID(controller: CalyxWindowController, surfaceID: UUID) -> String? {
        controller.windowSession.activeGroup?.activeTab?.sessionRefs[surfaceID]?.sessionID
    }

    // MARK: - .passthrough branch (persistent sessions OFF, the default)

    /// THE BUG (issue #43), now fixed. See this file's header for the
    /// full mechanism: pre-fix, `performCreateNewTab` resolved this
    /// override via `resolveNewTabSpawnCwd(override:)` but only fed the
    /// result into `spawnCwd:`, hardcoding `passthroughPwd: nil` -- and
    /// `.passthrough` read ONLY `passthroughPwd`. Today,
    /// `performCreateNewTab` passes `Self.normalizedCwdOverride(spawnCwd)`
    /// as `explicitCwd:`, which `.passthrough` reads directly. Failed
    /// pre-fix, observing `nil` instead of `"/tmp"`; pins the fix now.
    func test_passthroughBranch_explicitOverride_reachesSpawnedShell() {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, _) = makeController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        controller.performCreateNewTab(app: dummyApp, spawnCwd: "/tmp")

        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewTab must reach createManagedSurface exactly once for a plain new tab")
        XCTAssertEqual(observedPwd, "/tmp",
                       "an explicit Cockpit tab_create cwd override must reach the spawned shell's pwd even when " +
                       "persistent sessions are off -- silently dropping it defeats the entire point of the " +
                       "caller specifying a cwd")
    }

    /// REGRESSION PIN -- already passed pre-fix, and must keep passing
    /// now that the bug above is fixed. `explicitCwd == nil` is not
    /// itself a bug: it means "let libghostty inherit the
    /// currently-focused surface's own LIVE OSC 7 pwd"
    /// (ghostty/src/apprt/surface.zig's
    /// `window-inherit-working-directory` default), which is exactly
    /// the correct behavior for an override-less new tab -- ghostty's
    /// own live inheritance is more accurate than anything Calyx could
    /// resolve independently (see test e's doc comment below for why
    /// Calyx's own best proxy, `SurfacePropertyStore`, is a Calyx-side
    /// COPY of that same live report, not an independent source of
    /// truth, and is only needed at all on the `.persistent` branch,
    /// which has no FFI-level inheritance to fall back on). A fix that
    /// always threaded the resolved override into BOTH branches
    /// unconditionally -- the "obvious" naive fix for test a above --
    /// would have turned this `nil` into a concrete, resolved-at-
    /// spawn-time path (pre-fix, `resolveNewTabSpawnCwd`'s own fallback
    /// was `activeTab?.pwd`, exactly the possibly-stale value test e's
    /// contract exists to avoid on the OTHER branch), regressing every
    /// plain Cmd+T. Today's fix instead keeps `explicitCwd` genuinely
    /// `nil` for an override-less call (`Self.normalizedCwdOverride(nil)
    /// == nil`), so this contract holds without that risk.
    func test_passthroughBranch_noOverride_preservesLibghosttyInheritance() {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, _) = makeController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        controller.performCreateNewTab(app: dummyApp)

        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewTab must reach createManagedSurface exactly once for a plain new tab")
        XCTAssertNil(observedPwd,
                    "an override-less new tab must keep passing nil through to the spawned shell so libghostty " +
                    "performs its own live OSC-7-based working-directory inheritance -- resolving this to a " +
                    "concrete path would regress every plain Cmd+T from ghostty's own live inheritance back to " +
                    "Calyx's own, possibly stale, last-known pwd")
    }

    /// Same bug as test a, with a leading/trailing-whitespace-and-
    /// newline-padded override (plausible from
    /// an agent-constructed payload built from raw shell output, e.g.
    /// `$(pwd)`) -- `Self.normalizedCwdOverride(_:)` trims before use
    /// (see its own doc comment and `CockpitAppAccessSeamTests.swift`'s
    /// dedicated unit tests of that contract), so a correct fix must
    /// observe the TRIMMED path. NOTE: `MCPCockpitBridge.handleTabCreate`
    /// (the real `tab_create` MCP tool handler) already trims, expands
    /// `~`, and stat-validates its `cwd` argument before ever calling
    /// `access.createTab(groupName:cwd:)`, so a raw, untrimmed string
    /// like this can't actually arrive here via a live MCP call today --
    /// this pins `normalizedCwdOverride`'s own trimming contract for
    /// OTHER in-module callers (and against regression), not a scenario
    /// a real MCP agent can currently trigger. Failed pre-fix, for the
    /// same reason as test a.
    func test_passthroughBranch_whitespacePaddedOverride_trimmedAndReachesSpawnedShell() {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, _) = makeController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        controller.performCreateNewTab(app: dummyApp, spawnCwd: "  /tmp \n")

        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewTab must reach createManagedSurface exactly once for a plain new tab")
        XCTAssertEqual(observedPwd, "/tmp",
                       "a leading/trailing-whitespace-or-newline cwd override must be trimmed by " +
                       "normalizedCwdOverride AND still reach the spawned shell's pwd -- not silently dropped, " +
                       "the way an unconditional passthroughPwd: nil hardcoding used to drop test a's override " +
                       "pre-fix")
    }

    // MARK: - .persistent branch (persistent sessions ON + remote host --
    // see this file's header for why `host` is load-bearing here)

    /// REGRESSION PIN -- already passed pre-fix. `createManagedSurface`'s
    /// `.persistent` branch computes `sessionCwd = explicitCwd ??
    /// sessionFallbackCwd ?? NSHomeDirectory()`; `performCreateNewTab`
    /// passes `Self.normalizedCwdOverride(spawnCwd)` as `explicitCwd`,
    /// which for a non-blank override like `"/tmp"` is non-nil, so
    /// `sessionCwd` reduces to exactly that normalized override
    /// regardless of `sessionFallbackCwd`. (Pre-fix, this same reduction
    /// needed a THIRD parameter, `inheritedCwd`, reasoned away because
    /// `performCreateNewTab` never passed one -- that parameter no
    /// longer exists at all, collapsed away by this same diff; see this
    /// file's header.) This path was never hardcoded away the way
    /// `.passthrough`'s `explicitCwd` used to be (pre-fix,
    /// `passthroughPwd: nil` unconditionally), so it already threaded an
    /// explicit override through correctly even before this fix -- this
    /// test exists so a fix for tests a/c above can't silently break
    /// this already-working path (e.g. by swapping which branch gets the
    /// override, or making `explicitCwd` conditional on the branch).
    func test_persistentBranch_explicitOverride_reachesSpawnedShell() {
        SessionSettings.persistentSessionsEnabled = true
        let (controller, _) = makeController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        controller.performCreateNewTab(app: dummyApp, host: "devbox.example.com", spawnCwd: "/tmp")
        defer {
            if let sessionID = createdSessionID(controller: controller, surfaceID: newSurfaceID) {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewTab must reach createManagedSurface exactly once for a plain new tab")
        XCTAssertEqual(observedPwd, "/tmp",
                       "an explicit cwd override must reach the persistent-session spawn's pwd -- this path " +
                       "already worked before this fix and must keep working now that the .passthrough bug " +
                       "above has been fixed")
    }

    /// THE BUG, second angle (issue #43), now fixed. Turning a plain,
    /// override-less `tab_create` into a `.persistent` spawn must NOT
    /// change which directory the new tab opens in relative to
    /// persistent sessions being off. With sessions off (test b above),
    /// `.passthrough`'s `nil` lets libghostty inherit the FOCUSED
    /// surface's own LIVE OSC 7 pwd -- NOT the tab's own possibly-stale
    /// `pwd` field (`Tab.pwd` updates whenever ANY pane belonging to the
    /// tab reports a `.ghosttySetPwd` -- `handleSetPwdNotification` only
    /// resolves which TAB owns the reporting surface, with no check on
    /// whether that surface is the tab's currently-focused pane; a tab
    /// with multiple panes, or one whose focus moved elsewhere since the
    /// last report, can easily have a `pwd` that no longer matches its
    /// now-focused pane's actual live directory).
    /// `.persistent` has no such FFI-level inheritance available to it
    /// -- `sessionCwd` is always threaded explicitly into
    /// `createSurface(...pwd:...)`, since the spawned `calyx-session
    /// attach --create` command's cwd must be fixed at spawn time -- so
    /// its fallback (no explicit override given, i.e. whatever
    /// `sessionFallbackCwd` resolves to) must resolve to the SAME
    /// directory `.passthrough` would have used: the focused leaf's own
    /// recorded cwd (`SurfacePropertyStore.shared.cwd(for:)`, Calyx's
    /// own copy of that same live OSC 7 report), NOT `livePaneCwd`'s own
    /// last-resort degrade-to-`tab?.pwd` (consulted only when
    /// `SurfacePropertyStore` has no entry for the focused surface at
    /// all -- not the case here, since this test seeds one below).
    /// Failed pre-fix, observing the stale tab-level pwd instead of the
    /// focused pane's own live cwd -- pre-fix, `resolveNewTabSpawnCwd`'s
    /// own fallback read `activeTab?.pwd` directly, with no per-surface
    /// store to prefer at all.
    func test_persistentBranch_noOverride_usesFocusedPaneLiveCwd_notStaleTabPwd() {
        SessionSettings.persistentSessionsEnabled = true
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/stale-tab-pwd"

        let focusedSurfaceID = UUID()
        let focusedView = SurfaceView(frame: .zero)
        tab.registry._testInsert(view: focusedView, id: focusedSurfaceID)
        tab.splitTree = SplitTree(leafID: focusedSurfaceID)

        SurfacePropertyStore.shared.startObserving()
        NotificationCenter.default.post(
            name: .ghosttySetPwd, object: focusedView, userInfo: ["pwd": "/Users/dev/live-pane-cwd"]
        )
        XCTAssertEqual(SurfacePropertyStore.shared.cwd(for: focusedSurfaceID), "/Users/dev/live-pane-cwd",
                       "precondition: the focused leaf's own live cwd must be recorded before driving performCreateNewTab")

        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }
        var observerCallCount = 0
        var observedPwd: String?
        controller._createManagedSurfacePwdObserverForTesting = { pwd in
            observerCallCount += 1
            observedPwd = pwd
        }

        controller.performCreateNewTab(app: dummyApp, host: "devbox.example.com")
        defer {
            if let sessionID = createdSessionID(controller: controller, surfaceID: newSurfaceID) {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        XCTAssertEqual(observerCallCount, 1,
                       "precondition: performCreateNewTab must reach createManagedSurface exactly once for a plain new tab")
        XCTAssertEqual(observedPwd, "/Users/dev/live-pane-cwd",
                       "persistent sessions being on must not change which directory an override-less new tab " +
                       "opens in: it must fall back to the focused pane's own live cwd -- the SAME directory " +
                       ".passthrough would have used via libghostty's inheritance -- not the tab's possibly-stale " +
                       "pwd field")
    }

    // MARK: - Return value (Worktree Tasks)

    /// `performCreateNewTab` returns the new tab's leaf surface ID so a
    /// caller (Worktree Tasks) can type into exactly that pane.
    func test_performCreateNewTab_returnsNewTabsFirstLeafID() throws {
        SessionSettings.persistentSessionsEnabled = false
        let (controller, originalTab) = makeController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let returned = controller.performCreateNewTab(app: dummyApp, spawnCwd: "/tmp")

        let newTab = try XCTUnwrap(controller.windowSession.activeGroup?.activeTab)
        XCTAssertNotEqual(newTab.id, originalTab.id, "precondition: a new tab must be active")
        XCTAssertEqual(newTab.splitTree.allLeafIDs().first, newSurfaceID, "precondition: the hook's ID is the leaf")
        XCTAssertEqual(returned, newSurfaceID)
    }
}
