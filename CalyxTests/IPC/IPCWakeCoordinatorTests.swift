//
//  IPCWakeCoordinatorTests.swift
//  CalyxTests
//
//  Pins IPCWakeCoordinator: it holds one waiter (a suspended `awaitWake`
//  call) per surface and hands a wake to a waiter when the peer bound to
//  that surface has messages no waiter has been told about yet.
//
//  Driven with a real IPCStore, a fresh AgentRegistry and an `isEnabled`
//  closure reading a flag box. No server, no sockets.
//
//  Coverage:
//  - A message already waiting wakes a new waiter at once and becomes
//    nudged; a message that arrives while waiting wakes after
//    reevaluateAllWaiters()
//  - A message for another peer does not wake
//  - Each message wakes at most once; a newer message wakes again and the
//    wake counts only the newer one as new
//  - A burst of messages gives one wake counting all of them; a broadcast
//    wakes each waiting surface exactly once
//  - awaitWake returns nil, with message flags untouched, on timeout, on
//    cancellation, when superseded, on release(surfaceID:), on
//    releaseAllWaiters() and on `.calyxSurfaceDestroyed`
//  - A late cancellation of an older waiter does not evict a newer one
//  - An unbound surface keeps waiting, and bindSurface alone wakes it;
//    re-binding to another peer wakes for that peer's messages only; a
//    binding change in another registry is ignored
//  - isEnabled() == false: no wake, nothing marked, the waiter stays; the
//    messages wake a new waiter once enabled
//  - waitingSurfaceIDs no longer holds a surface once its awaitWake
//    returned
//  - Three races, reproduced through `_testBeforeOffer` (which runs after
//    a check built its takers and before it calls the store): the waiter
//    is superseded, the waiter's Task is cancelled, the peer's binding
//    moves to another surface
//
//  Synchronisation: "nothing happened" is never concluded from elapsed
//  time. A waiter that must not be woken gets a 30 s timeout; the test
//  waits until it is registered and `_testChecksInFlight` is 0 (every
//  check requested so far has returned from the store), asserts it is
//  still waiting, and then ends it with release(surfaceID:). Where a
//  message must be un-nudged while a waiter is suspended, the waiter's
//  registration check finishes on an empty inbox first and the message is
//  then put into the store directly, which requests no check.
//

import XCTest
@testable import Calyx

@MainActor
final class IPCWakeCoordinatorTests: XCTestCase {

    // MARK: - Properties

    private var store: IPCStore!
    private var registry: AgentRegistry!
    private var coordinator: IPCWakeCoordinator!
    /// What the coordinator's `isEnabled` closure returns.
    private var wakeFlag: WakeFlag!

    /// State for the `_testBeforeOffer` tests. The closure runs once per
    /// check, and the actions it takes cause further checks, so each
    /// closure acts only on specific calls.
    private var seamCalls = 0
    private var seamFirstWaiter: Task<IPCWakeResponse?, Never>?
    private var seamSecondWaiter: Task<IPCWakeResponse?, Never>?
    private var seamObservedFlags: [Bool]?
    private var seamSawStaleCheckFinish: Bool?

    /// Timeout of every waiter that is ended by an event other than its
    /// timeout. Far beyond any test's runtime, so the timeout never wins.
    private let longTimeoutMs = 30_000
    /// Upper bound for "ended because of the event, not the 30 s timeout".
    private let promptBound: Duration = .seconds(10)

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        let wakeFlag = WakeFlag()
        self.wakeFlag = wakeFlag
        seamCalls = 0
        seamFirstWaiter = nil
        seamSecondWaiter = nil
        seamObservedFlags = nil
        seamSawStaleCheckFinish = nil
        store = IPCStore()
        let registry = AgentRegistry()
        self.registry = registry
        coordinator = IPCWakeCoordinator(
            store: store,
            agentRegistry: { registry },
            isEnabled: { wakeFlag.value }
        )
    }

    override func tearDown() {
        coordinator._testBeforeOffer = nil
        coordinator.releaseAllWaiters()
        coordinator = nil
        registry = nil
        store = nil
        wakeFlag = nil
        seamFirstWaiter = nil
        seamSecondWaiter = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func startWaiter(_ surfaceID: UUID) -> Task<IPCWakeResponse?, Never> {
        Task { @MainActor in
            await self.coordinator.awaitWake(surfaceID: surfaceID, timeoutMs: self.longTimeoutMs)
        }
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Every check requested so far has returned from the store.
    private func waitForChecksIdle() async -> Bool {
        await waitUntil { self.coordinator._testChecksInFlight == 0 }
    }

    /// Waits until `surfaceIDs` are all registered and every check
    /// requested so far has finished, then asserts they are all still
    /// waiting: nothing that has happened up to now woke or dropped them.
    private func assertWaitingAfterChecksIdle(
        _ surfaceIDs: UUID..., file: StaticString = #filePath, line: UInt = #line
    ) async {
        let wanted = Set(surfaceIDs)
        let registered = await waitUntil { wanted.isSubset(of: self.coordinator.waitingSurfaceIDs) }
        XCTAssertTrue(registered, "the waiter must be registered while awaitWake is suspended", file: file, line: line)
        let idle = await waitForChecksIdle()
        XCTAssertTrue(idle, "every requested check must finish", file: file, line: line)
        XCTAssertTrue(wanted.isSubset(of: coordinator.waitingSurfaceIDs),
                      "the waiter must still be waiting once every requested check has finished",
                      file: file, line: line)
    }

    /// Ends a waiter that was expected not to be woken, and asserts it
    /// returned nil.
    private func releaseAndAssertNil(
        _ surfaceID: UUID, _ waiter: Task<IPCWakeResponse?, Never>, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        coordinator.release(surfaceID: surfaceID)
        let response = await waiter.value
        XCTAssertNil(response, message, file: file, line: line)
    }

    private func expectedWake(peer: UUID, new: Int, senders: Int, unread: Int) -> IPCWakeResponse {
        IPCWakeResponse(
            peerID: peer,
            ticket: IPCWakeTicket(newCount: new, senderCount: senders, unreadCount: unread)
        )
    }

    private func registerPeer(_ name: String) async -> UUID {
        await store.registerPeer(name: name, role: "terminal").id
    }

    /// Puts a message into the store directly. This requests no check.
    private func send(from sender: UUID, to recipient: UUID, _ content: String = "hello") async throws {
        _ = try await store.sendMessage(from: sender, to: recipient, content: content)
    }

    private func flags(_ peerID: UUID) async -> [Bool] {
        await store._testNudgedFlags(for: peerID)
    }

    // MARK: - Wake

    func test_awaitWake_messageAlreadyWaiting_wakesImmediately_andMarksItNudged() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer)
        let flagsBefore = await flags(peer)
        XCTAssertEqual(flagsBefore, [false], "precondition: the message is un-nudged")

        let clock = ContinuousClock()
        let start = clock.now
        let response = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        let elapsed = clock.now - start

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
        XCTAssertLessThan(elapsed, promptBound, "a message that is already waiting must wake without any trigger")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true], "the message the waiter was woken for must be nudged")
    }

    func test_awaitWake_waiterFirst_thenMessageAndReevaluate_wakes() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        try await send(from: sender, to: peer)
        coordinator.reevaluateAllWaiters()
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    func test_awaitWake_messageForADifferentPeer_doesNotWake() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let otherPeer = await registerPeer("other")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        try await send(from: sender, to: otherPeer)
        coordinator.reevaluateAllWaiters()

        await assertWaitingAfterChecksIdle(surface)
        let otherFlags = await flags(otherPeer)
        XCTAssertEqual(otherFlags, [false], "nobody was told about the other peer's message")
        await releaseAndAssertNil(surface, waiter, "the waiter was never woken")
    }

    // MARK: - At most one wake per message

    func test_awaitWake_sameMessages_neverWakeASecondWaiter() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer, "one")
        try await send(from: sender, to: peer, "two")
        let first = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        XCTAssertEqual(first, expectedWake(peer: peer, new: 2, senders: 1, unread: 2),
                       "precondition: the first waiter was woken for both messages")

        let secondWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        coordinator.reevaluateAllWaiters()

        await assertWaitingAfterChecksIdle(surface)
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true, true])
        await releaseAndAssertNil(surface, secondWaiter,
                                  "messages that already caused a wake must never wake a second waiter")
    }

    func test_awaitWake_newerMessage_wakesAgain_countingOnlyItAsNew() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer, "one")
        let first = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        XCTAssertEqual(first, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "precondition: the first message caused a wake")

        try await send(from: sender, to: peer, "two")
        let second = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)

        XCTAssertEqual(second, expectedWake(peer: peer, new: 1, senders: 1, unread: 2),
                       "the newer message wakes again: 1 new, and 2 unread because the first is still " +
                       "in the inbox")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true, true])
    }

    func test_awaitWake_burstOfMessagesBeforeOneCheck_givesOneWakeCountingAll() async throws {
        let senderX = await registerPeer("X")
        let senderY = await registerPeer("Y")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: senderX, to: peer, "x1")
        try await send(from: senderY, to: peer, "y1")
        try await send(from: senderX, to: peer, "x2")

        let first = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)

        XCTAssertEqual(first, expectedWake(peer: peer, new: 3, senders: 2, unread: 3),
                       "three messages from two senders give ONE wake that counts all of them")
        let secondWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)
        await releaseAndAssertNil(surface, secondWaiter, "the burst must not produce a second wake")
    }

    func test_broadcast_wakesEachWaitingSurfaceExactlyOnce() async throws {
        let sender = await registerPeer("sender")
        var surfaceByPeer: [UUID: UUID] = [:]
        for index in 0..<3 {
            let peer = await registerPeer("recipient-\(index)")
            let surface = UUID()
            registry.bindSurface(surface, toPeer: peer)
            surfaceByPeer[peer] = surface
        }
        let surfaces = Array(surfaceByPeer.values)
        var waiters: [UUID: Task<IPCWakeResponse?, Never>] = [:]
        for (peer, surface) in surfaceByPeer {
            waiters[peer] = startWaiter(surface)
        }
        await assertWaitingAfterChecksIdle(surfaces[0], surfaces[1], surfaces[2])

        let delivered = try await store.broadcast(from: sender, content: "to everyone")
        XCTAssertEqual(delivered.count, 3, "precondition: the broadcast reached the three recipients")
        coordinator.reevaluateAllWaiters()

        for (peer, waiter) in waiters {
            let response = await waiter.value
            XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                           "each waiting surface is woken for its own peer's copy")
        }

        // Exactly once: a second round of waiters is not woken.
        var secondRound: [UUID: Task<IPCWakeResponse?, Never>] = [:]
        for surface in surfaces {
            secondRound[surface] = startWaiter(surface)
        }
        await assertWaitingAfterChecksIdle(surfaces[0], surfaces[1], surfaces[2])
        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surfaces[0], surfaces[1], surfaces[2])
        for (surface, waiter) in secondRound {
            await releaseAndAssertNil(surface, waiter, "a broadcast copy must wake its surface only once")
        }
    }

    // MARK: - Returning nil

    /// The one test that lets a waiter run into its own timeout. The
    /// surface is bound and the message is un-nudged, so the waiter is
    /// wakeable the whole time; only the absence of a check request keeps
    /// it waiting, and the timeout must not mark the message.
    func test_awaitWake_timeout_returnsNil_andLeavesFlagsUnchanged() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let timeoutMs = 2_000
        // The elapsed time is measured inside the waiter's own Task, so
        // no polling done by this test counts toward it.
        let waiter = Task { @MainActor () -> (response: IPCWakeResponse?, elapsed: Duration) in
            let clock = ContinuousClock()
            let start = clock.now
            let response = await self.coordinator.awaitWake(surfaceID: surface, timeoutMs: timeoutMs)
            return (response, clock.now - start)
        }
        await assertWaitingAfterChecksIdle(surface)
        try await send(from: sender, to: peer)

        let result = await waiter.value

        XCTAssertNil(result.response, "a waiter nobody requested a check for must time out with nil")
        XCTAssertGreaterThanOrEqual(result.elapsed, .milliseconds(1_500),
                                    "awaitWake must really wait for its 2 s timeout, not return early")
        XCTAssertFalse(coordinator.waitingSurfaceIDs.contains(surface),
                       "a surface must be gone from waitingSurfaceIDs by the time its awaitWake timed out")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "a timeout must not mark the message")

        let later = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        XCTAssertEqual(later, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "the message is still owed its wake, and a later waiter receives it")
    }

    func test_awaitWake_cancelled_returnsNil_andALaterWaiterIsWokenForTheMessages() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        try await send(from: sender, to: peer)

        let clock = ContinuousClock()
        let start = clock.now
        waiter.cancel()
        let response = await waiter.value
        let elapsed = clock.now - start

        XCTAssertNil(response, "cancelling the awaiting Task must make awaitWake return nil")
        XCTAssertLessThan(elapsed, promptBound, "cancellation must end the wait, not the 30 s timeout")
        let removed = await waitUntil { !self.coordinator.waitingSurfaceIDs.contains(surface) }
        XCTAssertTrue(removed, "a cancelled waiter must not stay registered")
        let flagsAfterCancel = await flags(peer)
        XCTAssertEqual(flagsAfterCancel, [false], "cancellation must not mark the message")

        let later = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)

        XCTAssertEqual(later, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "the messages the cancelled waiter never received must wake a later waiter")
    }

    func test_awaitWake_superseded_oldReturnsNil_newGetsTheWake() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let oldWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        let clock = ContinuousClock()
        let start = clock.now
        let newWaiter = startWaiter(surface)
        let oldResponse = await oldWaiter.value
        let elapsed = clock.now - start

        XCTAssertNil(oldResponse, "a newer awaitWake for the same surface must make the older one return nil")
        XCTAssertLessThan(elapsed, promptBound, "the old waiter must end when superseded, not at its timeout")
        await assertWaitingAfterChecksIdle(surface)

        try await send(from: sender, to: peer)
        coordinator.reevaluateAllWaiters()
        let newResponse = await newWaiter.value

        XCTAssertEqual(newResponse, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
    }

    /// The Task of waiter 2 is created and waiter 1 is cancelled with no
    /// suspension point in between, so waiter 1's cancellation clean-up
    /// (a hop back to the main actor) can arrive after waiter 2 took the
    /// surface's slot. It must not remove waiter 2.
    func test_staleCancellationOfAnOlderWaiter_doesNotEvictTheNewerWaiter() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let firstWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        let secondWaiter = startWaiter(surface)
        firstWaiter.cancel()

        let firstResponse = await firstWaiter.value
        XCTAssertNil(firstResponse, "the cancelled waiter returns nil")
        await assertWaitingAfterChecksIdle(surface)
        // Let any clean-up still queued on the main actor run.
        for _ in 0..<100 {
            await Task.yield()
        }
        await assertWaitingAfterChecksIdle(surface)
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [surface],
                       "the older waiter's late clean-up must not evict the newer waiter")

        // The newer waiter is not only listed, it is still reachable.
        try await send(from: sender, to: peer)
        coordinator.reevaluateAllWaiters()
        let secondResponse = await secondWaiter.value
        XCTAssertEqual(secondResponse, expectedWake(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_surfaceDestroyed_releasesOnlyThatSurfacesWaiter() async throws {
        let sender = await registerPeer("sender")
        let peerA = await registerPeer("recipient-a")
        let surfaceA = UUID()
        let surfaceB = UUID()
        registry.bindSurface(surfaceA, toPeer: peerA)
        let waiterA = startWaiter(surfaceA)
        let waiterB = startWaiter(surfaceB)
        await assertWaitingAfterChecksIdle(surfaceA, surfaceB)
        try await send(from: sender, to: peerA)

        let clock = ContinuousClock()
        let start = clock.now
        NotificationCenter.default.post(
            name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": surfaceA]
        )
        let responseA = await waiterA.value
        let elapsed = clock.now - start

        XCTAssertNil(responseA, "the destroyed surface's waiter must return nil")
        XCTAssertLessThan(elapsed, promptBound, "the destroyed surface's waiter must end at the notification")
        await assertWaitingAfterChecksIdle(surfaceB)
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [surfaceB],
                       "another surface's waiter must be untouched by the destruction")
        let flagsAfter = await flags(peerA)
        XCTAssertEqual(flagsAfter, [false], "ending a waiter for a destroyed surface must not mark the message")
        await releaseAndAssertNil(surfaceB, waiterB, "the other waiter was never woken")

        let later = await coordinator.awaitWake(surfaceID: surfaceA, timeoutMs: longTimeoutMs)
        XCTAssertEqual(later, expectedWake(peer: peerA, new: 1, senders: 1, unread: 1),
                       "the message is still owed its wake")
    }

    func test_release_surfaceID_releasesOnlyThatSurfacesWaiter() async throws {
        let sender = await registerPeer("sender")
        let peerA = await registerPeer("recipient-a")
        let surfaceA = UUID()
        let surfaceB = UUID()
        registry.bindSurface(surfaceA, toPeer: peerA)
        let waiterA = startWaiter(surfaceA)
        let waiterB = startWaiter(surfaceB)
        await assertWaitingAfterChecksIdle(surfaceA, surfaceB)
        try await send(from: sender, to: peerA)

        let clock = ContinuousClock()
        let start = clock.now
        coordinator.release(surfaceID: surfaceA)
        let responseA = await waiterA.value
        let elapsed = clock.now - start

        XCTAssertNil(responseA, "release(surfaceID:) must make that surface's waiter return nil")
        XCTAssertLessThan(elapsed, promptBound)
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [surfaceB], "the other surface keeps waiting")
        let flagsAfter = await flags(peerA)
        XCTAssertEqual(flagsAfter, [false], "release(surfaceID:) must not mark the message")
        await releaseAndAssertNil(surfaceB, waiterB, "the other waiter was never woken")

        let later = await coordinator.awaitWake(surfaceID: surfaceA, timeoutMs: longTimeoutMs)
        XCTAssertEqual(later, expectedWake(peer: peerA, new: 1, senders: 1, unread: 1),
                       "the message is still owed its wake")
    }

    func test_releaseAllWaiters_allReturnNil_andFlagsAreUnchanged() async throws {
        let sender = await registerPeer("sender")
        let peerA = await registerPeer("recipient-a")
        let peerB = await registerPeer("recipient-b")
        let surfaceA = UUID()
        let surfaceB = UUID()
        registry.bindSurface(surfaceA, toPeer: peerA)
        registry.bindSurface(surfaceB, toPeer: peerB)
        let waiterA = startWaiter(surfaceA)
        let waiterB = startWaiter(surfaceB)
        await assertWaitingAfterChecksIdle(surfaceA, surfaceB)
        try await send(from: sender, to: peerA)
        try await send(from: sender, to: peerB)

        let clock = ContinuousClock()
        let start = clock.now
        coordinator.releaseAllWaiters()
        let responseA = await waiterA.value
        let responseB = await waiterB.value
        let elapsed = clock.now - start

        XCTAssertNil(responseA)
        XCTAssertNil(responseB)
        XCTAssertLessThan(elapsed, promptBound, "releaseAllWaiters must end every wait, not their 30 s timeouts")
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [])
        let flagsA = await flags(peerA)
        let flagsB = await flags(peerB)
        XCTAssertEqual(flagsA, [false], "releasing waiters must not mark any message")
        XCTAssertEqual(flagsB, [false], "releasing waiters must not mark any message")

        let later = await coordinator.awaitWake(surfaceID: surfaceA, timeoutMs: longTimeoutMs)
        XCTAssertEqual(later, expectedWake(peer: peerA, new: 1, senders: 1, unread: 1),
                       "the message is still owed its wake")
    }

    // MARK: - Binding

    func test_awaitWake_unboundSurface_staysWaiting_thenBindingToAPeerWithMessagesWakesIt() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        try await send(from: sender, to: peer)
        let surface = UUID()
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)
        let flagsWhileUnbound = await flags(peer)
        XCTAssertEqual(flagsWhileUnbound, [false], "nobody was told about the message while unbound")

        // No further message and no reevaluateAllWaiters(): the binding
        // change alone must request the check.
        registry.bindSurface(surface, toPeer: peer)
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "binding the surface to a peer that already has un-nudged messages must wake it")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    func test_awaitWake_rebindingToAnotherPeer_wakesForTheNewPeersMessagesOnly() async throws {
        let sender = await registerPeer("sender")
        let oldPeer = await registerPeer("old")
        let newPeer = await registerPeer("new")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: oldPeer)
        try await send(from: sender, to: newPeer, "n1")
        try await send(from: sender, to: newPeer, "n2")
        let waiter = startWaiter(surface)
        // Messages for a peer this surface is not bound to do not wake it.
        await assertWaitingAfterChecksIdle(surface)

        registry.bindSurface(surface, toPeer: newPeer)
        let response = await waiter.value

        XCTAssertEqual(response, expectedWake(peer: newPeer, new: 2, senders: 1, unread: 2),
                       "after the re-bind the waiter is woken for the new peer's messages")

        // The old peer's messages no longer concern this surface.
        try await send(from: sender, to: oldPeer, "o1")
        let laterWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        coordinator.reevaluateAllWaiters()

        await assertWaitingAfterChecksIdle(surface)
        let oldPeerFlags = await flags(oldPeer)
        XCTAssertEqual(oldPeerFlags, [false])
        await releaseAndAssertNil(surface, laterWaiter,
                                  "a message for the peer the surface was re-bound away from must not wake it")
    }

    /// The waiter is wakeable (bound in the coordinator's own registry,
    /// one un-nudged message) and only lacks a check request. A binding
    /// change for the SAME surface id in a different registry posts the
    /// notification with that other registry as its object; the
    /// coordinator must not take it for a check request.
    func test_bindingChangeInAnotherRegistry_doesNotWake() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        try await send(from: sender, to: peer)

        let otherRegistry = AgentRegistry()
        otherRegistry.bindSurface(surface, toPeer: UUID())
        XCTAssertNotNil(otherRegistry.boundPeerID(for: surface), "precondition: the other registry changed")

        await assertWaitingAfterChecksIdle(surface)
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "another registry's binding change must not cause a wake")
        await releaseAndAssertNil(surface, waiter, "the waiter was never woken")
    }

    // MARK: - Disabled

    func test_disabled_noWakeAndNothingMarked_thenEnabled_aNewWaiterIsWoken() async throws {
        wakeFlag.value = false
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer)

        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        coordinator.reevaluateAllWaiters()

        await assertWaitingAfterChecksIdle(surface)
        let flagsWhileDisabled = await flags(peer)
        XCTAssertEqual(flagsWhileDisabled, [false], "nothing may be marked while disabled")
        await releaseAndAssertNil(surface, waiter, "a check must do nothing while isEnabled() is false")

        wakeFlag.value = true
        let afterEnabling = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)

        XCTAssertEqual(afterEnabling, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "a message that arrived while disabled must wake a NEW waiter once enabled")
    }

    func test_disabled_waiterStaysUntilReleased() async throws {
        wakeFlag.value = false
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer)
        let waiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)

        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)

        let clock = ContinuousClock()
        let start = clock.now
        coordinator.release(surfaceID: surface)
        let response = await waiter.value
        let elapsed = clock.now - start
        XCTAssertNil(response)
        XCTAssertLessThan(elapsed, promptBound, "a waiter registered while disabled can still be released")
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [])
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false])
    }

    // MARK: - waitingSurfaceIDs

    func test_waitingSurfaceIDs_dropsASurfaceOnceItsAwaitWakeReturned() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let wokenSurface = UUID()
        let releasedSurface = UUID()
        registry.bindSurface(wokenSurface, toPeer: peer)
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [], "precondition: nothing is waiting")

        let wokenWaiter = startWaiter(wokenSurface)
        let releasedWaiter = startWaiter(releasedSurface)
        await assertWaitingAfterChecksIdle(wokenSurface, releasedSurface)
        XCTAssertEqual(coordinator.waitingSurfaceIDs, [wokenSurface, releasedSurface],
                       "both surfaces are listed while their awaitWake is suspended")

        try await send(from: sender, to: peer)
        coordinator.reevaluateAllWaiters()
        let woken = await wokenWaiter.value
        XCTAssertNotNil(woken, "precondition: this waiter was woken")
        XCTAssertFalse(coordinator.waitingSurfaceIDs.contains(wokenSurface),
                       "a surface must be gone from waitingSurfaceIDs by the time its awaitWake returned a wake")

        coordinator.release(surfaceID: releasedSurface)
        let released = await releasedWaiter.value
        XCTAssertNil(released, "precondition: this waiter was released")
        XCTAssertFalse(coordinator.waitingSurfaceIDs.contains(releasedSurface),
                       "a surface must be gone from waitingSurfaceIDs by the time its awaitWake returned nil")
    }

    // MARK: - Races between building the takers and calling the store

    /// (a) The waiter is superseded after its check built the taker and
    /// before the check reached the store. That check must hand nothing
    /// to the dead waiter and mark nothing; the newer waiter is woken by
    /// its own check. One wake in total.
    ///
    /// The newer waiter's own check is held inside the seam closure (its
    /// second call) until `_testChecksInFlight` drops to 1, that is until
    /// the stale check has returned from the store. It then records the
    /// flags the stale check left behind.
    func test_beforeOffer_waiterSuperseded_staleCheckMarksNothing_newWaiterWokenByItsOwnCheck() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer)
        let store: IPCStore = self.store

        coordinator._testBeforeOffer = { [weak self] in
            guard let self else { return }
            self.seamCalls += 1
            if self.seamCalls == 1 {
                self.seamSecondWaiter = self.startWaiter(surface)
                // Wait until the first waiter has returned (superseded).
                _ = await self.seamFirstWaiter?.value
            } else if self.seamCalls == 2 {
                self.seamSawStaleCheckFinish = await self.waitUntil {
                    self.coordinator._testChecksInFlight == 1
                }
                self.seamObservedFlags = await store._testNudgedFlags(for: peer)
            }
        }
        let firstWaiter = startWaiter(surface)
        seamFirstWaiter = firstWaiter

        let firstResponse = await firstWaiter.value
        XCTAssertNil(firstResponse, "the superseded waiter must get nothing")
        let secondWaiter = try XCTUnwrap(seamSecondWaiter, "the seam closure must have started the second waiter")
        let secondResponse = await secondWaiter.value

        XCTAssertEqual(seamSawStaleCheckFinish, true,
                       "precondition: the stale check returned from the store before the newer check ran")
        XCTAssertEqual(seamObservedFlags, [false],
                       "the stale check, whose waiter was already gone, must not have marked the message")
        XCTAssertEqual(secondResponse, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "the newer waiter must be woken for the message, by its own check")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])

        // Exactly one wake in total.
        coordinator._testBeforeOffer = nil
        let thirdWaiter = startWaiter(surface)
        await assertWaitingAfterChecksIdle(surface)
        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)
        await releaseAndAssertNil(surface, thirdWaiter, "the message caused exactly one wake")
    }

    /// (b) The waiter's Task is cancelled after its check built the taker
    /// and before the check reached the store. Nothing may be marked.
    func test_beforeOffer_waiterCancelled_marksNothing() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await send(from: sender, to: peer)

        coordinator._testBeforeOffer = { [weak self] in
            guard let self else { return }
            self.seamCalls += 1
            guard self.seamCalls == 1 else { return }
            self.seamFirstWaiter?.cancel()
            _ = await self.seamFirstWaiter?.value
        }
        let firstWaiter = startWaiter(surface)
        seamFirstWaiter = firstWaiter

        let firstResponse = await firstWaiter.value

        XCTAssertNil(firstResponse, "the cancelled waiter must get nothing")
        XCTAssertEqual(seamCalls, 1, "precondition: the seam closure ran for the cancelled waiter's check")
        // The stale check goes on to the store after the closure returned.
        let idle = await waitForChecksIdle()
        XCTAssertTrue(idle, "the stale check must return from the store")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false],
                       "a check whose waiter was cancelled before the store call must mark nothing")

        coordinator._testBeforeOffer = nil
        let later = await coordinator.awaitWake(surfaceID: surface, timeoutMs: longTimeoutMs)
        XCTAssertEqual(later, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "the message is still owed its wake, and a later waiter receives it")
    }

    /// (c) The peer's binding moves to another surface after the check
    /// read it. The binding is a snapshot taken when the check starts, so
    /// the ORIGINAL surface's waiter still receives the wake and the
    /// messages are marked; a waiter on the other surface is not woken for
    /// them.
    func test_beforeOffer_bindingMoved_originalSurfaceStillGetsTheWake_otherSurfaceDoesNot() async throws {
        let sender = await registerPeer("sender")
        let peer = await registerPeer("recipient")
        let originalSurface = UUID()
        let otherSurface = UUID()
        registry.bindSurface(originalSurface, toPeer: peer)
        try await send(from: sender, to: peer)
        let registry: AgentRegistry = self.registry

        coordinator._testBeforeOffer = { [weak self] in
            guard let self else { return }
            self.seamCalls += 1
            guard self.seamCalls == 1 else { return }
            registry.bindSurface(otherSurface, toPeer: peer)
        }

        let response = await coordinator.awaitWake(surfaceID: originalSurface, timeoutMs: longTimeoutMs)

        XCTAssertGreaterThanOrEqual(seamCalls, 1, "precondition: the seam closure ran")
        XCTAssertNil(registry.boundPeerID(for: originalSurface), "precondition: the binding really moved away")
        XCTAssertEqual(registry.boundPeerID(for: otherSurface), peer, "precondition: the binding really moved")
        XCTAssertEqual(response, expectedWake(peer: peer, new: 1, senders: 1, unread: 1),
                       "the check uses the binding it read when it started: the original surface's " +
                       "waiter still receives the wake")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true], "the delivered messages are marked")

        coordinator._testBeforeOffer = nil
        let otherWaiter = startWaiter(otherSurface)
        await assertWaitingAfterChecksIdle(otherSurface)
        coordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(otherSurface)
        await releaseAndAssertNil(otherSurface, otherWaiter,
                                  "the other surface must not be woken for messages already delivered")
    }
}

/// The enabled flag the coordinator under test reads. A main-actor box
/// rather than a property of the test case, so the `isEnabled` closure
/// captures no test case.
@MainActor
private final class WakeFlag {
    var value = true
}
