//
//  CalyxMCPServerAgentStatusToolTests.swift
//  CalyxTests
//
//  Pins the server-side wiring of the agent_status Cockpit tool (spec B.2),
//  driven through route(request:) on POST /mcp with no real NWConnection:
//
//  - handleCockpitToolCall passes the request's X-Calyx-Surface-ID through,
//    so is_self is true for the calling pane and false for another
//  - lazyCockpitBridge reads unread counts live from the server's own
//    IPCStore (store.inboxCounts), not from the agent row's cached
//    unreadCount
//  - agent_status is not in inboxSyncToolNames: a call leaves the bound
//    row's AgentEntry.unreadCount as it was (the same technique as
//    CalyxMCPServerCockpitToolsTests.test_toolsCall_cockpitTool_doesNotTriggerInboxSync)
//

import XCTest
@testable import Calyx

@MainActor
private final class AgentStatusServerFakeCockpitAccess: CockpitAppAccessing {
    var panes: [CockpitPaneInfo] = []

    func listPanes() -> [CockpitPaneInfo] { panes }
    func paneExists(_ id: UUID) -> Bool { panes.contains { $0.surfaceID == id } }
    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {}
    func sendKeys(surfaceID: UUID, text: String) throws {}
    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID { throw CockpitAccessError.appUnavailable }
    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab { throw CockpitAccessError.appUnavailable }
    func availablePaletteCommands() -> [CockpitPaletteCommand] { [] }
    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand { throw CockpitAccessError.appUnavailable }
}

@MainActor
final class CalyxMCPServerAgentStatusToolTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!
    private let testToken = "test-token-agent-status"

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalyxMCPServerAgentStatusToolTests-\(UUID().uuidString)").path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server.sessionSurfaceMap = SessionSurfaceMap()
        server.approvalInbox = ApprovalInboxStore()
        server._testSetToken(testToken)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func pane(surfaceID: UUID = UUID()) -> CockpitPaneInfo {
        CockpitPaneInfo(
            surfaceID: surfaceID, windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "zsh", title: nil, cwd: nil, isFocused: false, agentKind: nil, calyxSessionID: nil
        )
    }

    private func mcpToolCall(
        _ toolName: String, arguments: [String: Any], surfaceID: UUID? = nil, id: Int = 7
    ) throws -> HTTPRequest {
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments],
        ]
        var headers = ["Authorization": "Bearer \(testToken)", "Content-Type": "application/json"]
        if let surfaceID { headers["X-Calyx-Surface-ID"] = surfaceID.uuidString }
        return HTTPRequest(
            method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: object))
    }

    /// The tool result's text and error flag from a tools/call envelope.
    private func toolText(_ body: Data?) throws -> (text: String, isError: Bool) {
        let data = try XCTUnwrap(body, "response body must not be nil")
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], "missing result: \(envelope)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    private func panes(_ text: String) throws -> [String: [String: Any]] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
        return try XCTUnwrap(object["panes"] as? [String: [String: Any]], "panes must be keyed by surface_id: \(text)")
    }

    private func registerPeer(name: String) async throws -> UUID {
        let response = await server.route(request: try mcpToolCall("register_peer", arguments: ["name": name, "role": "terminal"]))
        XCTAssertEqual(response.statusCode, 200)
        let (text, _) = try toolText(response.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["peerId"] as? String)))
    }

    // MARK: - is_self from the request's surface header

    func test_agentStatus_isSelf_followsTheRequestsSurfaceHeader() async throws {
        let caller = pane()
        let other = pane()
        let access = AgentStatusServerFakeCockpitAccess()
        access.panes = [caller, other]
        server.cockpitAccess = access

        let response = await server.route(
            request: try mcpToolCall("agent_status", arguments: ["include_git": false], surfaceID: caller.surfaceID)
        )

        XCTAssertEqual(response.statusCode, 200)
        let (text, isError) = try toolText(response.body)
        XCTAssertFalse(isError, "agent_status must succeed; got: \(text)")
        let result = try panes(text)
        XCTAssertEqual(result[caller.surfaceID.uuidString]?["is_self"] as? Bool, true)
        XCTAssertEqual(result[other.surfaceID.uuidString]?["is_self"] as? Bool, false)
    }

    func test_agentStatus_withoutSurfaceHeader_noPaneIsSelf() async throws {
        let access = AgentStatusServerFakeCockpitAccess()
        access.panes = [pane(), pane()]
        server.cockpitAccess = access

        let response = await server.route(request: try mcpToolCall("agent_status", arguments: ["include_git": false]))

        let (text, isError) = try toolText(response.body)
        XCTAssertFalse(isError, "agent_status must succeed; got: \(text)")
        let result = try panes(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.values.compactMap { $0["is_self"] as? Bool }, [false, false])
    }

    // MARK: - Live unread counts, and no inbox sync

    func test_agentStatus_readsUnreadFromStore_andDoesNotSyncAgentRowUnreadCount() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let boundSurface = UUID()
        let access = AgentStatusServerFakeCockpitAccess()
        access.panes = [pane(surfaceID: boundSurface)]
        server.cockpitAccess = access

        let p1 = try await registerPeer(name: "P1")
        let p2 = try await registerPeer(name: "P2")
        // A hook event carrying the pane's own peer id binds the surface
        // and creates its row (as in CalyxMCPServerCockpitToolsTests).
        let binding = HTTPRequest(
            method: "POST", path: "/agent-event",
            headers: ["Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": boundSurface.uuidString],
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__send_message",
             "tool_input":{"from":"\(p1.uuidString)","to":"\(p2.uuidString)","content":"hi"}}
            """.utf8)
        )
        let bindingResponse = await server.route(request: binding)
        XCTAssertEqual(bindingResponse.statusCode, 204)
        XCTAssertEqual(registry.boundPeerID(for: boundSurface), p1, "precondition: the surface is bound to P1")
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0, "precondition")

        // Delivered straight into the store: no tool call, so no sync.
        _ = try await server.store.sendMessage(from: p2, to: p1, content: "hello from P2")

        let response = await server.route(
            request: try mcpToolCall("agent_status", arguments: ["include_git": false], id: 10)
        )

        XCTAssertEqual(response.statusCode, 200)
        let (text, isError) = try toolText(response.body)
        XCTAssertFalse(isError, "agent_status must succeed; got: \(text)")
        let dict = try XCTUnwrap(try panes(text)[boundSurface.uuidString])
        XCTAssertEqual(dict["peer_id"] as? String, p1.uuidString)
        XCTAssertEqual(dict["unread_count"] as? Int, 1,
                       "unread_count must be read live from the server's IPCStore")
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "agent_status is not in inboxSyncToolNames, so the row's cached count stays stale")
    }
}
