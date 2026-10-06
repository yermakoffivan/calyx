//
//  WindowSessionMoveTests.swift
//  CalyxTests
//
//  Model half of the sidebar's cross-group drag: `TabGroup.insertTab(_:at:)`,
//  `WindowSession.moveGroup(fromIndex:toIndex:)` and
//  `WindowSession.moveTab(id:toGroup:at:)`.
//
//  `moveGroup`'s `toIndex` is the group's FINAL position after the move,
//  the same meaning as `TabGroup.moveTab(fromIndex:toIndex:)`.
//  `moveTab(id:toGroup:at:)` moves the selection with the tab only when
//  that tab was the one on screen (active tab of the active group);
//  otherwise neither group's selection nor `activeGroupID` changes. An
//  emptied source group is removed, as when its last tab is closed.
//

import XCTest
@testable import Calyx

@MainActor
final class WindowSessionMoveTests: XCTestCase {

    // MARK: - Fixture

    /// Two groups: A [a0, a1] (active a0, the window's active group) and
    /// B [b0, b1, b2] (active b0).
    private struct TwoGroups {
        let session: WindowSession
        let groupA: TabGroup
        let a: [Tab]
        let groupB: TabGroup
        let b: [Tab]
    }

    private func makeTwoGroups() -> TwoGroups {
        let a = [Tab(title: "a0"), Tab(title: "a1")]
        let b = [Tab(title: "b0"), Tab(title: "b1"), Tab(title: "b2")]
        let groupA = TabGroup(name: "A", tabs: a, activeTabID: a[0].id)
        let groupB = TabGroup(name: "B", tabs: b, activeTabID: b[0].id)
        let session = WindowSession(groups: [groupA, groupB], activeGroupID: groupA.id)
        return TwoGroups(session: session, groupA: groupA, a: a, groupB: groupB, b: b)
    }

    /// Three single-purpose groups, for `moveGroup`.
    private func makeThreeGroupSession() -> (session: WindowSession, g: [TabGroup]) {
        let g = ["G0", "G1", "G2"].map { TabGroup(name: $0, tabs: [Tab(title: $0)]) }
        let session = WindowSession(groups: g, activeGroupID: g[1].id)
        return (session, g)
    }

    // MARK: - TabGroup.insertTab

    func test_insertTab_atMiddleIndex_insertsThere() {
        let a = Tab(title: "A"), b = Tab(title: "B"), x = Tab(title: "X")
        let group = TabGroup(tabs: [a, b], activeTabID: a.id)

        group.insertTab(x, at: 1)

        XCTAssertEqual(group.tabs.map(\.id), [a.id, x.id, b.id])
        XCTAssertEqual(group.activeTabID, a.id, "An existing activeTabID must not change")
    }

    func test_insertTab_atZero_and_atCount() {
        let a = Tab(title: "A"), x = Tab(title: "X"), y = Tab(title: "Y")
        let group = TabGroup(tabs: [a], activeTabID: a.id)

        group.insertTab(x, at: 0)
        group.insertTab(y, at: 2)

        XCTAssertEqual(group.tabs.map(\.id), [x.id, a.id, y.id])
    }

    func test_insertTab_negativeIndex_clampsToFront() {
        let a = Tab(title: "A"), x = Tab(title: "X")
        let group = TabGroup(tabs: [a], activeTabID: a.id)

        group.insertTab(x, at: -5)

        XCTAssertEqual(group.tabs.map(\.id), [x.id, a.id])
    }

    func test_insertTab_tooLargeIndex_clampsToEnd() {
        let a = Tab(title: "A"), b = Tab(title: "B"), x = Tab(title: "X")
        let group = TabGroup(tabs: [a, b], activeTabID: a.id)

        group.insertTab(x, at: 99)

        XCTAssertEqual(group.tabs.map(\.id), [a.id, b.id, x.id])
    }

    func test_insertTab_intoGroupWithNilActiveTab_setsActiveTab() {
        let x = Tab(title: "X")
        let group = TabGroup(tabs: [])

        group.insertTab(x, at: 0)

        XCTAssertEqual(group.tabs.map(\.id), [x.id])
        XCTAssertEqual(group.activeTabID, x.id, "activeTabID is set only when it was nil")
    }

    // MARK: - WindowSession.moveGroup

    func test_moveGroup_forward_toLast() {
        let (session, g) = makeThreeGroupSession()

        session.moveGroup(fromIndex: 0, toIndex: 2)

        XCTAssertEqual(session.groups.map(\.id), [g[1].id, g[2].id, g[0].id])
        XCTAssertEqual(session.activeGroupID, g[1].id, "activeGroupID is ID-based and must not change")
    }

    func test_moveGroup_backward_toFirst() {
        let (session, g) = makeThreeGroupSession()

        session.moveGroup(fromIndex: 2, toIndex: 0)

        XCTAssertEqual(session.groups.map(\.id), [g[2].id, g[0].id, g[1].id])
        XCTAssertEqual(session.activeGroupID, g[1].id)
    }

    func test_moveGroup_activeGroupItself_keepsActiveGroupID() {
        let (session, g) = makeThreeGroupSession()

        session.moveGroup(fromIndex: 1, toIndex: 0)

        XCTAssertEqual(session.groups.map(\.id), [g[1].id, g[0].id, g[2].id])
        XCTAssertEqual(session.activeGroupID, g[1].id)
    }

    func test_moveGroup_sameIndex_isNoOp() {
        let (session, g) = makeThreeGroupSession()

        session.moveGroup(fromIndex: 1, toIndex: 1)

        XCTAssertEqual(session.groups.map(\.id), g.map(\.id))
    }

    func test_moveGroup_outOfRange_isNoOp() {
        let (session, g) = makeThreeGroupSession()

        session.moveGroup(fromIndex: 3, toIndex: 0)
        session.moveGroup(fromIndex: -1, toIndex: 0)
        session.moveGroup(fromIndex: 0, toIndex: 3)
        session.moveGroup(fromIndex: 0, toIndex: -1)

        XCTAssertEqual(session.groups.map(\.id), g.map(\.id))
        XCTAssertEqual(session.activeGroupID, g[1].id)
    }

    // MARK: - WindowSession.moveTab(id:toGroup:at:) -- insertion

    /// a1 (not displayed) into B at index 1: B becomes [b0, a1, b1, b2].
    func test_moveTab_insertsAtIndexInDestination() {
        let f = makeTwoGroups()

        let moved = f.session.moveTab(id: f.a[1].id, toGroup: f.groupB.id, at: 1)

        XCTAssertTrue(moved)
        XCTAssertEqual(f.groupA.tabs.map(\.id), [f.a[0].id])
        XCTAssertEqual(f.groupB.tabs.map(\.id), [f.b[0].id, f.a[1].id, f.b[1].id, f.b[2].id])
    }

    func test_moveTab_negativeIndex_clampsToFront() {
        let f = makeTwoGroups()

        XCTAssertTrue(f.session.moveTab(id: f.a[1].id, toGroup: f.groupB.id, at: -3))

        XCTAssertEqual(f.groupB.tabs.map(\.id), [f.a[1].id, f.b[0].id, f.b[1].id, f.b[2].id])
    }

    func test_moveTab_tooLargeIndex_clampsToEnd() {
        let f = makeTwoGroups()

        XCTAssertTrue(f.session.moveTab(id: f.a[1].id, toGroup: f.groupB.id, at: 42))

        XCTAssertEqual(f.groupB.tabs.map(\.id), [f.b[0].id, f.b[1].id, f.b[2].id, f.a[1].id])
    }

    // MARK: - Selection

    /// a0 is the displayed tab (A is active, A.activeTabID == a0): it
    /// follows into B and B becomes the active group. A's own selection
    /// falls to its remaining neighbour a1 (TabGroup.removeTab rule).
    func test_moveTab_displayedTab_followsToDestination() {
        let f = makeTwoGroups()

        XCTAssertTrue(f.session.moveTab(id: f.a[0].id, toGroup: f.groupB.id, at: 2))

        XCTAssertEqual(f.groupB.tabs.map(\.id), [f.b[0].id, f.b[1].id, f.a[0].id, f.b[2].id])
        XCTAssertEqual(f.groupB.activeTabID, f.a[0].id)
        XCTAssertEqual(f.session.activeGroupID, f.groupB.id)
        XCTAssertEqual(f.groupA.activeTabID, f.a[1].id)
        XCTAssertEqual(f.session.groups.map(\.id), [f.groupA.id, f.groupB.id])
    }

    /// a1 is in the active group but not its active tab: nothing about
    /// the selection changes.
    func test_moveTab_nonDisplayedTab_leavesSelectionsAlone() {
        let f = makeTwoGroups()

        XCTAssertTrue(f.session.moveTab(id: f.a[1].id, toGroup: f.groupB.id, at: 0))

        XCTAssertEqual(f.session.activeGroupID, f.groupA.id)
        XCTAssertEqual(f.groupA.activeTabID, f.a[0].id)
        XCTAssertEqual(f.groupB.activeTabID, f.b[0].id)
    }

    /// b0 is B's active tab, but B is not the active group, so b0 is not
    /// displayed: it moves into A without taking the selection.
    func test_moveTab_activeTabOfInactiveGroup_isNotDisplayed_leavesSelectionsAlone() {
        let f = makeTwoGroups()

        XCTAssertTrue(f.session.moveTab(id: f.b[0].id, toGroup: f.groupA.id, at: 1))

        XCTAssertEqual(f.groupA.tabs.map(\.id), [f.a[0].id, f.b[0].id, f.a[1].id])
        XCTAssertEqual(f.session.activeGroupID, f.groupA.id)
        XCTAssertEqual(f.groupA.activeTabID, f.a[0].id)
        XCTAssertEqual(f.groupB.activeTabID, f.b[1].id, "B's selection falls to b0's right neighbour")
    }

    // MARK: - Emptied source group

    /// Active single-tab source: its displayed tab moves to B, the source
    /// group disappears and B is active with the moved tab displayed.
    func test_moveTab_emptiesActiveSource_removesItAndActivatesDestination() {
        let solo = Tab(title: "s0")
        let source = TabGroup(name: "S", tabs: [solo], activeTabID: solo.id)
        let b = [Tab(title: "b0"), Tab(title: "b1")]
        let dest = TabGroup(name: "B", tabs: b, activeTabID: b[0].id)
        let session = WindowSession(groups: [source, dest], activeGroupID: source.id)

        XCTAssertTrue(session.moveTab(id: solo.id, toGroup: dest.id, at: 1))

        XCTAssertEqual(session.groups.map(\.id), [dest.id])
        XCTAssertEqual(dest.tabs.map(\.id), [b[0].id, solo.id, b[1].id])
        XCTAssertEqual(session.activeGroupID, dest.id)
        XCTAssertEqual(dest.activeTabID, solo.id)
    }

    /// Non-active single-tab source (C) emptied into B: C disappears,
    /// activeGroupID stays on A, B's selection is unchanged.
    func test_moveTab_emptiesNonActiveSource_removesItAndKeepsActiveGroup() {
        let a = [Tab(title: "a0")]
        let groupA = TabGroup(name: "A", tabs: a, activeTabID: a[0].id)
        let b = [Tab(title: "b0")]
        let groupB = TabGroup(name: "B", tabs: b, activeTabID: b[0].id)
        let c = [Tab(title: "c0")]
        let groupC = TabGroup(name: "C", tabs: c, activeTabID: c[0].id)
        let session = WindowSession(groups: [groupA, groupB, groupC], activeGroupID: groupA.id)

        XCTAssertTrue(session.moveTab(id: c[0].id, toGroup: groupB.id, at: 0))

        XCTAssertEqual(session.groups.map(\.id), [groupA.id, groupB.id])
        XCTAssertEqual(groupB.tabs.map(\.id), [c[0].id, b[0].id])
        XCTAssertEqual(session.activeGroupID, groupA.id)
        XCTAssertEqual(groupA.activeTabID, a[0].id)
        XCTAssertEqual(groupB.activeTabID, b[0].id)
    }

    // MARK: - Rejections

    func test_moveTab_sameGroup_returnsFalseAndChangesNothing() {
        let f = makeTwoGroups()

        XCTAssertFalse(f.session.moveTab(id: f.a[0].id, toGroup: f.groupA.id, at: 1))

        XCTAssertEqual(f.groupA.tabs.map(\.id), f.a.map(\.id))
        XCTAssertEqual(f.groupA.activeTabID, f.a[0].id)
        XCTAssertEqual(f.session.activeGroupID, f.groupA.id)
    }

    func test_moveTab_unknownTab_returnsFalseAndChangesNothing() {
        let f = makeTwoGroups()

        XCTAssertFalse(f.session.moveTab(id: UUID(), toGroup: f.groupB.id, at: 0))

        XCTAssertEqual(f.groupA.tabs.map(\.id), f.a.map(\.id))
        XCTAssertEqual(f.groupB.tabs.map(\.id), f.b.map(\.id))
    }

    func test_moveTab_unknownDestination_returnsFalseAndChangesNothing() {
        let f = makeTwoGroups()

        XCTAssertFalse(f.session.moveTab(id: f.a[0].id, toGroup: UUID(), at: 0))

        XCTAssertEqual(f.groupA.tabs.map(\.id), f.a.map(\.id))
        XCTAssertEqual(f.groupA.activeTabID, f.a[0].id)
        XCTAssertEqual(f.session.groups.map(\.id), [f.groupA.id, f.groupB.id])
        XCTAssertEqual(f.session.activeGroupID, f.groupA.id)
    }
}
