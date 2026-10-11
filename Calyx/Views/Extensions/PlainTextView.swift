//
//  PlainTextView.swift
//  Calyx
//
//  A multi-line text area that never rewrites what is typed or pasted.
//  SwiftUI's `TextEditor` follows the system text settings, so smart
//  quotes turn `"` into `“ ”` and smart dashes turn `--flag` into
//  `—flag`; SwiftUI has no modifier for either on macOS. This wraps an
//  `NSTextView` with every automatic rewrite turned off, and takes the
//  font, text inset, accessibility identifier and editability from the
//  caller. Editability is a parameter because SwiftUI's `.disabled` does
//  not reach the `NSTextView`'s own `isEditable`.
//
//  Escape: `NSTextView` turns Escape into `cancelOperation(_:)`, which it
//  does not implement, so `doCommand(by:)` hands it up the responder
//  chain to `NSWindow.cancelOperation(_:)`. The key event itself never
//  reaches the window's key-equivalent dispatch, where SwiftUI's
//  `.keyboardShortcut(.cancelAction)` lives, so a sheet's Cancel button
//  does not fire while this view has focus. `onCancel` lets the caller
//  run its cancel action for that command instead.
//

import AppKit
import SwiftUI

struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textContainerInset: NSSize
    let accessibilityIdentifier: String
    var isEditable: Bool = true
    /// Horizontal padding `NSTextContainer` adds inside each side of the
    /// text inset. AppKit's default is 5 pt; the default here is 0 so
    /// `textContainerInset` alone states where the text starts.
    var lineFragmentPadding: CGFloat = 0
    /// Run for the text view's `cancelOperation(_:)` command (Escape),
    /// instead of `NSTextView`'s handling of it. `nil` leaves the command
    /// to `NSTextView`.
    var onCancel: (@MainActor () -> Void)? = nil

    /// Turns off every rewrite of typed or pasted text, applies this
    /// view's font, inset and editability, and sets the accessibility
    /// identifier on the text view itself, the element XCUITest finds.
    func configure(_ textView: NSTextView) {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = font
        textView.textContainerInset = textContainerInset
        textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        Self.configureScrollers(scrollView)
        let textView = Self.textView(in: scrollView)
        configure(textView)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCancel = onCancel
        let textView = Self.textView(in: scrollView)
        configure(textView)
        if textView.string != text {
            textView.string = text
        }
    }

    /// Keeps the vertical scroller but shows it only while the text
    /// overflows. A permanently visible scroller track takes width from
    /// the text container, so text would wrap early even when it fits.
    static func configureScrollers(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    /// `NSTextView.scrollableTextView()` documents its document view as
    /// an `NSTextView`; anything else is an AppKit contract violation.
    private static func textView(in scrollView: NSScrollView) -> NSTextView {
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() returned a scroll view without an NSTextView document view")
        }
        return textView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCancel: onCancel)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCancel: (@MainActor () -> Void)?

        init(text: Binding<String>, onCancel: (@MainActor () -> Void)?) {
            self.text = text
            self.onCancel = onCancel
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)),
                  let onCancel else { return false }
            onCancel()
            return true
        }

        func textDidChange(_ notification: Notification) {
            // NSText posts its delegate notifications with itself as the object.
            guard let textView = notification.object as? NSTextView else {
                preconditionFailure("textDidChange arrived without an NSTextView object")
            }
            text.wrappedValue = textView.string
        }
    }
}
