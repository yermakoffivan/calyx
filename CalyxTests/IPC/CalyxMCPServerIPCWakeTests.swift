//
//  CalyxMCPServerIPCWakeTests.swift
//  CalyxTests
//
//  Pins `POST /ipc-wake` on CalyxMCPServer: the request the client
//  long-polling `/ipc-wake` holds open, answered with 200 and a short note
//  when the surface's peer has messages it has not been told about yet,
//  otherwise 204. Same harness as CalyxMCPServerApprovalRequestTests: HTTPRequest
//  values driven straight through `server.route(request:)`, an isolated
//  `agent-endpoint.json` directory, a fresh AgentRegistry and an isolated
//  IPCWakeSettings suite. The server is started (`start()` on a
//  kernel-assigned port) because `start()` is what connects the store's
//  inbox-growth sink to the coordinator: a message reaching the store by
//  any path then requests a check.
//
//  Coverage:
//  - ipcWakeTimeoutMs defaults to IPCWakeHookTiming.serverTimeoutMs
//  - Bearer auth (401), unresolvable surface (400), and their order: the
//    bearer is checked before the surface, the surface before the kind
//  - X-Calyx-Agent-Kind present and not "claude-code": 204 at once
//  - IPCWakeSettings.enabled == false: 204 at once, no waiter registered
//  - Surface bound to nothing: 204 after the timeout
//  - A wake: 200, Content-Type "text/plain; charset=utf-8", body equal to
//    IPCWakeResponse.bodyData; the body names the recipient's own peer id
//    and none of the sender's name, role or message content
//  - A poll that is already waiting is woken by a send_message or
//    broadcast tools/call once initialize or register_peer bound its
//    surface, by a message put straight into the store (no tools/call at
//    all), and by a hook event that binds its surface to a peer that
//    already has un-nudged messages
//  - Each message wakes at most once; a newer message wakes again
//  - A second poll for the same surface makes the first return 204;
//    server.stop() and cancelling the route's Task end a waiting poll,
//    leaving the message un-nudged
//  - receive_messages output carries no `nudged` key
//
//  Synchronisation: "nothing happened" is never concluded from elapsed
//  time. A poll that must not be woken gets a 30 s timeout; the test waits
//  until it is registered and the coordinator's `_testChecksInFlight` is
//  0, asserts it is still waiting, and then ends it explicitly.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerIPCWakeTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private let testToken = "ipc-wake-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerIPCWakeTests"

    /// Test-isolated `agent-endpoint.json` directory, written by
    /// `start()` and removed by `stopAndWait()`.
    private var agentEndpointDir: String!

    /// Timeout of every poll that is ended by an event other than its
    /// timeout. Far beyond any test's runtime, so the timeout never wins.
    private let longTimeoutMs = 30_000
    /// Upper bound for "ended because of the event, not the 30 s timeout".
    private let promptBound: Duration = .seconds(10)

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
        IPCWakeSettings.enabled = true
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        registry = AgentRegistry()
        server.agentRegistry = registry
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server.ipcWakeTimeoutMs = longTimeoutMs
        try await server.start(token: testToken, preferredPort: 0)
    }

    override func tearDown() async throws {
        await server.stopAndWait()
        server = nil
        registry = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Request-building helpers

    private func wakeRequest(
        token: String?,
        surfaceIDHeader: String?,
        kindHeader: String? = nil
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        if let kindHeader { headers["X-Calyx-Agent-Kind"] = kindHeader }
        return HTTPRequest(method: "POST", path: "/ipc-wake", headers: headers, body: nil)
    }

    private func poll(_ surfaceID: UUID) async -> HTTPResponse {
        await server.route(request: wakeRequest(token: testToken, surfaceIDHeader: surfaceID.uuidString))
    }

    private func startPoll(_ surfaceID: UUID) -> Task<HTTPResponse, Never> {
        Task { @MainActor in
            await self.poll(surfaceID)
        }
    }

    private func agentEventRequest(surfaceID: UUID, body: Data) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/agent-event",
            headers: ["Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": surfaceID.uuidString],
            body: body
        )
    }

    private func rpcRequest(id: Int, method: String, params: [String: Any]) -> Data {
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func initializeRequestBody() -> Data {
        rpcRequest(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])
    }

    /// Runs one `tools/call` through `handleJSONRPC` and returns the text
    /// of its result, failing if the call reported an error.
    @discardableResult
    private func callTool(
        _ toolName: String, _ arguments: [String: Any], surfaceID: UUID? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> String {
        let data = rpcRequest(id: 2, method: "tools/call", params: ["name": toolName, "arguments": arguments])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken, surfaceID: surfaceID)
        XCTAssertEqual(statusCode, 200, file: file, line: line)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(body, file: file, line: line)) as? [String: Any],
            file: file, line: line
        )
        let result = try XCTUnwrap(json["result"] as? [String: Any], file: file, line: line)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], file: file, line: line)
        let text = try XCTUnwrap(content.first?["text"] as? String, file: file, line: line)
        XCTAssertFalse(result["isError"] as? Bool ?? false, "\(toolName) failed: \(text)", file: file, line: line)
        return text
    }

    /// Registers a peer through the `register_peer` tool and returns its id.
    private func registerPeerViaTool(name: String, role: String = "terminal", surfaceID: UUID? = nil) async throws -> UUID {
        let text = try await callTool("register_peer", ["name": name, "role": role], surfaceID: surfaceID)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["peerId"] as? String)))
    }

    /// Registers a peer straight in the store, with no tools/call.
    private func registerPeerInStore(_ name: String, role: String = "terminal") async -> UUID {
        await server.store.registerPeer(name: name, role: role).id
    }

    /// Delivers a message straight through the store, with no tools/call.
    /// The server was started, so the store's inbox sink requests a check
    /// for the recipient.
    private func deliverInStore(from sender: UUID, to recipient: UUID, _ content: String = "hello") async throws {
        _ = try await server.store.sendMessage(from: sender, to: recipient, content: content)
    }

    // MARK: - Waiting helpers

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func waitForWaitingPoll(_ surfaceID: UUID) async -> Bool {
        await waitUntil { self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID) }
    }

    /// Waits until the poll for `surfaceID` is registered and every check
    /// requested so far has returned from the store, then asserts the poll
    /// is still waiting: nothing that has happened up to now ended it. A
    /// message delivered afterwards can only be noticed by a later check.
    private func assertWaitingAfterChecksIdle(
        _ surfaceID: UUID, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let registered = await waitForWaitingPoll(surfaceID)
        XCTAssertTrue(registered, "the poll must be registered while route(request:) is suspended",
                      file: file, line: line)
        let idle = await waitUntil { self.server.ipcWakeCoordinator._testChecksInFlight == 0 }
        XCTAssertTrue(idle, "every requested check must finish", file: file, line: line)
        XCTAssertTrue(server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID),
                      "the poll must still be waiting once every requested check has finished",
                      file: file, line: line)
    }

    private func expectedBody(peer: UUID, new: Int, senders: Int, unread: Int) -> Data {
        IPCWakeResponse(
            peerID: peer,
            ticket: IPCWakeTicket(newCount: new, senderCount: senders, unreadCount: unread)
        ).bodyData
    }

    private func flags(_ peerID: UUID) async -> [Bool] {
        await server.store._testNudgedFlags(for: peerID)
    }

    // MARK: - Default timeout

    func test_defaultTimeout_isIPCWakeHookTimingServerTimeout() {
        let freshServer = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)

        XCTAssertEqual(freshServer.ipcWakeTimeoutMs, IPCWakeHookTiming.serverTimeoutMs)
        XCTAssertEqual(freshServer.ipcWakeTimeoutMs, 570_000,
                       "the default /ipc-wake long-poll timeout must be 570_000 ms")
    }

    // MARK: - Authentication

    func test_route_missingOrWrongBearer_returns401() async throws {
        // The surface's peer has a message, so an authenticated poll
        // would answer 200: only the bearer check can produce the 401.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)
        let cases: [(label: String, token: String?)] = [
            ("missing", nil),
            ("wrong", "wrong-token"),
        ]

        for testCase in cases {
            let response = await server.route(
                request: wakeRequest(token: testCase.token, surfaceIDHeader: surface.uuidString)
            )

            XCTAssertEqual(response.statusCode, 401, "[\(testCase.label) bearer] must return 401")
            XCTAssertNil(response.body, "[\(testCase.label) bearer] a 401 must carry an empty body")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "a rejected poll registers no waiter")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "a rejected poll must not be told about the message")
    }

    /// The bearer is checked first: a request that is wrong in two ways
    /// (bad bearer, no surface header) is answered for the bearer.
    func test_route_wrongBearerAndNoSurfaceHeader_returns401() async {
        let response = await server.route(request: wakeRequest(token: "wrong-token", surfaceIDHeader: nil))

        XCTAssertEqual(response.statusCode, 401, "the bearer check must come before surface resolution")
        XCTAssertNil(response.body)
    }

    // MARK: - Surface resolution

    /// The surface is resolved before the agent kind is looked at: a
    /// non-claude-code kind gets its 204 only for a resolvable surface.
    func test_route_unresolvableSurfaceAndNonClaudeKind_returns400() async {
        let cases: [(label: String, header: String?)] = [
            ("missing header", nil),
            ("unknown calyx-session id", "not-a-surface-or-known-session"),
        ]

        for testCase in cases {
            let response = await server.route(request: wakeRequest(
                token: testToken, surfaceIDHeader: testCase.header, kindHeader: "codex"
            ))

            XCTAssertEqual(response.statusCode, 400,
                           "[\(testCase.label)] surface resolution must come before the agent-kind check")
        }
    }

    func test_route_unresolvableSurface_returns400() async {
        let cases: [(label: String, header: String?)] = [
            ("missing header", nil),
            ("unknown calyx-session id", "not-a-surface-or-known-session"),
        ]

        for testCase in cases {
            let response = await server.route(
                request: wakeRequest(token: testToken, surfaceIDHeader: testCase.header)
            )

            XCTAssertEqual(response.statusCode, 400, "[\(testCase.label)] must return 400")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Agent kind

    func test_route_nonClaudeKindHeader_returns204Immediately() async throws {
        // The surface's peer has a message, so a Claude Code poll would
        // answer 200 and a poll that waited would take 30 s.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        for kind in ["codex", "grok", "opencode"] {
            let clock = ContinuousClock()
            let start = clock.now
            let response = await server.route(
                request: wakeRequest(token: testToken, surfaceIDHeader: surface.uuidString, kindHeader: kind)
            )
            let elapsed = clock.now - start

            XCTAssertEqual(response.statusCode, 204, "[\(kind)] a non-claude-code kind must get 204")
            XCTAssertNil(response.body, "[\(kind)] a 204 must carry an empty body")
            XCTAssertLessThan(elapsed, promptBound, "[\(kind)] the 204 must come at once, not after the timeout")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "a non-claude-code poll must not consume the message's wake")
    }

    func test_route_explicitClaudeCodeKindHeader_isServedLikeNoHeader() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let response = await server.route(
            request: wakeRequest(token: testToken, surfaceIDHeader: surface.uuidString, kindHeader: "claude-code")
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - Setting off

    func test_route_settingOff_returns204Immediately_andRegistersNoWaiter() async throws {
        IPCWakeSettings.enabled = false
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let clock = ContinuousClock()
        let start = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204, "with the setting off the poll must get 204")
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "the 204 must come at once, not after the 30 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "no waiter may be registered")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "with the setting off nothing may be marked")
    }

    // MARK: - Timeout

    func test_route_surfaceBoundToNothing_returns204AfterTheTimeout() async throws {
        server.ipcWakeTimeoutMs = 400
        // A message exists, but for a peer this surface is not bound to.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        try await deliverInStore(from: sender, to: peer)
        let surface = UUID()

        let clock = ContinuousClock()
        let start = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNil(response.body)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300),
                                    "an unbound surface's poll must wait for the 400 ms timeout, not return at once")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false])
    }

    // MARK: - Wake response

    func test_route_peerHasMessage_returns200TextPlain_withTheExactNote_andNoSenderStrings() async throws {
        let senderName = "ZZ-SENDER-NAME-7731"
        let senderRole = "ZZ-SENDER-ROLE-4402"
        let content = "ZZ-MESSAGE-CONTENT-9958"
        let sender = await registerPeerInStore(senderName, role: senderRole)
        let peer = await registerPeerInStore("ZZ-RECIPIENT-NAME-1186", role: "ZZ-RECIPIENT-ROLE-3320")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, content)

        let response = await poll(surface)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1),
                       "the body must be exactly IPCWakeResponse's note for 1 new message from 1 peer")
        let text = try XCTUnwrap(String(data: try XCTUnwrap(response.body), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("Calyx IPC: "), "got: \(text)")
        XCTAssertTrue(text.contains(peer.uuidString), "the note must name the recipient's own peer id")
        XCTAssertFalse(text.contains(senderName), "the note must not contain the sender's name")
        XCTAssertFalse(text.contains(senderRole), "the note must not contain the sender's role")
        XCTAssertFalse(text.contains(content), "the note must not contain the message content")
        XCTAssertFalse(text.contains("ZZ-"), "the note must contain no string chosen by a peer")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true], "the message the poll was woken for is nudged")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Woken by a messaging tools/call

    func test_route_bindingFromInitialize_thenSendMessageToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")

        let (initStatus, _) = await server.handleJSONRPC(
            data: initializeRequestBody(), authToken: testToken, surfaceID: surface
        )
        XCTAssertEqual(initStatus, 200)
        let peer = try XCTUnwrap(registry.boundPeerID(for: surface), "initialize must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")
        XCTAssertTrue(server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface),
                      "precondition: the binding alone, with no message, does not end the poll")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200, "a send_message tools/call must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromRegisterPeer_thenBroadcastToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")

        let peer = try await registerPeerViaTool(name: "recipient", surfaceID: surface)
        XCTAssertEqual(registry.boundPeerID(for: surface), peer, "register_peer must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("broadcast", ["from": sender.uuidString, "content": "to everyone"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200, "a broadcast tools/call must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromInitialize_thenBroadcastToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        _ = await server.handleJSONRPC(data: initializeRequestBody(), authToken: testToken, surfaceID: surface)
        let peer = try XCTUnwrap(registry.boundPeerID(for: surface), "initialize must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("broadcast", ["from": sender.uuidString, "content": "to everyone"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromRegisterPeer_thenSendMessageToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        let peer = try await registerPeerViaTool(name: "recipient", surfaceID: surface)
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    /// The trigger follows the store, not the transport: once `start()`
    /// has run, a message put straight into the store wakes a poll that
    /// is already waiting, with no tools/call involved. The poll's
    /// timeout is short so that a missing trigger fails as a 204 after
    /// 2 s rather than a 30 s hang.
    func test_route_messageDeliveredStraightIntoTheStoreAfterStart_wakesTheWaitingPoll() async throws {
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let pollTask = startPoll(surface)
        // The registration check runs on an empty inbox, so only the
        // store's own report of the new message can wake the poll.
        await assertWaitingAfterChecksIdle(surface)

        try await deliverInStore(from: sender, to: peer)
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "a message that reaches the store by any path must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    /// Pins that `start()` reinstalls the store's inbox sink on every call
    /// and `stop()` does not remove it: after `stopAndWait()` and a second
    /// `start()`, a message put straight into the store, with no
    /// tools/call, still wakes a poll that is already waiting. The poll's
    /// timeout is short so that a missing trigger fails as a 204 after
    /// 2 s rather than a 30 s hang.
    func test_route_afterStopAndRestart_messageDeliveredStraightIntoTheStore_stillWakesTheWaitingPoll() async throws {
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: 0)
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let pollTask = startPoll(surface)
        // The registration check runs on an empty inbox, so only the
        // store's own report of the new message can wake the poll.
        await assertWaitingAfterChecksIdle(surface)

        try await deliverInStore(from: sender, to: peer)
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "after a stop and restart a message put straight into the store must still wake the poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    // MARK: - Woken by a hook-derived binding

    func test_route_hookEventBindsSurfaceToExistingPeerWithMessages_wakesTheWaitingPoll() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        try await deliverInStore(from: sender, to: peer)
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")
        // An unbound surface's poll keeps waiting.
        await assertWaitingAfterChecksIdle(surface)

        // A PreToolUse event for receive_messages carries the pane's own
        // peer id in tool_input.peer_id; the registry binds the surface
        // to it. No message is sent and no tools/call is made.
        let eventResponse = await server.route(request: agentEventRequest(
            surfaceID: surface,
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__receive_messages",
             "tool_input":{"peer_id":"\(peer.uuidString)"}}
            """.utf8)
        ))
        XCTAssertEqual(eventResponse.statusCode, 204)
        XCTAssertEqual(registry.boundPeerID(for: surface), peer, "precondition: the hook event bound the surface")
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "binding the surface to a peer that already has un-nudged messages must wake the poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - At most one wake per message

    func test_route_sameMessage_secondPollGets204_newerMessageGets200() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, "one")
        let first = await poll(surface)
        XCTAssertEqual(first.statusCode, 200, "precondition: the first poll is woken for the message")
        XCTAssertEqual(first.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))

        let secondPoll = startPoll(surface)
        await assertWaitingAfterChecksIdle(surface)
        server.ipcWakeCoordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)
        server.ipcWakeCoordinator.release(surfaceID: surface)
        let second = await secondPoll.value

        XCTAssertEqual(second.statusCode, 204, "the same message must not wake a second poll")
        XCTAssertNil(second.body)

        try await deliverInStore(from: sender, to: peer, "two")
        let third = await poll(surface)

        XCTAssertEqual(third.statusCode, 200, "a newer message must wake again")
        XCTAssertEqual(third.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 2),
                       "1 new message, 2 unread: the first message is still in the inbox")
    }

    // MARK: - Supersede

    func test_route_secondPollForTheSameSurface_makesTheFirstReturn204() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let firstPoll = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the first poll is waiting")

        let clock = ContinuousClock()
        let start = clock.now
        let secondPoll = startPoll(surface)
        let first = await firstPoll.value
        let elapsed = clock.now - start

        XCTAssertEqual(first.statusCode, 204, "a second poll for the same surface must end the first with 204")
        XCTAssertNil(first.body)
        XCTAssertLessThan(elapsed, promptBound, "the first poll must end when superseded, not at its 30 s timeout")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let second = await secondPoll.value
        XCTAssertEqual(second.statusCode, 200, "the second poll is the one that is woken")
        XCTAssertEqual(second.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - Server stop

    func test_serverStop_makesAWaitingPollReturn204() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        let clock = ContinuousClock()
        let start = clock.now
        server.stop()
        let response = await pollTask.value
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "stop() must end the poll at once, not leave it to its 30 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Cancellation

    func test_route_taskCancelledWhileWaiting_removesTheWaiter_andLeavesTheMessageUnNudged() async throws {
        // The surface is bound and the message is un-nudged, so the poll
        // is wakeable. Its registration check is held in the coordinator's
        // `_testBeforeOffer` seam (after the taker was built, before the
        // store call) while the route's Task is cancelled, so the
        // cancellation always comes first and the check must then hand
        // nothing over.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)
        let pollBox = PollTaskBox()
        server.ipcWakeCoordinator._testBeforeOffer = {
            guard let pollTask = pollBox.task, !pollBox.cancelled else { return }
            pollBox.cancelled = true
            pollTask.cancel()
            pollBox.response = await pollTask.value
        }

        let clock = ContinuousClock()
        let start = clock.now
        let pollTask = startPoll(surface)
        pollBox.task = pollTask
        let response = await pollTask.value
        let elapsed = clock.now - start

        XCTAssertTrue(pollBox.cancelled, "precondition: the poll was cancelled inside its registration check")
        XCTAssertEqual(response.statusCode, 204, "a cancelled poll resolves as no wake")
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "cancellation must end the poll, not its 30 s timeout")
        let removed = await waitUntil { !self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface) }
        XCTAssertTrue(removed, "cancelling the Task running route(request:) must remove the waiter")
        server.ipcWakeCoordinator._testBeforeOffer = nil
        let idle = await waitUntil { self.server.ipcWakeCoordinator._testChecksInFlight == 0 }
        XCTAssertTrue(idle, "the held check must return from the store")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "the message must stay un-nudged")

        // The message is still owed its wake.
        let later = await poll(surface)
        XCTAssertEqual(later.statusCode, 200)
        XCTAssertEqual(later.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - receive_messages output

    func test_receiveMessagesToolCall_messageObjectsHaveNoNudgedKey() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, "one")
        let woken = await poll(surface)
        XCTAssertEqual(woken.statusCode, 200, "precondition: the first message caused a wake")
        try await deliverInStore(from: sender, to: peer, "two")
        let flagsBefore = await flags(peer)
        XCTAssertEqual(flagsBefore, [true, false], "precondition: one nudged and one un-nudged message")

        let text = try await callTool("receive_messages", ["peer_id": peer.uuidString])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["content"] as? String }, ["one", "two"])
        for message in messages {
            XCTAssertNil(message["nudged"], "the nudged flag is internal and must not appear in receive_messages")
            XCTAssertEqual(Set(message.keys), ["id", "from", "to", "content", "timestamp"],
                           "receive_messages must keep exactly its existing message keys")
        }
        XCTAssertFalse(text.contains("nudged"), "got: \(text)")
    }
}

/// The poll Task the `_testBeforeOffer` closure of the cancellation test
/// cancels, set once the Task exists. A main-actor box so the closure
/// captures no test case.
@MainActor
private final class PollTaskBox {
    var task: Task<HTTPResponse, Never>?
    var cancelled = false
    var response: HTTPResponse?
}
