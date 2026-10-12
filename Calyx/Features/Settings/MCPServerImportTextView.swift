//
//  MCPServerImportTextView.swift
//  Calyx
//
//  The JSON text area of the MCP server import sheet: a `PlainTextView`
//  (no smart quotes or dashes, which would break or silently alter the
//  JSON) in a monospaced font. Escape in it runs `onCancel`, the
//  sheet's Cancel action.
//

import AppKit
import SwiftUI

struct MCPServerImportTextView: View {
    @Binding var text: String
    var onCancel: (@MainActor () -> Void)? = nil

    private static func plainTextView(
        text: Binding<String>,
        onCancel: (@MainActor () -> Void)? = nil
    ) -> PlainTextView {
        PlainTextView(
            text: text,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textContainerInset: .zero,
            accessibilityIdentifier: AccessibilityID.MCPServersSettings.importTextView,
            // AppKit's default padding, which this view has always used.
            lineFragmentPadding: 5,
            onCancel: onCancel
        )
    }

    /// Applies the import sheet's text view configuration.
    @MainActor
    static func configure(_ textView: NSTextView) {
        plainTextView(text: .constant("")).configure(textView)
    }

    var body: some View {
        Self.plainTextView(text: $text, onCancel: onCancel)
    }
}
