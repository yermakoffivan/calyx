//
//  SettingsPaneWindowFitTests.swift
//  CalyxTests
//
//  A Settings pane taller than SettingsLayout.maxPaneContentHeight stops
//  there and scrolls inside its scroll view, and fitting the window to a
//  pane keeps its top edge and x/width fixed while never letting its
//  bottom edge come closer than SettingsLayout.screenBottomMargin to the
//  screen's visible bottom (except when the minimum height forces it).
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SettingsPaneWindowFitTests: XCTestCase {

    // MARK: - Constants

    func test_constants_haveApprovedValues() {
        XCTAssertEqual(SettingsLayout.maxPaneContentHeight, 640)
        XCTAssertEqual(SettingsLayout.screenBottomMargin, 48)
    }

    // MARK: - fittedWindowFrame

    private func fit(_ current: NSRect, target: CGFloat, minimum: CGFloat = 250,
                     visible: NSRect, margin: CGFloat = 48) -> NSRect {
        SettingsPaneContentViewController.fittedWindowFrame(
            current: current, targetFrameHeight: target, minimumFrameHeight: minimum,
            visibleFrame: visible, bottomMargin: margin)
    }

    func test_fittedWindowFrame_fitsOnScreen_usesTargetHeightKeepingTopXAndWidth() {
        // top = 900, target 500 -> bottom 400, well above 0 + 48.
        let r = fit(NSRect(x: 100, y: 600, width: 560, height: 300), target: 500,
                    visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r, NSRect(x: 100, y: 400, width: 560, height: 500))
    }

    func test_fittedWindowFrame_wouldOverflowBottom_stopsAtMarginAboveVisibleBottom() {
        // top = 700, target 900 -> would reach -200; clamp bottom to 48 -> height 652.
        let r = fit(NSRect(x: 100, y: 400, width: 560, height: 300), target: 900,
                    visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r, NSRect(x: 100, y: 48, width: 560, height: 652))
    }

    func test_fittedWindowFrame_shrinking_usesTargetHeightKeepingTop() {
        // top = 800, target 300 -> bottom 500.
        let r = fit(NSRect(x: 100, y: 100, width: 560, height: 700), target: 300,
                    visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r, NSRect(x: 100, y: 500, width: 560, height: 300))
    }

    func test_fittedWindowFrame_offsetScreen_appliesRulesRelativeToVisibleFrame() {
        // Display left/below: visible minY = -1000, so bottom limit = -952.
        // top = -300, target 900 -> would reach -1200; clamp -> height 652.
        let visible = NSRect(x: -1920, y: -1000, width: 1920, height: 1000)
        let r = fit(NSRect(x: -1500, y: -600, width: 560, height: 300), target: 900, visible: visible)
        XCTAssertEqual(r, NSRect(x: -1500, y: -952, width: 560, height: 652))

        // Same display, target that fits: top -300, target 400 -> bottom -700.
        let fits = fit(NSRect(x: -1500, y: -600, width: 560, height: 300), target: 400, visible: visible)
        XCTAssertEqual(fits, NSRect(x: -1500, y: -700, width: 560, height: 400))
    }

    func test_fittedWindowFrame_topNearScreenBottom_floorWins() {
        // top = 200; margin-limited height would be 152 < minimum 250 -> 250.
        let r = fit(NSRect(x: 100, y: 50, width: 560, height: 150), target: 900, minimum: 250,
                    visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r, NSRect(x: 100, y: -50, width: 560, height: 250))
    }

    func test_fittedWindowFrame_exactlyAtBoundary_usesTargetHeight() {
        // top = 748, target 700 -> bottom exactly 48.
        let r = fit(NSRect(x: 100, y: 448, width: 560, height: 300), target: 700,
                    visible: NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r, NSRect(x: 100, y: 48, width: 560, height: 700))
    }

    func test_fittedWindowFrame_noScreen_usesTargetHeightKeepingTopXAndWidth() {
        let r = SettingsPaneContentViewController.fittedWindowFrame(
            current: NSRect(x: 100, y: 400, width: 560, height: 300), targetFrameHeight: 900,
            minimumFrameHeight: 250, visibleFrame: nil, bottomMargin: 48)
        XCTAssertEqual(r, NSRect(x: 100, y: -200, width: 560, height: 900))
    }

    // MARK: - Pane height cap

    private func makePane(contentHeight: CGFloat, width: CGFloat = 560, inset: CGFloat = 24)
        -> SettingsPaneContentViewController {
        let filler = NSView()
        filler.translatesAutoresizingMaskIntoConstraints = false
        let h = filler.heightAnchor.constraint(equalToConstant: contentHeight)
        h.priority = .required
        h.isActive = true
        let stack = NSStackView(views: [filler])
        stack.orientation = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        return SettingsPaneContentViewController(contentStack: stack, width: width, contentInset: inset)
    }

    func test_tallPane_capsPreferredHeightAtMaxPaneContentHeight() {
        // 720 + 2*24 = 768 natural height, above maxPaneContentHeight.
        let pane = makePane(contentHeight: 720)
        pane.loadViewIfNeeded()
        XCTAssertEqual(pane.preferredContentSize.height, SettingsLayout.maxPaneContentHeight, accuracy: 0.5)
    }

    func test_shortPane_usesNaturalContentHeight() {
        let pane = makePane(contentHeight: 300)
        pane.loadViewIfNeeded()
        XCTAssertEqual(pane.preferredContentSize.height, 348, accuracy: 0.5)
    }

    func test_pane_preferredWidthEqualsWidth() {
        let pane = makePane(contentHeight: 720, width: 560)
        pane.loadViewIfNeeded()
        XCTAssertEqual(pane.preferredContentSize.width, 560)
    }

    // MARK: - Fitting a real window

    /// A titled window hosting a tall pane, ordered in without becoming
    /// key, with its top edge at `top` on its screen.
    private func makeWindow(top: CGFloat) throws -> (NSWindow, SettingsPaneContentViewController, NSRect) {
        let pane = makePane(contentHeight: 720)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        guard let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            throw XCTSkip("No screen available to place the window on.")
        }
        window.setFrame(NSRect(x: visible.minX + 100, y: visible.minY + top - 300,
                               width: 560, height: 300), display: false)
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        guard let screenVisible = window.screen?.visibleFrame else {
            throw XCTSkip("Window is not on any screen.")
        }
        return (window, pane, screenVisible)
    }

    func test_fitWindow_lowOnScreen_keepsTopAndStopsAboveBottomMargin() throws {
        let (window, pane, visible) = try makeWindow(top: 400)
        let top = window.frame.maxY
        pane.contentDidChange()
        XCTAssertGreaterThanOrEqual(window.frame.minY,
                                    visible.minY + SettingsLayout.screenBottomMargin - 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        XCTAssertLessThan(window.contentRect(forFrameRect: window.frame).height,
                          SettingsLayout.maxPaneContentHeight)
    }

    func test_fitWindow_roomOnScreen_usesMaxPaneContentHeight() throws {
        let (window, pane, visible) = try makeWindow(top: 640 + 300)
        guard visible.height >= 640 + 300 else {
            throw XCTSkip("Screen too short to leave room for the full pane height.")
        }
        let top = window.frame.maxY
        pane.contentDidChange()
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height,
                       SettingsLayout.maxPaneContentHeight, accuracy: 0.5)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
    }

    // MARK: - Every frame during a scenario

    /// Records every frame `window` is resized to while it is attached.
    @MainActor
    private final class FrameRecorder {
        private(set) var frames: [NSRect] = []
        private var token: NSObjectProtocol?

        init(_ window: NSWindow) {
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.frames.append(window.frame)
                }
            }
        }

        func stop() {
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
        }
    }

    /// Asserts that every recorded frame keeps its bottom edge at least
    /// `screenBottomMargin` above `visible.minY` and its top edge at `top`.
    private func assertEveryFrame(_ recorder: FrameRecorder, top: CGFloat, visible: NSRect,
                                  _ step: String, line: UInt = #line) {
        for frame in recorder.frames {
            XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + SettingsLayout.screenBottomMargin - 0.5,
                                        "\(step): frame \(frame) below the margin", line: line)
            XCTAssertEqual(frame.maxY, top, accuracy: 0.5, "\(step): frame \(frame) moved the top edge",
                           line: line)
        }
    }

    // MARK: - Real Settings window

    /// The real Settings window and its tab view controller, with a
    /// teardown that restores the selected tab, frame and visibility once
    /// NSTabViewController's asynchronous resize for the restored tab has
    /// settled, so later tests see the shared window as it was.
    private func settingsWindow() throws -> (NSWindow, NSTabViewController) {
        let window = try XCTUnwrap(SettingsWindowController.shared.window)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        let savedIndex = tabs.selectedTabViewItemIndex
        let savedFrame = window.frame
        let wasVisible = window.isVisible
        addTeardownBlock { [self] in
            tabs.selectedTabViewItemIndex = savedIndex
            waitForSettledResize(window, tabs)
            window.setFrame(savedFrame, display: false)
            // Panes measured at this test's window position are measured
            // again for the restored frame (the selected pane) or with no
            // window (the others), so no later test sees those values.
            for item in tabs.tabViewItems {
                (item.viewController as? SettingsPaneContentViewController)?.contentDidChange()
            }
            waitForSettledResize(window, tabs)
            if !wasVisible { window.orderOut(nil) }
        }
        return (window, tabs)
    }

    /// Spins the run loop until the window's content height matches the
    /// selected pane's `preferredContentSize` height, which is what
    /// NSTabViewController's asynchronous resize after a selection or show
    /// produces, and has kept matching with no frame change for
    /// `settleInterval`, so a later asynchronous resize is not missed.
    /// Fails after `timeout`.
    private func waitForSettledResize(_ window: NSWindow, _ tabs: NSTabViewController,
                                      timeout: TimeInterval = 2,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let settleInterval: TimeInterval = 0.1
        let deadline = Date().addingTimeInterval(timeout)
        func settled() -> Bool {
            guard let pane = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController else { return false }
            let contentHeight = window.contentRect(forFrameRect: window.frame).height
            return abs(contentHeight - pane.preferredContentSize.height) <= 0.5
        }
        var lastFrame = window.frame
        var stableSince: Date? = settled() ? Date() : nil
        while Date() < deadline {
            if let stableSince, Date().timeIntervalSince(stableSince) >= settleInterval { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if window.frame != lastFrame || !settled() {
                lastFrame = window.frame
                stableSince = settled() ? Date() : nil
            } else if stableSince == nil {
                stableSince = Date()
            }
        }
        XCTAssertTrue(settled(), "window never resized to the selected pane's preferredContentSize",
                      file: file, line: line)
    }

    /// NSTabViewController resizes the window to the selected pane's
    /// `preferredContentSize` after `tabView(_:didSelect:)`, keeping the top
    /// edge fixed. Selecting Agents (then again once loaded) with the
    /// window's top too low for its full height must still leave the
    /// bottom edge above the screen-bottom margin once that resize ran.
    func test_tabSwitch_toAgentsLowOnScreen_keepsBottomAboveMargin() throws {
        let (window, tabs) = try settingsWindow()
        let titles = tabs.tabViewItems.map(\.label)
        let agents = try XCTUnwrap(titles.firstIndex(of: SettingsPane.agents.title))
        let other = try XCTUnwrap(titles.firstIndex(of: SettingsPane.appearance.title))
        let agentsPane = try XCTUnwrap(tabs.tabViewItems[agents].viewController)

        window.orderFront(nil)
        guard let visible = window.screen?.visibleFrame else {
            throw XCTSkip("Settings window is not on any screen.")
        }
        let margin = SettingsLayout.screenBottomMargin

        // Measure the shorter pane's frame height with room to spare, then
        // put the top just 20pt above where that pane fits: the shorter
        // pane fits there and Agents (capped at maxPaneContentHeight) does not.
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 100, y: visible.maxY))
        tabs.selectedTabViewItemIndex = other
        waitForSettledResize(window, tabs)
        let otherFrameHeight = window.frame.height
        let agentsFullFrameHeight = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: window.frame.width, height: SettingsLayout.maxPaneContentHeight)).height
        let top = visible.minY + margin + otherFrameHeight + 20
        guard agentsFullFrameHeight > otherFrameHeight + 20, top <= visible.maxY else {
            throw XCTSkip("Screen or pane heights leave no position where only Agents overflows.")
        }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 100, y: top))
        XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY + margin - 0.5,
                                    "precondition: the shorter pane fits at the chosen top")

        func assertFitted(_ step: String, line: UInt = #line) {
            XCTAssertGreaterThanOrEqual(window.frame.minY, visible.minY + margin - 0.5,
                                        "\(step): bottom edge below the margin", line: line)
            XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "\(step): top edge moved", line: line)
        }

        // The shared controller lives for the whole test process, so Agents
        // is loaded by this selection only if no earlier test loaded it.
        let firstStep = agentsPane.isViewLoaded
            ? "first Agents selection (already loaded)"
            : "first Agents selection (loads the pane)"
        let recorder = FrameRecorder(window)
        defer { recorder.stop() }

        tabs.selectedTabViewItemIndex = agents
        waitForSettledResize(window, tabs)
        assertFitted(firstStep)

        tabs.selectedTabViewItemIndex = other
        waitForSettledResize(window, tabs)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "top edge moved selecting the shorter pane")

        tabs.selectedTabViewItemIndex = agents
        waitForSettledResize(window, tabs)
        assertFitted("second Agents selection (already loaded)")
        XCTAssertFalse(recorder.frames.isEmpty, "selecting Agents from the shorter pane never resized the window")
        assertEveryFrame(recorder, top: top, visible: visible, "during the tab switches")
    }

    /// Showing the Settings window low on its screen with a pane whose
    /// `preferredContentSize` was measured while the window was hidden
    /// must still leave the bottom edge above the screen-bottom margin
    /// once NSTabViewController's resize on show has run.
    func test_show_lowOnScreen_keepsBottomAboveMargin() throws {
        let (window, tabs) = try settingsWindow()
        let agents = try XCTUnwrap(tabs.tabViewItems.map(\.label).firstIndex(of: SettingsPane.agents.title))

        window.orderOut(nil)
        tabs.selectedTabViewItemIndex = agents
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            throw XCTSkip("No screen available to show the Settings window on.")
        }
        // 300pt tall with its top at minY + 400: on screen, and shorter
        // than Agents' fitted height there (at least 352), so showing it
        // must resize it.
        window.setFrame(NSRect(x: visible.minX + 100, y: visible.minY + 100,
                               width: window.frame.width, height: 300), display: false)
        let recorder = FrameRecorder(window)
        defer { recorder.stop() }
        window.orderFront(nil)
        waitForSettledResize(window, tabs)

        let screenVisible = try XCTUnwrap(window.screen?.visibleFrame)
        XCTAssertGreaterThanOrEqual(window.frame.minY,
                                    screenVisible.minY + SettingsLayout.screenBottomMargin - 0.5)
        XCTAssertFalse(recorder.frames.isEmpty, "showing the window never resized it")
        assertEveryFrame(recorder, top: window.frame.maxY, visible: screenVisible, "showing the window")
    }

    // MARK: - Fresh tab view controller

    /// A Settings-style window hosting a fresh toolbar NSTabViewController
    /// whose panes have never been loaded: a short pane, then a tall one.
    private func makeTabWindow(tallFirst: Bool) throws
        -> (NSWindow, NSTabViewController, short: Int, tall: Int) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.paneWidth, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes = [("Short", makePane(contentHeight: 400)), ("Tall", makePane(contentHeight: 720))]
        for (label, pane) in tallFirst ? panes.reversed() : panes {
            let item = NSTabViewItem(viewController: pane)
            item.label = label
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: label)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        addTeardownBlock { window.orderOut(nil) }
        return (window, tabs, tallFirst ? 1 : 0, tallFirst ? 0 : 1)
    }

    /// First show of a window whose selected pane is tall and was measured
    /// with no window: NSTabViewController's resize when the window is
    /// ordered in must already respect the screen-bottom margin.
    func test_freshTabs_firstShowLowOnScreen_everyFrameKeepsBottomAboveMargin() throws {
        let (window, tabs, _, _) = try makeTabWindow(tallFirst: true)
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else {
            throw XCTSkip("No screen available to show the window on.")
        }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 100, y: visible.minY + 400))
        let recorder = FrameRecorder(window)
        defer { recorder.stop() }
        // Ordering in may move the window (not resize it) to keep it on
        // screen; the top edge is checked against where it ends up.
        window.orderFront(nil)
        waitForSettledResize(window, tabs)

        let screenVisible = try XCTUnwrap(window.screen?.visibleFrame)
        XCTAssertFalse(recorder.frames.isEmpty, "showing the window never resized it")
        assertEveryFrame(recorder, top: window.frame.maxY, visible: screenVisible, "first show")
    }

    /// Switching to a tall pane that was never loaded, and again once it
    /// is loaded, with the window's top too low for its full height: the
    /// window grows to exactly the screen-bottom margin and no frame on
    /// the way passes it or moves the top edge.
    func test_freshTabs_tabSwitchLowOnScreen_fitsToMarginOnEveryFrame() throws {
        let (window, tabs, short, tall) = try makeTabWindow(tallFirst: false)
        window.orderFront(nil)
        guard let visible = window.screen?.visibleFrame else {
            throw XCTSkip("Window is not on any screen.")
        }
        waitForSettledResize(window, tabs)
        let margin = SettingsLayout.screenBottomMargin
        let top = visible.minY + margin + window.frame.height + 20
        let tallFullFrameHeight = window.frameRect(forContentRect: NSRect(
            x: 0, y: 0, width: window.frame.width, height: SettingsLayout.maxPaneContentHeight)).height
        guard tallFullFrameHeight > window.frame.height + 20, top <= visible.maxY else {
            throw XCTSkip("Screen or pane heights leave no position where only the tall pane overflows.")
        }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 100, y: top))
        let tallPane = try XCTUnwrap(tabs.tabViewItems[tall].viewController)
        XCTAssertFalse(tallPane.isViewLoaded, "precondition: the tall pane has never been loaded")

        let recorder = FrameRecorder(window)
        defer { recorder.stop() }
        for step in ["first selection (loads the pane)", "second selection (already loaded)"] {
            tabs.selectedTabViewItemIndex = tall
            waitForSettledResize(window, tabs)
            XCTAssertEqual(window.frame.minY, visible.minY + margin, accuracy: 0.5,
                           "\(step): window not fitted down to the margin")
            XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "\(step): top edge moved")
            tabs.selectedTabViewItemIndex = short
            waitForSettledResize(window, tabs)
        }
        assertEveryFrame(recorder, top: top, visible: visible, "tab switches")
        recorder.stop()

        // The tall pane's size is still limited from the low position. With
        // the window moved to the top of the screen, selecting it again must
        // grow the window back to maxPaneContentHeight.
        let highTop = visible.maxY
        guard highTop - tallFullFrameHeight >= visible.minY + margin else {
            throw XCTSkip("Screen too short to show the tall pane at maxPaneContentHeight.")
        }
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 100, y: highTop))
        tabs.selectedTabViewItemIndex = tall
        waitForSettledResize(window, tabs)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height,
                       SettingsLayout.maxPaneContentHeight, accuracy: 0.5,
                       "re-selected with room: not grown back to maxPaneContentHeight")
        XCTAssertEqual(window.frame.maxY, highTop, accuracy: 0.5, "re-selected with room: top edge moved")
    }
}
