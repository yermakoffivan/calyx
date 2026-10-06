//
//  UsageWindowRefreshSchedulerTests.swift
//  CalyxTests
//
//  Pins UsageWindowRefreshScheduler (R5e, section C): while the Usage
//  window is visible, every feed change schedules one table refresh,
//  coalesced into at most one per interval (a fixed window: a change
//  during a pending window joins it, the window's end always refreshes).
//  Hidden: nothing is scheduled and a pending refresh does not run.
//  Showing the window refreshes once at once. The one-shot timer is
//  injected and fired by the test, so nothing waits on real time.
//

import Foundation
import XCTest
@testable import Calyx

@MainActor
final class UsageWindowRefreshSchedulerTests: XCTestCase {

    /// Records each one-shot timer; the test fires them explicitly.
    private final class FakeTimers {
        var scheduled: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        var delays: [TimeInterval] { scheduled.map(\.delay) }

        /// Fires the oldest unfired timer; fails (not traps) when none is pending.
        @MainActor func fireNext(file: StaticString = #filePath, line: UInt = #line) {
            guard !scheduled.isEmpty else {
                XCTFail("no timer is pending", file: file, line: line)
                return
            }
            let next = scheduled.removeFirst()
            next.action()
        }
    }

    private let timers = FakeTimers()
    private var refreshes = 0

    private func makeScheduler(interval: TimeInterval = 2) -> UsageWindowRefreshScheduler {
        let timers = timers
        return UsageWindowRefreshScheduler(
            interval: interval,
            schedule: { delay, action in timers.scheduled.append((delay, action)) },
            refresh: { [unowned self] in self.refreshes += 1 })
    }

    func test_defaultInterval_isTwoSeconds() {
        XCTAssertEqual(UsageWindowRefreshScheduler.defaultInterval, 2)
    }

    func test_creating_schedulesAndRefreshesNothing() {
        _ = makeScheduler()
        XCTAssertEqual(timers.delays, [])
        XCTAssertEqual(refreshes, 0)
    }

    func test_show_refreshesOnceAtOnce() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(timers.delays, [])
    }

    func test_aBurstOfChanges_whileVisible_givesOneRefreshAfterTheInterval() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        refreshes = 0

        scheduler.feedDidChange()
        scheduler.feedDidChange()
        scheduler.feedDidChange()

        XCTAssertEqual(refreshes, 0, "nothing before the interval has passed")
        XCTAssertEqual(timers.delays, [2], "one timer for the whole burst")
        timers.fireNext()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(timers.delays, [])
    }

    func test_theInjectedInterval_isTheTimersDelay() {
        let scheduler = makeScheduler(interval: 5)
        scheduler.windowDidShow()
        scheduler.feedDidChange()
        XCTAssertEqual(timers.delays, [5])
    }

    func test_aChangeAfterTheInterval_givesAnotherRefresh() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        refreshes = 0

        scheduler.feedDidChange()
        timers.fireNext()
        XCTAssertEqual(refreshes, 1)

        scheduler.feedDidChange()
        scheduler.feedDidChange()
        XCTAssertEqual(timers.delays, [2])
        timers.fireNext()
        XCTAssertEqual(refreshes, 2)
    }

    func test_changesWhileHidden_scheduleAndRefreshNothing() {
        let scheduler = makeScheduler()

        scheduler.feedDidChange()
        scheduler.feedDidChange()

        XCTAssertEqual(timers.delays, [])
        XCTAssertEqual(refreshes, 0)
    }

    func test_changesAfterHiding_scheduleNothing() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        scheduler.windowDidHide()
        refreshes = 0

        scheduler.feedDidChange()

        XCTAssertEqual(timers.delays, [])
        XCTAssertEqual(refreshes, 0)
    }

    func test_aPendingRefresh_doesNotRunOnceTheWindowIsHidden() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        refreshes = 0
        scheduler.feedDidChange()

        scheduler.windowDidHide()
        timers.fireNext()

        XCTAssertEqual(refreshes, 0)
    }

    func test_changesWhileHidden_thenShow_refreshOnceOnly() {
        let scheduler = makeScheduler()
        scheduler.feedDidChange()

        scheduler.windowDidShow()

        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(timers.delays, [])
    }

    func test_hideThenShowAgain_changesScheduleAgain() {
        let scheduler = makeScheduler()
        scheduler.windowDidShow()
        scheduler.windowDidHide()
        scheduler.windowDidShow()
        XCTAssertEqual(refreshes, 2)

        scheduler.feedDidChange()
        XCTAssertEqual(timers.delays, [2])
        timers.fireNext()

        XCTAssertEqual(refreshes, 3)
    }
}
