// TerminalAccessibilityE2ETests.swift
// CalyxUITests
//
// The terminal pane is exposed as an AXTextArea whose value is the viewport text.

import XCTest

final class TerminalAccessibilityE2ETests: CalyxUITestCase {

    func test_terminalPaneValueContainsEchoedMarker() {
        XCTAssertTrue(waitFor(app.windows.firstMatch, timeout: 10), "main window did not appear")

        let marker = "CALYXAXMARKER\(ProcessInfo.processInfo.processIdentifier)"
        panePasteAndReturn("echo \(marker)")

        let pane = app.textViews
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.terminal.pane."))
            .firstMatch
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane AX text area not found")

        var value = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            value = (pane.value as? String) ?? ""
            if value.contains(marker) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(value.contains(marker), "pane value did not contain echoed marker: \(value)")
        XCTAssertFalse(value.hasSuffix("\n\n"), "trailing empty rows were not trimmed")
    }
}
