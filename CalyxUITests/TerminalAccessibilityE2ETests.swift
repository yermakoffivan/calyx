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

    func test_terminalPaneValueContainsCJKLine() {
        XCTAssertTrue(waitFor(app.windows.firstMatch, timeout: 10), "main window did not appear")

        let pid = ProcessInfo.processInfo.processIdentifier
        let cjk = "日本語テスト全角ＡＢ\(pid)"
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-\(pid)-cjk.sh").path
        do {
            try "printf '%s\\n' '\(cjk)'\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("failed to write pane script \(scriptPath): \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        Thread.sleep(forTimeInterval: 1)
        // Same guard as PaneCLIExec.typePaneScript (private there): the path is typed unquoted.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard scriptPath.unicodeScalars.allSatisfy(allowed.contains) else {
            XCTFail("pane script path contains a character requiring quoting: \(scriptPath)")
            return
        }
        app.typeText("sh \(scriptPath)\n")

        let pane = app.textViews
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.terminal.pane."))
            .firstMatch
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane AX text area not found")

        var value = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            value = (pane.value as? String) ?? ""
            if value.contains(cjk) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(value.contains(cjk), "pane value did not contain CJK line: \(value.debugDescription)")

        let lines = value.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains(cjk), "no line was exactly the CJK text (spacer artifacts?): \(value.debugDescription)")

        let outputOccurrences = lines
            .filter { !$0.contains("sh ") }
            .reduce(0) { $0 + $1.components(separatedBy: cjk).count - 1 }
        XCTAssertEqual(outputOccurrences, 1, "CJK text not present exactly once in output lines: \(value.debugDescription)")
    }
}
