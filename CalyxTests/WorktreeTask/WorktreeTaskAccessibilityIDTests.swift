// WorktreeTaskAccessibilityIDTests.swift
// CalyxTests
//
// Pins the sheet's accessibility identifiers, which
// WorktreeTaskSheetUITests looks up as string literals.

import Testing
@testable import Calyx

struct WorktreeTaskAccessibilityIDTests {
    @Test func test_identifiers() {
        #expect(AccessibilityID.WorktreeTask.sheet == "calyx.worktreeTask.sheet")
        #expect(AccessibilityID.WorktreeTask.branchField == "calyx.worktreeTask.branchField")
        #expect(AccessibilityID.WorktreeTask.basePicker == "calyx.worktreeTask.basePicker")
        #expect(AccessibilityID.WorktreeTask.agentPicker == "calyx.worktreeTask.agentPicker")
        #expect(AccessibilityID.WorktreeTask.promptField == "calyx.worktreeTask.promptField")
        #expect(AccessibilityID.WorktreeTask.argumentsField == "calyx.worktreeTask.argumentsField")
        #expect(AccessibilityID.WorktreeTask.createButton == "calyx.worktreeTask.createButton")
        #expect(AccessibilityID.WorktreeTask.cancelButton == "calyx.worktreeTask.cancelButton")
        #expect(AccessibilityID.WorktreeTask.errorLabel == "calyx.worktreeTask.errorLabel")
    }
}
