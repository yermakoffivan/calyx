//
//  CalyxMCPServerIPCWakeEnabledGateTests.swift
//  CalyxTests
//
//  Pins that `POST /ipc-wake` has one reader of the wake setting: the
//  route asks `ipcWakeCoordinator.isEnabled`, not `IPCWakeSettings.enabled`
//  directly. The server's `_testIPCWakeIsEnabled` seam is the `isEnabled`
//  closure the lazily built coordinator receives; it is set before
//  anything touches `ipcWakeCoordinator`.
//
//  With `IPCWakeSettings.enabled == true` but the coordinator's gate
//  returning false, a route that read the setting directly would register
//  a waiter and long-poll; the route that asks the coordinator answers
//  204 at once with no waiter. And the other way round: setting off,
//  coordinator gate on, the poll is served (200 for a waiting message).
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerIPCWakeEnabledGateTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var agentEndpointDir: String!
    private var gate: EnabledGateBox!
    private let testToken = "ipc-wake-enabled-gate-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerIPCWakeEnabledGateTests"
    /// Short, so that a route that wrongly long-polls fails after 3 s
    /// instead of hanging.
    private let pollTimeoutMs = 3_000
    private let promptBound: Duration = .milliseconds(1_500)

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        registry = AgentRegistry()
        server.agentRegistry = registry
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server._testSetToken(testToken)
        server.ipcWakeTimeoutMs = pollTimeoutMs
        let gate = EnabledGateBox()
        self.gate = gate
        server._testIPCWakeIsEnabled = { gate.value }
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        registry = nil
        gate = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    private func poll(_ surfaceID: UUID) async -> HTTPResponse {
        await server.route(request: HTTPRequest(
            method: "POST", path: "/ipc-wake",
            headers: ["Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": surfaceID.uuidString],
            body: nil
        ))
    }

    func test_route_settingOnButCoordinatorGateOff_returns204AtOnce_andRegistersNoWaiter() async throws {
        IPCWakeSettings.enabled = true
        gate.value = false
        XCTAssertFalse(server.ipcWakeCoordinator.isEnabled, "precondition: the coordinator's gate reads false")
        let sender = await server.store.registerPeer(name: "sender", role: "terminal").id
        let peer = await server.store.registerPeer(name: "recipient", role: "terminal").id
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        _ = try await server.store.sendMessage(from: sender, to: peer, content: "hello")

        let clock = ContinuousClock()
        let start = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204, "the coordinator's gate is off, so the poll gets 204")
        XCTAssertLessThan(elapsed, promptBound,
                          "the route must ask the coordinator's gate and answer at once, not register a " +
                          "waiter because IPCWakeSettings.enabled is true")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "no waiter may be registered")
        let flagsAfter = await server.store._testNudgedFlags(for: peer)
        XCTAssertEqual(flagsAfter, [false])
    }

    func test_route_settingOffButCoordinatorGateOn_servesThePoll() async throws {
        IPCWakeSettings.enabled = false
        gate.value = true
        let sender = await server.store.registerPeer(name: "sender", role: "terminal").id
        let peer = await server.store.registerPeer(name: "recipient", role: "terminal").id
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        _ = try await server.store.sendMessage(from: sender, to: peer, content: "hello")

        let response = await poll(surface)

        XCTAssertEqual(response.statusCode, 200,
                       "the route's gate is the coordinator's isEnabled: with it on, a waiting message is " +
                       "answered whatever IPCWakeSettings.enabled says")
        XCTAssertEqual(response.body, IPCWakeResponse(
            peerID: peer, ticket: IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)
        ).bodyData)
    }
}

/// The value the coordinator's `isEnabled` closure returns. A main-actor
/// box so the closure captures no test case.
@MainActor
private final class EnabledGateBox {
    var value = true
}
