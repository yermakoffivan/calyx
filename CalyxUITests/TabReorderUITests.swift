// TabReorderUITests.swift
// CalyxUITests
//
// UI tests for tab drag-reorder in both the tab bar and sidebar.

import XCTest

final class TabReorderUITests: CalyxUITestCase {

    // MARK: - Helpers

    // Position-ordered tab lookup.
    //
    // The tab rows expose their `calyx.*.tab.<UUID>` identifier (via
    // `.accessibilityElement(children: .contain)`) but NOT their
    // `.accessibilityValue` index: XCUITest surfaces a container element's
    // identifier and label, but not its `AXValue`, so the previous
    // value-based index lookup returned nothing. Instead, resolve a tab's
    // ordinal position from the on-screen geometry of the identifier-bearing
    // elements: left-to-right (minX) for the horizontal tab bar,
    // top-to-bottom (minY) for the vertical sidebar list.
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"

    /// Tab-bar tab elements (identifier `calyx.tabBar.tab.<UUID>`, no
    /// `.closeButton` suffix) sorted left-to-right by frame.
    private func tabBarTabsByPosition() -> [XCUIElement] {
        let query = tabBarTabsQuery()
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Sidebar tab elements (identifier `calyx.sidebar.tab.<UUID>`) sorted
    /// top-to-bottom by frame.
    private func sidebarTabsByPosition() -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier MATCHES %@",
                                    "calyx\\.sidebar\\.tab\\.\(Self.uuidPattern)")
        let query = app.descendants(matching: .any).matching(predicate)
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func tabBarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = tabBarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }

    private func sidebarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = sidebarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }

    /// Reads the identifier of the tab-bar tab at a given ordinal position.
    private func tabBarTabIdentifier(atIndex index: Int) -> String? {
        tabBarTab(atIndex: index)?.identifier
    }

    /// Reads the identifier of the sidebar tab at a given ordinal position.
    private func sidebarTabIdentifier(atIndex index: Int) -> String? {
        sidebarTab(atIndex: index)?.identifier
    }

    /// Creates `count` additional tabs (beyond the initial one) and waits for them to appear.
    private func createTabs(count: Int) {
        for _ in 0..<count {
            createNewTabViaMenu()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Tab Bar Reorder

    func test_dragTabBarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total (1 initial + 2 new)
        createTabs(count: 2)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before drag")

        // Capture the identifier of the tab currently at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let originalFirstTabID = firstTabElement.identifier

        // Also capture the tab at index 2 to know the drag target position
        guard let thirdTabElement = tabBarTab(atIndex: 2) else {
            return XCTFail("Tab at index 2 should exist")
        }

        // Act: drag the first tab to the right, past the third tab.
        // `press(forDuration:thenDragTo:)` delivers ZERO synthetic mouse
        // events to the app-under-test on this Xcode/macOS toolchain
        // (field-verified via mouseDown/mouseDragged/mouseUp
        // instrumentation in ClickContainerNSView and an app-wide
        // NSEvent local monitor: neither ever fired). `click(forDuration:
        // thenDragTo:)` is the same click-and-hold-then-drag gesture via
        // a different XCTest code path and does deliver events.
        firstTabElement.click(forDuration: 0.2, thenDragTo: thirdTabElement)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally first should no longer be at index 0
        let newFirstTabID = tabBarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstTabID, "A tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstTabID, originalFirstTabID,
            "After dragging the first tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at index 1 or 2
        let tabAtIndex1 = tabBarTabIdentifier(atIndex: 1)
        let tabAtIndex2 = tabBarTabIdentifier(atIndex: 2)
        let originalTabMoved = (tabAtIndex1 == originalFirstTabID) || (tabAtIndex2 == originalFirstTabID)
        XCTAssertTrue(
            originalTabMoved,
            "The original first tab should have moved to index 1 or 2"
        )
    }

    // MARK: - Sidebar Reorder

    func test_dragSidebarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total
        createTabs(count: 2)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before toggling sidebar")

        // The sidebar is shown by default (WindowSession.showSidebar
        // defaults to true), so its tab rows are already on screen. Do NOT
        // call toggleSidebarViaMenu() here: that would CLOSE the sidebar and
        // hide the very rows this test drags. Just let it settle.
        Thread.sleep(forTimeInterval: 1.0)

        // Find the sidebar tab at index 0
        guard let firstSidebarTab = sidebarTab(atIndex: 0) else {
            return XCTFail("Sidebar tab at index 0 should exist")
        }
        let originalFirstSidebarID = firstSidebarTab.identifier

        // Find the sidebar tab at index 2
        guard let thirdSidebarTab = sidebarTab(atIndex: 2) else {
            return XCTFail("Sidebar tab at index 2 should exist")
        }

        // Act: drag the first sidebar tab down past the third. See
        // test_dragTabBarTab_reordersCorrectly's own comment above for
        // why `click(forDuration:thenDragTo:)`, not `press(forDuration:
        // thenDragTo:)`, is used here.
        firstSidebarTab.click(forDuration: 0.2, thenDragTo: thirdSidebarTab)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally at index 0 should no longer be there
        let newFirstSidebarID = sidebarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstSidebarID, "A sidebar tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstSidebarID, originalFirstSidebarID,
            "After dragging the first sidebar tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at a later index
        let sidebarTabAt1 = sidebarTabIdentifier(atIndex: 1)
        let sidebarTabAt2 = sidebarTabIdentifier(atIndex: 2)
        let originalSidebarTabMoved = (sidebarTabAt1 == originalFirstSidebarID) || (sidebarTabAt2 == originalFirstSidebarID)
        XCTAssertTrue(
            originalSidebarTabMoved,
            "The original first sidebar tab should have moved to index 1 or 2"
        )
    }

    // MARK: - Sidebar Cross-Group Drag

    /// Group header elements sorted top-to-bottom by frame.
    private func groupHeadersByPosition() -> [XCUIElement] {
        groupHeadersQuery().allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
    }

    func test_dragSidebarTab_intoAnotherGroup_movesRowUnderThatGroup() {
        // Arrange: group 1 gets 2 tabs, then a second group (1 tab) is
        // created. Group 1 keeps a tab after the move, so both headers stay.
        createTabs(count: 1)
        createGroupViaCommandPalette(expectingGroupCount: 2)
        Thread.sleep(forTimeInterval: 1.0)

        let headers = groupHeadersByPosition()
        XCTAssertEqual(headers.count, 2, "Should have 2 group headers")
        guard headers.count == 2 else { return }
        let upperHeaderID = headers[0].identifier
        let lowerHeaderID = headers[1].identifier
        let upperMinY = headers[0].frame.minY
        let lowerMinY = headers[1].frame.minY

        let rowsBefore = sidebarTabsByPosition()
        XCTAssertEqual(rowsBefore.count, 3, "Should have 3 sidebar rows before the drag")
        guard let source = rowsBefore.first(where: {
            $0.frame.minY > upperMinY && $0.frame.minY < lowerMinY
        }) else {
            return XCTFail("A row of the upper group should sit between the two headers")
        }
        let sourceID = source.identifier

        // Act: drop the row onto the lower group's (expanded) header,
        // pressing/dropping on the header's left part (away from the
        // collapse chevron / close glyph). See
        // test_dragTabBarTab_reordersCorrectly for why `click(forDuration:
        // thenDragTo:)`.
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = headers[1].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.click(forDuration: 0.2, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: same row count; the moved row now sits below the lower
        // group's header, which is still below the upper group's header.
        XCTAssertEqual(waitForCount({ self.sidebarTabsByPosition().count }, toEqual: 3), 3,
                       "Moving a tab between groups must not add or remove rows")
        let headersAfter = groupHeadersByPosition()
        XCTAssertEqual(headersAfter.map(\.identifier), [upperHeaderID, lowerHeaderID],
                       "Both groups should remain, in the same order")
        guard headersAfter.count == 2 else { return }
        guard let moved = sidebarTabsByPosition().first(where: { $0.identifier == sourceID }) else {
            return XCTFail("The dragged row should still exist")
        }
        XCTAssertGreaterThan(
            moved.frame.minY, headersAfter[1].frame.minY,
            "The dragged row should now be listed under the other group's header"
        )
        let rowsUnderLower = sidebarTabsByPosition().filter { $0.frame.minY > headersAfter[1].frame.minY }
        XCTAssertEqual(rowsUnderLower.count, 2, "The other group should now hold 2 rows")
    }

    func test_dragGroupHeader_pastAnotherGroup_swapsHeaderOrder() {
        // Arrange: two groups, one tab each.
        createGroupViaCommandPalette(expectingGroupCount: 2)
        Thread.sleep(forTimeInterval: 1.0)

        let headers = groupHeadersByPosition()
        XCTAssertEqual(headers.count, 2, "Should have 2 group headers")
        guard headers.count == 2 else { return }
        let upperID = headers[0].identifier
        let lowerID = headers[1].identifier

        guard let lastRow = sidebarTabsByPosition().last else {
            return XCTFail("The lower group's row should exist")
        }

        // Act: drag the upper header (from its left part) down to one row
        // height BELOW the lower group's last row (still inside the
        // sidebar). That point is below the lower group's whole section,
        // so its section midpoint is above the dragged header's midpoint
        // whatever the group's row count, which resolves to the last index.
        let start = headers[0].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = lastRow.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 2.0))
        start.click(forDuration: 0.2, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the headers' top-to-bottom order is swapped.
        XCTAssertEqual(
            groupHeadersByPosition().map(\.identifier), [lowerID, upperID],
            "After dragging the upper group past the lower one, their headers should swap order"
        )
    }

    // MARK: - Tap After Drag

    func test_tapStillWorksAfterDrag() {
        // Arrange: create 2 tabs total
        createTabs(count: 1)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have 2 tabs")

        // Find the tab at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let tabID = firstTabElement.identifier

        // Act: perform a very short press-and-drag (within the 5pt minimumDistance threshold)
        // This should not trigger a reorder; instead the tab should remain tappable.
        // We drag to a nearby coordinate offset (2pt right, 0pt down) which is < minimumDistance.
        let startCoordinate = firstTabElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let nearbyCoordinate = startCoordinate.withOffset(CGVector(dx: 2, dy: 0))
        // `click(forDuration:thenDragTo:)`, not `press(forDuration:
        // thenDragTo:)` -- see test_dragTabBarTab_reordersCorrectly's own
        // comment. Using the broken `press` variant here made this
        // assertion pass vacuously (no drag was ever delivered to assert
        // "no reorder" against).
        startCoordinate.click(forDuration: 0.1, thenDragTo: nearbyCoordinate)

        Thread.sleep(forTimeInterval: 0.5)

        // Assert: the tab should still be at the same index (no reorder occurred)
        let tabAfterDrag = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterDrag, tabID,
            "Tab should remain at index 0 after a sub-threshold drag"
        )

        // Verify the tab is still tappable by clicking it
        guard let tabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should still exist")
        }
        XCTAssertTrue(tabElement.isHittable, "Tab should be hittable after a sub-threshold drag")
        tabElement.click()

        Thread.sleep(forTimeInterval: 0.5)

        // The tab should still exist and be at the same position
        let tabAfterClick = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterClick, tabID,
            "Tab should remain at index 0 after clicking"
        )
    }
}
