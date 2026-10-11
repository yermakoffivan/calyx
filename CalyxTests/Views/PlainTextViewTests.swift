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

    func test_configure_appliesEditability() {
        let editable = makeSubstitutingTextView()
        makeView(isEditable: true).configure(editable)
        XCTAssertTrue(editable.isEditable)
        XCTAssertTrue(editable.isSelectable)

        let readOnly = makeSubstitutingTextView()
        makeView(isEditable: false).configure(readOnly)
        XCTAssertFalse(readOnly.isEditable)
        XCTAssertFalse(readOnly.isSelectable)
    }

    func test_worktreePromptEditor_usesBodyFontInsetAndPromptIdentifier() {
        let view = WorktreeTaskSheetView.promptTextView(text: .constant(""), isEditable: true)
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
        let view = WorktreeTaskSheetView.promptTextView(text: .constant(""), isEditable: false)
        let textView = makeSubstitutingTextView()
        view.configure(textView)
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
}
