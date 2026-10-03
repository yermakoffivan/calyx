//
//  CalyxMCPServerUsageToolsTests.swift
//  CalyxTests
//
//  Pins the usage_* tool surface of CalyxMCPServer and MCPRouter:
//
//  - `usage_report` is always listed (tools/list, `allTools`, after the
//    Cockpit tools), and `isUsageTool` is exactly the `usage_` prefix.
//  - A `tools/call` through `route(request:)` reaches the injected
//    `usageBridge` with the request's surface, and comes back as a
//    success envelope with the bridge's text, or as a tool error with
//    the thrown error's text (tracking off, a store failure, which is
//    not retried).
//  - Without a bridge the call is the "not available" tool error.
//  - Both instruction variants of `initialize` carry a paragraph about
//    the usage_* tools.
//
//  The bridge is built over stub closures; nothing here touches a store,
//  a file under the home directory or the shared registry.
//

import os
import XCTest
@testable import Calyx

/// What the stub closures saw, and what they answer.
private final class UsageBridgeProbe: Sendable {
    private struct State: Sendable {
        var enabled = true
        var reportCalls: [[UsageQuery]] = []
        var surfacesAsked: [UUID] = []
        var sessions: [UUID: String] = [:]
        var failure: (any Error & Sendable)?
        var rows: [UsageRow] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var enabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    var reportCalls: [[UsageQuery]] { state.withLock { $0.reportCalls } }
    var surfacesAsked: [UUID] { state.withLock { $0.surfacesAsked } }

    func setSession(_ sessionID: String, for surfaceID: UUID) { state.withLock { $0.sessions[surfaceID] = sessionID } }
    func fail(with error: any Error & Sendable) { state.withLock { $0.failure = error } }
    func answerRows(_ rows: [UsageRow]) { state.withLock { $0.rows = rows } }

    func reports(_ queries: [UsageQuery]) throws -> [[UsageRow]] {
        let (failure, rows) = state.withLock { state in
            state.reportCalls.append(queries)
            return (state.failure, state.rows)
        }
        if let failure { throw failure }
        return queries.map { _ in rows }
    }

    func session(for surfaceID: UUID) -> String? {
        state.withLock { state in
            state.surfacesAsked.append(surfaceID)
            return state.sessions[surfaceID]
        }
    }
}

@MainActor
final class CalyxMCPServerUsageToolsTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var probe: UsageBridgeProbe!
    private var agentEndpointDir: String!
    private let testToken = "test-token-usage-tools"

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalyxMCPServerUsageToolsTests-\(UUID().uuidString)").path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        probe = UsageBridgeProbe()
    }

    override func tearDown() async throws {
        server?.usageBridge = nil
        server?.stop()
        server = nil
        probe = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func installBridge() {
        let probe = self.probe!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        server.usageBridge = MCPUsageBridge(
            isEnabled: { probe.enabled },
            reports: { queries, _ in try probe.reports(queries) },
            currentSessionID: { probe.session(for: $0) },
            // 2026-10-02T10:27:29.765Z
            now: { Date(timeIntervalSince1970: 1_790_936_849.765) },
            calendar: { utc })
    }

    private func mcpRequest(
        method: String, params: [String: Any]? = nil, surfaceID: UUID? = nil
    ) throws -> HTTPRequest {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method]
        if let params { object["params"] = params }
        var headers = ["Authorization": "Bearer \(testToken)", "Content-Type": "application/json"]
        if let surfaceID { headers["X-Calyx-Surface-ID"] = surfaceID.uuidString }
        return HTTPRequest(
            method: "POST", path: "/mcp", headers: headers, body: try JSONSerialization.data(withJSONObject: object))
    }

    /// Routes a `usage_report` call and returns its envelope.
    private func callUsageReport(
        _ arguments: [String: Any], surfaceID: UUID? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (text: String, isError: Bool) {
        let response = await server.route(
            request: try mcpRequest(
                method: "tools/call", params: ["name": "usage_report", "arguments": arguments], surfaceID: surfaceID))
        XCTAssertEqual(response.statusCode, 200, file: file, line: line)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(response.body, file: file, line: line))
                as? [String: Any], file: file, line: line)
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)", file: file, line: line)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(content.count, 1, file: file, line: line)
        let text = try XCTUnwrap(content.first?["text"] as? String, file: file, line: line)
        return (text, try XCTUnwrap(result["isError"] as? Bool, file: file, line: line))
    }

    private func toolNames(_ body: Data?) throws -> [String] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    // MARK: - Catalogue

    func test_usageTools_isTheBridgesCatalogue() {
        XCTAssertEqual(MCPRouter.usageTools.map(\.name), ["usage_report"])
        XCTAssertEqual(MCPRouter.usageTools.map(\.name), MCPUsageBridge.tools.map(\.name))
    }

    func test_allTools_endsWithTheUsageTools_afterEveryOtherSurface() {
        let expected = MCPRouter.tools + MCPRouter.lspTools + MCPRouter.terminalTools + MCPRouter.cockpitTools
            + MCPRouter.usageTools

        XCTAssertEqual(MCPRouter.allTools.map(\.name), expected.map(\.name))
        XCTAssertEqual(MCPRouter.allTools.filter { $0.name == "usage_report" }.count, 1)
    }

    func test_isUsageTool_isExactlyTheUsagePrefix() {
        XCTAssertTrue(MCPRouter.isUsageTool(name: "usage_report"))
        XCTAssertTrue(MCPRouter.isUsageTool(name: "usage_anything"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "usage"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "Usage_report"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "my_usage_report"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "lsp_usage_report"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "terminal_list_commands"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "pane_list"))
        XCTAssertFalse(MCPRouter.isUsageTool(name: "list_peers"))
    }

    // Listed whether or not a bridge is installed: the tool fails at call
    // time instead of disappearing.
    func test_toolsList_listsUsageReport_withAndWithoutABridge() async throws {
        let without = await server.route(request: try mcpRequest(method: "tools/list"))
        installBridge()
        let with = await server.route(request: try mcpRequest(method: "tools/list"))

        for response in [without, with] {
            XCTAssertEqual(response.statusCode, 200)
            let names = try toolNames(response.body)
            XCTAssertEqual(names.filter { $0 == "usage_report" }.count, 1)
            XCTAssertEqual(names.count, 86)
        }
    }

    // MARK: - Instructions

    private func usageParagraphs(_ instructions: String) -> [String] {
        instructions.components(separatedBy: "\n\n").filter { $0.contains("usage_report") }
    }

    func test_instructions_bothInitializeVariants_carryOneUsageParagraph() throws {
        let plain = try XCTUnwrap(
            MCPRouter.buildInitializeResponse(id: .int(1)).result.flatMap(Self.instructions))
        let registered = try XCTUnwrap(
            MCPRouter.buildInitializeResponse(id: .int(1), peerID: UUID()).result.flatMap(Self.instructions))

        XCTAssertEqual(usageParagraphs(plain).count, 1, plain)
        XCTAssertEqual(usageParagraphs(registered).count, 1, registered)
        XCTAssertEqual(usageParagraphs(plain), usageParagraphs(registered))
        XCTAssertEqual(usageParagraphs(MCPRouter.instructions).count, 1)
        // The paragraph is about the usage_* surface as a whole.
        XCTAssertTrue(usageParagraphs(plain).first?.contains("usage_") == true)
    }

    private static func instructions(_ result: AnyCodable) -> String? {
        guard let data = try? JSONEncoder().encode(result),
              let decoded = try? JSONDecoder().decode(CalyxIPCInitializeResult.self, from: data) else { return nil }
        return decoded.instructions
    }

    // MARK: - tools/call

    func test_toolsCall_reachesTheBridge_withTheRequestsSurface_andReturnsItsText() async throws {
        installBridge()
        let pane = UUID()
        probe.setSession("session-of-pane", for: pane)
        probe.answerRows([UsageRow(
            key: ["claude-opus-5-5"], responses: 4, finalResponses: 3, inputTokens: 12, cacheReadTokens: 360_000,
            cacheCreationTokens: 4_800, cacheCreation1hTokens: 4_000, outputTokensFinal: 1_260,
            thinkingTokensFinal: 450, lastTimestampMs: 1_790_936_849_765)])

        let (text, isError) = try await callUsageReport(
            ["session_id": "current", "group_by": ["model"]], surfaceID: pane)

        XCTAssertFalse(isError, text)
        XCTAssertEqual(probe.surfacesAsked, [pane])
        XCTAssertEqual(probe.reportCalls, [[
            UsageQuery(groupBy: [.model], sessionID: "session-of-pane"),
            UsageQuery(groupBy: [], sessionID: "session-of-pane"),
        ]])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows.first?["key"] as? [String: Any])?["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual((rows.first?["output_tokens_final"] as? NSNumber)?.int64Value, 1_260)
        XCTAssertEqual(((object["totals"] as? [String: Any])?["responses"] as? NSNumber)?.int64Value, 4)
    }

    func test_toolsCall_withoutASurfaceHeader_currentIsAToolError() async throws {
        installBridge()

        let (text, isError) = try await callUsageReport(["session_id": "current"])

        XCTAssertTrue(isError)
        XCTAssertEqual(text, "No agent session is known for the calling pane.")
        XCTAssertEqual(probe.surfacesAsked, [])
        XCTAssertEqual(probe.reportCalls.count, 0)
    }

    func test_toolsCall_trackingOff_isAToolErrorWithItsText() async throws {
        installBridge()
        probe.enabled = false

        let (text, isError) = try await callUsageReport([:])

        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
        XCTAssertEqual(probe.reportCalls.count, 0)
    }

    func test_toolsCall_invalidArgument_isAToolErrorWithTheErrorsText() async throws {
        installBridge()

        let (text, isError) = try await callUsageReport(["limit": 0])

        XCTAssertTrue(isError)
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(probe.reportCalls.count, 0)
    }

    func test_toolsCall_storeError_isAToolErrorWithItsDescription_andIsNotRetried() async throws {
        installBridge()
        probe.fail(with: UsageStoreError.closed)

        let (text, isError) = try await callUsageReport([:])

        XCTAssertTrue(isError)
        XCTAssertEqual(text, "The usage database is closed.")
        XCTAssertEqual(probe.reportCalls.count, 1)
    }

    // SQLite's own message for a call can quote a name or a path; the
    // agent gets the result code and the library's fixed text for it.
    func test_toolsCall_sqliteError_isAToolErrorWithTheCodeAndItsFixedText() async throws {
        installBridge()
        probe.fail(with: SQLiteError(code: 5, message: "unable to open /synthetic/path/usage.sqlite"))

        let (text, isError) = try await callUsageReport([:])

        XCTAssertTrue(isError)
        XCTAssertEqual(text, "The usage database reported SQLite error 5 (database is locked).")
        XCTAssertFalse(text.contains("/"), text)
    }

    func test_toolsCall_withoutABridge_isTheNotAvailableToolError() async throws {
        XCTAssertNil(server.usageBridge, "a new server has no usage bridge")

        let (text, isError) = try await callUsageReport([:])

        XCTAssertTrue(isError)
        XCTAssertEqual(text, "Usage tracking is not available.")
    }

    // A usage_ name the bridge does not know still goes to the bridge,
    // whose own error names it; without a bridge it is "not available".
    func test_toolsCall_unknownUsageName_isRoutedToTheBridge() async throws {
        let request = try mcpRequest(method: "tools/call", params: ["name": "usage_other", "arguments": [:]])
        let withoutBridge = await server.route(request: request)
        installBridge()
        let withBridge = await server.route(request: request)

        let texts = try [withoutBridge, withBridge].map { response -> String in
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
            let result = try XCTUnwrap(json["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true)
            return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        }
        XCTAssertEqual(texts[0], "Usage tracking is not available.")
        XCTAssertEqual(texts[1], MCPUsageBridgeError.unknownTool("usage_other").localizedDescription)
    }
}
