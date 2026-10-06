// UsageWindowView.swift
// Calyx
//
// SwiftUI content view for `UsageWindowController`: three filters, the
// reception status line, a table of Claude Code's own token counts with
// a column per grouped dimension (the Columns menu) and a totals row, and the note on how to read it. Its
// texts and row mapping are the static members below (pinned by
// `UsageWindowViewPinsTests`); the body is built from them. Every read goes
// through `UsageWindowModel.refresh()`; the view calls it whenever a
// filter changes, the model never does so by itself.

import SwiftUI

struct UsageWindowView: View {
    @Bindable var model: UsageWindowModel

    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterRow
            if let statusLine = Self.statusLine(for: model.statusText) {
                Text(statusLine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.Usage.statusLine)
            }
            if !model.isTrackingEnabled {
                trackingOffBanner
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if model.rows.isEmpty && model.errorMessage == nil {
                Text(Self.emptyStateText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UsageTable(rows: model.rows, totals: model.totals, groupBy: model.rowsGroupBy)
            }
            Text(Self.footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.Usage.footnote)
            HStack {
                Spacer()
                Button("Delete Usage Data…", role: .destructive) {
                    isConfirmingDelete = true
                }
                .accessibilityIdentifier(AccessibilityID.Usage.deleteButton)
            }
        }
        .padding(14)
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .onChange(of: model.period) { refresh() }
        .onChange(of: model.project) { refresh() }
        .onChange(of: model.thread) { refresh() }
        .onChange(of: model.groupBy) { refresh() }
        .confirmationDialog(
            "Delete all usage data?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteAllData() }
            }
        } message: {
            Text(Self.deleteDialogMessage)
        }
    }

    // MARK: - Size

    /// The window's minimum content size: wide enough for four key
    /// columns and the four token columns at their ideal widths, plus the
    /// padding, the column gaps and the scroller.
    static let minimumWidth: CGFloat = 1220
    static let minimumHeight: CGFloat = 360

    /// The window's content size when it is first opened.
    static let initialSize = CGSize(width: 1220, height: 520)

    /// A table column's minimum and ideal width.
    struct ColumnWidth: Equatable {
        let min: CGFloat
        let ideal: CGFloat
    }

    /// The width of every token column.
    static let tokenColumnWidth = ColumnWidth(min: 90, ideal: 110)

    /// The width of a key column.
    static func columnWidth(for dimension: UsageTokenQuery.Dimension) -> ColumnWidth {
        switch dimension {
        case .day: ColumnWidth(min: 90, ideal: 100)
        case .model, .effort, .thread, .project, .agentType, .session: ColumnWidth(min: 90, ideal: 140)
        }
    }

    // MARK: - Texts and row mapping

    /// The table's column titles.
    enum Column {
        static let model = "Model"
        static let effort = "Effort"
        static let thread = "Thread"
        static let project = "Project"
        static let day = "Day"
        static let input = "Input"
        static let cacheRead = "Cache Read"
        static let cacheWrite = "Cache Write"
        static let output = "Output"
    }

    /// The token columns, after the key columns.
    static let tokenColumnTitles = [Column.input, Column.cacheRead, Column.cacheWrite, Column.output]

    /// The title of a key column (and of its Columns menu item).
    static func columnTitle(for dimension: UsageTokenQuery.Dimension) -> String {
        switch dimension {
        case .model: Column.model
        case .effort: Column.effort
        case .thread: Column.thread
        case .project: Column.project
        case .day: Column.day
        case .agentType: "Agent Type"
        case .session: "Session"
        }
    }

    /// One key column per `groupBy` member in key order, then the token
    /// columns.
    static func columnTitles(for groupBy: [UsageTokenQuery.Dimension]) -> [String] {
        groupBy.map(columnTitle(for:)) + tokenColumnTitles
    }

    static let footnote =
        "Token counts are Claude Code's own, received while Calyx is running. Rows marked unreported are "
        + "tokens Claude Code counted in a tracked session that Calyx did not receive (for example because "
        + "it was not running); their effort is not known. Thinking tokens are part of Output."

    static let deleteDialogMessage =
        "All recorded usage is deleted. Sessions that are still running are counted from now on; what they "
        + "used before is not restored."

    static let trackingOffText = "Usage tracking is off (Settings > Agents > Usage Tracking). Stored data is shown."

    static let emptyStateText = "No usage recorded for this selection."

    /// What an unreported row shows in the Effort column.
    static let unreportedEffortText = "unreported"

    /// The project picker's entry for every project.
    static let allProjectsText = "All Projects"

    /// The project picker's and the Project column's text for usage
    /// without a project.
    static let unattributedText = "Unattributed"

    /// Shown for any other missing value.
    private static let missingText = "\u{2014}"

    /// The totals line's first key column.
    private static let totalText = "Total"

    /// One entry of the thread picker: its title and the thread label it
    /// filters by (nil: every thread).
    struct ThreadChoice: Hashable {
        let title: String
        let thread: String?
    }

    static let threadChoices = [
        ThreadChoice(title: "All", thread: nil),
        ThreadChoice(title: "Main", thread: "main"),
        ThreadChoice(title: "Subagents", thread: "subagent"),
        ThreadChoice(title: "Auxiliary", thread: "auxiliary"),
    ]

    /// One item of the Columns menu.
    struct ColumnMenuItem: Hashable {
        let dimension: UsageTokenQuery.Dimension
        let title: String
        let accessibilityID: String
    }

    static let columnMenuItems: [ColumnMenuItem] = [.model, .effort, .thread, .project, .day].map { dimension in
        ColumnMenuItem(
            dimension: dimension, title: columnTitle(for: dimension),
            accessibilityID: AccessibilityID.Usage.column(dimension.rawValue))
    }

    /// The text of one key cell: `value` of `dimension` in a row.
    static func cellText(
        _ value: String?, for dimension: UsageTokenQuery.Dimension, isUnreported: Bool,
        home: String = NSHomeDirectory()
    ) -> String {
        switch dimension {
        case .effort where isUnreported:
            return unreportedEffortText
        case .project:
            return value.map { UsageWindowModel.projectLabel(root: $0, home: home) } ?? unattributedText
        default:
            return value ?? missingText
        }
    }

    /// A table line: one row, or the totals.
    struct Line: Identifiable, Equatable {
        let id: String
        /// One text per key column, in `groupBy` order.
        let cells: [String]
        let tokens: UsageTokenTotals
        let isTotal: Bool
    }

    /// The rows in order, then the totals line when there are totals. A
    /// key shorter than `groupBy` shows "—" in the missing columns.
    static func tableLines(
        rows: [UsageWindowModel.Row], totals: UsageTokenTotals?,
        groupBy: [UsageTokenQuery.Dimension], home: String = NSHomeDirectory()
    ) -> [Line] {
        let rowLines = rows.map { row in
            let cells = groupBy.enumerated().map { index, dimension in
                index < row.key.count
                    ? cellText(row.key[index], for: dimension, isUnreported: row.isUnreported, home: home)
                    : missingText
            }
            return Line(id: "row:" + row.id, cells: cells, tokens: row.tokens, isTotal: false)
        }
        guard let totals else { return rowLines }
        let totalCells = groupBy.indices.map { $0 == 0 ? totalText : "" }
        return rowLines + [Line(id: "total", cells: totalCells, tokens: totals, isTotal: true)]
    }

    /// The status line's text; nil (no line) for an empty status.
    static func statusLine(for statusText: String) -> String? {
        statusText.isEmpty ? nil : statusText
    }

    private func refresh() {
        Task { await model.refresh() }
    }

    private var filterRow: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $model.period) {
                ForEach(UsageWindowModel.Period.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.Usage.periodPicker)

            Picker("Project", selection: $model.project) {
                Text(Self.allProjectsText).tag(UsageWindowModel.ProjectChoice.all)
                ForEach(projectChoices, id: \.self) { choice in
                    projectLabel(choice).tag(choice)
                }
            }
            .frame(maxWidth: 260)
            .accessibilityIdentifier(AccessibilityID.Usage.projectPicker)

            Picker("Thread", selection: $model.thread) {
                ForEach(Self.threadChoices, id: \.self) { choice in
                    Text(choice.title).tag(choice.thread)
                }
            }
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.Usage.threadPicker)

            columnsMenu

            Spacer()

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { refresh() }
                .accessibilityIdentifier(AccessibilityID.Usage.refreshButton)
        }
    }

    /// Which dimensions get a column; a check mark on each one that is on.
    private var columnsMenu: some View {
        Menu("Columns") {
            ForEach(Self.columnMenuItems, id: \.self) { item in
                Toggle(
                    item.title,
                    isOn: Binding(
                        get: { model.groupBy.contains(item.dimension) },
                        set: { _ in model.toggleGrouping(item.dimension) }))
                .accessibilityIdentifier(item.accessibilityID)
            }
        }
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.Usage.columnsMenu)
    }

    /// The offered projects, plus the selected one when the ledger no
    /// longer offers it: the selection stays (the model never resets
    /// it), so the picker must still be able to show it.
    private var projectChoices: [UsageWindowModel.ProjectChoice] {
        guard model.project != .all, !model.projects.contains(model.project) else { return model.projects }
        return model.projects + [model.project]
    }

    @ViewBuilder
    private func projectLabel(_ choice: UsageWindowModel.ProjectChoice) -> some View {
        switch choice {
        case .all:
            Text(Self.allProjectsText)
        case .root(let path):
            Text(UsageWindowModel.projectLabel(root: path, home: NSHomeDirectory())).help(path)
        case .unattributed:
            Text(Self.unattributedText)
        }
    }

    private var trackingOffBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            Text(Self.trackingOffText)
            Spacer()
            Button("Open Settings") {
                SettingsWindowController.shared.showSettings()
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Usage.trackingOffBanner)
    }
}

extension UsageWindowModel.Period {
    fileprivate var title: String {
        switch self {
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        case .all: "All Time"
        }
    }
}

/// The usage table: a column per grouped dimension, then the token
/// columns; its last line the totals of the selection.
private struct UsageTable: View {
    let rows: [UsageWindowModel.Row]
    let totals: UsageTokenTotals?
    let groupBy: [UsageTokenQuery.Dimension]

    private typealias Column = UsageWindowView.Column

    private let tokenWidth = UsageWindowView.tokenColumnWidth

    private func keyWidth(_ dimension: UsageTokenQuery.Dimension) -> UsageWindowView.ColumnWidth {
        UsageWindowView.columnWidth(for: dimension)
    }

    /// One key column: its position in the key and its dimension.
    private struct KeyColumn: Hashable {
        let index: Int
        let dimension: UsageTokenQuery.Dimension
    }

    var body: some View {
        Table(UsageWindowView.tableLines(rows: rows, totals: totals, groupBy: groupBy)) {
            TableColumnForEach(groupBy.enumerated().map { KeyColumn(index: $0, dimension: $1) }, id: \.self) { column in
                TableColumn(UsageWindowView.columnTitle(for: column.dimension)) { line in
                    cell(column.index < line.cells.count ? line.cells[column.index] : "", line)
                }
                .width(min: keyWidth(column.dimension).min, ideal: keyWidth(column.dimension).ideal)
            }
            TableColumn(Column.input) { line in number(line.tokens.input, line) }
                .width(min: tokenWidth.min, ideal: tokenWidth.ideal)
            TableColumn(Column.cacheRead) { line in number(line.tokens.cacheRead, line) }
                .width(min: tokenWidth.min, ideal: tokenWidth.ideal)
            TableColumn(Column.cacheWrite) { line in number(line.tokens.cacheCreation, line) }
                .width(min: tokenWidth.min, ideal: tokenWidth.ideal)
            TableColumn(Column.output) { line in number(line.tokens.output, line) }
                .width(min: tokenWidth.min, ideal: tokenWidth.ideal)
        }
        .id(groupBy)
        .accessibilityIdentifier(AccessibilityID.Usage.table)
    }

    private func cell(_ text: String, _ line: UsageWindowView.Line) -> some View {
        Text(text).fontWeight(line.isTotal ? .semibold : .regular)
    }

    /// Grouped by the locale's convention and right-aligned.
    private func number(_ value: Int64, _ line: UsageWindowView.Line) -> some View {
        cell(value.formatted(.number.grouping(.automatic)), line)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
