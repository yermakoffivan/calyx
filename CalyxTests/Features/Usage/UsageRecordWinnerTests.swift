//
//  UsageRecordWinnerTests.swift
//  CalyxTests
//
//  Pins UsageRecord.winner, the rule that folds the several transcript
//  lines of ONE API response (same key) into a single record. Larger wins
//  under the priority isFinal > outputTokens > timestampMs > agentID (nil
//  counts as "") > sessionID; a five-way tie falls through to the
//  remaining fields so the result never depends on argument order.
//

import XCTest
@testable import Calyx

final class UsageRecordWinnerTests: XCTestCase {

    private func makeRecord(
        key: String = "msg_01ABC",
        sessionID: String = "session-m",
        timestampMs: Int64 = 1_000,
        model: String = "claude-opus-5-5",
        effort: String? = "high",
        thread: UsageRecord.Thread = .main,
        agentID: String? = nil,
        agentType: String? = nil,
        gitBranch: String? = "main",
        cwd: String? = "/tmp/project",
        inputTokens: Int64 = 3,
        outputTokens: Int64 = 100,
        thinkingTokens: Int64 = 10,
        cacheReadTokens: Int64 = 9_000,
        cacheCreationTokens: Int64 = 120,
        cacheCreation1hTokens: Int64 = 100,
        isFinal: Bool = false
    ) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID,
            timestampMs: timestampMs,
            model: model,
            effort: effort,
            thread: thread,
            agentID: agentID,
            agentType: agentType,
            gitBranch: gitBranch,
            cwd: cwd,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            isFinal: isFinal
        )
    }

    /// Asserts `expected` wins in BOTH argument orders.
    private func assertWinner(
        _ expected: UsageRecord, over loser: UsageRecord,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNotEqual(expected, loser, "Fixture error: the pair must differ", file: file, line: line)
        XCTAssertEqual(UsageRecord.winner(expected, loser), expected, "winner(expected, loser)", file: file, line: line)
        XCTAssertEqual(UsageRecord.winner(loser, expected), expected, "winner(loser, expected)", file: file, line: line)
    }

    // MARK: - Each priority level decides in turn

    func test_winner_isFinalDiffers_finalWins() {
        let final = makeRecord(isFinal: true)
        let partial = makeRecord(isFinal: false)

        assertWinner(final, over: partial)
    }

    func test_winner_bothNonFinal_largerOutputTokensWins() {
        let larger = makeRecord(outputTokens: 300)
        let smaller = makeRecord(outputTokens: 100)

        assertWinner(larger, over: smaller)
    }

    func test_winner_sameOutputTokens_laterTimestampWins() {
        let later = makeRecord(timestampMs: 2_000)
        let earlier = makeRecord(timestampMs: 1_000)

        assertWinner(later, over: earlier)
    }

    func test_winner_sameTimestamp_largerAgentIDWins() {
        let larger = makeRecord(agentID: "b")
        let smaller = makeRecord(agentID: "a")

        assertWinner(larger, over: smaller)
    }

    func test_winner_agentIDNilCountsAsEmptyString_nonNilWins() {
        let withAgent = makeRecord(agentID: "a")
        let withoutAgent = makeRecord(agentID: nil)

        assertWinner(withAgent, over: withoutAgent)
    }

    func test_winner_sameAgentID_largerSessionIDWins() {
        let larger = makeRecord(sessionID: "session-z")
        let smaller = makeRecord(sessionID: "session-a")

        assertWinner(larger, over: smaller)
    }

    // MARK: - A higher level overrides every lower level

    func test_winner_finalWithFewerOutputTokens_beatsNonFinalWithMore() {
        let final = makeRecord(
            sessionID: "session-a", timestampMs: 1_000, agentID: nil, outputTokens: 5, isFinal: true)
        let partial = makeRecord(
            sessionID: "session-z", timestampMs: 9_000, agentID: "z", outputTokens: 900, isFinal: false)

        assertWinner(final, over: partial)
    }

    func test_winner_largerOutputTokens_beatsLaterTimestampAgentIDAndSessionID() {
        let moreOutput = makeRecord(
            sessionID: "session-a", timestampMs: 1_000, agentID: nil, outputTokens: 300)
        let lessOutput = makeRecord(
            sessionID: "session-z", timestampMs: 9_000, agentID: "z", outputTokens: 100)

        assertWinner(moreOutput, over: lessOutput)
    }

    func test_winner_laterTimestamp_beatsLargerAgentIDAndSessionID() {
        let later = makeRecord(sessionID: "session-a", timestampMs: 2_000, agentID: nil)
        let earlier = makeRecord(sessionID: "session-z", timestampMs: 1_000, agentID: "z")

        assertWinner(later, over: earlier)
    }

    func test_winner_largerAgentID_beatsLargerSessionID() {
        let largerAgent = makeRecord(sessionID: "session-a", agentID: "b")
        let smallerAgent = makeRecord(sessionID: "session-z", agentID: "a")

        assertWinner(largerAgent, over: smallerAgent)
    }

    // MARK: - Five-way tie: still order-independent

    func test_winner_pairDifferingOnlyInInputTokens_isCommutativeAndReturnsOneOfThePair() {
        let a = makeRecord(inputTokens: 3)
        let b = makeRecord(inputTokens: 7)

        let ab = UsageRecord.winner(a, b)
        let ba = UsageRecord.winner(b, a)

        XCTAssertEqual(ab, ba, "The result must not depend on argument order")
        XCTAssertTrue(ab == a || ab == b, "The winner must be one of the two inputs, not a blend")
    }

    func test_winner_pairDifferingOnlyInOneLowPriorityField_isCommutativeForEveryField() {
        let base = makeRecord()
        let variants: [(String, UsageRecord)] = [
            ("key", makeRecord(key: "msg_01ABD")),
            ("model", makeRecord(model: "claude-fable-5-1")),
            ("effort", makeRecord(effort: "low")),
            ("effort nil", makeRecord(effort: nil)),
            ("thread", makeRecord(thread: .subagent)),
            ("agentType", makeRecord(agentType: "swift-specialist")),
            ("gitBranch", makeRecord(gitBranch: "feature/x")),
            ("gitBranch nil", makeRecord(gitBranch: nil)),
            ("cwd", makeRecord(cwd: "/tmp/other")),
            ("inputTokens", makeRecord(inputTokens: 4)),
            ("thinkingTokens", makeRecord(thinkingTokens: 11)),
            ("cacheReadTokens", makeRecord(cacheReadTokens: 9_001)),
            ("cacheCreationTokens", makeRecord(cacheCreationTokens: 121)),
            ("cacheCreation1hTokens", makeRecord(cacheCreation1hTokens: 101)),
        ]

        for (name, variant) in variants {
            XCTAssertNotEqual(base, variant, "Fixture error: \(name) variant must differ")
            let forward = UsageRecord.winner(base, variant)
            let backward = UsageRecord.winner(variant, base)
            XCTAssertEqual(forward, backward, "Order dependence for a pair differing only in \(name)")
            XCTAssertTrue(forward == base || forward == variant, "Blended result for \(name)")
        }
    }

    // MARK: - Folding one response split over three lines

    func test_winner_threeLinesOfOneResponse_allSixOrderingsFoldToTheFinalLine() {
        let first = makeRecord(timestampMs: 1_000, outputTokens: 100, isFinal: false)
        let second = makeRecord(timestampMs: 2_000, outputTokens: 300, isFinal: false)
        let last = makeRecord(timestampMs: 3_000, outputTokens: 420, thinkingTokens: 150, isFinal: true)

        let orderings: [[UsageRecord]] = [
            [first, second, last],
            [first, last, second],
            [second, first, last],
            [second, last, first],
            [last, first, second],
            [last, second, first],
        ]

        for (index, ordering) in orderings.enumerated() {
            let folded = UsageRecord.winner(UsageRecord.winner(ordering[0], ordering[1]), ordering[2])
            XCTAssertEqual(folded, last, "Ordering #\(index) folded to a different record")
        }
    }

    func test_winner_threeNonFinalLines_allSixOrderingsFoldToTheLargestOutput() {
        let first = makeRecord(timestampMs: 1_000, outputTokens: 100)
        let second = makeRecord(timestampMs: 2_000, outputTokens: 300)
        let third = makeRecord(timestampMs: 3_000, outputTokens: 200)

        let orderings: [[UsageRecord]] = [
            [first, second, third],
            [first, third, second],
            [second, first, third],
            [second, third, first],
            [third, first, second],
            [third, second, first],
        ]

        for (index, ordering) in orderings.enumerated() {
            let folded = UsageRecord.winner(UsageRecord.winner(ordering[0], ordering[1]), ordering[2])
            XCTAssertEqual(folded, second, "Ordering #\(index) folded to a different record")
        }
    }

    // MARK: - Identity

    func test_winner_sameRecordTwice_returnsThatRecord() {
        let a = makeRecord(agentID: "a1b2c3", agentType: "swift-specialist", outputTokens: 420, isFinal: true)

        XCTAssertEqual(UsageRecord.winner(a, a), a)
    }

    // MARK: - Five-way tie: larger wins, remaining fields in declaration order

    func test_winner_fiveWayTie_largerInputTokensWins() {
        assertWinner(makeRecord(inputTokens: 7), over: makeRecord(inputTokens: 3))
    }

    func test_winner_fiveWayTie_largerOptionalStringWinsAndNilIsBelowAnyValue() {
        // "low" > "high" because "l" > "h".
        assertWinner(makeRecord(effort: "low"), over: makeRecord(effort: "high"))
        assertWinner(makeRecord(effort: "high"), over: makeRecord(effort: nil))
        assertWinner(makeRecord(gitBranch: "main"), over: makeRecord(gitBranch: nil))
    }

    func test_winner_fiveWayTie_threadComparesByRawValue() {
        // Raw values: "advisor" < "main" < "subagent".
        assertWinner(makeRecord(thread: .subagent), over: makeRecord(thread: .main))
        assertWinner(makeRecord(thread: .main), over: makeRecord(thread: .advisor))
    }

    func test_winner_fiveWayTie_earlierDeclaredFieldDecidesBeforeLaterOnes() {
        // model is declared before effort and inputTokens.
        let largerModel = makeRecord(model: "claude-opus-5-5", effort: "high", inputTokens: 3)
        let smallerModel = makeRecord(model: "claude-fable-5-1", effort: "low", inputTokens: 900)
        assertWinner(largerModel, over: smallerModel)

        // inputTokens is declared before thinkingTokens and cacheReadTokens.
        let largerInput = makeRecord(inputTokens: 7, thinkingTokens: 1, cacheReadTokens: 1)
        let smallerInput = makeRecord(inputTokens: 3, thinkingTokens: 999, cacheReadTokens: 99_999)
        assertWinner(largerInput, over: smallerInput)
    }

    // MARK: - Review group B: agentID nil versus ""

    func test_winner_agentIDNilVersusEmptyString_isCommutativeAndEmptyStringWins() {
        let withNil = makeRecord(agentID: nil)
        let withEmpty = makeRecord(agentID: "")

        XCTAssertEqual(UsageRecord.winner(withNil, withEmpty), UsageRecord.winner(withEmpty, withNil))
        XCTAssertEqual(UsageRecord.winner(withNil, withEmpty).agentID, "")
        XCTAssertEqual(UsageRecord.winner(withEmpty, withNil).agentID, "")
    }
}
