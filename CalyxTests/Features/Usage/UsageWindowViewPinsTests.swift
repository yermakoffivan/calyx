//
//  UsageWindowViewPinsTests.swift
//  CalyxTests
//
//  Pins the pieces of the Usage window (`UsageWindowView`, R5c) that a
//  unit test can observe: the table's column titles and lines, what an
//  unreported row shows in the Effort column, the thread picker's titles
//  and values, the footnote and the delete dialog's message, the texts
//  that stay as they were, and the reception status line's identifier
//  and when it is shown. The view builds its table, pickers and texts
//  from exactly these members. Where they are drawn is not observable
//  here: an offscreen NSHostingView exposes no SwiftUI accessibility
//  children to a unit test.
//

import XCTest
@testable import Calyx

@MainActor
final class UsageWindowViewPinsTests: XCTestCase {

    private func row(
        id: String, model: String?, effort: String?, unreported: Bool = false, input: Int64 = 1
    ) -> UsageWindowModel.Row {
        UsageWindowModel.Row(
            id: id, model: model, effort: effort, isUnreported: unreported,
            tokens: UsageTokenTotals(input: input, output: 0, cacheRead: 0, cacheCreation: 0))
    }

    // MARK: - Table

    func test_columnTitles_areModelEffortInputCacheReadCacheWriteOutput_inOrder() {
        XCTAssertEqual(
            UsageWindowView.columnTitles, ["Model", "Effort", "Input", "Cache Read", "Cache Write", "Output"])
    }

    func test_columnTitles_haveNoVersion1Columns() {
        for removed in ["Responses", "Thinking", "Final"] {
            XCTAssertFalse(UsageWindowView.columnTitles.contains(removed), removed)
        }
    }

    func test_effortText_ofAnUnreportedRow_isUnreported_andItsModelIsShownAsUsual() {
        let unreported = row(id: "u", model: "claude-opus", effort: nil, unreported: true)

        XCTAssertEqual(UsageWindowView.effortText(for: unreported), "unreported")
        XCTAssertEqual(UsageWindowView.modelText(for: unreported), "claude-opus")
    }

    func test_effortText_ofARecordedRow_isItsEffort_orAnEmDash() {
        XCTAssertEqual(UsageWindowView.effortText(for: row(id: "a", model: "m", effort: "high")), "high")
        XCTAssertEqual(UsageWindowView.effortText(for: row(id: "b", model: "m", effort: nil)), "\u{2014}")
    }

    func test_modelText_ofARowWithoutAModel_isAnEmDash() {
        XCTAssertEqual(UsageWindowView.modelText(for: row(id: "a", model: nil, effort: "high")), "\u{2014}")
    }

    func test_tableLines_areTheRowsInOrder_thenTotalLast() {
        let rows = [
            row(id: "r1", model: "claude-opus", effort: "high", input: 3),
            row(id: "r2", model: "claude-opus", effort: nil, unreported: true, input: 4),
        ]
        let totals = UsageTokenTotals(input: 7, output: 1, cacheRead: 2, cacheCreation: 3)

        let lines = UsageWindowView.tableLines(rows: rows, totals: totals)

        XCTAssertEqual(lines.map(\.model), ["claude-opus", "claude-opus", "Total"])
        XCTAssertEqual(lines.map(\.effort), ["high", "unreported", ""])
        XCTAssertEqual(lines.map(\.isTotal), [false, false, true])
        XCTAssertEqual(lines.map(\.tokens.input), [3, 4, 7])
        XCTAssertEqual(lines.last?.tokens, totals)
        XCTAssertEqual(Set(lines.map(\.id)).count, 3, "line ids collide: \(lines.map(\.id))")
    }

    func test_tableLines_withoutTotals_haveNoTotalLine() {
        let lines = UsageWindowView.tableLines(rows: [row(id: "r1", model: "m", effort: "low")], totals: nil)

        XCTAssertEqual(lines.map(\.model), ["m"])
        XCTAssertEqual(lines.map(\.isTotal), [false])
    }

    // MARK: - Thread picker

    func test_threadChoices_areAllMainSubagentsAuxiliary_withTheirLabels() {
        XCTAssertEqual(UsageWindowView.threadChoices.map(\.title), ["All", "Main", "Subagents", "Auxiliary"])
        XCTAssertEqual(UsageWindowView.threadChoices.map(\.thread), [nil, "main", "subagent", "auxiliary"])
    }

    // MARK: - Texts

    func test_footnote_isExact() {
        XCTAssertEqual(
            UsageWindowView.footnote,
            "Token counts are Claude Code's own, received while Calyx is running. Rows marked unreported are "
                + "tokens Claude Code counted in a tracked session that Calyx did not receive (for example because "
                + "it was not running); their effort is not known. Thinking tokens are part of Output.")
    }

    func test_deleteDialogMessage_isExact() {
        XCTAssertEqual(
            UsageWindowView.deleteDialogMessage,
            "All recorded usage is deleted. Sessions that are still running are counted from now on; what they "
                + "used before is not restored.")
    }

    func test_trackingOffBannerAndEmptyState_areUnchanged() {
        XCTAssertEqual(
            UsageWindowView.trackingOffText,
            "Usage tracking is off (Settings > Agents > Usage Tracking). Stored data is shown.")
        XCTAssertEqual(UsageWindowView.emptyStateText, "No usage recorded for this selection.")
    }

    // MARK: - Status line

    func test_statusLine_accessibilityIdentifier_isTheExactLiteral() {
        XCTAssertEqual(AccessibilityID.Usage.statusLine, "calyx.usage.statusLine")
    }

    func test_statusLine_isDistinctFromTheWindowsOtherIdentifiers() {
        let others = [
            AccessibilityID.Usage.periodPicker, AccessibilityID.Usage.projectPicker,
            AccessibilityID.Usage.threadPicker, AccessibilityID.Usage.table, AccessibilityID.Usage.refreshButton,
            AccessibilityID.Usage.deleteButton, AccessibilityID.Usage.trackingOffBanner,
            AccessibilityID.Usage.footnote,
        ]
        XCTAssertFalse(others.contains(AccessibilityID.Usage.statusLine))
    }

    func test_statusLine_isAbsentForAnEmptyText() {
        XCTAssertNil(UsageWindowView.statusLine(for: ""))
    }

    func test_statusLine_showsANonEmptyTextAsItIs() {
        XCTAssertEqual(
            UsageWindowView.statusLine(for: "Not receiving: AI Agent IPC is off."),
            "Not receiving: AI Agent IPC is off.")
    }
}
