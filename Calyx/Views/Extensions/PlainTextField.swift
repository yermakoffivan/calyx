//
//  PlainTextField.swift
//  Calyx
//
//  A single-line text field that never rewrites what is typed or pasted:
//  the single-line counterpart of `PlainTextView`. SwiftUI's `TextField`
//  edits through the window's field editor with the system text
//  settings, so smart quotes turn `"` into `“ ”` and smart dashes turn
//  `--flag` into `—flag`; SwiftUI has no modifier for either on macOS.
//  This wraps a rounded-bezel `NSTextField` (the look of a SwiftUI
//  `TextField` in a Form) and turns the rewrites off on the field editor
//  each time editing begins, since the field editor is shared by the
//  window and configured per edit.
//
//  Return is left to AppKit: the coordinator does not handle the field
//  editor's commands, so Return still reaches the window's default
//  button (a sheet's `.keyboardShortcut(.defaultAction)`).
//

import AppKit
import SwiftUI

struct PlainTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let accessibilityIdentifier: String

    /// One-time setup, from `makeNSView` only: rounded bezel, font,
    /// placeholder, single-line scrolling, and the accessibility
    /// identifier on the `NSTextField` itself, the element XCUITest finds.
    func configure(_ textField: NSTextField) {
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.isEditable = true
        textField.isSelectable = true
        textField.font = font
        textField.placeholderString = placeholder
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.lineBreakMode = .byClipping
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        configure(textField)
        textField.stringValue = text
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    /// Turns off every rewrite of typed or pasted text on `fieldEditor`.
    static func configureFieldEditor(_ fieldEditor: NSTextView) {
        fieldEditor.isAutomaticQuoteSubstitutionEnabled = false
        fieldEditor.isAutomaticDashSubstitutionEnabled = false
        fieldEditor.isAutomaticTextReplacementEnabled = false
        fieldEditor.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.isAutomaticTextCompletionEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        /// Asked before the first change of an editing session is made,
        /// so even the first typed character is not rewritten.
        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            PlainTextField.configureFieldEditor(Self.textView(fieldEditor))
            return true
        }

        /// Posted once an editing session has begun; configures the field
        /// editor again in case another control reconfigured it since.
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let fieldEditor = obj.userInfo?["NSFieldEditor"] else {
                preconditionFailure("controlTextDidBeginEditing arrived without an NSFieldEditor")
            }
            guard let textView = fieldEditor as? NSTextView else {
                preconditionFailure("controlTextDidBeginEditing's field editor is not an NSTextView")
            }
            PlainTextField.configureFieldEditor(textView)
        }

        func controlTextDidChange(_ obj: Notification) {
            // NSControl posts its delegate notifications with itself as the object.
            guard let textField = obj.object as? NSTextField else {
                preconditionFailure("controlTextDidChange arrived without an NSTextField object")
            }
            text.wrappedValue = textField.stringValue
        }

        /// AppKit's field editor is an `NSTextView`; anything else is an
        /// AppKit contract violation.
        private static func textView(_ fieldEditor: NSText) -> NSTextView {
            guard let textView = fieldEditor as? NSTextView else {
                preconditionFailure("the field editor is not an NSTextView")
            }
            return textView
        }
    }
}
