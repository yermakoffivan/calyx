// WorktreeTaskSheetController.swift
// Calyx
//
// Hosts WorktreeTaskSheetView in a sheet window, the same shape as
// ClipboardConfirmationController. Describes the repository at the
// pane's cwd on open; outside a repository the sheet still opens with an
// error and Create disabled.

import AppKit
import SwiftUI

@MainActor
final class WorktreeTaskSheetController: NSWindowController, NSWindowDelegate {
    let model = WorktreeTaskSheetModel()
    private let onCreate: (WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void
    private let onCancel: () -> Void
    private var didFinish = false
    private var describeTask: Task<Void, Never>?

    static let notARepositoryMessage = "Not inside a git repository"

    init(
        cwd: String?,
        onCreate: @escaping (WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCreate = onCreate
        self.onCancel = onCancel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Worktree Task"

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: WorktreeTaskSheetView(
            model: model,
            onCreate: { [weak self] in self?.create() },
            onCancel: { [weak self] in self?.cancel() }
        ))

        let model = self.model
        guard let cwd else {
            model.isLoading = false
            model.errorMessage = Self.notARepositoryMessage
            return
        }
        describeTask = Task { @MainActor in
            do {
                let description = try await WorktreeTaskService.describeRepository(cwd: cwd)
                model.apply(description)
            } catch {
                model.isLoading = false
                model.errorMessage = Self.notARepositoryMessage
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Marks the sheet busy while the caller creates the task, or clears
    /// that state when creation failed and the sheet stays open.
    func setBusy(_ busy: Bool) {
        model.isLoading = busy
    }

    /// Ends the sheet without reporting a cancel.
    func dismiss() {
        didFinish = true
        describeTask?.cancel()
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: - Private

    private func create() {
        guard model.canCreate, let repository = model.repository else { return }
        onCreate(model.request, repository)
    }

    private func cancel() {
        guard !didFinish else { return }
        dismiss()
        onCancel()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        describeTask?.cancel()
        onCancel()
    }
}
