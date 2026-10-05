//
//  UsageLiveSummariesTests.swift
//  CalyxTests
//
//  Pins UsageLiveSummaries, the observable map from a session id to that
//  session's total `UsageTokenTotals` (recorded plus unreported, as the
//  ledger publishes it): set stores or replaces, nil removes, removeAll
//  empties, and a change is visible to Observation -- while a `set` that
//  changes nothing is NOT a change: an observer must not be invalidated
//  for totals that stayed the same.
//

import Observation
import os
import XCTest
@testable import Calyx

@MainActor
final class UsageLiveSummariesTests: XCTestCase {

    /// Session totals; `responses` scales the input side, `output` is
    /// the output total, so two values differ by either.
    private func row(responses: Int64, output: Int64) -> UsageTokenTotals {
        UsageTokenTotals(
            input: 3 * responses, output: output, cacheRead: 90_000 * responses, cacheCreation: 1_200 * responses)
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

    // MARK: - A set that changes nothing does not notify

    /// Observes `bySession` once. `onChange` runs synchronously inside
    /// the mutation, so the flag can be read right after a call returns.
    private func observeBySession(of summaries: UsageLiveSummaries) -> OSAllocatedUnfairLock<Bool> {
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = summaries.bySession
        } onChange: {
            notified.withLock { $0 = true }
        }
        return notified
    }

    func test_set_rowEqualToTheStoredOne_doesNotNotify_andADifferentRowDoes() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        summaries.set(row(responses: 2, output: 840), forSession: "session-b")
        let notified = observeBySession(of: summaries)

        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        summaries.set(row(responses: 2, output: 840), forSession: "session-b")

        XCTAssertFalse(notified.withLock { $0 }, "an equal row was reported as a change")
        XCTAssertEqual(summaries.bySession, [
            "session-a": row(responses: 1, output: 420), "session-b": row(responses: 2, output: 840),
        ])

        // The same observation does fire for a row that differs.
        summaries.set(row(responses: 2, output: 841), forSession: "session-a")

        XCTAssertTrue(notified.withLock { $0 })
        XCTAssertEqual(summaries.bySession["session-a"], row(responses: 2, output: 841))
    }

    func test_setNil_forAnAbsentSession_doesNotNotify_andRemovingAStoredOneDoes() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        let notified = observeBySession(of: summaries)

        summaries.set(nil, forSession: "session-unknown")

        XCTAssertFalse(notified.withLock { $0 }, "removing a session that is not there was reported as a change")

        summaries.set(nil, forSession: "session-a")

        XCTAssertTrue(notified.withLock { $0 })
        XCTAssertEqual(summaries.bySession, [:])
    }

    func test_setNil_onAnEmptyMap_doesNotNotify() {
        let summaries = UsageLiveSummaries()
        let notified = observeBySession(of: summaries)

        summaries.set(nil, forSession: "session-a")

        XCTAssertFalse(notified.withLock { $0 })
    }

    func test_set_firstRowOfASession_notifies() {
        let summaries = UsageLiveSummaries()
        summaries.set(row(responses: 1, output: 420), forSession: "session-a")
        let notified = observeBySession(of: summaries)

        summaries.set(row(responses: 1, output: 420), forSession: "session-b")

        XCTAssertTrue(notified.withLock { $0 }, "the same row under a session that had none is a change")
    }
}
