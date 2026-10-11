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
    var agent: WorktreeTaskAgentKind = .claudeCode
    var prompt = ""
    var localBranches: [String] = []
    var repoDisplayName: String?
    /// True while the repository is being described or a task is being
    /// created.
    var isLoading = true
    var errorMessage: String?
    /// The repository the sheet was opened against; nil until described
    /// or when the pane is not inside a git repository.
    var repository: WorktreeTaskRepositoryDescription?

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

    var request: WorktreeTaskRequest {
        WorktreeTaskRequest(
            branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
            base: base,
            agent: agent,
            prompt: prompt
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
            Form {
                TextField("Branch", text: $model.branch, prompt: Text("task/my-change"))
                    .accessibilityIdentifier(AccessibilityID.WorktreeTask.branchField)
                basePicker
                agentPicker
            }
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
