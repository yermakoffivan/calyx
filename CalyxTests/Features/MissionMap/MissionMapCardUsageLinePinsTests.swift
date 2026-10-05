//
//  MissionMapCardUsageLinePinsTests.swift
//  CalyxTests
//
//  Pins the pieces of a card's usage line that a unit test can observe:
//  - `MissionMapCard.usage` defaults to nil, so cards built without a
//    usage row need not pass it
//  - `AccessibilityID.MissionMap.cardUsage(_:)` is per card and distinct
//    from the card's own identifier
//  - the shared `MissionMapFixture` gives card a4 (and only a4) a git
//    badge and a usage row, the card the Mission Map UI test reads the
//    rendered line from
//  Where the line is drawn and its spoken label are checked end to end
//  by MissionMapPopoverUITests: an offscreen NSHostingView exposes no
//  SwiftUI accessibility children to a unit test.
//

import XCTest
@testable import Calyx

final class MissionMapCardUsageLinePinsTests: XCTestCase {

    func test_card_usage_defaultsToNil() {
        let id = UUID()
        let card = MissionMapCard(
            id: id, groupID: UUID(), groupName: "Default", tabID: UUID(), kindLabel: nil,
            paneTitle: "Shell", cwdLabel: "~", state: nil, toolLine: nil,
            children: [], unreadCount: 0, approval: nil, git: nil, focusTarget: id
        )

        XCTAssertNil(card.usage)
    }

    func test_accessibilityID_cardUsage_isPerCard() {
        let a = UUID()
        let b = UUID()

        XCTAssertEqual(AccessibilityID.MissionMap.cardUsage(a), "calyx.missionMap.cardUsage.\(a.uuidString)")
        XCTAssertNotEqual(AccessibilityID.MissionMap.cardUsage(a), AccessibilityID.MissionMap.cardUsage(b))
        XCTAssertNotEqual(AccessibilityID.MissionMap.cardUsage(a), AccessibilityID.MissionMap.card(a))
    }

    // MARK: - Fixture

    private let fixtureNow = Date(timeIntervalSince1970: 1_700_000_000)

    func test_fixture_a4_hasTheMainBranchGitBadge() throws {
        let a4 = try XCTUnwrap(MissionMapFixture.make(now: fixtureNow).cards["a4"])

        XCTAssertEqual(a4.git, MissionMapGitBadge(branch: "main", shortHash: "abc1234", changedFileCount: 0))
        XCTAssertEqual(a4.toolLine, "Bash: swift test")
    }

    /// 10 responses, 9 final; input 1,000,000 + cache read 150,000 +
    /// cache creation 50,000 = 1,200,000; output 45,200.
    func test_fixture_a4_hasTheSessionUsageRow() throws {
        let a4 = try XCTUnwrap(MissionMapFixture.make(now: fixtureNow).cards["a4"])

        let expected = UsageRow(
            key: [], responses: 10, finalResponses: 9, inputTokens: 1_000_000, cacheReadTokens: 150_000,
            cacheCreationTokens: 50_000, cacheCreation1hTokens: 0, outputTokensFinal: 45_200,
            thinkingTokensFinal: 0, lastTimestampMs: 0
        )
        let usage = try XCTUnwrap(a4.usage)
        XCTAssertEqual(usage, expected)
        XCTAssertEqual(UsageCardLine.text(for: usage), "\u{2265}45.2k out \u{00B7} 1.2M in")
    }

    /// The snapshot the map draws holds the same a4 as `cards`.
    func test_fixture_snapshotCardA4_carriesTheSameUsageAndGit() throws {
        let fixture = MissionMapFixture.make(now: fixtureNow)
        let a4 = try XCTUnwrap(fixture.cards["a4"])
        let drawn = try XCTUnwrap(fixture.snapshot.cards.first { $0.id == a4.id })

        XCTAssertNotNil(drawn.usage)
        XCTAssertEqual(drawn.usage, a4.usage)
        XCTAssertEqual(drawn.git, a4.git)
    }

    func test_fixture_everyOtherCard_hasNoUsageAndNoGit() throws {
        let fixture = MissionMapFixture.make(now: fixtureNow)
        let a4ID = try XCTUnwrap(fixture.cards["a4"]).id

        XCTAssertEqual(fixture.snapshot.cards.count, 6)
        for card in fixture.snapshot.cards where card.id != a4ID {
            XCTAssertNil(card.usage, card.paneTitle)
            XCTAssertNil(card.git, card.paneTitle)
        }
    }
}
