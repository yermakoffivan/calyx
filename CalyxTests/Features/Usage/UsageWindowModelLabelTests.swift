//
//  UsageWindowModelLabelTests.swift
//  CalyxTests
//
//  Pins the two texts the Usage window derives from data:
//
//  - `finalPercentText(final:responses:)`, the Final column: the share
//    of responses whose final transcript line was written, truncated to
//    a whole percent in integer arithmetic. It never overstates: 999 of
//    1,000 is 99%, and only "every response is final" shows 100% (a
//    `Double` ratio rounds (10^18 - 1) / 10^18 up to 100%). No responses
//    show an em dash; out-of-range pairs Gold never produces do not trap.
//  - `projectLabel(root:home:)`, the project picker's label: the full
//    root with the home directory written `~`, component-aware, so two
//    different roots never share a label (no tooltip is needed to tell
//    them apart).
//

import XCTest
@testable import Calyx

@MainActor
final class UsageWindowModelLabelTests: XCTestCase {

    private func percent(_ final: Int64, _ responses: Int64) -> String {
        UsageWindowModel.finalPercentText(final: final, responses: responses)
    }

    // MARK: - Final column

    func test_finalPercent_noResponses_isAnEmDash() {
        XCTAssertEqual(percent(0, 0), "\u{2014}")
        XCTAssertEqual(percent(3, 0), "\u{2014}")
        XCTAssertEqual(percent(3, -1), "\u{2014}")
    }

    func test_finalPercent_truncates_neverRoundsUp() {
        XCTAssertEqual(percent(999, 1_000), "99%")
        XCTAssertEqual(percent(1, 3), "33%")
        XCTAssertEqual(percent(2, 3), "66%")
        XCTAssertEqual(percent(0, 5), "0%")
    }

    func test_finalPercent_isOneHundredOnlyWhenEveryResponseIsFinal() {
        XCTAssertEqual(percent(1_000, 1_000), "100%")
        XCTAssertEqual(percent(Int64.max, Int64.max), "100%")
    }

    func test_finalPercent_hugeCounts_useIntegerArithmetic() {
        let quintillion: Int64 = 1_000_000_000_000_000_000
        XCTAssertEqual(percent(quintillion - 1, quintillion), "99%", "a Double ratio shows 100%")
        XCTAssertEqual(percent(Int64.max - 1, Int64.max), "99%")
    }

    func test_finalPercent_outOfRangePairs_clampWithoutTrapping() {
        XCTAssertEqual(percent(5, 3), "100%")
        XCTAssertEqual(percent(-1, 5), "0%")
    }

    // MARK: - Project label

    func test_projectLabel_underHome_isTildeAndTheFullRest() {
        XCTAssertEqual(UsageWindowModel.projectLabel(root: "/Users/me/src/calyx", home: "/Users/me"), "~/src/calyx")
    }

    func test_projectLabel_theHomeDirectoryItself_isTilde() {
        XCTAssertEqual(UsageWindowModel.projectLabel(root: "/Users/me", home: "/Users/me"), "~")
    }

    func test_projectLabel_outsideHome_isUnchanged() {
        XCTAssertEqual(UsageWindowModel.projectLabel(root: "/opt/work/app", home: "/Users/me"), "/opt/work/app")
    }

    func test_projectLabel_aSiblingSharingHomesSpelling_isUnchanged() {
        XCTAssertEqual(UsageWindowModel.projectLabel(root: "/Users/me2/x", home: "/Users/me"), "/Users/me2/x")
    }

    func test_projectLabel_rootsWithTheSameLastTwoComponents_getDifferentLabels() {
        let first = UsageWindowModel.projectLabel(root: "/Users/me/client-a/web/app", home: "/Users/me")
        let second = UsageWindowModel.projectLabel(root: "/Users/me/client-b/web/app", home: "/Users/me")

        XCTAssertEqual(first, "~/client-a/web/app")
        XCTAssertEqual(second, "~/client-b/web/app")
        XCTAssertNotEqual(first, second)
    }
}
