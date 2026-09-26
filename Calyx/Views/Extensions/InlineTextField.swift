// InlineTextField.swift
// Calyx
//
// A reusable inline text field for renaming items in place.
// Wraps NSTextField with click-outside-to-commit (any mouse button
// pressed outside the field commits), Enter/Escape handling, and
// focus requested on attachment to a window (see InlineEditorTextField).

import SwiftUI

/// The inline editor's text field. Requests keyboard focus the first
/// time it is attached to a window, in `viewDidMoveToWindow()`, because
/// SwiftUI attaches the field some time after `makeNSView` returns and
/// a focus request made before that point is silently ignored by
/// `selectText(_:)`. Later re-attachments do not take focus again.
final class InlineEditorTextField: NSTextField {
    private var hasRequestedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasRequestedInitialFocus else { return }
        hasRequestedInitialFocus = true
        selectText(nil)
    }
}

struct InlineTextField: NSViewRepresentable {
    let initialText: String
    let accessibilityID: String
    var fontSize: CGFloat = 12
    var fontWeight: NSFont.Weight = .semibold
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = InlineEditorTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.stringValue = initialText
        textField.delegate = context.coordinator
        textField.setAccessibilityIdentifier(accessibilityID)

        let systemFont = NSFont.systemFont(ofSize: fontSize, weight: fontWeight)
        if let rounded = systemFont.fontDescriptor.withDesign(.rounded) {
            textField.font = NSFont(descriptor: rounded, size: fontSize)
        } else {
            textField.font = systemFont
        }

        context.coordinator.textField = textField

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                context.coordinator.installClickMonitor()
            }
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        weak var textField: NSTextField?
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var clickMonitor: Any?
        private var didEnd = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func installClickMonitor() {
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, !self.didEnd else { return event }
                if let textField = self.textField,
                   let eventWindow = event.window,
                   eventWindow == textField.window {
                    let point = textField.convert(event.locationInWindow, from: nil)
                    if textField.bounds.contains(point) {
                        return event
                    }
                    if let editor = textField.currentEditor() {
                        let editorPoint = editor.convert(event.locationInWindow, from: nil)
                        if editor.bounds.contains(editorPoint) {
                            return event
                        }
                    }
                }
                self.finish(commit: true)
                return event
            }
        }

        private func finish(commit: Bool) {
            guard !didEnd else { return }
            didEnd = true
            removeClickMonitor()
            if commit {
                onCommit(textField?.stringValue ?? "")
            } else {
                onCancel()
            }
        }

        private func removeClickMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(commit: true)
        }

        isolated deinit {
            removeClickMonitor()
        }
    }
}
