//
//  SidebarDropTargetTests.swift
//  CalyxTests
//
//  Pure drop-target logic for the sidebar's drag gestures
//  (`SidebarDropResolver`, `SidebarDragState`), driven by hand-built
//  `SidebarLayoutSnapshot` fixtures with explicit frames (y grows
//  downward, all frames in the sidebar's content coordinate space).
//
//  Every expected index below is counted by hand from the fixture's
//  midYs: "the number of other rows/sections whose midY is above the
//  dragged midpoint", which is also the item's final index.
//
//  Standard fixture (`layout`):
//
//      A  header   0..20   (mid  10)   expanded
//         a0      24..44   (mid  34)
//         a1      44..64   (mid  54)
//         a2      64..84   (mid  74)     section A  0..84   (mid  42)
//      B  header  90..110  (mid 100)   expanded
//         b0     114..134  (mid 124)
//         b1     134..154  (mid 144)     section B 90..154  (mid 122)
//      C  header 160..180  (mid 170)   collapsed, tabs c0, c1 (frames .zero)
//                                        section C 160..180 (mid 170)
//

import XCTest
@testable import Calyx

@MainActor
final class SidebarDropTargetTests: XCTestCase {

    // MARK: - Fixture

    private let groupA = UUID(), groupB = UUID(), groupC = UUID()
    private let a0 = UUID(), a1 = UUID(), a2 = UUID()
    private let b0 = UUID(), b1 = UUID()
    private let c0 = UUID(), c1 = UUID()

    private func rect(_ minY: CGFloat, _ maxY: CGFloat) -> CGRect {
        CGRect(x: 0, y: minY, width: 200, height: maxY - minY)
    }

    private var groupASnapshot: SidebarLayoutSnapshot.Group {
        .init(id: groupA, isCollapsed: false, headerFrame: rect(0, 20), tabs: [
            .init(id: a0, frame: rect(24, 44)),
            .init(id: a1, frame: rect(44, 64)),
            .init(id: a2, frame: rect(64, 84)),
        ])
    }

    private var groupBSnapshot: SidebarLayoutSnapshot.Group {
        .init(id: groupB, isCollapsed: false, headerFrame: rect(90, 110), tabs: [
            .init(id: b0, frame: rect(114, 134)),
            .init(id: b1, frame: rect(134, 154)),
        ])
    }

    private var groupCSnapshot: SidebarLayoutSnapshot.Group {
        .init(id: groupC, isCollapsed: true, headerFrame: rect(160, 180), tabs: [
            .init(id: c0, frame: .zero),
            .init(id: c1, frame: .zero),
        ])
    }

    /// A, B, C as drawn in the header comment.
    private var layout: SidebarLayoutSnapshot {
        SidebarLayoutSnapshot(groups: [groupASnapshot, groupBSnapshot, groupCSnapshot])
    }

    /// A and B only, so the last group is expanded.
    private var layoutAB: SidebarLayoutSnapshot {
        SidebarLayoutSnapshot(groups: [groupASnapshot, groupBSnapshot])
    }

    private func tabTarget(_ tab: UUID, _ midY: CGFloat, in layout: SidebarLayoutSnapshot? = nil) -> SidebarTabDropTarget? {
        SidebarDropResolver.tabDropTarget(draggedTabID: tab, dragMidY: midY, layout: layout ?? self.layout)
    }

    private func groupIndex(_ group: UUID, _ midY: CGFloat, in layout: SidebarLayoutSnapshot? = nil) -> Int? {
        SidebarDropResolver.groupDropIndex(draggedGroupID: group, dragMidY: midY, layout: layout ?? self.layout)
    }

    // MARK: - tabDropTarget: guards

    func test_tabDropTarget_emptyLayout_isNil() {
        XCTAssertNil(SidebarDropResolver.tabDropTarget(
            draggedTabID: a0, dragMidY: 50, layout: SidebarLayoutSnapshot(groups: [])
        ))
    }

    func test_tabDropTarget_unknownTab_isNil() {
        XCTAssertNil(tabTarget(UUID(), 130))
    }

    // MARK: - tabDropTarget: within the same group

    /// a0 to midY 60: other rows above 60 are a1 (54) -> index 1.
    func test_tabDropTarget_withinGroup_movesDown() {
        XCTAssertEqual(tabTarget(a0, 60), SidebarTabDropTarget(groupID: groupA, index: 1, isOntoHeader: false))
    }

    /// a2 to midY 30: other rows above 30: none -> index 0; 30 is below
    /// A's header (maxY 20) so not onto the header.
    func test_tabDropTarget_withinGroup_movesToTop() {
        XCTAssertEqual(tabTarget(a2, 30), SidebarTabDropTarget(groupID: groupA, index: 0, isOntoHeader: false))
    }

    /// a1 to midY 50: other rows above 50 are a0 (34) -> index 1, a1's
    /// current index -> no move.
    func test_tabDropTarget_withinGroup_samePosition_isNil() {
        XCTAssertNil(tabTarget(a1, 50))
    }

    // MARK: - tabDropTarget: into another group

    /// a0 to midY 130: in B (header minY 90 <= 130); b0 (124) above -> 1.
    func test_tabDropTarget_betweenRowsOfOtherGroup() {
        XCTAssertEqual(tabTarget(a0, 130), SidebarTabDropTarget(groupID: groupB, index: 1, isOntoHeader: false))
    }

    /// a0 to midY 100: on B's expanded header (90..110) -> index 0, onto header.
    func test_tabDropTarget_ontoExpandedHeader_isIndexZero() {
        XCTAssertEqual(tabTarget(a0, 100), SidebarTabDropTarget(groupID: groupB, index: 0, isOntoHeader: true))
    }

    /// a0 to midY 112: between B's header (maxY 110) and b0 (minY 114) ->
    /// index 0, NOT onto the header.
    func test_tabDropTarget_gapBetweenHeaderAndFirstRow_isIndexZeroNotOntoHeader() {
        XCTAssertEqual(tabTarget(a0, 112), SidebarTabDropTarget(groupID: groupB, index: 0, isOntoHeader: false))
    }

    /// b0 to midY 87: between a2 (maxY 84) and B's header (minY 90) ->
    /// belongs to A (last header with minY <= 87); a0, a1, a2 all above -> 3.
    func test_tabDropTarget_gapBetweenGroups_belongsToUpperGroupEnd() {
        XCTAssertEqual(tabTarget(b0, 87), SidebarTabDropTarget(groupID: groupA, index: 3, isOntoHeader: false))
    }

    /// a0 onto collapsed C's header (midY 170): append after c0, c1 -> 2.
    func test_tabDropTarget_ontoCollapsedHeader_appendsToEnd() {
        XCTAssertEqual(tabTarget(a0, 170), SidebarTabDropTarget(groupID: groupC, index: 2, isOntoHeader: true))
    }

    /// Far below C (collapsed, the last group): still C, appended.
    func test_tabDropTarget_belowCollapsedLastGroup_appendsToIt() {
        XCTAssertEqual(tabTarget(b0, 500), SidebarTabDropTarget(groupID: groupC, index: 2, isOntoHeader: true))
    }

    /// Far below B's last row when B is the last (expanded) group: end of
    /// B, i.e. after b0 and b1 -> 2.
    func test_tabDropTarget_belowExpandedLastGroup_isItsEnd() {
        XCTAssertEqual(
            tabTarget(a0, 500, in: layoutAB),
            SidebarTabDropTarget(groupID: groupB, index: 2, isOntoHeader: false)
        )
    }

    /// Above A's header: first group, index 0; -50 < A.header.maxY (20) so
    /// it counts as onto the header.
    func test_tabDropTarget_aboveFirstGroup_isFirstGroupFront() {
        XCTAssertEqual(tabTarget(b1, -50), SidebarTabDropTarget(groupID: groupA, index: 0, isOntoHeader: true))
    }

    // MARK: - groupDropIndex

    func test_groupDropIndex_unknownGroup_isNil() {
        XCTAssertNil(groupIndex(UUID(), 130))
    }

    /// A to midY 130: sections above 130 are B (122); C (170) is not -> 1.
    /// (C's collapsed `.zero` tab frames must not stretch its section up
    /// to y 0, or its midY would be 90 and the answer 2.)
    func test_groupDropIndex_movesDownPastOneGroup() {
        XCTAssertEqual(groupIndex(groupA, 130), 1)
    }

    /// A to midY 175: B (122) and C (170) above -> 2.
    func test_groupDropIndex_movesToLast() {
        XCTAssertEqual(groupIndex(groupA, 175), 2)
    }

    /// C to midY 50: A (42) above -> 1.
    func test_groupDropIndex_movesUp() {
        XCTAssertEqual(groupIndex(groupC, 50), 1)
    }

    /// C to midY 30: nothing above -> 0.
    func test_groupDropIndex_movesToFirst() {
        XCTAssertEqual(groupIndex(groupC, 30), 0)
    }

    /// B to midY 100: A (42) above, C (170) not -> 1 == B's index -> nil.
    func test_groupDropIndex_samePosition_isNil() {
        XCTAssertNil(groupIndex(groupB, 100))
    }

    /// Very different heights:
    ///
    ///     S  header   0..20  (mid 10)  collapsed     section mid 10
    ///     L  header  24..44  (mid 34)  expanded, rows 48..148 (5 x 20)
    ///                                   section 24..148, mid 86
    ///
    /// Dragging S down to midY 70 passes L's HEADER mid (34) but not L's
    /// SECTION mid (86): no move. At 90 it passes L's section -> 1.
    /// Dragging L up to midY 14 passes S's mid (10) -> 1 == current -> nil;
    /// to 4 -> 0.
    func test_groupDropIndex_unevenHeights_usesWholeSectionMidpoint() {
        let small = UUID(), large = UUID()
        let rows = (0..<5).map { i in
            SidebarLayoutSnapshot.TabRow(id: UUID(), frame: rect(48 + CGFloat(i) * 20, 68 + CGFloat(i) * 20))
        }
        let uneven = SidebarLayoutSnapshot(groups: [
            .init(id: small, isCollapsed: true, headerFrame: rect(0, 20), tabs: [.init(id: UUID(), frame: .zero)]),
            .init(id: large, isCollapsed: false, headerFrame: rect(24, 44), tabs: rows),
        ])

        XCTAssertNil(groupIndex(small, 70, in: uneven))
        XCTAssertEqual(groupIndex(small, 90, in: uneven), 1)
        XCTAssertNil(groupIndex(large, 14, in: uneven))
        XCTAssertEqual(groupIndex(large, 4, in: uneven), 0)
    }

    // MARK: - SidebarDragState

    func test_dragState_initiallyIdle() {
        let state = SidebarDragState()

        XCTAssertNil(state.item)
        XCTAssertEqual(state.dragOffset, 0)
        XCTAssertNil(state.frozenLayout)
        XCTAssertNil(state.tabDropTarget)
        XCTAssertNil(state.groupDropIndex)
    }

    /// a0's frozen midY is 34; translation 96 -> 130 -> B index 1.
    func test_dragState_tabDrag_tracksOffsetAndTarget() {
        let state = SidebarDragState()

        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { self.layout })

        XCTAssertEqual(state.item, .tab(a0))
        XCTAssertEqual(state.dragOffset, 96)
        XCTAssertEqual(state.frozenLayout, layout)
        XCTAssertEqual(state.tabDropTarget, SidebarTabDropTarget(groupID: groupB, index: 1, isOntoHeader: false))
        XCTAssertNil(state.groupDropIndex)
    }

    func test_dragState_freezesLayoutOnFirstUpdateOnly() {
        let state = SidebarDragState()
        var calls = 0
        let original = layout
        // Same IDs, but every frame shifted down by 1000: a resolver fed
        // this one would put a0 (frozen mid 34) nowhere near B.
        let shifted = SidebarLayoutSnapshot(groups: original.groups.map { g in
            .init(id: g.id, isCollapsed: g.isCollapsed, headerFrame: g.headerFrame.offsetBy(dx: 0, dy: 1000),
                  tabs: g.tabs.map { .init(id: $0.id, frame: $0.frame.offsetBy(dx: 0, dy: 1000)) })
        })

        state.updateTabDrag(tabID: a0, translation: 10, currentLayout: { calls += 1; return original })
        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { calls += 1; return shifted })

        XCTAssertEqual(calls, 1, "currentLayout must be read once, at the start of the drag")
        XCTAssertEqual(state.frozenLayout, original)
        XCTAssertEqual(state.dragOffset, 96)
        XCTAssertEqual(state.tabDropTarget, SidebarTabDropTarget(groupID: groupB, index: 1, isOntoHeader: false))
    }

    func test_dragState_nilLayout_doesNotStartDrag() {
        let state = SidebarDragState()

        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { nil })

        XCTAssertNil(state.item)
        XCTAssertNil(state.frozenLayout)
        XCTAssertNil(state.tabDropTarget)
    }

    /// a0 mid 34 + 26 = 60 -> A index 1 (same group).
    func test_dragState_endDrag_withinGroup() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 26, currentLayout: { self.layout })

        XCTAssertEqual(state.endDrag(), .moveTabWithinGroup(groupID: groupA, fromIndex: 0, toIndex: 1))
        assertIdle(state)
    }

    func test_dragState_endDrag_toOtherGroup() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { self.layout })

        XCTAssertEqual(state.endDrag(), .moveTabToGroup(tabID: a0, groupID: groupB, index: 1))
        assertIdle(state)
    }

    /// A's HEADER mid 10 + 120 = 130 -> index 1.
    func test_dragState_groupDrag_endDrag_movesGroup() {
        let state = SidebarDragState()
        state.updateGroupDrag(groupID: groupA, translation: 120, currentLayout: { self.layout })

        XCTAssertEqual(state.item, .group(groupA))
        XCTAssertEqual(state.dragOffset, 120)
        XCTAssertEqual(state.groupDropIndex, 1)
        XCTAssertNil(state.tabDropTarget)

        XCTAssertEqual(state.endDrag(), .moveGroup(groupID: groupA, toIndex: 1))
        assertIdle(state)
    }

    /// a1 (mid 54) moved by 2 -> 56: still index 1 -> no target.
    func test_dragState_endDrag_withoutTarget_returnsNilAndResets() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a1, translation: 2, currentLayout: { self.layout })
        XCTAssertEqual(state.item, .tab(a1))
        XCTAssertNil(state.tabDropTarget)

        XCTAssertNil(state.endDrag())
        assertIdle(state)
    }

    func test_dragState_reset_clearsEverything() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { self.layout })

        state.reset()

        assertIdle(state)
    }

    // MARK: - SidebarDragState: route gating (allowsWithinGroup / allowsCrossGroup)

    /// Within-group disallowed: a0 + 26 = 60 -> A index 1 (own group) ->
    /// suppressed; then a0 + 96 = 130 -> B index 1 (other group) -> kept.
    func test_dragState_withinGroupDisallowed_suppressesOwnGroupTarget_keepsCrossGroup() {
        let state = SidebarDragState()

        state.updateTabDrag(tabID: a0, translation: 26, allowsWithinGroup: false, allowsCrossGroup: true,
                            currentLayout: { self.layout })
        XCTAssertEqual(state.item, .tab(a0))
        XCTAssertNil(state.tabDropTarget, "a target in the dragged tab's own group must be dropped when within-group is unwired")
        XCTAssertNil(state.dropIndicator)

        state.updateTabDrag(tabID: a0, translation: 96, allowsWithinGroup: false, allowsCrossGroup: true,
                            currentLayout: { self.layout })
        XCTAssertEqual(state.tabDropTarget, SidebarTabDropTarget(groupID: groupB, index: 1, isOntoHeader: false))
        XCTAssertEqual(state.endDrag(), .moveTabToGroup(tabID: a0, groupID: groupB, index: 1))
    }

    /// Cross-group disallowed: a0 + 96 = 130 -> B index 1 -> suppressed;
    /// then a0 + 26 = 60 -> A index 1 -> kept.
    func test_dragState_crossGroupDisallowed_suppressesOtherGroupTarget_keepsWithinGroup() {
        let state = SidebarDragState()

        state.updateTabDrag(tabID: a0, translation: 96, allowsWithinGroup: true, allowsCrossGroup: false,
                            currentLayout: { self.layout })
        XCTAssertEqual(state.item, .tab(a0))
        XCTAssertNil(state.tabDropTarget, "a target in another group must be dropped when cross-group is unwired")
        XCTAssertNil(state.dropIndicator)

        state.updateTabDrag(tabID: a0, translation: 26, allowsWithinGroup: true, allowsCrossGroup: false,
                            currentLayout: { self.layout })
        XCTAssertEqual(state.tabDropTarget, SidebarTabDropTarget(groupID: groupA, index: 1, isOntoHeader: false))
        XCTAssertEqual(state.endDrag(), .moveTabWithinGroup(groupID: groupA, fromIndex: 0, toIndex: 1))
    }

    /// a0 + 26 -> A index 1, within-group disallowed -> endDrag is nil and idle.
    func test_dragState_withinGroupDisallowed_endDragReturnsNil() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 26, allowsWithinGroup: false, currentLayout: { self.layout })

        XCTAssertNil(state.endDrag())
        assertIdle(state)
    }

    /// a0 + 136 = 170 -> onto collapsed C's header, cross-group disallowed
    /// -> endDrag is nil and idle.
    func test_dragState_crossGroupDisallowed_ontoCollapsedHeader_endDragReturnsNil() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 136, allowsCrossGroup: false, currentLayout: { self.layout })

        XCTAssertNil(state.tabDropTarget)
        XCTAssertNil(state.dropIndicator)
        XCTAssertNil(state.endDrag())
        assertIdle(state)
    }

    /// Both explicitly true behaves like the defaults: a0 + 96 -> B index 1.
    func test_dragState_bothRoutesAllowed_keepsTarget() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 96, allowsWithinGroup: true, allowsCrossGroup: true,
                            currentLayout: { self.layout })

        XCTAssertEqual(state.tabDropTarget, SidebarTabDropTarget(groupID: groupB, index: 1, isOntoHeader: false))
    }

    // MARK: - SidebarDragState: dropIndicator geometry
    //
    // Spec intent: a line sits between the neighbouring rows/sections
    // (the dragged item excluded), on the neighbour's outer edge at the
    // first/last slot; a drop onto a header highlights that header.
    // Line rects: x = across.minX + 14, width = across.width - 28 = 172,
    // height 2, centred on the slot y (so minY = y - 1). Fixture frames
    // are all x 0, width 200.

    private func line(y: CGFloat) -> SidebarDropIndicator {
        .line(CGRect(x: 14, y: y - 1, width: 172, height: 2))
    }

    func test_dropIndicator_idle_isNil() {
        XCTAssertNil(SidebarDragState().dropIndicator)
    }

    /// a1 + 2 = 56 -> still A index 1 -> no target -> no indicator.
    func test_dropIndicator_tabDragWithoutTarget_isNil() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a1, translation: 2, currentLayout: { self.layout })
        XCTAssertNil(state.dropIndicator)
    }

    /// B + 2 -> header mid 102 -> still index 1 -> no indicator.
    func test_dropIndicator_groupDragWithoutTarget_isNil() {
        let state = SidebarDragState()
        state.updateGroupDrag(groupID: groupB, translation: 2, currentLayout: { self.layout })
        XCTAssertNil(state.dropIndicator)
    }

    /// a0 + 136 = 170 -> onto collapsed C header (160..180).
    func test_dropIndicator_ontoCollapsedHeader_highlightsHeader() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 136, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, .header(CGRect(x: 0, y: 160, width: 200, height: 20)))
    }

    /// a0 + 66 = 100 -> onto expanded B header (90..110).
    func test_dropIndicator_ontoExpandedHeader_highlightsHeader() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 66, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, .header(CGRect(x: 0, y: 90, width: 200, height: 20)))
    }

    /// a0 + 78 = 112 -> B index 0 (below header): line on b0's top edge, y 114.
    func test_dropIndicator_tabFirstSlot_isOnFirstRowTopEdge() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 78, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 114))
    }

    /// a0 + 96 = 130 -> B index 1: between b0 (maxY 134) and b1 (minY 134) -> y 134.
    func test_dropIndicator_tabMiddleSlot_otherGroup_isBetweenNeighbours() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 96, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 134))
    }

    /// a0 + 26 = 60 -> A index 1. a0 excluded, so the neighbours are a1
    /// (44..64) and a2 (64..84) -> y 64. (Had a0 been kept, slot 1 would
    /// sit between a0 and a1 at y 44.)
    func test_dropIndicator_tabMiddleSlot_ownGroup_excludesDraggedRow() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: a0, translation: 26, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 64))
    }

    /// b0 - 37 = 87 -> A index 3 (end): line on a2's bottom edge, y 84.
    func test_dropIndicator_tabLastSlot_isOnLastRowBottomEdge() {
        let state = SidebarDragState()
        state.updateTabDrag(tabID: b0, translation: -37, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 84))
    }

    /// C header mid 170 - 140 = 30 -> index 0. Other sections A (0..84),
    /// B (90..154): line on A's top edge, y 0, across C's header.
    func test_dropIndicator_groupFirstSlot_isOnFirstSectionTopEdge() {
        let state = SidebarDragState()
        state.updateGroupDrag(groupID: groupC, translation: -140, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 0))
    }

    /// C mid 170 - 120 = 50 -> index 1: between A (maxY 84) and B (minY 90) -> y 87.
    func test_dropIndicator_groupMiddleSlot_isBetweenNeighbourSections() {
        let state = SidebarDragState()
        state.updateGroupDrag(groupID: groupC, translation: -120, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 87))
    }

    /// A mid 10 + 165 = 175 -> index 2. Other sections B (90..154), C
    /// (160..180): line on C's bottom edge, y 180.
    func test_dropIndicator_groupLastSlot_isOnLastSectionBottomEdge() {
        let state = SidebarDragState()
        state.updateGroupDrag(groupID: groupA, translation: 165, currentLayout: { self.layout })
        XCTAssertEqual(state.dropIndicator, line(y: 180))
    }

    private func assertIdle(_ state: SidebarDragState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.item, file: file, line: line)
        XCTAssertEqual(state.dragOffset, 0, file: file, line: line)
        XCTAssertNil(state.frozenLayout, file: file, line: line)
        XCTAssertNil(state.tabDropTarget, file: file, line: line)
        XCTAssertNil(state.groupDropIndex, file: file, line: line)
    }
}
