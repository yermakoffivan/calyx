// UsageWindowView.swift
// Calyx
//
// SwiftUI content view for `UsageWindowController`: three filters, the
// reception status line, a model x effort table of Claude Code's own
// token counts with a totals row, and the note on how to read it. Its
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
                UsageTable(rows: model.rows, totals: model.totals)
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
        .frame(minWidth: 760, minHeight: 360)
        .onChange(of: model.period) { refresh() }
        .onChange(of: model.project) { refresh() }
        .onChange(of: model.thread) { refresh() }
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

    // MARK: - Texts and row mapping

    /// The table's column titles, in order.
    enum Column {
        static let model = "Model"
        static let effort = "Effort"
        static let input = "Input"
        static let cacheRead = "Cache Read"
        static let cacheWrite = "Cache Write"
        static let output = "Output"
    }

    static let columnTitles = [
        Column.model, Column.effort, Column.input, Column.cacheRead, Column.cacheWrite, Column.output,
    ]

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

    /// Shown for a missing model or effort.
    private static let missingText = "\u{2014}"

    /// The totals line's Model column.
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

    static func modelText(for row: UsageWindowModel.Row) -> String {
        row.model ?? missingText
    }

    static func effortText(for row: UsageWindowModel.Row) -> String {
        row.isUnreported ? unreportedEffortText : (row.effort ?? missingText)
    }

    /// A table line: one row, or the totals.
    struct Line: Identifiable, Equatable {
        let id: String
        let model: String
        let effort: String
        let tokens: UsageTokenTotals
        let isTotal: Bool
    }

    /// The rows in order, then the totals line when there are totals.
    static func tableLines(rows: [UsageWindowModel.Row], totals: UsageTokenTotals?) -> [Line] {
        let rowLines = rows.map { row in
            Line(
                id: "row:" + row.id, model: modelText(for: row), effort: effortText(for: row),
                tokens: row.tokens, isTotal: false)
        }
        guard let totals else { return rowLines }
        return rowLines + [Line(id: "total", model: totalText, effort: "", tokens: totals, isTotal: true)]
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
                Text("All Projects").tag(UsageWindowModel.ProjectChoice.all)
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

            Spacer()

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Refresh") { refresh() }
                .accessibilityIdentifier(AccessibilityID.Usage.refreshButton)
        }
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
            Text("All Projects")
        case .root(let path):
            Text(UsageWindowModel.projectLabel(root: path, home: NSHomeDirectory())).help(path)
        case .unattributed:
            Text("Unattributed")
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

/// The model x effort table, its last line the totals of the selection.
private struct UsageTable: View {
    let rows: [UsageWindowModel.Row]
    let totals: UsageTokenTotals?

    private typealias Column = UsageWindowView.Column

    var body: some View {
        Table(UsageWindowView.tableLines(rows: rows, totals: totals)) {
            TableColumn(Column.model) { line in cell(line.model, line) }
            TableColumn(Column.effort) { line in cell(line.effort, line) }
                .width(min: 50, ideal: 80)
            TableColumn(Column.input) { line in number(line.tokens.input, line) }
            TableColumn(Column.cacheRead) { line in number(line.tokens.cacheRead, line) }
            TableColumn(Column.cacheWrite) { line in number(line.tokens.cacheCreation, line) }
            TableColumn(Column.output) { line in number(line.tokens.output, line) }
        }
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
