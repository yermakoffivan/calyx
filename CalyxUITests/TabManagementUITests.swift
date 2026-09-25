// TabManagementUITests.swift
// CalyxUITests

import XCTest

final class TabManagementUITests: CalyxUITestCase {

    func test_initialState_hasOneTab() {
        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 1, "Initial state should have exactly one tab")
    }

    func test_createNewTab_addsTab() {
        createNewTabViaMenu()

        // Wait for the second tab to appear
        Thread.sleep(forTimeInterval: 1.0)

        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 2, "Should have two tabs after creating a new one")
    }

    func test_closeTab_removesTab() {
        // Create a second tab
        createNewTabViaMenu()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have two tabs before closing")

        // Close the active tab via menu
        closeTabViaMenu()

        // Wait for tab removal
        Thread.sleep(forTimeInterval: 1.0)

        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 1, "Should have one tab after closing")
    }

    func test_closeLastTab_closesWindow() {
        // Close the only tab
        closeTabViaMenu()

        // The window should close and the app should terminate
        waitForNonExistence(app.windows.firstMatch)
    }

    /// Regression guard for a macOS 27 bug: double-clicking the EMPTY area
    /// of the tab strip (right of the last tab, left of the "+" button)
    /// stopped creating a new tab. See `WheelBridgeView.handleDoubleClick`
    /// in `Calyx/Views/TabBar/TabBarContentView.swift` -- the "+" button
    /// (a separate SwiftUI control) is unaffected, which made this easy
    /// to miss.
    func test_doubleClickEmptyTabBarArea_createsNewTab() {
        let initialTabCount = countTabBarTabs()
        XCTAssertEqual(initialTabCount, 1, "Should start with exactly one tab")

        let window = app.windows.firstMatch
        XCTAssertTrue(waitFor(window), "App window should exist")
        let initialWindowFrame = window.frame

        let lastTab = tabBarTabsQuery().allElementsBoundByIndex.last
        XCTAssertNotNil(lastTab, "Should find at least one tab element")
        guard let lastTab else { return }
        let lastTabFrame = lastTab.frame

        // The "+" button's `accessibilityIdentifier(AccessibilityID.TabBar
        // .newTabButton)` modifier (applied after `.buttonStyle(.glass)`)
        // does not reach the accessibility tree as its own identifier on
        // macOS 27: `app.debugDescription` shows this button surfaces as
        // `Button, identifier: 'calyx.tabBar', label: 'Add'` -- the same
        // identifier as the tab strip's `ScrollView` container, with the
        // system-supplied "Add" label being the only way to disambiguate
        // it. (Raw literal, matching this file's own convention -- see
        // `tabBarTabsQuery()`/`groupHeadersQuery()` above -- since the
        // production `AccessibilityID` enum lives in `Calyx/Helpers/`,
        // which is not part of the CalyxUITests target's sources.)
        let newTabButton = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "calyx.tabBar", "Add"))
            .firstMatch
        XCTAssertTrue(waitFor(newTabButton), "New tab '+' button should exist")
        let newTabButtonFrame = newTabButton.frame

        // 40pt to the right of the last tab's trailing edge, vertically
        // centered on the tab, but clamped to stay left of the "+"
        // button's frame AND the 40pt `Spacer` immediately preceding it
        // (which has its own, unaffected, `onTapGesture(count: 2)`), so
        // the point can only land inside the NSScrollView-backed empty
        // strip area that the bug actually affects.
        let preferredX = lastTabFrame.maxX + 40
        let safeMargin: CGFloat = 4
        let spacerWidth: CGFloat = 40
        let targetX = min(preferredX, newTabButtonFrame.minX - spacerWidth - safeMargin)
        let targetY = lastTabFrame.midY

        XCTAssertLessThan(
            targetX, newTabButtonFrame.minX - spacerWidth,
            "Chosen click point must stay left of the '+' button AND its preceding Spacer"
        )
        XCTAssertGreaterThan(
            targetX, lastTabFrame.maxX,
            "Chosen click point must stay right of the last tab's trailing edge (i.e. empty strip area)"
        )
        XCTAssertFalse(
            newTabButtonFrame.contains(CGPoint(x: targetX, y: targetY)),
            "Chosen click point must not be inside the '+' button's frame"
        )

        print("[test_doubleClickEmptyTabBarArea_createsNewTab] initialWindowFrame=\(initialWindowFrame) " +
              "lastTabFrame=\(lastTabFrame) newTabButtonFrame=\(newTabButtonFrame) " +
              "target=(\(targetX), \(targetY))")

        // `XCUIElement.frame` and `XCUIElement.coordinate` share the same
        // top-left-origin, absolute-screen-point space; anchoring on the
        // window (not `app`, which has no real frame and crashes here --
        // see `CockpitApprovalE2ETests`'s header comment on the same
        // pitfall) converts the absolute target point into an offset from
        // the window's own zero-normalized coordinate.
        let targetCoordinate = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: targetX - initialWindowFrame.minX,
                dy: targetY - initialWindowFrame.minY
            ))

        targetCoordinate.doubleClick()

        let observedCount = waitForCount({ self.countTabBarTabs() }, toEqual: initialTabCount + 1, timeout: 3)
        XCTAssertEqual(
            observedCount, initialTabCount + 1,
            "Double-clicking the empty tab strip area should create exactly one new tab"
        )

        XCTAssertEqual(
            window.frame, initialWindowFrame,
            "Double-clicking the empty tab strip area must not resize/zoom the window"
        )
    }
}
