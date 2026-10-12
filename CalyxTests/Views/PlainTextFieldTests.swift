//
//  PlainTextFieldTests.swift
//  CalyxTests
//
//  `PlainTextField` wraps a rounded-bezel `NSTextField` whose field
//  editor never rewrites typed text. The worktree task sheet's Arguments
//  field uses it so `"` and `--flag` reach the argument parser unchanged.
//

import XCTest
import AppKit
import SwiftUI
@testable import Calyx

@MainActor
final class PlainTextFieldTests: XCTestCase {

    private func makeSubstitutingFieldEditor() -> NSTextView {
        let textView = NSTextView()
        textView.isFieldEditor = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        return textView
    }

    private func assertNoSubstitutions(_ textView: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled, file: file, line: line)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled, file: file, line: line)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled, file: file, line: line)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled, file: file, line: line)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled, file: file, line: line)
    }

    private func makeField() -> PlainTextField {
        PlainTextField(
            text: .constant(""),
            placeholder: "--flag",
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            accessibilityIdentifier: "test.plainField"
        )
    }

    func test_textShouldBeginEditing_disablesSubstitutionsOnTheFieldEditor_andAllowsEditing() {
        let coordinator = makeField().makeCoordinator()
        let fieldEditor = makeSubstitutingFieldEditor()

        let allowed = coordinator.control(NSTextField(), textShouldBeginEditing: fieldEditor)

        XCTAssertTrue(allowed)
        assertNoSubstitutions(fieldEditor)
    }

    func test_controlTextDidBeginEditing_disablesSubstitutionsOnTheFieldEditor() {
        let coordinator = makeField().makeCoordinator()
        let fieldEditor = makeSubstitutingFieldEditor()

        coordinator.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: NSTextField(),
            userInfo: ["NSFieldEditor": fieldEditor]
        ))

        assertNoSubstitutions(fieldEditor)
    }

    func test_configure_roundedBezelFontPlaceholderAndIdentifier() {
        let textField = NSTextField()
        makeField().configure(textField)
        XCTAssertTrue(textField.isBezeled)
        XCTAssertEqual(textField.bezelStyle, .roundedBezel)
        XCTAssertTrue(textField.isEditable)
        XCTAssertEqual(textField.font, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertEqual(textField.placeholderString, "--flag")
        XCTAssertEqual(textField.accessibilityIdentifier(), "test.plainField")
        XCTAssertTrue(textField.usesSingleLineMode)
    }

    func test_controlTextDidChange_writesTheBinding() {
        var text = ""
        let field = PlainTextField(
            text: Binding(get: { text }, set: { text = $0 }),
            placeholder: "", font: .systemFont(ofSize: 13), accessibilityIdentifier: "x"
        )
        let coordinator = field.makeCoordinator()
        let textField = NSTextField()
        textField.stringValue = "--model \"o3\""

        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))

        XCTAssertEqual(text, "--model \"o3\"")
    }

    func test_worktreeArgumentsField_usesMonospacedBodyFontPlaceholderAndArgumentsIdentifier() {
        let field = WorktreeTaskSheetView.argumentsTextField(text: .constant(""))
        let textField = NSTextField()
        field.configure(textField)
        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        XCTAssertEqual(textField.font, NSFont.monospacedSystemFont(ofSize: bodySize, weight: .regular))
        XCTAssertEqual(textField.placeholderString, "--model opus --effort high")
        XCTAssertEqual(textField.accessibilityIdentifier(), AccessibilityID.WorktreeTask.argumentsField)
        XCTAssertEqual(textField.bezelStyle, .roundedBezel)
    }
}
