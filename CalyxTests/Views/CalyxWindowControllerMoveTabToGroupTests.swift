//
//  CalyxWindowControllerMoveTabToGroupTests.swift
//  CalyxTests
//
//  Controller half of the sidebar's cross-group drag:
//  `CalyxWindowController.moveTab(id:toGroup:at:)` and
//  `moveGroup(id:toIndex:)`. The model rules themselves are covered by
//  `WindowSessionMoveTests`; this file checks the controller boundary:
//  the displayed tab keeps being displayed WITHOUT a re-activation
//  (`_activateCurrentTabCountForTesting` delta 0 -- the same `Tab`
//  object stays on screen), the snapshot reflects the move, and a tab
//  already being closed is not moved.
//
//  The "closing" case reaches `closingTabIDs` through
//  `windowWillClose(_:)`, which marks every tab as closing and never
//  clears it (mirrors `CalyxWindowControllerNonLastWindowCloseTests`'s
//  direct call, with a `ConfirmQuitMockAppDelegate` swapped in so the
//  test process is not terminated).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerMoveTabToGroupTests: XCTestCase {

    // MARK: - moveTab(id:toGroup:at:)

    /// A0 is displayed (A active, A.activeTabID == A0). Moving it to B at
    /// index 1 keeps it displayed with B active, with no re-activation.
    func test_moveTab_displayedTab_staysActiveInDestinationWithoutReactivation() {
        let fixture = TwoGroupFixture.make()
        let moved = fixture.tabsA[0]
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.moveTab(id: moved.id, toGroup: fixture.groupB.id, at: 1)

        XCTAssertEqual(
            fixture.groupB.tabs.map(\.id),
            [fixture.tabsB[0].id, moved.id, fixture.tabsB[1].id, fixture.tabsB[2].id]
        )
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupB.id)
        XCTAssertTrue(fixture.session.activeGroup?.activeTab === moved,
                      "The moved Tab object must remain the displayed tab")
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0,
                       "Moving the displayed tab must not re-run activateCurrentTab()")
    }

    /// A1 is not displayed: A stays active with A0, B keeps B0.
    func test_moveTab_nonDisplayedTab_leavesActiveTabAlone() {
        let fixture = TwoGroupFixture.make()
        let before = fixture.controller._activateCurrentTabCountForTesting

        fixture.controller.moveTab(id: fixture.tabsA[1].id, toGroup: fixture.groupB.id, at: 3)

        XCTAssertEqual(fixture.groupA.tabs.map(\.id), [fixture.tabsA[0].id])
        XCTAssertEqual(fixture.groupB.tabs.map(\.id), fixture.tabsB.map(\.id) + [fixture.tabsA[1].id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertTrue(fixture.session.activeGroup?.activeTab === fixture.tabsA[0])
        XCTAssertEqual(fixture.groupB.activeTabID, fixture.tabsB[0].id)
        XCTAssertEqual(fixture.controller._activateCurrentTabCountForTesting - before, 0)
    }

    /// C's only tab c0 moves to A: C disappears, A stays active.
    func test_moveTab_emptiedSourceGroupDisappears() {
        let fixture = ThreeGroupFixture.make()

        fixture.controller.moveTab(id: fixture.tabsC[0].id, toGroup: fixture.groupA.id, at: 0)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id])
        XCTAssertEqual(fixture.groupA.tabs.map(\.id), [fixture.tabsC[0].id, fixture.tabsA[0].id, fixture.tabsA[1].id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(fixture.groupA.activeTabID, fixture.tabsA[0].id)
    }

    /// b2 moves to the front of A: the persisted snapshot shows it.
    func test_moveTab_reflectedInWindowSnapshot() {
        let fixture = ThreeGroupFixture.make()

        fixture.controller.moveTab(id: fixture.tabsB[2].id, toGroup: fixture.groupA.id, at: 0)

        let snapshot = fixture.controller.windowSnapshot()
        XCTAssertEqual(snapshot.groups.map(\.id), [fixture.groupA.id, fixture.groupB.id, fixture.groupC.id])
        XCTAssertEqual(
            snapshot.groups[0].tabs.map(\.id),
            [fixture.tabsB[2].id, fixture.tabsA[0].id, fixture.tabsA[1].id]
        )
        XCTAssertEqual(snapshot.groups[1].tabs.map(\.id), [fixture.tabsB[0].id, fixture.tabsB[1].id])
        XCTAssertEqual(snapshot.activeGroupID, fixture.groupA.id)
    }

    func test_moveTab_closingTab_isRejected() {
        let fixture = TwoGroupFixture.make()
        let mock = ConfirmQuitMockAppDelegate()
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        withExtendedLifetime(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }
        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.contains(fixture.tabsA[1].id),
                      "Precondition: windowWillClose marks every tab as closing")

        fixture.controller.moveTab(id: fixture.tabsA[1].id, toGroup: fixture.groupB.id, at: 0)

        XCTAssertEqual(fixture.groupA.tabs.map(\.id), fixture.tabsA.map(\.id))
        XCTAssertEqual(fixture.groupB.tabs.map(\.id), fixture.tabsB.map(\.id))
    }

    // MARK: - moveGroup(id:toIndex:)

    /// A (active) to index 2: [B, C, A], A still active.
    func test_moveGroup_reordersAndKeepsActiveGroup() {
        let fixture = ThreeGroupFixture.make()

        fixture.controller.moveGroup(id: fixture.groupA.id, toIndex: 2)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupB.id, fixture.groupC.id, fixture.groupA.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
        XCTAssertEqual(
            fixture.controller.windowSnapshot().groups.map(\.id),
            [fixture.groupB.id, fixture.groupC.id, fixture.groupA.id]
        )
    }

    /// C to index 0: [C, A, B].
    func test_moveGroup_nonActiveGroupToFront() {
        let fixture = ThreeGroupFixture.make()

        fixture.controller.moveGroup(id: fixture.groupC.id, toIndex: 0)

        XCTAssertEqual(fixture.session.groups.map(\.id), [fixture.groupC.id, fixture.groupA.id, fixture.groupB.id])
        XCTAssertEqual(fixture.session.activeGroupID, fixture.groupA.id)
    }
}
