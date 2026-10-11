//
//  PlainTextViewTests.swift
//  CalyxTests
//
//  `PlainTextView` wraps an `NSTextView` that never rewrites typed text
//  and takes its font, text inset, identifier and editability from the
//  caller. The worktree task sheet's prompt editor uses it so a prompt
//  containing `"` or `--flag` reaches the agent unchanged.
//

import XCTest
import AppKit
import SwiftUI
@testable import Calyx

/// Next responder that records `cancelOperation(_:)` reaching it.
private final class CancelRecordingResponder: NSResponder {
    var cancelCount = 0
    override func cancelOperation(_ sender: Any?) {
        cancelCount += 1
    }
}

@MainActor
final class PlainTextViewTests: XCTestCase {

    private func makeSubstitutingTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextCompletionEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.isRichText = true
        return textView
    }

    private func makeView(isEditable: Bool = true) -> PlainTextView {
        PlainTextView(
            text: .constant("hello"),
            font: .systemFont(ofSize: 17),
            textContainerInset: NSSize(width: 2, height: 7),
            accessibilityIdentifier: "test.plainText",
            isEditable: isEditable
        )
    }

    func test_configure_disablesEverySubstitution() {
        let textView = makeSubstitutingTextView()
        makeView().configure(textView)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.smartInsertDeleteEnabled)
        XCTAssertFalse(textView.isRichText)
    }

    func test_configure_appliesFontInsetAndIdentifier() {
        let textView = makeSubstitutingTextView()
        makeView().configure(textView)
        XCTAssertEqual(textView.font, NSFont.systemFont(ofSize: 17))
        XCTAssertEqual(textView.textContainerInset, NSSize(width: 2, height: 7))
        XCTAssertEqual(textView.accessibilityIdentifier(), "test.plainText")
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
    }

    func test_applyEditability_appliesEditability() {
        let editable = makeSubstitutingTextView()
        makeView(isEditable: true).applyEditability(editable)
        XCTAssertTrue(editable.isEditable)
        XCTAssertTrue(editable.isSelectable)

        let readOnly = makeSubstitutingTextView()
        makeView(isEditable: false).applyEditability(readOnly)
        XCTAssertFalse(readOnly.isEditable)
        XCTAssertFalse(readOnly.isSelectable)
    }

    /// What `updateNSView` applies: editability only; the one-time
    /// configuration (font, inset, substitutions) is left as it is.
    func test_applyEditability_leavesOneTimeConfigurationAlone() {
        let textView = NSTextView()
        makeView().configure(textView)
        textView.font = .systemFont(ofSize: 9)
        textView.textContainerInset = NSSize(width: 1, height: 1)
        textView.isAutomaticQuoteSubstitutionEnabled = true

        makeView(isEditable: false).applyEditability(textView)

        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(textView.font, NSFont.systemFont(ofSize: 9))
        XCTAssertEqual(textView.textContainerInset, NSSize(width: 1, height: 1))
        XCTAssertTrue(textView.isAutomaticQuoteSubstitutionEnabled)
    }

    func test_worktreePromptEditor_usesBodyFontInsetAndPromptIdentifier() {
        let view = WorktreeTaskSheetView.promptTextView(text: .constant(""), isEditable: true, onCancel: {})
        let textView = makeSubstitutingTextView()
        view.configure(textView)
        XCTAssertEqual(textView.font, NSFont.preferredFont(forTextStyle: .body))
        XCTAssertEqual(textView.textContainerInset, WorktreeTaskSheetView.promptTextInset)
        XCTAssertEqual(WorktreeTaskSheetView.promptTextInset, NSSize(width: 6.5, height: 4.5))
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(textView.accessibilityIdentifier(), AccessibilityID.WorktreeTask.promptField)
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
    }

    func test_worktreePromptEditor_isReadOnlyWhenPromptNotAccepted() {
        let view = WorktreeTaskSheetView.promptTextView(text: .constant(""), isEditable: false, onCancel: {})
        let textView = makeSubstitutingTextView()
        view.applyEditability(textView)
        XCTAssertFalse(textView.isEditable)
    }

    func test_configureScrollers_keepsVerticalScrollerButAutohidesIt() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        PlainTextView.configureScrollers(scrollView)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertTrue(scrollView.autohidesScrollers)
    }

    // MARK: - Escape (cancelOperation)

    /// A configured text view whose delegate is `view`'s coordinator, as
    /// `makeNSView` wires it, with `stub` as its next responder.
    private func makeWiredTextView(
        _ view: PlainTextView,
        stub: NSResponder
    ) -> (NSTextView, PlainTextView.Coordinator) {
        let textView = NSTextView()
        view.configure(textView)
        let coordinator = view.makeCoordinator()
        textView.delegate = coordinator
        textView.nextResponder = stub
        return (textView, coordinator)
    }

    func test_cancelOperation_withOnCancel_runsOnCancelInsteadOfPassingItOn() {
        var cancelCount = 0
        let view = PlainTextView(
            text: .constant("hello"),
            font: .systemFont(ofSize: 17),
            textContainerInset: .zero,
            accessibilityIdentifier: "test.plainText",
            onCancel: { cancelCount += 1 }
        )
        let stub = CancelRecordingResponder()
        let (textView, coordinator) = makeWiredTextView(view, stub: stub)

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(stub.cancelCount, 0)
        withExtendedLifetime(coordinator) {}
    }

    func test_cancelOperation_withoutOnCancel_isLeftToTheTextView() {
        let stub = CancelRecordingResponder()
        let (textView, coordinator) = makeWiredTextView(makeView(), stub: stub)

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        // NSTextView does not implement cancelOperation(_:) and passes it
        // up the responder chain, unchanged by the coordinator.
        XCTAssertEqual(stub.cancelCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func test_otherCommands_areLeftToTheTextView() {
        var cancelCount = 0
        let view = PlainTextView(
            text: .constant("hello"),
            font: .systemFont(ofSize: 17),
            textContainerInset: .zero,
            accessibilityIdentifier: "test.plainText",
            onCancel: { cancelCount += 1 }
        )
        let (textView, coordinator) = makeWiredTextView(view, stub: CancelRecordingResponder())
        textView.string = "hello"
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(textView.string, "hell")
        XCTAssertEqual(cancelCount, 0)
        withExtendedLifetime(coordinator) {}
    }

    func test_worktreePromptEditor_escapeRunsTheSheetsCancelAction() {
        var cancelCount = 0
        let view = WorktreeTaskSheetView.promptTextView(
            text: .constant(""),
            isEditable: true,
            onCancel: { cancelCount += 1 }
        )
        let (textView, coordinator) = makeWiredTextView(view, stub: CancelRecordingResponder())

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(cancelCount, 1)
        withExtendedLifetime(coordinator) {}
    }
}
