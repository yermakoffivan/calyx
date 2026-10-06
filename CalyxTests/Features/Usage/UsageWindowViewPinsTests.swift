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
        id: String, key: [String?], unreported: Bool = false, input: Int64 = 1
    ) -> UsageWindowModel.Row {
        UsageWindowModel.Row(
            id: id, key: key, isUnreported: unreported,
            tokens: UsageTokenTotals(input: input, output: 0, cacheRead: 0, cacheCreation: 0))
    }

    private static let tokenTitles = ["Input", "Cache Read", "Cache Write", "Output"]
    private static let home = "/Users/someone"

    // MARK: - Table: column titles (R5e)

    func test_columnTitles_default_areModelEffortThreadProject_thenTheTokenColumns() {
        XCTAssertEqual(
            UsageWindowView.columnTitles(for: [.model, .effort, .thread, .project]),
            ["Model", "Effort", "Thread", "Project", "Input", "Cache Read", "Cache Write", "Output"])
    }

    func test_columnTitles_dayOn_threadOff_followTheKeyOrder() {
        XCTAssertEqual(
            UsageWindowView.columnTitles(for: [.day, .model, .effort, .project]),
            ["Day", "Model", "Effort", "Project"] + Self.tokenTitles)
    }

    func test_columnTitles_aSingleKeyColumn() {
        XCTAssertEqual(UsageWindowView.columnTitles(for: [.project]), ["Project"] + Self.tokenTitles)
    }

    func test_columnTitles_haveNoVersion1Columns() {
        let titles = UsageWindowView.columnTitles(for: [.day, .model, .effort, .thread, .project])
        for removed in ["Responses", "Thinking", "Final"] {
            XCTAssertFalse(titles.contains(removed), removed)
        }
    }

    // MARK: - Table: cell texts

    func test_cellText_model_isAsIs_orAnEmDash() {
        XCTAssertEqual(UsageWindowView.cellText("claude-opus", for: .model, isUnreported: false, home: Self.home), "claude-opus")
        XCTAssertEqual(UsageWindowView.cellText("claude-opus", for: .model, isUnreported: true, home: Self.home), "claude-opus")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .model, isUnreported: false, home: Self.home), "\u{2014}")
    }

    func test_cellText_effort_isAsIs_unreported_orAnEmDash() {
        XCTAssertEqual(UsageWindowView.cellText("high", for: .effort, isUnreported: false, home: Self.home), "high")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .effort, isUnreported: true, home: Self.home), "unreported")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .effort, isUnreported: false, home: Self.home), "\u{2014}")
    }

    func test_cellText_thread_isAsIs_andAnEmDashForAnUnreportedRow() {
        for thread in ["main", "subagent", "auxiliary"] {
            XCTAssertEqual(UsageWindowView.cellText(thread, for: .thread, isUnreported: false, home: Self.home), thread)
        }
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .thread, isUnreported: true, home: Self.home), "\u{2014}")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .thread, isUnreported: false, home: Self.home), "\u{2014}")
    }

    func test_cellText_project_isTildeAbbreviated_orUnattributed() {
        XCTAssertEqual(
            UsageWindowView.cellText("/Users/someone/work/app", for: .project, isUnreported: false, home: Self.home),
            "~/work/app")
        XCTAssertEqual(
            UsageWindowView.cellText("/opt/work/app", for: .project, isUnreported: false, home: Self.home),
            "/opt/work/app")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .project, isUnreported: false, home: Self.home), "Unattributed")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .project, isUnreported: true, home: Self.home), "Unattributed")
    }

    func test_cellText_day_isAsTheQueryReturnsIt_orAnEmDash() {
        XCTAssertEqual(UsageWindowView.cellText("2026-03-10", for: .day, isUnreported: false, home: Self.home), "2026-03-10")
        XCTAssertEqual(UsageWindowView.cellText(nil, for: .day, isUnreported: false, home: Self.home), "\u{2014}")
    }

    // MARK: - Table: lines

    func test_tableLines_default_cellsInKeyOrder_thenTotalFirstColumnOnly() {
        let rows = [
            row(id: "r1", key: ["claude-opus", "high", "main", "/Users/someone/work/app"], input: 3),
            row(id: "r2", key: ["claude-opus", nil, nil, nil], unreported: true, input: 4),
        ]
        let totals = UsageTokenTotals(input: 7, output: 1, cacheRead: 2, cacheCreation: 3)

        let lines = UsageWindowView.tableLines(
            rows: rows, totals: totals, groupBy: [.model, .effort, .thread, .project], home: Self.home)

        XCTAssertEqual(
            lines.map(\.cells),
            [
                ["claude-opus", "high", "main", "~/work/app"],
                ["claude-opus", "unreported", "\u{2014}", "Unattributed"],
                ["Total", "", "", ""],
            ])
        XCTAssertEqual(lines.map(\.isTotal), [false, false, true])
        XCTAssertEqual(lines.map(\.tokens.input), [3, 4, 7])
        XCTAssertEqual(lines.last?.tokens, totals)
        XCTAssertEqual(Set(lines.map(\.id)).count, 3, "line ids collide: \(lines.map(\.id))")
    }

    func test_tableLines_dayFirst_totalIsInTheDayColumn() {
        let rows = [row(id: "r1", key: ["2026-03-10", "/opt/x"])]
        let lines = UsageWindowView.tableLines(
            rows: rows, totals: UsageTokenTotals(input: 1, output: 0, cacheRead: 0, cacheCreation: 0),
            groupBy: [.day, .project], home: Self.home)

        XCTAssertEqual(lines.map(\.cells), [["2026-03-10", "/opt/x"], ["Total", ""]])
    }

    func test_tableLines_aKeyShorterThanGroupBy_showsEmDashes_withoutTrapping() {
        let lines = UsageWindowView.tableLines(
            rows: [row(id: "r1", key: ["m"])], totals: nil, groupBy: [.model, .effort, .thread], home: Self.home)

        XCTAssertEqual(lines.map(\.cells), [["m", "\u{2014}", "\u{2014}"]])
    }

    func test_tableLines_withoutTotals_haveNoTotalLine() {
        let lines = UsageWindowView.tableLines(
            rows: [row(id: "r1", key: ["m", "low"])], totals: nil, groupBy: [.model, .effort], home: Self.home)

        XCTAssertEqual(lines.map(\.cells), [["m", "low"]])
        XCTAssertEqual(lines.map(\.isTotal), [false])
    }

    // MARK: - Columns menu

    func test_columnsMenu_accessibilityIdentifier_isTheExactLiteral() {
        XCTAssertEqual(AccessibilityID.Usage.columnsMenu, "calyx.usage.columnsMenu")
    }

    func test_columnMenuItems_oneItemPerDimension_withTitlesAndIds() {
        let items = UsageWindowView.columnMenuItems
        XCTAssertEqual(items.map(\.dimension), [.model, .effort, .thread, .project, .day])
        XCTAssertEqual(items.map(\.title), ["Model", "Effort", "Thread", "Project", "Day"])
        XCTAssertEqual(
            items.map(\.accessibilityID),
            [
                "calyx.usage.column.model", "calyx.usage.column.effort", "calyx.usage.column.thread",
                "calyx.usage.column.project", "calyx.usage.column.day",
            ])
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
            AccessibilityID.Usage.footnote, AccessibilityID.Usage.columnsMenu,
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
