//
//  CalyxWindowControllerSetTabTitleTests.swift
//  CalyxTests
//
//  Missing observer: ghostty's
//  set_tab_title keybind (`GHOSTTY_ACTION_SET_TAB_TITLE`) is not routed
//  anywhere in `GhosttyActionRouter.handleAction` at all (falls to
//  `default:`) -- pressing it does nothing.
//  `CalyxWindowController.processSetTabTitle(tab:title:)` is the intended
//  receiver once a `.ghosttySetTabTitle` case/observer exists; today it is
//  an intentional no-op stub (see its own doc comment in
//  CalyxWindowController.swift), so every test below that expects
//  `tab.titleOverride` to change fails.
//
//  `ghostty_action_set_title_s` (ghostty.h) is reused for both `set_title`
//  and `set_tab_title` (same payload shape, just a different union tag),
//  so the only field is `title: const char*` -> Swift `String`, matching
//  `processSetTabTitle`'s own `title: String` parameter.
//
//  `processSetTabTitle` is called directly, not via a posted
//  `.ghosttySetTabTitle` notification: its signature already carries the
//  resolved `tab`, decoupled from notification routing (that routing, via
//  findTab(for:), is later-pass work for the not-yet-written
//  `handleSetTabTitleNotification` -- mirrors
//  `CalyxWindowControllerCloseTabTests`'s established split between
//  "processX called directly" now and "Notification post (Tactic A)" once
//  the observer exists).
//
//  Coverage-gap follow-up: the direct-call tests above only ever exercised
//  `processSetTabTitle` itself, never `handleSetTabTitleNotification`'s own
//  `findTab(for:)` routing or the real `.ghosttySetTabTitle` notification
//  wiring -- and, as this investigation itself proved, having a
//  fully-implemented `process*` body is NOT sufficient: `registerNotificationObservers()`
//  never actually registered an observer for `.ghosttySetTabTitle`, so
//  ghostty's set_tab_title keybind stayed silently inert regardless. The
//  "Notification post (Tactic A)" section below closes both gaps and
//  covers the fix (mirrors `CalyxWindowControllerRendererHealthTests`'s
//  own identically-named section).

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerSetTabTitleTests: XCTestCase {

    /// `processSetTabTitle` has no ownership/routing logic of its own
    /// (that lives in the not-yet-written notification handler), so the
    /// tab under test does not need to belong to this controller's
    /// `windowSession` at all. Mirrors
    /// `CalyxWindowControllerRendererHealthTests.makeController()`.
    private func makeController() -> CalyxWindowController {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    /// `processSetTabTitle(tab:title: "Renamed")` must set
    /// `tab.titleOverride` to that exact string.
    func test_processSetTabTitle_setsTitleOverride() {
        let controller = makeController()
        let tab = Tab(title: "Shell")
        XCTAssertNil(tab.titleOverride, "Precondition: a freshly created Tab must have no titleOverride")

        controller.processSetTabTitle(tab: tab, title: "Renamed")

        XCTAssertEqual(
            tab.titleOverride,
            "Renamed",
            "processSetTabTitle must set tab.titleOverride to the given title"
        )
    }

    /// An empty string must CLEAR `titleOverride` back to `nil` (ghostty's
    /// own "empty resets to the default" convention), not set it to `""`.
    func test_processSetTabTitle_emptyString_clearsTitleOverrideToNil() {
        let controller = makeController()
        let tab = Tab(title: "Shell", titleOverride: "Old Custom Title")

        controller.processSetTabTitle(tab: tab, title: "")

        XCTAssertNil(
            tab.titleOverride,
            "An empty title must clear titleOverride to nil, not set it to an empty string"
        )
    }

    // MARK: - Notification post ("Tactic A")

    /// Unlike `makeController()` above, `findTab(for:)` needs a real
    /// `SurfaceRegistry` entry -- mirrors `CalyxWindowControllerCloseWindowTests
    /// .SurfaceOwningFixture`.
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
        let tab: Tab
    }

    private func makeSurfaceOwningFixture() -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView, tab: tab)
    }

    /// Posting the real `.ghosttySetTabTitle` notification for a surface
    /// THIS window owns must set that surface's owning tab's
    /// `titleOverride` -- exercises `handleSetTabTitleNotification`'s
    /// `findTab(for:)` routing and `userInfo["title"]` extraction end to
    /// end, not just `processSetTabTitle` called directly.
    func test_ghosttySetTabTitle_postedForOwnSurface_setsTitleOverride() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertNil(fixture.tab.titleOverride, "Precondition: fixture tab starts with no titleOverride")

        NotificationCenter.default.post(
            name: .ghosttySetTabTitle,
            object: fixture.surfaceView,
            userInfo: ["title": "Renamed via Notification"]
        )

        XCTAssertEqual(
            fixture.tab.titleOverride,
            "Renamed via Notification",
            "Posting .ghosttySetTabTitle for a surface this window owns must set that surface's owning tab's titleOverride"
        )
    }

    /// Regression guard: posting `.ghosttySetTabTitle` for a surface NO
    /// controller's `windowSession` owns must leave every tab's
    /// `titleOverride` untouched -- depends on
    /// `handleSetTabTitleNotification`'s own `guard let (owningTab, _) =
    /// findTab(for:)` actually gating the dispatch, catching a future
    /// implementation that skips the ownership check.
    func test_ghosttySetTabTitle_postedForSurfaceNoWindowOwns_doesNotChangeTitleOverride() {
        // A live fixture must exist so at least one real observer is
        // registered to (correctly) ignore this notification -- otherwise
        // this test would trivially pass even if findTab(for:)'s ownership
        // check were removed entirely.
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)

        NotificationCenter.default.post(
            name: .ghosttySetTabTitle,
            object: orphanSurfaceView,
            userInfo: ["title": "Should Not Apply"]
        )

        XCTAssertNil(
            fixture.tab.titleOverride,
            "Posting .ghosttySetTabTitle for a surface no window owns must not change any tab's titleOverride"
        )
    }

    // MARK: - Background-tab (detached) surfaces

    /// `SplitContainerView` detaches non-active tabs' SurfaceViews from the
    /// window, so their `view.window` is nil. The fixture surface is in no
    /// window -- that state. An OSC 0/2 title for the tab's focused leaf
    /// must still set `tab.title`; a `view.window === self.window`
    /// ownership guard silently drops it.
    func test_setTitleNotification_forSurfaceDetachedFromWindow_isStillHandled() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertNil(fixture.surfaceView.window,
                     "Precondition: the fixture surface must be detached from any window (background-tab state)")
        XCTAssertNotEqual(fixture.tab.title, "Detached Title", "Precondition: tab title differs from the posted one")

        NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: fixture.surfaceView,
            userInfo: ["title": "Detached Title"]
        )

        XCTAssertEqual(fixture.tab.title, "Detached Title",
                       ".ghosttySetTitle for a surface owned by this window's tab (but detached from the window) " +
                       "must still update that tab's title")
    }

    /// Same detached state for OSC 7: `.ghosttySetPwd` must still update
    /// the owning tab's `pwd`.
    func test_setPwdNotification_forSurfaceDetachedFromWindow_isStillHandled() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertNil(fixture.surfaceView.window,
                     "Precondition: the fixture surface must be detached from any window (background-tab state)")
        XCTAssertNotEqual(fixture.tab.pwd, "/Users/dev/detached-pwd", "Precondition: tab pwd differs from the posted one")

        NotificationCenter.default.post(
            name: .ghosttySetPwd,
            object: fixture.surfaceView,
            userInfo: ["pwd": "/Users/dev/detached-pwd"]
        )

        XCTAssertEqual(fixture.tab.pwd, "/Users/dev/detached-pwd",
                       ".ghosttySetPwd for a surface owned by this window's tab (but detached from the window) " +
                       "must still update that tab's pwd")
    }

    // MARK: - Window title vs. background tab

    private struct TwoTabFixture {
        let controller: CalyxWindowController
        let window: CalyxWindow
        let activeTab: Tab
        let activeSurface: SurfaceView
        let backgroundTab: Tab
        let backgroundSurface: SurfaceView
    }

    /// Two tabs in one group, each owning its own registry-backed surface;
    /// `activeTabID` is the FIRST tab, so the second is a background tab.
    private func makeTwoTabFixture() -> TwoTabFixture {
        let activeRegistry = SurfaceRegistry()
        let activeLeafID = UUID()
        let activeSurface = SurfaceView(frame: .zero)
        activeRegistry._testInsert(view: activeSurface, id: activeLeafID)
        let activeTab = Tab(splitTree: SplitTree(leafID: activeLeafID), registry: activeRegistry)

        let bgRegistry = SurfaceRegistry()
        let bgLeafID = UUID()
        let bgSurface = SurfaceView(frame: .zero)
        bgRegistry._testInsert(view: bgSurface, id: bgLeafID)
        let bgTab = Tab(splitTree: SplitTree(leafID: bgLeafID), registry: bgRegistry)

        let group = TabGroup(name: "Default", tabs: [activeTab, bgTab], activeTabID: activeTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoTabFixture(controller: controller, window: window, activeTab: activeTab,
                             activeSurface: activeSurface, backgroundTab: bgTab, backgroundSurface: bgSurface)
    }

    /// A title for a background tab's focused surface must update that
    /// tab's `title` but must NOT overwrite the window title (which belongs
    /// to the active tab).
    func test_setTitleNotification_forBackgroundTab_updatesThatTabTitleButNotWindowTitle() {
        let fixture = makeTwoTabFixture()
        XCTAssertTrue(fixture.controller.window === fixture.window, "Precondition: controller owns the fixture window")
        fixture.window.title = "Sentinel Window Title"
        let activeTitleBefore = fixture.activeTab.title
        XCTAssertNotEqual(activeTitleBefore, "BG Title", "Precondition")

        NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: fixture.backgroundSurface,
            userInfo: ["title": "BG Title"]
        )

        XCTAssertEqual(fixture.backgroundTab.title, "BG Title",
                       "Background tab's title must be updated")
        XCTAssertEqual(fixture.activeTab.title, activeTitleBefore,
                       "Active tab's title must be unchanged")
        XCTAssertEqual(fixture.window.title, "Sentinel Window Title",
                       "A background tab's title change must not overwrite the window title")
    }

    /// A title for the active tab's focused surface updates both the tab
    /// title and the window title (no titleOverride set).
    func test_setTitleNotification_forActiveTab_updatesWindowTitle() {
        let fixture = makeTwoTabFixture()
        XCTAssertTrue(fixture.controller.window === fixture.window, "Precondition: controller owns the fixture window")
        XCTAssertNil(fixture.activeTab.titleOverride, "Precondition: no titleOverride")
        fixture.window.title = "Sentinel Window Title"
        let bgTitleBefore = fixture.backgroundTab.title

        NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: fixture.activeSurface,
            userInfo: ["title": "FG Title"]
        )

        XCTAssertEqual(fixture.activeTab.title, "FG Title")
        XCTAssertEqual(fixture.window.title, "FG Title",
                       "The active tab's title change must update the window title")
        XCTAssertEqual(fixture.backgroundTab.title, bgTitleBefore,
                       "Background tab's title must be unchanged")
    }
}
