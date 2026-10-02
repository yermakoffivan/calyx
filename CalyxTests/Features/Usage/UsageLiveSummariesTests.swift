//
//  UsageLiveSummariesTests.swift
//  CalyxTests
//
//  Pins UsageLiveSummaries, the observable map from a session id to that
//  session's total usage row (the row of `UsageQuery(sessionID:)` with an
//  empty groupBy, so its key is []): set stores or replaces, nil removes,
//  removeAll empties, and a change is visible to Observation.
//

import Observation
import XCTest
@testable import Calyx

@MainActor
final class UsageLiveSummariesTests: XCTestCase {

    private func row(responses: Int64, output: Int64) -> UsageRow {
        UsageRow(
            key: [], responses: responses, finalResponses: responses, inputTokens: 3 * responses,
            cacheReadTokens: 90_000 * responses, cacheCreationTokens: 1_200 * responses,
            cacheCreation1hTokens: 1_000 * responses, outputTokensFinal: output,
            thinkingTokensFinal: 150 * responses, lastTimestampMs: 1_790_936_849_765)
    }

    func test_initialState_isEmpty() {
        XCTAssertEqual(UsageLiveSummaries().bySession, [:])
    }

    func test_set_storesTheRowUnderItsSession() {
        let summaries = UsageLiveSummaries()
        let first = row(responses: 1, output: 420)
        let second = row(responses: 2, output: 840)

        summaries.set(first, forSession: "session-a")
        summaries.set(second, forSession: "session-b")

        XCTAssertEqual(summaries.bySession, ["session-a": first, "session-b": second])
    }

    func test_set_replacesTheRowOfTheSameSession() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        let newer = row(responses: 2, output: 840)

        summaries.set(newer, forSession: "session-a")

        XCTAssertEqual(summaries.bySession, ["session-a": newer])
    }

    func test_setNil_removesOnlyThatSession() {
        let summaries = UsageLiveSummaries()
        let kept = row(responses: 2, output: 840)
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        summaries.set(kept, forSession: "session-b")

        summaries.set(nil, forSession: "session-a")

        XCTAssertEqual(summaries.bySession, ["session-b": kept])
    }

    func test_setNil_forAnUnknownSession_changesNothing() {
        let summaries = UsageLiveSummaries()
        let kept = row(responses: 1, output: 420)
        summaries.set(kept, forSession: "session-a")

        summaries.set(nil, forSession: "session-unknown")

        XCTAssertEqual(summaries.bySession, ["session-a": kept])
    }

    func test_removeAll_emptiesTheMap() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        summaries.set(row(responses: 2, output: 840), forSession: "session-b")

        summaries.removeAll()

        XCTAssertEqual(summaries.bySession, [:])
    }

    func test_set_isVisibleToObservationTracking() {
        let summaries = UsageLiveSummaries()
        let changed = expectation(description: "bySession change observed")
        withObservationTracking {
            _ = summaries.bySession
        } onChange: {
            changed.fulfill()
        }

        summaries.set(row(responses: 1, output: 420), forSession: "session-a")

        wait(for: [changed], timeout: 5)
    }

    func test_removeAll_isVisibleToObservationTracking() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        let changed = expectation(description: "bySession change observed")
        withObservationTracking {
            _ = summaries.bySession
        } onChange: {
            changed.fulfill()
        }

        summaries.removeAll()

        wait(for: [changed], timeout: 5)
    }
}
