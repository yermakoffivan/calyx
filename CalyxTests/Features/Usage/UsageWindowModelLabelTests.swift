//
//  UsageWindowModelLabelTests.swift
//  CalyxTests
//
//  Pins the text the Usage window derives from data:
//
//  - `projectLabel(root:home:)`, the project picker's label: the full
//    root with the home directory written `~`, component-aware, so two
//    different roots never share a label (no tooltip is needed to tell
//    them apart).
//
//  (The Final column and its `finalPercentText` were removed with R5c:
//  Claude Code's own counts have no "final" share.)
//

import XCTest
@testable import Calyx

@MainActor
final class UsageWindowModelLabelTests: XCTestCase {

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
