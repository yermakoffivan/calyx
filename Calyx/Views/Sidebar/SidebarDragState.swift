// SidebarDragState.swift
// Calyx
//
// Drag state tracking for the sidebar's tab and group drags.
// Freezes the sidebar layout when a drag starts, resolves the drop target
// (a slot in any group for a tab, a slot among the groups for a group
// header) and maps it to the move to perform when the drag ends.

import SwiftUI

// MARK: - SidebarLayoutSnapshot

/// The sidebar's groups in display order, with frames in the sidebar's
/// content coordinate space (`SidebarDragState.coordinateSpaceName`).
struct SidebarLayoutSnapshot: Equatable {
    struct TabRow: Equatable {
        let id: UUID
        /// Ignored (`.zero`) for the tabs of a collapsed group, which has
        /// no rows on screen.
        let frame: CGRect
    }

    struct Group: Equatable {
        let id: UUID
        let isCollapsed: Bool
        let headerFrame: CGRect
        /// Every tab of the group in model order, also when collapsed.
        let tabs: [TabRow]

        /// The header plus, when expanded, its rows.
        var sectionFrame: CGRect {
            guard !isCollapsed else { return headerFrame }
            return tabs.reduce(headerFrame) { $0.union($1.frame) }
        }
    }

    var groups: [Group]
}

extension SidebarLayoutSnapshot {
    /// Builds the snapshot of `groups` from measured frames, or `nil` if a
    /// header frame or an expanded group's row frame has not been measured.
    @MainActor
    init?(groups: [TabGroup], tabFrames: [UUID: CGRect], headerFrames: [UUID: CGRect]) {
        var snapshots: [Group] = []
        snapshots.reserveCapacity(groups.count)
        for group in groups {
            guard let headerFrame = headerFrames[group.id] else { return nil }
            var rows: [TabRow] = []
            rows.reserveCapacity(group.tabs.count)
            for tab in group.tabs {
                if group.isCollapsed {
                    rows.append(TabRow(id: tab.id, frame: .zero))
                } else {
                    guard let frame = tabFrames[tab.id] else { return nil }
                    rows.append(TabRow(id: tab.id, frame: frame))
                }
            }
            snapshots.append(Group(id: group.id, isCollapsed: group.isCollapsed, headerFrame: headerFrame, tabs: rows))
        }
        self.init(groups: snapshots)
    }
}

// MARK: - Drop Targets

struct SidebarTabDropTarget: Equatable {
    let groupID: UUID
    /// The tab's final index in the group.
    let index: Int
    /// The drop lands on the group header rather than between rows.
    let isOntoHeader: Bool
}

enum SidebarDropResolver {

    /// Where a tab dragged to `dragMidY` would land, or `nil` when that is
    /// where it already is.
    ///
    /// The target group is the last one whose header starts above
    /// `dragMidY` (the first group above all of them), so the gap below a
    /// group's last row still belongs to that group. A collapsed target
    /// takes the tab at its end. In an expanded target the index is the
    /// number of its other rows whose midpoint is above `dragMidY`, which
    /// is directly the tab's final index.
    static func tabDropTarget(
        draggedTabID: UUID,
        dragMidY: CGFloat,
        layout: SidebarLayoutSnapshot
    ) -> SidebarTabDropTarget? {
        guard let source = location(ofTab: draggedTabID, in: layout),
              let target = layout.groups.last(where: { $0.headerFrame.minY <= dragMidY }) ?? layout.groups.first
        else { return nil }

        let otherRows = target.tabs.filter { $0.id != draggedTabID }
        let result: SidebarTabDropTarget
        if target.isCollapsed {
            result = SidebarTabDropTarget(groupID: target.id, index: otherRows.count, isOntoHeader: true)
        } else {
            result = SidebarTabDropTarget(
                groupID: target.id,
                index: otherRows.filter { $0.frame.midY < dragMidY }.count,
                isOntoHeader: dragMidY < target.headerFrame.maxY
            )
        }

        guard result.groupID != source.groupID || result.index != source.index else { return nil }
        return result
    }

    /// The final index of a group whose header is dragged to `dragMidY`, or
    /// `nil` when that is its current index. Counts the other groups whose
    /// whole section (header plus visible rows) has its midpoint above
    /// `dragMidY`, so groups of very different heights swap at their middle.
    static func groupDropIndex(
        draggedGroupID: UUID,
        dragMidY: CGFloat,
        layout: SidebarLayoutSnapshot
    ) -> Int? {
        guard let currentIndex = layout.groups.firstIndex(where: { $0.id == draggedGroupID }) else { return nil }

        let index = layout.groups
            .filter { $0.id != draggedGroupID && $0.sectionFrame.midY < dragMidY }
            .count
        guard index != currentIndex else { return nil }
        return index
    }

    /// The group containing `tabID` and the tab's index in it.
    static func location(ofTab tabID: UUID, in layout: SidebarLayoutSnapshot) -> (groupID: UUID, index: Int)? {
        for group in layout.groups {
            if let index = group.tabs.firstIndex(where: { $0.id == tabID }) {
                return (group.id, index)
            }
        }
        return nil
    }
}

// MARK: - SidebarDropOutcome

enum SidebarDropOutcome: Equatable {
    case moveTabWithinGroup(groupID: UUID, fromIndex: Int, toIndex: Int)
    case moveTabToGroup(tabID: UUID, groupID: UUID, index: Int)
    case moveGroup(groupID: UUID, toIndex: Int)
}

// MARK: - SidebarDropIndicator

/// What the sidebar draws for the current drop target, in the content
/// coordinate space.
enum SidebarDropIndicator: Equatable {
    /// An insertion line between rows or group sections.
    case line(CGRect)
    /// A highlight around a group header the tab will be dropped onto.
    case header(CGRect)
}

// MARK: - SidebarDragState

@MainActor @Observable
final class SidebarDragState {

    enum Item: Equatable {
        case tab(UUID)
        case group(UUID)
    }

    /// The named coordinate space of the sidebar's tab-list content, in
    /// which every row and header frame is measured.
    static let coordinateSpaceName = "sidebarContent"

    private static let indicatorInset: CGFloat = 14
    private static let indicatorThickness: CGFloat = 2

    // MARK: Properties

    private(set) var item: Item?
    private(set) var dragOffset: CGFloat = 0
    private(set) var frozenLayout: SidebarLayoutSnapshot?
    private(set) var tabDropTarget: SidebarTabDropTarget?
    private(set) var groupDropIndex: Int?

    /// Latest measured frames, written on every preference change. Not
    /// observed: only a drag start reads them, so re-measuring must not
    /// re-render the sidebar.
    @ObservationIgnored var measuredTabFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var measuredHeaderFrames: [UUID: CGRect] = [:]

    // MARK: Updates

    /// `allowsWithinGroup` / `allowsCrossGroup` say whether the caller can
    /// perform a drop in the dragged tab's own group / in another group. A
    /// target on a disallowed route is dropped, so the indicator never
    /// points at a drop that would then do nothing.
    func updateTabDrag(
        tabID: UUID,
        translation: CGFloat,
        allowsWithinGroup: Bool = true,
        allowsCrossGroup: Bool = true,
        currentLayout: () -> SidebarLayoutSnapshot?
    ) {
        guard let layout = layoutForDrag(of: .tab(tabID), currentLayout: currentLayout) else { return }
        dragOffset = translation
        tabDropTarget = layout.groups.lazy
            .flatMap(\.tabs)
            .first { $0.id == tabID }
            .flatMap { row in
                SidebarDropResolver.tabDropTarget(
                    draggedTabID: tabID,
                    dragMidY: row.frame.midY + translation,
                    layout: layout
                )
            }
            .flatMap { target in
                guard let source = SidebarDropResolver.location(ofTab: tabID, in: layout) else { return nil }
                let isWithinGroup = source.groupID == target.groupID
                return (isWithinGroup ? allowsWithinGroup : allowsCrossGroup) ? target : nil
            }
    }

    func updateGroupDrag(groupID: UUID, translation: CGFloat, currentLayout: () -> SidebarLayoutSnapshot?) {
        guard let layout = layoutForDrag(of: .group(groupID), currentLayout: currentLayout) else { return }
        dragOffset = translation
        groupDropIndex = layout.groups
            .first { $0.id == groupID }
            .flatMap { group in
                SidebarDropResolver.groupDropIndex(
                    draggedGroupID: groupID,
                    dragMidY: group.headerFrame.midY + translation,
                    layout: layout
                )
            }
    }

    /// The move the current drop target asks for (`nil` if none). Always
    /// leaves the state idle.
    func endDrag() -> SidebarDropOutcome? {
        defer { reset() }
        switch item {
        case .tab(let tabID):
            guard let target = tabDropTarget,
                  let layout = frozenLayout,
                  let source = SidebarDropResolver.location(ofTab: tabID, in: layout)
            else { return nil }
            if source.groupID == target.groupID {
                return .moveTabWithinGroup(groupID: target.groupID, fromIndex: source.index, toIndex: target.index)
            }
            return .moveTabToGroup(tabID: tabID, groupID: target.groupID, index: target.index)
        case .group(let groupID):
            return groupDropIndex.map { .moveGroup(groupID: groupID, toIndex: $0) }
        case nil:
            return nil
        }
    }

    /// Clears the drag (not the measured frames, which stay current).
    func reset() {
        item = nil
        dragOffset = 0
        frozenLayout = nil
        tabDropTarget = nil
        groupDropIndex = nil
    }

    // MARK: Indicator

    /// The indicator for the current drop target, derived from the frozen
    /// layout so it stays put while the dragged views move.
    var dropIndicator: SidebarDropIndicator? {
        guard let layout = frozenLayout else { return nil }
        switch item {
        case .tab(let tabID):
            guard let target = tabDropTarget,
                  let group = layout.groups.first(where: { $0.id == target.groupID })
            else { return nil }
            if target.isOntoHeader {
                return .header(group.headerFrame)
            }
            let rows = group.tabs.filter { $0.id != tabID }.map(\.frame)
            let y = Self.slotY(index: target.index, frames: rows, emptyY: group.headerFrame.maxY)
            return .line(Self.lineRect(y: y, across: group.headerFrame))
        case .group(let groupID):
            guard let index = groupDropIndex,
                  let dragged = layout.groups.first(where: { $0.id == groupID })
            else { return nil }
            let sections = layout.groups.filter { $0.id != groupID }.map(\.sectionFrame)
            let y = Self.slotY(index: index, frames: sections, emptyY: dragged.headerFrame.minY)
            return .line(Self.lineRect(y: y, across: dragged.headerFrame))
        case nil:
            return nil
        }
    }

    // MARK: Private

    /// The frozen layout of the drag of `dragItem`, freezing `currentLayout()`
    /// when this is the first update of that drag. `nil` (the drag does not
    /// start) while the layout cannot be measured yet.
    ///
    /// Freezing happens BEFORE the first `dragOffset` write: rows and
    /// headers are measured inside their `.offset`, so a layout read after
    /// the offset is applied would place the dragged item where it is being
    /// drawn rather than where it started. Later updates keep the frozen
    /// layout, which stays correct because the model is not mutated until
    /// the drag ends.
    private func layoutForDrag(
        of dragItem: Item,
        currentLayout: () -> SidebarLayoutSnapshot?
    ) -> SidebarLayoutSnapshot? {
        if item == dragItem, let frozenLayout {
            return frozenLayout
        }
        guard let layout = currentLayout() else { return nil }
        // A different item means the previous drag never saw its end
        // (no mouseUp); start over from a clean state.
        reset()
        item = dragItem
        frozenLayout = layout
        return layout
    }

    /// The y of slot `index` among `frames` (sorted top to bottom): the top
    /// of the first, the bottom of the last, or midway between neighbours.
    private static func slotY(index: Int, frames: [CGRect], emptyY: CGFloat) -> CGFloat {
        guard let first = frames.first, let last = frames.last else { return emptyY }
        if index <= 0 { return first.minY }
        if index >= frames.count { return last.maxY }
        return (frames[index - 1].maxY + frames[index].minY) / 2
    }

    private static func lineRect(y: CGFloat, across frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + indicatorInset,
            y: y - indicatorThickness / 2,
            width: max(frame.width - indicatorInset * 2, 0),
            height: indicatorThickness
        )
    }
}

// MARK: - Preference Keys

/// Sidebar tab row frames in `SidebarDragState.coordinateSpaceName`.
struct SidebarTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Sidebar group header frames in `SidebarDragState.coordinateSpaceName`.
struct SidebarGroupHeaderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
