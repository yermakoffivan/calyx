// WorktreeTaskSheetUITests.swift
// CalyxUITests
//
// Opens the New Worktree Task sheet from the command palette, checks
// every control is exposed under its accessibility identifier and that
// Create stays disabled with an empty branch name, then cancels. No
// agent CLI is launched.

import XCTest

final class WorktreeTaskSheetUITests: CalyxUITestCase {

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func test_openFromPalette_showsAllControls_createDisabled_cancelDismisses() {
        openCommandPaletteViaMenu()
        let searchField = element("calyx.commandPalette.searchField")
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")

        searchField.typeText("New Worktree Task")
        searchField.typeKey(.enter, modifierFlags: [])

        let sheet = element("calyx.worktreeTask.sheet")
        XCTAssertTrue(waitFor(sheet), "New Worktree Task sheet should appear")

        for identifier in [
            "calyx.worktreeTask.branchField",
            "calyx.worktreeTask.basePicker",
            "calyx.worktreeTask.agentPicker",
            "calyx.worktreeTask.promptField",
            "calyx.worktreeTask.createButton",
            "calyx.worktreeTask.cancelButton",
        ] {
            XCTAssertTrue(waitFor(element(identifier)), "\(identifier) should exist")
        }

        XCTAssertFalse(element("calyx.worktreeTask.createButton").isEnabled,
                       "Create must be disabled while the branch name is empty")

        element("calyx.worktreeTask.cancelButton").click()
        waitForNonExistence(sheet)
    }
}
