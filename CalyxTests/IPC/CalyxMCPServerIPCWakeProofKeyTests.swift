//
//  CalyxMCPServerIPCWakeProofKeyTests.swift
//  CalyxTests
//
//  Pins CalyxMCPServer's wake proof key itself (spec A.3 `CalyxMCPServer`
//  "key: created in init, recreated on every start(), written to the
//  endpoint file"; I14). CalyxMCPServerIPCWakeTests covers everything that
//  can be seen through the endpoint file; this file needs the key's bytes,
//  so it relies on the planned stored property and is kept apart so the
//  rest of the target compiles before it exists.
//
//  Planned API used here:
//    CalyxMCPServer.wakeProofKey: IPCWakeProofKey { get }   // private(set)
//
//  Coverage:
//  - the blocks in agent-endpoint.json are the current key's blocks
//  - start() twice gives a different key
//  - neither the key bytes (hex, either case) nor either block appears in
//    any /ipc-wake response body or header
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerIPCWakeProofKeyTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var agentEndpointDir: String!
    private let testToken = "ipc-wake-proof-key-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerIPCWakeProofKeyTests"

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
        server.ipcWakeTimeoutMs = 30_000
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

    private func request(token: String, surface: UUID, nonce: String?) -> HTTPRequest {
        var headers = ["Authorization": "Bearer \(token)", "X-Calyx-Surface-ID": surface.uuidString]
        if let nonce { headers[IPCWakeResponse.nonceHeader] = nonce }
        return HTTPRequest(method: "POST", path: "/ipc-wake", headers: headers, body: nil)
    }

    func test_endpointFileBlocks_areTheCurrentKeysBlocks() throws {
        let blocks = try XCTUnwrap(IPCWakeTestCrypto.readEndpointBlocks(directory: agentEndpointDir))
        XCTAssertEqual(blocks.inner, server.wakeProofKey.innerBlockHex)
        XCTAssertEqual(blocks.outer, server.wakeProofKey.outerBlockHex)
        XCTAssertEqual(server.wakeProofKey.bytes.count, 32)
    }

    func test_start_twice_givesADifferentKey() async throws {
        let first = server.wakeProofKey
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: 0)

        XCTAssertNotEqual(server.wakeProofKey, first, "start() must create a new key")
        let blocks = try XCTUnwrap(IPCWakeTestCrypto.readEndpointBlocks(directory: agentEndpointDir))
        XCTAssertEqual(blocks.inner, server.wakeProofKey.innerBlockHex, "the file carries the new key's blocks")
    }

    func test_responses_carryNeitherTheKeyNorItsBlocks() async throws {
        let sender = await server.store.registerPeer(name: "sender", role: "terminal").id
        let peer = await server.store.registerPeer(name: "recipient", role: "terminal").id
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        _ = try await server.store.sendMessage(from: sender, to: peer, content: "hello")
        let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"

        let responses = [
            await server.route(request: request(token: testToken, surface: surface, nonce: nonce)),
            await server.route(request: request(token: testToken, surface: surface, nonce: nil)),
            await server.route(request: request(token: "wrong", surface: surface, nonce: nonce)),
        ]
        XCTAssertEqual(responses.map(\.statusCode), [200, 400, 401])
        let note = IPCWakeResponse(
            peerID: peer, ticket: IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)
        ).note
        XCTAssertEqual(responses[0].body, IPCWakeResponse.responseBody(
            proof: server.wakeProofKey.proof(nonce: nonce, note: note), note: note))

        let key = server.wakeProofKey
        let keyHex = IPCWakeTestCrypto.hex(key.bytes)
        for response in responses {
            let body = String(data: response.body ?? Data(), encoding: .utf8)?.lowercased() ?? ""
            let headers = response.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n").lowercased()
            for (name, secret) in [("key", keyHex), ("inner block", key.innerBlockHex), ("outer block", key.outerBlockHex)] {
                XCTAssertFalse(body.contains(secret), "[\(response.statusCode)] body must not carry the \(name)")
                XCTAssertFalse(headers.contains(secret), "[\(response.statusCode)] headers must not carry the \(name)")
            }
        }
    }
}
