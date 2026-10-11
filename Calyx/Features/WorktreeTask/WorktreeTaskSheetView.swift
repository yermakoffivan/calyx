// WorktreeTaskSheetView.swift
// Calyx
//
// The New Worktree Task sheet: branch name, base branch, agent CLI and an
// optional initial prompt.

import AppKit
import Observation
import SwiftUI

/// State behind the New Worktree Task sheet.
@MainActor @Observable
final class WorktreeTaskSheetModel {
    var branch = ""
    var base = ""
    /// Switching agents keeps what was typed: the text is stashed under
    /// the previous agent and the new agent gets its stashed text from
    /// this sheet, else its remembered text.
    var agent: WorktreeTaskAgentKind = .claudeCode {
        didSet {
            argumentsStash[oldValue] = argumentsText
            argumentsText = argumentsStash[agent] ?? remembered(for: agent)
        }
    }
    var prompt = ""
    /// The "Arguments" field as typed; `argumentsError` follows it.
    var argumentsText = "" {
        didSet { parseArguments() }
    }
    /// Why `argumentsText` does not parse; nil when it does.
    private(set) var argumentsError: String?
    /// `argumentsText` parsed; meaningful only while `argumentsError` is nil.
    private var parsedArguments: [String] = []
    var localBranches: [String] = []
    var repoDisplayName: String?
    /// True while the repository is being described or a task is being
    /// created.
    var isLoading = true
    var errorMessage: String?
    /// The repository the sheet was opened against; nil until described
    /// or when the pane is not inside a git repository.
    var repository: WorktreeTaskRepositoryDescription?

    /// Where the last-used "Arguments" text per agent is remembered; nil
    /// remembers nothing (the coordinator's contract).
    @ObservationIgnored private let argumentMemory: WorktreeTaskArgumentMemory?
    /// "Arguments" text typed in this sheet, per agent switched away from.
    @ObservationIgnored private var argumentsStash: [WorktreeTaskAgentKind: String] = [:]

    init(argumentMemory: WorktreeTaskArgumentMemory?) {
        self.argumentMemory = argumentMemory
        argumentsText = remembered(for: agent)
        parseArguments()
    }

    private func remembered(for kind: WorktreeTaskAgentKind) -> String {
        guard let argumentMemory else { return "" }
        return argumentMemory.arguments(for: kind)
    }

    private func parseArguments() {
        do {
            parsedArguments = try WorktreeTaskArgumentParser.parse(argumentsText)
            argumentsError = nil
        } catch {
            parsedArguments = []
            switch error {
            case .unterminatedQuote: argumentsError = "Arguments have an unterminated quote"
            case .danglingEscape: argumentsError = "Arguments end with a dangling backslash"
            }
        }
    }

    /// Whether the selected agent takes the initial prompt; the prompt
    /// field is disabled when it does not.
    var acceptsPrompt: Bool {
        agent.acceptsInitialPrompt
    }

    var canCreate: Bool {
        !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !base.isEmpty
            && !isLoading
            && repository != nil
            && argumentsError == nil
    }

    /// Fills the pickers from a described repository. The base defaults
    /// to the branch checked out at the pane's cwd.
    func apply(_ description: WorktreeTaskRepositoryDescription) {
        repository = description
        repoDisplayName = description.displayName
        localBranches = description.localBranches
        if let head = description.headBranch, description.localBranches.contains(head) {
            base = head
        } else {
            base = description.localBranches.first ?? ""
        }
        errorMessage = nil
        isLoading = false
    }

    /// The request and repository to create a task from, marking the
    /// sheet busy before returning so a second Create (a repeated Return)
    /// is refused synchronously, before any async hop; nil while Create
    /// is not possible.
    func beginCreate() -> (request: WorktreeTaskRequest, repository: WorktreeTaskRepositoryDescription)? {
        guard canCreate, let repository else { return nil }
        isLoading = true
        return (request, repository)
    }

    var request: WorktreeTaskRequest {
        WorktreeTaskRequest(
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            base: base,
            agent: agent,
            prompt: prompt,
            arguments: parsedArguments,
            argumentsText: argumentsText
        )
    }
}

struct WorktreeTaskSheetView: View {
    @Bindable var model: WorktreeTaskSheetModel
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            fields
            promptEditor
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .accessibilityIdentifier(AccessibilityID.WorktreeTask.errorLabel)
            }
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.WorktreeTask.sheet)
    }

    private var header: some View {
        HStack {
            Text("New Worktree Task").font(.headline)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else if let name = model.repoDisplayName {
                Text(name).foregroundStyle(.secondary)
            }
        }
    }

    /// Width of the widest field label, measured from the rendered
    /// labels; nil until the first layout pass reports it.
    @State private var labelWidth: CGFloat?

    /// Horizontal gap between a label and its control.
    private static let labelSpacing: CGFloat = 8

    /// One labelled row: the label left-aligned in a column as wide as the
    /// widest label, the control starting right after it.
    private func fieldRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.labelSpacing) {
            Text(label)
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FieldLabelWidthKey.self, value: proxy.size.width)
                })
                .frame(width: labelWidth, alignment: .leading)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The labelled rows. Each row is an explicit HStack whose label
    /// frame is `.leading`-aligned, so labels share the content's left
    /// edge and every control starts at labelWidth + 8.
    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldRow("Branch") {
                TextField("Branch", text: $model.branch, prompt: Text("task/my-change"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.WorktreeTask.branchField)
            }
            fieldRow("Base") {
                basePicker
                    .labelsHidden()
                    .fixedSize()
            }
            fieldRow("Agent") {
                agentPicker
                    .labelsHidden()
                    .fixedSize()
            }
            argumentsField
        }
        .onPreferenceChange(FieldLabelWidthKey.self) { width in
            labelWidth = width
        }
    }

    /// Always rendered, even with no branches yet, so the control (and
    /// its identifier) exists while the repository is being described.
    private var basePicker: some View {
        Picker("Base", selection: $model.base) {
            if model.localBranches.isEmpty {
                Text("—").tag("")
            }
            ForEach(model.localBranches, id: \.self) { branch in
                Text(branch).tag(branch)
            }
        }
        .disabled(model.localBranches.isEmpty)
        .accessibilityIdentifier(AccessibilityID.WorktreeTask.basePicker)
    }

    private var agentPicker: some View {
        Picker("Agent", selection: $model.agent) {
            ForEach(WorktreeTaskAgentKind.allCases) { kind in
                Text(kind.displayName).tag(kind)
            }
        }
        .accessibilityIdentifier(AccessibilityID.WorktreeTask.agentPicker)
    }

    /// The Arguments field: a `PlainTextField`, so `"` and `--flag` reach
    /// the parser without smart-quote/dash rewrites. Rounded bezel like
    /// the Branch field; monospaced body font for the typed text.
    static func argumentsTextField(text: Binding<String>) -> PlainTextField {
        PlainTextField(
            text: text,
            placeholder: "--model opus --effort high",
            font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular),
            accessibilityIdentifier: AccessibilityID.WorktreeTask.argumentsField
        )
    }

    /// Extra CLI arguments, split by `WorktreeTaskArgumentParser`.
    /// A parse error shows below the field, in the control column.
    private var argumentsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldRow("Arguments") {
                Self.argumentsTextField(text: $model.argumentsText)
            }
            if let message = model.argumentsError {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.leading, (labelWidth ?? 0) + Self.labelSpacing)
            }
        }
    }

    /// Text inset of the prompt editor. These are measured values, not
    /// derived from NSTextField internals: at 1x, the roundedBorder Branch
    /// field above draws its first ink pixel 7 pt in from its outer border
    /// line and 9 pt down; this inset reproduces those border-to-ink
    /// distances inside the editor's 0.5 pt stroke. `PlainTextView` sets
    /// `lineFragmentPadding` to 0, so this inset alone positions the text
    /// (height applies to top and bottom).
    static let promptTextInset = NSSize(width: 6.5, height: 4.5)

    /// The prompt editor: a `PlainTextView`, so a prompt containing `"`
    /// or `--flag` reaches the agent without smart-quote/dash rewrites.
    /// Escape in the editor runs `onCancel`, the Cancel button's action.
    static func promptTextView(
        text: Binding<String>,
        isEditable: Bool,
        onCancel: @escaping () -> Void
    ) -> PlainTextView {
        PlainTextView(
            text: text,
            font: .preferredFont(forTextStyle: .body),
            textContainerInset: promptTextInset,
            accessibilityIdentifier: AccessibilityID.WorktreeTask.promptField,
            isEditable: isEditable,
            onCancel: onCancel
        )
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Initial prompt (optional)").font(.callout).foregroundStyle(.secondary)
            Self.promptTextView(text: $model.prompt, isEditable: model.acceptsPrompt, onCancel: onCancel)
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                .opacity(model.acceptsPrompt ? 1 : 0.5)
            if !model.acceptsPrompt {
                Text("\(model.agent.displayName) starts without an initial prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.WorktreeTask.cancelButton)
            Button("Create & Launch", action: onCreate)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCreate)
                .accessibilityIdentifier(AccessibilityID.WorktreeTask.createButton)
        }
    }
}

/// The widest field label width in the New Worktree Task sheet.
private struct FieldLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
