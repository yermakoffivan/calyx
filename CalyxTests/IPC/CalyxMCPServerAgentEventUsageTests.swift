//
//  CalyxMCPServerAgentEventUsageTests.swift
//  CalyxTests
//
//  Pins CalyxMCPServer.usageSink: POST /agent-event hands one
//  UsageActivity to the sink per ACCEPTED (204) event whose resolved
//  agent kind is claude-code and whose payload names both a session id
//  and a transcript path -- subagent events included -- and never for
//  another kind, a rejected request or a payload missing either field.
//  The server does not consult the usage setting; the ledger does.
//  Every path in a payload is synthetic and nothing is read from disk.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerAgentEventUsageTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "test-token-usage"
    private var agentEndpointDir: String!
    /// What the sink received, in call order.
    private var received: [UsageActivity] = []

    private let sessionID = "11111111-2222-3333-4444-555555555555"
    private let transcriptPath =
        "/synthetic/projects/-Users-someone-repo/11111111-2222-3333-4444-555555555555.jsonl"

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        received = []
    }

    override func tearDown() async throws {
        server.usageSink = nil
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        received = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func installSink() {
        server.usageSink = { [weak self] activity in
            self?.received.append(activity)
        }
    }

    /// A Claude-shaped (snake_case) hook payload. A nil field is omitted.
    private func payload(
        event: String = "Stop",
        sessionID: String? = "11111111-2222-3333-4444-555555555555",
        transcriptPath: String? = "/synthetic/projects/-Users-someone-repo/11111111-2222-3333-4444-555555555555.jsonl",
        agentID: String? = nil,
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = ["hook_event_name": event, "cwd": "/synthetic/repo"]
        if let sessionID { object["session_id"] = sessionID }
        if let transcriptPath { object["transcript_path"] = transcriptPath }
        if let agentID { object["agent_id"] = agentID }
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func request(
        body: Data?, token: String? = "test-token-usage", surfaceID: String? = UUID().uuidString,
        kind: String? = nil
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceID { headers["X-Calyx-Surface-ID"] = surfaceID }
        if let kind { headers["X-Calyx-Agent-Kind"] = kind }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    private func activity(_ event: String = "Stop") -> UsageActivity {
        UsageActivity(sessionID: sessionID, transcriptPath: transcriptPath, hookEventName: event)
    }

    // MARK: - Default

    func test_usageSink_isNilByDefault_andAnEventIsStillAccepted() async throws {
        XCTAssertNil(server.usageSink)

        let response = await server.route(request: request(body: try payload()))

        XCTAssertEqual(response.statusCode, 204)
    }

    // MARK: - Called

    func test_claudeEventWithoutKindHeader_callsTheSinkOnceWithTheExactActivity() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload()))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [activity("Stop")])
    }

    func test_explicitClaudeCodeKindHeader_callsTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(), kind: "claude-code"))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [activity("Stop")])
    }

    func test_blankKindHeader_resolvesToClaudeCodeAndCallsTheSink() async throws {
        installSink()

        let empty = await server.route(request: request(body: try payload(), kind: ""))
        let blank = await server.route(request: request(body: try payload(), kind: "   "))

        XCTAssertEqual(empty.statusCode, 204)
        XCTAssertEqual(blank.statusCode, 204)
        XCTAssertEqual(received, [activity("Stop"), activity("Stop")])
    }

    func test_everyEventName_isPassedThroughVerbatim_onceEach_inOrder() async throws {
        installSink()
        let names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
                     "SomethingNew"]
        let surface = UUID().uuidString

        for name in names {
            let response = await server.route(request: request(body: try payload(event: name), surfaceID: surface))
            XCTAssertEqual(response.statusCode, 204, name)
        }

        XCTAssertEqual(received, names.map { activity($0) })
    }

    func test_subagentEvent_callsTheSinkWithTheSessionsTranscriptPath() async throws {
        // Outside the `!isSubagentEvent` guard: SubagentStop is one of
        // the ledger's ingest triggers.
        installSink()
        let body = try payload(
            event: "SubagentStop", agentID: "a1b2",
            extra: [
                "agent_type": "Explore",
                "agent_transcript_path":
                    "/synthetic/projects/-Users-someone-repo/\(sessionID)/subagents/agent-a1b2.jsonl",
            ])

        let response = await server.route(request: request(body: body))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [activity("SubagentStop")])
    }

    func test_subagentToolEvent_callsTheSinkToo() async throws {
        installSink()
        let body = try payload(event: "PreToolUse", agentID: "a1b2", extra: ["tool_name": "Read"])

        let response = await server.route(request: request(body: body))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [activity("PreToolUse")])
    }

    func test_emptyTranscriptPath_isStillHandedToTheSink() async throws {
        // Both fields are non-nil; rejecting "" is the locator's job.
        installSink()

        let response = await server.route(request: request(body: try payload(transcriptPath: "")))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [UsageActivity(sessionID: sessionID, transcriptPath: "", hookEventName: "Stop")])
    }

    func test_sinkIsCalledWhateverTheUsageSettingSays() async throws {
        // The server does not read the setting. The ledger does.
        let suite = "com.calyx.tests.CalyxMCPServerAgentEventUsageTests"
        UsageTrackingSettings._testUseSuite(named: suite)
        defer { UsageTrackingSettings._testTeardownSuite(named: suite) }
        XCTAssertFalse(UsageTrackingSettings.enabled, "Fixture error: the setting must be off")
        installSink()

        let response = await server.route(request: request(body: try payload()))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [activity("Stop")])
    }

    func test_theRegistryIsUpdatedBeforeTheSinkRuns() async throws {
        // "At the end of routeAgentEvent": the event's own effects are
        // visible from inside the sink.
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surface = UUID()
        var sessionSeenBySink: String?
        var calls = 0
        server.usageSink = { _ in
            calls += 1
            sessionSeenBySink = registry.entries[surface]?.sessionID
        }

        let response = await server.route(
            request: request(body: try payload(event: "SessionStart"), surfaceID: surface.uuidString))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(sessionSeenBySink, sessionID)
    }

    // MARK: - Not called: missing fields

    func test_missingSessionID_doesNotCallTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(sessionID: nil)))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [])
    }

    func test_missingTranscriptPath_doesNotCallTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(transcriptPath: nil)))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [])
    }

    func test_nonStringTranscriptPath_doesNotCallTheSink() async throws {
        installSink()

        let null = await server.route(request: request(
            body: try payload(transcriptPath: nil, extra: ["transcript_path": NSNull()])))
        let number = await server.route(request: request(
            body: try payload(transcriptPath: nil, extra: ["transcript_path": 42])))

        XCTAssertEqual(null.statusCode, 204)
        XCTAssertEqual(number.statusCode, 204)
        XCTAssertEqual(received, [])
    }

    // MARK: - Not called: other kinds

    func test_everyOtherAgentKind_doesNotCallTheSink() async throws {
        installSink()

        for kind in ["codex", "grok", "opencode", "pi", "hermes", "something-else"] {
            let response = await server.route(request: request(body: try payload(), kind: kind))
            XCTAssertEqual(response.statusCode, 204, kind)
            XCTAssertEqual(received, [], kind)
        }
    }

    func test_codexSubagentStop_doesNotCallTheSink() async throws {
        installSink()
        let body = try payload(event: "SubagentStop", agentID: "sub-777")

        let response = await server.route(request: request(body: body, kind: "codex"))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [])
    }

    func test_grokShapedPayloadWithoutKindHeader_doesNotCallTheSink() async throws {
        // The kind resolves to claude-code here, so what keeps the sink
        // silent is the Grok decoder never reading a transcript path.
        installSink()
        let body = try JSONSerialization.data(withJSONObject: [
            "hookEventName": "stop",
            "reason": "end_turn",
            "sessionId": sessionID,
            "cwd": "/synthetic/repo",
            "transcriptPath": transcriptPath,
            "transcript_path": transcriptPath,
        ])

        let response = await server.route(request: request(body: body))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(received, [])
    }

    // MARK: - Not called: rejected requests

    func test_wrongToken_returns401AndDoesNotCallTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(), token: "wrong-token"))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(received, [])
    }

    func test_missingToken_returns401AndDoesNotCallTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(), token: nil))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(received, [])
    }

    func test_missingSurfaceHeader_returns400AndDoesNotCallTheSink() async throws {
        installSink()

        let response = await server.route(request: request(body: try payload(), surfaceID: nil))

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(received, [])
    }

    func test_missingBody_returns400AndDoesNotCallTheSink() async {
        installSink()

        let response = await server.route(request: request(body: nil))

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(received, [])
    }

    func test_undecodablePayload_returns400AndDoesNotCallTheSink() async throws {
        installSink()
        // Valid JSON naming both fields but no hook_event_name.
        let body = try JSONSerialization.data(withJSONObject: [
            "session_id": sessionID, "transcript_path": transcriptPath,
        ])

        let response = await server.route(request: request(body: body))

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(received, [])
    }
}
