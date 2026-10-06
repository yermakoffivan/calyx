//
//  UsageFileWorkTests.swift
//  CalyxTests
//
//  Pins UsageFileWork: `run` returns the work's value, the throwing
//  variant rethrows the work's error unchanged, the work runs off the
//  main thread, and works run one at a time in the order submitted.
//
//  WAITING. A blocked work waits on a semaphore the test signals (bound
//  `waitSeconds`, reached only on failure). That a second work does NOT
//  start while the first is blocked is checked with an inverted
//  expectation (`absenceSeconds`), XCTest's way of asserting that
//  something does not happen.
//

import Foundation
import os
import XCTest
@testable import Calyx

@MainActor
final class UsageFileWorkTests: XCTestCase {

    private let waitSeconds: TimeInterval = 30
    private let absenceSeconds: TimeInterval = 1

    private struct WorkError: Error, Equatable {
        let code: Int
    }

    /// An ordered, lock-protected event log.
    private final class Log: Sendable {
        private let events = OSAllocatedUnfairLock(initialState: [String]())
        func append(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    func test_run_returnsTheWorksValue() async {
        let value = await UsageFileWork.run { 6 * 7 }
        XCTAssertEqual(value, 42)
    }

    func test_throwingRun_returnsTheWorksValue() async throws {
        let value = try await UsageFileWork.run { () throws -> String in "done" }
        XCTAssertEqual(value, "done")
    }

    func test_throwingRun_rethrowsTheWorksErrorUnchanged() async {
        do {
            _ = try await UsageFileWork.run { () throws -> Int in throw WorkError(code: 17) }
            XCTFail("the work's error must be rethrown")
        } catch let error as WorkError {
            XCTAssertEqual(error, WorkError(code: 17))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_work_runsOffTheMainThread_whenCalledFromTheMainActor() async throws {
        XCTAssertNotEqual(pthread_main_np(), 0, "Fixture error: the test runs on the main thread")

        let plainOnMain = await UsageFileWork.run { pthread_main_np() != 0 }
        let throwingOnMain = try await UsageFileWork.run { () throws -> Bool in pthread_main_np() != 0 }

        XCTAssertFalse(plainOnMain)
        XCTAssertFalse(throwingOnMain)
    }

    // A is blocked; B is submitted after it. B must not start until A has
    // finished, and they run in submission order.
    func test_twoWorks_runInSubmissionOrder_andNeverOverlap() async {
        let log = Log()
        let release = DispatchSemaphore(value: 0)
        let aStarted = expectation(description: "A started")
        let bStartedEarly = expectation(description: "B started while A was blocked")
        bStartedEarly.isInverted = true
        let waitSeconds = self.waitSeconds

        let a = Task { () -> Bool in
            await UsageFileWork.run { () -> Bool in
                log.append("A start")
                aStarted.fulfill()
                let released = release.wait(timeout: .now() + waitSeconds) == .success
                log.append("A end")
                return released
            }
        }
        await fulfillment(of: [aStarted], timeout: waitSeconds)
        // B is submitted only after A started, so B is the later of the
        // two. Its task leaves the main actor before it submits, so when
        // exactly B reaches the queue is not observable: the inverted
        // expectation below gives a concurrent queue `absenceSeconds` to
        // start B while A is still blocked.
        let b = Task {
            await UsageFileWork.run {
                log.append("B start")
                bStartedEarly.fulfill()
                log.append("B end")
            }
        }
        await fulfillment(of: [bStartedEarly], timeout: absenceSeconds)
        release.signal()
        let released = await a.value
        await b.value

        XCTAssertTrue(released, "A was released by the test, not by its timeout")
        XCTAssertEqual(log.all, ["A start", "A end", "B start", "B end"])
    }
}
