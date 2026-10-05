// UsageWindowView.swift
// Calyx
//
// SwiftUI content view for `UsageWindowController`: three filters, a
// model x effort table with a totals row, and the notes a reader needs
// to compare these numbers with Claude Code's own. Every read goes
// through `UsageWindowModel.refresh()`; the view calls it whenever a
// filter changes, the model never does so by itself.

import SwiftUI

struct UsageWindowView: View {
    @Bindable var model: UsageWindowModel

    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterRow
            if !model.isTrackingEnabled {
                trackingOffBanner
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if model.rows.isEmpty && model.errorMessage == nil {
                Text("No usage recorded for this selection.")
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
            Text(
                "All recorded usage is deleted. While Usage Tracking is on, sessions that are still running are "
                    + "read again from the start of their transcripts at their next event, so their usage reappears."
            )
        }
    }

    private static let footnote =
        "Output and thinking count only responses whose final transcript line was written (see the Final "
        + "column). Requests Claude Code does not write to its transcript are not included, so these numbers "
        + "are lower than Claude Code's own session totals (output by roughly 1\u{2013}3%, cache reads by more)."

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
                Text("All").tag(UsageRecord.Thread?.none)
                Text("Main").tag(UsageRecord.Thread?.some(.main))
                Text("Subagents").tag(UsageRecord.Thread?.some(.subagent))
                Text("Advisor").tag(UsageRecord.Thread?.some(.advisor))
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
            Text("Usage tracking is off (Settings > Agents > Usage Tracking). Stored data is shown.")
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
    let totals: UsageRow?

    /// A table line: one model x effort row, or the totals.
    private struct Line: Identifiable {
        let id: String
        let model: String
        let effort: String
        let usage: UsageRow
        let isTotal: Bool
    }

    private var lines: [Line] {
        let rowLines = rows.map { row in
            Line(
                id: "row:" + row.id, model: row.model ?? "\u{2014}", effort: row.effort ?? "\u{2014}",
                usage: row.usage, isTotal: false)
        }
        guard let totals else { return rowLines }
        return rowLines + [Line(id: "total", model: "Total", effort: "", usage: totals, isTotal: true)]
    }

    var body: some View {
        Table(lines) {
            TableColumn("Model") { line in cell(line.model, line) }
            TableColumn("Effort") { line in cell(line.effort, line) }
                .width(min: 50, ideal: 70)
            TableColumn("Responses") { line in number(line.usage.responses, line) }
            TableColumn("Input") { line in number(line.usage.inputTokens, line) }
            TableColumn("Cache Read") { line in number(line.usage.cacheReadTokens, line) }
            TableColumn("Cache Write") { line in number(line.usage.cacheCreationTokens, line) }
            TableColumn("Output") { line in number(line.usage.outputTokensFinal, line) }
            TableColumn("Thinking") { line in number(line.usage.thinkingTokensFinal, line) }
            TableColumn("Final") { line in
                cell(
                    UsageWindowModel.finalPercentText(
                        final: line.usage.finalResponses, responses: line.usage.responses),
                    line
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 52)
        }
        .accessibilityIdentifier(AccessibilityID.Usage.table)
    }

    private func cell(_ text: String, _ line: Line) -> some View {
        Text(text).fontWeight(line.isTotal ? .semibold : .regular)
    }

    /// Grouped by the locale's convention and right-aligned.
    private func number(_ value: Int64, _ line: Line) -> some View {
        cell(value.formatted(.number.grouping(.automatic)), line)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
