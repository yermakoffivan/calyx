//
//  IPCWakeHookTimingTests.swift
//  CalyxTests
//
//  Pins IPCWakeHookTiming: the three timeouts that bound one `/ipc-wake`
//  long-poll, all derived from `holdSeconds`.
//
//  Coverage:
//  - holdSeconds is 600 (the same length as IPCStore's peer TTL)
//  - The three derived values: serverTimeoutMs 570_000, curlTimeoutSeconds
//    585, hookEntryTimeoutSeconds 600
//  - The nesting invariant: serverTimeoutMs < curlTimeoutSeconds * 1000 <
//    hookEntryTimeoutSeconds * 1000, so the server always answers the
//    client long-polling `/ipc-wake` before that client's own deadlines
//

import XCTest
@testable import Calyx

final class IPCWakeHookTimingTests: XCTestCase {

    func test_holdSeconds_is600() {
        XCTAssertEqual(IPCWakeHookTiming.holdSeconds, 600)
    }

    func test_derivedValues_matchTheSpec() {
        XCTAssertEqual(IPCWakeHookTiming.serverTimeoutMs, 570_000,
                       "serverTimeoutMs must be holdSeconds * 1000 - 30_000")
        XCTAssertEqual(IPCWakeHookTiming.curlTimeoutSeconds, 585,
                       "curlTimeoutSeconds must be holdSeconds - 15")
        XCTAssertEqual(IPCWakeHookTiming.hookEntryTimeoutSeconds, 600,
                       "hookEntryTimeoutSeconds must be holdSeconds")
    }

    func test_derivedValues_areDerivedFromHoldSeconds() {
        XCTAssertEqual(IPCWakeHookTiming.serverTimeoutMs, IPCWakeHookTiming.holdSeconds * 1000 - 30_000)
        XCTAssertEqual(IPCWakeHookTiming.curlTimeoutSeconds, IPCWakeHookTiming.holdSeconds - 15)
        XCTAssertEqual(IPCWakeHookTiming.hookEntryTimeoutSeconds, IPCWakeHookTiming.holdSeconds)
    }

    func test_nestingInvariant_serverBeforeCurlBeforeHookEntry() {
        XCTAssertLessThan(IPCWakeHookTiming.serverTimeoutMs, IPCWakeHookTiming.curlTimeoutSeconds * 1000,
                          "the server's own wait must end strictly before curlTimeoutSeconds, so the client " +
                          "long-polling /ipc-wake always sees the server's 204 rather than its own timeout")
        XCTAssertLessThan(IPCWakeHookTiming.curlTimeoutSeconds * 1000,
                          IPCWakeHookTiming.hookEntryTimeoutSeconds * 1000,
                          "curlTimeoutSeconds must be strictly below hookEntryTimeoutSeconds, so the client " +
                          "long-polling /ipc-wake ends by its own deadline first")
    }
}
