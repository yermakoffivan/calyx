//
//  IPCWakeCoordinatorInboxGrewTests.swift
//  CalyxTests
//
//  Pins the parts of IPCWakeCoordinator that slice A-4 adds or changes:
//
//  - `inboxGrew(peerID:)`: called on the main actor by the store's inbox
//    sink, it requests a check for the surface bound to that peer, and
//    only that surface.
//  - The store-driven trigger end to end: with the sink installed the
//    way `CalyxMCPServer.start()` installs it, a message put straight into
//    the store (no server, no tools/call) wakes a waiting surface, once.
//  - The check Task: `reevaluateAllWaiters()` and `inboxGrew(peerID:)`
//    return the Task of the check they requested, and once that Task has
//    finished the store call is over (a woken waiter's message is
//    already nudged; a waiter that was not woken can be released to nil).
//  - P6 at the coordinator: a waiter registered while the setting was on,
//    the setting turned off, a message delivered while off: once the
//    setting is back on, `reevaluateAllWaiters()` wakes it.
//  - `isEnabled` is readable on the coordinator, the single reader of the
//    setting (the route asks it).
//
//  Synchronisation: no test concludes "nothing happened" from elapsed
//  time or from a check counter. A waiter's registration requests a
//  check of its own that no test can await, so every waiter here is
//  registered while that check can build nothing: either the coordinator's
//  enabled flag is false at that moment, or the surface is bound to no
//  peer. Then the only checks are the ones a test awaits.
//

import XCTest
@testable import Calyx

@MainActor
final class IPCWakeCoordinatorInboxGrewTests: XCTestCase {

    // MARK: - Properties

    private var store: IPCStore!
    private var registry: AgentRegistry!
    private var coordinator: IPCWakeCoordinator!
    private var wakeFlag: InboxGrewWakeFlag!

    private let longTimeoutMs = 30_000
    /// Timeout of a waiter that a missing trigger would leave waiting:
    /// short enough that the failure is a nil after 5 s, not a hang.
    private let boundedTimeoutMs = 5_000

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        let wakeFlag = InboxGrewWakeFlag()
        self.wakeFlag = wakeFlag
        store = IPCStore()
        let registry = AgentRegistry()
        self.registry = registry
        coordinator = IPCWakeCoordinator(
            store: store,
            agentRegistry: { registry },
            isEnabled: { wakeFlag.value }
        )
    }

    override func tearDown() async throws {
        await store.setInboxAppendedSink(nil)
        coordinator.releaseAllWaiters()
        coordinator = nil
        registry = nil
        store = nil
        wakeFlag = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func registerPeer(_ name: String) async -> UUID {
        await store.registerPeer(name: name, role: "terminal").id
    }

    private func flags(_ peerID: UUID) async -> [Bool] {
        await store._testNudgedFlags(for: peerID)
    }

    private func expectedWake(peer: UUID, new: Int, senders: Int, unread: Int) -> IPCWakeResponse {
        IPCWakeResponse(
            peerID: peer,
            ticket: IPCWakeTicket(newCount: new, senderCount: senders, unreadCount: unread)
        )
    }

    /// Polls `condition` until it holds or `timeout` passes. Used only to
    /// see a waiter appear in `waitingSurfaceIDs`, a state that, once
    /// reached, stays until something ends the waiter.
    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Registers a waiter for `surfaceID` while the enabled flag is
    /// false, so its registration requests no store call, then sets the
    /// flag back to `enabledAfterwards`.
    private func startWaiterWithoutARegistrationCheck(
        _ surfaceID: UUID, timeoutMs: Int, enabledAfterwards: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Task<IPCWakeResponse?, Never> {
        wakeFlag.value = false
        let waiter = Task { @MainActor in
            await self.coordinator.awaitWake(surfaceID: surfaceID, timeoutMs: timeoutMs)
        }
        let registered = await waitUntil { self.coordinator.waitingSurfaceIDs.contains(surfaceID) }
        XCTAssertTrue(registered, "precondition: the waiter registered", file: file, line: line)
        wakeFlag.value = enabledAfterwards
        return waiter
    }

    /// Installs the sink exactly as `CalyxMCPServer.start()` does: the
    /// store calls it inside the actor, and it hops to the main actor.
    private func installSinkLikeServerStart() async {
        let coordinator: IPCWakeCoordinator = self.coordinator
        await store.setInboxAppendedSink { [weak coordinator] peerID in
            Task { @MainActor in
                coordinator?.inboxGrew(peerID: peerID)
            }
        }
    }

    // MARK: - isEnabled

    func test_isEnabled_readsTheInjectedClosure() {
        wakeFlag.value = true
        XCTAssertTrue(coordinator.isEnabled)
        wakeFlag.value = false
        XCTAssertFalse(coordinator.isEnabled, "isEnabled must read the injected closure each time, not cache it")
    }

    // MARK: - Store-driven trigger, end to end

    func test_storeSink_messageSentStraightToTheStore_wakesTheWaitingSurface() async throws {
        await installSinkLikeServerStart()
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: boundedTimeoutMs)

        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "a message added to the store must wake the waiting surface through the store's own " +
                       "report, with no tools/call and no reevaluateAllWaiters()")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    func test_storeSink_broadcast_wakesEachWaitingSurface() async throws {
        await installSinkLikeServerStart()
        let sender = await registerPeer("sender")
        let peerA = await registerPeer("a")
        let peerB = await registerPeer("b")
        let surfaceA = UUID()
        let surfaceB = UUID()
        registry.bindSurface(surfaceA, toPeer: peerA)
        registry.bindSurface(surfaceB, toPeer: peerB)
        wakeFlag.value = false
        let waiterA = Task { @MainActor in
            await self.coordinator.awaitWake(surfaceID: surfaceA, timeoutMs: self.boundedTimeoutMs)
        }
        let waiterB = Task { @MainActor in
            await self.coordinator.awaitWake(surfaceID: surfaceB, timeoutMs: self.boundedTimeoutMs)
        }
        let registered = await waitUntil { self.coordinator.waitingSurfaceIDs == [surfaceA, surfaceB] }
        XCTAssertTrue(registered, "precondition: both waiters registered")
        wakeFlag.value = true

        _ = try await store.broadcast(from: sender, content: "to everyone")
        let responseA = await waiterA.value
        let responseB = await waiterB.value

        XCTAssertEqual(responseA, expectedWake(peer: peerA, new: 1, senders: 1, unread: 1))
        XCTAssertEqual(responseB, expectedWake(peer: peerB, new: 1, senders: 1, unread: 1))
    }

    func test_storeSink_requeue_wakesTheWaitingSurface() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")
        let received = await store.receiveMessages(for: peer)
        XCTAssertEqual(received.count, 1, "precondition: the message was taken out of the inbox")
        await installSinkLikeServerStart()
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: boundedTimeoutMs)

        await store.requeue(received, for: peer)
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "a requeued, never-announced message must wake the waiting surface")
    }

    // MARK: - inboxGrew(peerID:)

    func test_inboxGrew_wakesTheSurfaceBoundToThatPeer_andItsTaskEndsAfterTheStoreCall() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: longTimeoutMs)
        // No sink: the message alone requests nothing.
        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")

        await coordinator.inboxGrew(peerID: peer).value

        let flagsRightAfter = await flags(peer)
        XCTAssertEqual(flagsRightAfter, [true],
                       "once the Task inboxGrew returned has finished, its store call is over and the " +
                       "message it handed over is nudged")
        let response = await waiter.value
        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_inboxGrew_forAnotherPeer_doesNotCheckThisSurface() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let otherPeer = await registerPeer("other")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: longTimeoutMs)
        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")

        await coordinator.inboxGrew(peerID: otherPeer).value

        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false],
                       "inboxGrew for another peer must request no check for this surface, although this " +
                       "surface's peer has an un-nudged message")
        coordinator.release(surfaceID: surface)
        let response = await waiter.value
        XCTAssertNil(response, "the waiter was never woken, so release ends it with nil")
    }

    func test_inboxGrew_whileDisabled_doesNothing() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(
            surface, timeoutMs: longTimeoutMs, enabledAfterwards: false
        )
        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")

        await coordinator.inboxGrew(peerID: peer).value

        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "with the setting off a check must neither wake nor mark")
        coordinator.release(surfaceID: surface)
        let response = await waiter.value
        XCTAssertNil(response)
    }

    // MARK: - The check Task of reevaluateAllWaiters()

    func test_reevaluateAllWaiters_returnsTheCheckTask_awaitedMessageIsNudged() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: longTimeoutMs)
        _ = try await store.sendMessage(from: sender, to: peer, content: "hello")

        await coordinator.reevaluateAllWaiters().value

        let flagsRightAfter = await flags(peer)
        XCTAssertEqual(flagsRightAfter, [true],
                       "once the Task reevaluateAllWaiters returned has finished, the wake was handed over")
        let response = await waiter.value
        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_reevaluateAllWaiters_messageForADifferentPeer_doesNotWake() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let otherPeer = await registerPeer("other")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: longTimeoutMs)
        _ = try await store.sendMessage(from: sender, to: otherPeer, content: "hello")

        await coordinator.reevaluateAllWaiters().value

        let otherFlags = await flags(otherPeer)
        XCTAssertEqual(otherFlags, [false], "nobody was told about the other peer's message")
        coordinator.release(surfaceID: surface)
        let response = await waiter.value
        XCTAssertNil(response, "the finished check did not wake the waiter, so release ends it with nil")
    }

    func test_reevaluateAllWaiters_sameMessages_neverWakeASecondWaiter() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        _ = try await store.sendMessage(from: sender, to: peer, content: "one")
        let first = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        XCTAssertEqual(first, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "precondition: the first waiter was woken for the message")

        let second = await startWaiterWithoutARegistrationCheck(surface, timeoutMs: longTimeoutMs)
        await coordinator.reevaluateAllWaiters().value

        coordinator.release(surfaceID: surface)
        let response = await second.value
        XCTAssertNil(response, "a message that already caused a wake must never wake a second waiter")
    }

    // MARK: - P6: setting back on re-evaluates

    func test_settingOffThenOn_messageDeliveredWhileOff_wakesTheWaiterOnReevaluate() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        // Registered while the setting is on; unbound, so the
        // registration check builds no taker and calls no store.
        wakeFlag.value = true
        let waiter = Task { @MainActor in
            await self.coordinator.awaitWake(surfaceID: surface, timeoutMs: self.longTimeoutMs)
        }
        let registered = await waitUntil { self.coordinator.waitingSurfaceIDs.contains(surface) }
        XCTAssertTrue(registered, "precondition: the waiter registered while the setting was on")

        wakeFlag.value = false
        registry.bindSurface(surface, toPeer: peer)
        _ = try await store.sendMessage(from: sender, to: peer, content: "sent while off")
        let flagsWhileOff = await flags(peer)
        XCTAssertEqual(flagsWhileOff, [false], "precondition: nothing was announced while the setting was off")

        wakeFlag.value = true
        await coordinator.reevaluateAllWaiters().value
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "turning the setting back on re-evaluates the waiters, and the message that arrived " +
                       "while it was off wakes the waiter that was already registered")
    }
}

/// The enabled flag the coordinator under test reads. A main-actor box
/// so the `isEnabled` closure captures no test case.
@MainActor
private final class InboxGrewWakeFlag {
    var value = true
}
