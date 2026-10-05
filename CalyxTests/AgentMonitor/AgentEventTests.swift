//
//  AgentEventTests.swift
//  CalyxTests
//
//  Covers AgentEvent.decode(from:): Claude Code hook stdin JSON
//  (snake_case) decoding for each hook_event_name Calyx observes.
//
//  Coverage:
//  - Real stdin JSON for each observed hook_event_name
//  - hook_event_name is mandatory; its absence rejects the payload
//  - Unknown/extra fields are tolerated
//  - Optional fields (session_id / cwd / message) may be entirely absent
//  - Malformed JSON is rejected
//  - toolSummary: the tool-specific string derived from tool_input
//    (Bash's command, Write's file_path, WebFetch's url), tool_input's
//    own arguments as sorted `key: value` pairs for any other tool, nil
//    when there is no tool_input object or the derived string is empty,
//    collapsed to a single line and capped at
//    AgentToolSummary.maxSummaryLength visible characters
//  - A pair list cut by the cap never ends on a dangling separator
//  - A structured value cut by the cap never ends on a dangling
//    element separator, in an array and in an object alike
//

import XCTest
@testable import Calyx

final class AgentEventTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Per-event decoding

    func test_decode_sessionStart_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "transcript_path": "/Users/dev/.claude/projects/x/abc-123.jsonl",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionStart",
            "source": "startup"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
    }

    func test_decode_userPromptSubmit_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "fix the bug"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
    }

    func test_decode_preToolUse_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_postToolUse_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_response": {"stdout": "ok"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "PostToolUse")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_notification_populatesMessage() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "Notification")
        XCTAssertEqual(event.message, "Claude needs your permission to use Bash")
    }

    func test_decode_stop_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "Stop",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "Stop")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_sessionEnd_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionEnd",
            "reason": "exit"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionEnd")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_sessionEnd_codexMinimalRequiredPayload_populatesFieldsAndToleratesUnmodelledFields() throws {
        // Codex 0.148.0's embedded schema for session-end.command.input
        // requires exactly: cwd, hook_event_name, reason, session_id,
        // transcript_path, with additionalProperties: false and reason
        // fixed to the const "other". This payload carries only those
        // five fields, the minimal one the schema allows Codex to send.
        let data = json("""
        {
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionEnd",
            "reason": "other",
            "session_id": "codex-session-1",
            "transcript_path": "/Users/dev/.codex/sessions/codex-session-1.jsonl"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionEnd")
        XCTAssertEqual(event.sessionID, "codex-session-1")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
    }

    func test_decode_subagentStop_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStop",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStop")
    }

    // MARK: - Rejection / tolerance

    func test_decode_missingHookEventName_returnsNil() {
        // Sanity: a well-formed payload for the same fields must decode,
        // proving the rejection below is caused by the missing key and not
        // some other defect.
        let validData = json("""
        { "session_id": "abc-123", "cwd": "/Users/dev/repo", "hook_event_name": "UserPromptSubmit" }
        """)
        XCTAssertNotNil(AgentEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "session_id": "abc-123", "cwd": "/Users/dev/repo" }
        """)
        XCTAssertNil(AgentEvent.decode(from: data), "hook_event_name is mandatory")
    }

    func test_decode_extraFields_areTolerated() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "UserPromptSubmit",
            "an_unknown_future_field": {"nested": [1, 2, 3]},
            "another_unknown_field": true
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
    }

    func test_decode_missingOptionalFields_stillDecodes() throws {
        let data = json("""
        { "hook_event_name": "SessionStart" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
        XCTAssertNil(event.message)
    }

    func test_decode_malformedJSON_returnsNil() {
        // Sanity: a well-formed payload must decode, proving the rejection
        // below is caused by the malformed JSON and not some other defect.
        let validData = json("""
        { "hook_event_name": "Stop" }
        """)
        XCTAssertNotNil(AgentEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("this is not { json")
        XCTAssertNil(AgentEvent.decode(from: data))
    }

    // MARK: - displayName(forKind:) — Phase 2 (Codex / OpenCode)

    func test_displayName_codexKind_returnsCodex() {
        XCTAssertEqual(AgentEntry.displayName(forKind: "codex"), "Codex")
    }

    func test_displayName_openCodeKind_returnsOpenCode() {
        XCTAssertEqual(AgentEntry.displayName(forKind: "opencode"), "OpenCode")
    }

    func test_displayName_hermesKind_returnsHermesAgent() {
        XCTAssertEqual(AgentEntry.displayName(forKind: "hermes"), "Hermes Agent")
    }

    func test_displayName_grokKind_returnsGrok() {
        XCTAssertEqual(AgentEntry.displayName(forKind: AgentEntry.grokKind), "Grok",
                       "The sidebar row's secondary line shows the product name, not the wire kind")
        XCTAssertEqual(AgentEntry.grokKind, "grok",
                       "The kind constant is the literal Calyx writes into Grok's hook command argument " +
                       "and X-Calyx-Agent-Kind header, so its value is part of the wire contract")
    }

    func test_displayName_piKind_returnsPi() {
        XCTAssertEqual(AgentEntry.piKind, "pi",
                       "The kind constant must equal the literal PiExtensionManager.scriptBody sends in " +
                       "its X-Calyx-Agent-Kind header. The header value is a TypeScript string inside a " +
                       "Swift string, so nothing but this assertion keeps the two ends of the wire " +
                       "contract in agreement")
        XCTAssertEqual(AgentEntry.displayName(forKind: AgentEntry.piKind), "pi",
                       "pi's product name is lowercase, so the sidebar row shows the kind verbatim")
    }

    // MARK: - ipcSelfPeerID extraction (unread message badges)
    //
    // A PreToolUse for one of Calyx's own mcp__calyx-ipc__* tools carries
    // this surface's own peer ID in tool_input — AgentRegistry uses it to
    // learn the surface-to-peer binding that drives unread badges.

    func test_decode_preToolUse_sendMessage_extractsIpcSelfPeerIDFromFrom() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__send_message",
            "tool_input": {
                "from": "11111111-1111-1111-1111-111111111111",
                "to": "22222222-2222-2222-2222-222222222222",
                "content": "hi"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "11111111-1111-1111-1111-111111111111",
                       "PreToolUse for send_message must extract the sender's own peer ID from tool_input.from")
    }

    func test_decode_preToolUse_broadcast_extractsIpcSelfPeerIDFromFrom() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__broadcast",
            "tool_input": {
                "from": "33333333-3333-3333-3333-333333333333",
                "content": "announcement"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "33333333-3333-3333-3333-333333333333",
                       "PreToolUse for broadcast must extract the sender's own peer ID from tool_input.from")
    }

    func test_decode_preToolUse_receiveMessages_extractsIpcSelfPeerIDFromPeerID() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__receive_messages",
            "tool_input": {
                "peer_id": "44444444-4444-4444-4444-444444444444"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "44444444-4444-4444-4444-444444444444",
                       "PreToolUse for receive_messages must extract this surface's own peer ID from tool_input.peer_id")
    }

    // test_decode_preToolUse_ackMessages_extractsIpcSelfPeerIDFromPeerID
    // removed: ack_messages was removed as an MCP tool, so it's
    // no longer one of the tool names AgentEvent extracts a self peer ID
    // for either.

    // MARK: - Subagent fields (agent_id / agent_type / tool_name)
    //
    // agent_id is the only subagent predicate in the codebase
    // (isSubagentEvent == (agentID != nil)): agent_type alone also
    // appears on a main-thread event when the session was started with
    // `claude --agent foo`, so it must never be read as "this is a
    // subagent event" on its own.

    func test_decode_claudeCodeSubagentStart_populatesAgentIDAndAgentType() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStart",
            "agent_id": "sub-001",
            "agent_type": "general-purpose"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStart")
        XCTAssertEqual(event.agentID, "sub-001")
        XCTAssertEqual(event.agentType, "general-purpose")
        XCTAssertTrue(event.isSubagentEvent, "A SubagentStart event with agent_id must be a subagent event")
    }

    func test_decode_claudeCodeSubagentStop_populatesAgentIDAndAgentType() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStop",
            "agent_id": "sub-001",
            "agent_type": "general-purpose",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStop")
        XCTAssertEqual(event.agentID, "sub-001")
        XCTAssertEqual(event.agentType, "general-purpose")
        XCTAssertTrue(event.isSubagentEvent)
    }

    // Codex's subagent hooks reuse the PARENT session's own session_id
    // (per Codex's own docs), and carry turn_id / agent_transcript_path /
    // last_assistant_message / stop_hook_active -- none of which
    // AgentEvent models, so this also pins that they're tolerated rather
    // than rejected.
    func test_decode_codexSubagentStart_populatesAgentIDAndAgentType_toleratesUnmodelledFields() throws {
        let data = json("""
        {
            "session_id": "codex-parent-session",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStart",
            "agent_id": "sub-777",
            "agent_type": "reviewer",
            "turn_id": "turn-42",
            "agent_transcript_path": "/Users/dev/.codex/sessions/sub-777.jsonl"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStart")
        XCTAssertEqual(event.agentID, "sub-777")
        XCTAssertEqual(event.agentType, "reviewer")
        XCTAssertTrue(event.isSubagentEvent)
    }

    func test_decode_codexSubagentStop_populatesAgentIDAndAgentType_toleratesUnmodelledFields() throws {
        let data = json("""
        {
            "session_id": "codex-parent-session",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStop",
            "agent_id": "sub-777",
            "agent_type": "reviewer",
            "turn_id": "turn-42",
            "agent_transcript_path": "/Users/dev/.codex/sessions/sub-777.jsonl",
            "last_assistant_message": "Done reviewing the diff.",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStop")
        XCTAssertEqual(event.agentID, "sub-777")
        XCTAssertEqual(event.agentType, "reviewer")
        XCTAssertTrue(event.isSubagentEvent)
    }

    func test_decode_minimalPayload_hookEventNameAndAgentIDOnly_decodesAsSubagentEvent() throws {
        let data = json("""
        { "hook_event_name": "PreToolUse", "agent_id": "sub-1" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.agentID, "sub-1")
        XCTAssertTrue(event.isSubagentEvent, "agent_id alone, with every other field absent, must still decode as a subagent event")
    }

    // agent_type ALSO appears on a main-thread event when the session was
    // started with `claude --agent foo`, WITHOUT agent_id. Reading
    // agent_type alone as "this is a subagent" would kill that session's
    // parent row permanently, so isSubagentEvent must stay false here.
    func test_decode_agentTypeWithoutAgentID_isNotASubagentEvent() throws {
        let data = json("""
        {
            "session_id": "main-session",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "UserPromptSubmit",
            "agent_type": "reviewer"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.agentType, "reviewer")
        XCTAssertNil(event.agentID)
        XCTAssertFalse(event.isSubagentEvent,
                       "agent_type alone (no agent_id) is a claude --agent main-thread session, not a subagent")
    }

    func test_decode_neitherAgentIDNorAgentType_isNotASubagentEvent() throws {
        let data = json("""
        { "session_id": "main-session", "cwd": "/Users/dev/repo", "hook_event_name": "UserPromptSubmit" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertNil(event.agentID)
        XCTAssertNil(event.agentType)
        XCTAssertFalse(event.isSubagentEvent)
    }

    func test_decode_toolName_mapsToToolNameProperty() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolName, "Bash")
    }

    func test_decode_toolName_absentDecodesAsNil() throws {
        let data = json("""
        { "session_id": "abc-123", "hook_event_name": "Stop" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertNil(event.toolName)
    }

    func test_decode_preToolUse_nonCalyxIPCToolAndMissingToolInput_ipcSelfPeerIDIsNil() throws {
        // Sanity: a calyx-ipc send_message PreToolUse must actually
        // extract a peer ID — otherwise the nil assertions below would be
        // indistinguishable from a decoder that never populates
        // ipcSelfPeerID at all.
        let calyxData = json("""
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__send_message",
            "tool_input": {"from": "66666666-6666-6666-6666-666666666666", "to": "x", "content": "y"}
        }
        """)
        let calyxEvent = try XCTUnwrap(AgentEvent.decode(from: calyxData))
        XCTAssertEqual(calyxEvent.ipcSelfPeerID, "66666666-6666-6666-6666-666666666666",
                       "Precondition: a calyx-ipc PreToolUse must populate ipcSelfPeerID")

        let bashData = json("""
        { "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"} }
        """)
        let bashEvent = try XCTUnwrap(AgentEvent.decode(from: bashData))
        XCTAssertNil(bashEvent.ipcSelfPeerID,
                    "A non-calyx-ipc tool_name must never populate ipcSelfPeerID, even with an unrelated tool_input")

        let missingInputData = json("""
        { "hook_event_name": "PreToolUse", "tool_name": "mcp__calyx-ipc__send_message" }
        """)
        let missingInputEvent = try XCTUnwrap(AgentEvent.decode(from: missingInputData))
        XCTAssertNil(missingInputEvent.ipcSelfPeerID,
                    "A calyx-ipc tool_name with no tool_input at all must decode ipcSelfPeerID as nil, not crash")
    }

    // MARK: - toolSummary

    func test_decode_bashToolInput_toolSummaryIsTheCommand() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "git status --short"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "git status --short")
    }

    func test_decode_writeToolInput_toolSummaryIsTheFilePath() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Write",
            "tool_input": {"file_path": "/Users/dev/repo/file.swift", "content": "x"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "/Users/dev/repo/file.swift")
    }

    func test_decode_webFetchToolInput_toolSummaryIsTheURL() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "WebFetch",
            "tool_input": {"url": "https://example.com/docs"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "https://example.com/docs")
    }

    /// A tool with no well-known tool_input key of its own shows its
    /// arguments as readable `key: value` pairs, never a raw JSON blob.
    func test_decode_unknownTool_toolSummaryIsReadableArgumentPairs() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "SomeFutureUnknownTool",
            "tool_input": {"pattern": "TODO"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "pattern: TODO")
    }

    /// Keys are sorted, so the same call always reads the same way
    /// regardless of the order the payload spelled them in.
    func test_decode_unknownToolWithSeveralKeys_toolSummaryPairsAreSortedByKey() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Grep",
            "tool_input": {"pattern": "TODO", "glob": "*.swift"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "glob: *.swift, pattern: TODO")
    }

    func test_decode_unknownToolWithNonStringValues_toolSummaryRendersThemNaturally() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Grep",
            "tool_input": {"multiline": true, "head_limit": 20}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "head_limit: 20, multiline: true")
    }

    /// A structured value is rendered as the compact JSON of that one
    /// value -- never of the whole tool_input object around it.
    func test_decode_unknownToolWithStructuredValue_toolSummaryRendersThatValueAsCompactJSON() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "TodoWrite",
            "tool_input": {"todos": [{"status": "pending", "content": "ship it"}], "note": null}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "note: null, todos: [{\"content\":\"ship it\",\"status\":\"pending\"}]")
    }

    /// A tool input built in Swift rather than decoded from JSON carries
    /// native containers in its values, and they render exactly as the
    /// decoded ones do.
    func test_readableArguments_nativeNestedContainers_renderAsCompactJSON() {
        let toolInput: [String: Any] = [
            "todos": [["status": "pending", "content": "ship it"] as [String: Any]] as [Any],
            "note": NSNull()
        ]

        let summary = AgentToolSummary.readableArguments(toolInput)

        XCTAssertEqual(summary, "note: null, todos: [{\"content\":\"ship it\",\"status\":\"pending\"}]")
    }

    /// The pair list stops at the cap, so a value that fills the budget
    /// leaves the keys sorted after it unrendered.
    func test_decode_unknownToolOverCap_toolSummaryStopsMidList() throws {
        let longValue = String(repeating: "a", count: 600)
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "SomeFutureUnknownTool",
            "tool_input": {"alpha": "\(longValue)", "beta": "short"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        let summary = try XCTUnwrap(event.toolSummary)
        XCTAssertEqual(summary.count, AgentToolSummary.maxSummaryLength)
        XCTAssertEqual(summary, "alpha: " + String(repeating: "a", count: AgentToolSummary.maxSummaryLength - 7))
        XCTAssertFalse(summary.contains("beta"), "The budget is spent before the second key is reached")
    }

    func test_decode_emptyToolInputObject_toolSummaryIsNil() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "SomeFutureUnknownTool",
            "tool_input": {}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolName, "SomeFutureUnknownTool", "Precondition: the tool name still decodes")
        XCTAssertNil(event.toolSummary, "An argument-less call has no arguments to show, so the row shows the tool name alone")
    }

    func test_decode_preToolUseWithNoToolInput_toolSummaryIsNil() throws {
        let data = json("""
        { "session_id": "abc-123", "hook_event_name": "PreToolUse", "tool_name": "Bash" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolName, "Bash", "Precondition: the tool name still decodes without a tool_input object")
        XCTAssertNil(event.toolSummary, "No tool_input object at all leaves nothing to derive a summary from")
    }

    func test_decode_emptyDerivedValue_toolSummaryIsNilNotEmptyString() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": ""}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertNil(event.toolSummary, "An empty derived string is nil, never an empty string a row would render as a bare separator")
    }

    func test_decode_toolSummaryOverCap_truncatedToMaxSummaryLength() throws {
        let longCommand = String(repeating: "a", count: 600)
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "\(longCommand)"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary?.count, AgentToolSummary.maxSummaryLength)
        XCTAssertEqual(event.toolSummary, String(longCommand.prefix(AgentToolSummary.maxSummaryLength)))
    }

    func test_decode_nonToolEvent_toolSummaryIsNil() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionStart",
            "source": "startup"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertNil(event.toolSummary)
    }

    /// A heredoc command carries hard line breaks, and the row draws its
    /// tool line as one `.lineLimit(1)` `Text` whose help and
    /// accessibility strings join their fields with newlines, so the
    /// summary is one line: every run of whitespace becomes one space.
    func test_decode_multiLineCommand_toolSummaryIsOneLine() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "cat <<'EOF' > /tmp/x\\nline one\\nline two\\nEOF"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "cat <<'EOF' > /tmp/x line one line two EOF")
    }

    func test_decode_commandWithTabsAndCarriageReturns_toolSummaryCollapsesThemToSingleSpaces() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "\\r\\n\\tgit\\tstatus \\r\\n  --short\\t\\r\\n"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary, "git status --short")
    }

    /// The cap counts characters that survive the collapse, so leading
    /// whitespace and line breaks never spend the budget.
    func test_decode_commandWithLeadingWhitespaceOverCap_toolSummaryHasMaxSummaryLengthVisibleCharacters() throws {
        let command = "\\n   \\n\\t" + String(repeating: "a", count: 600)
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "\(command)"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.toolSummary?.count, AgentToolSummary.maxSummaryLength)
        XCTAssertEqual(event.toolSummary, String(repeating: "a", count: AgentToolSummary.maxSummaryLength))
    }

    /// The pair separator is only written when a character of the pair
    /// behind it still fits, so a list cut by the cap never ends on a
    /// dangling `,` or `, `.
    func test_decode_unknownToolCutInsideSeparator_toolSummaryHasNoDanglingSeparator() throws {
        for firstValueLength in [495, 496] {
            let firstValue = String(repeating: "x", count: firstValueLength)
            let data = json("""
            {
                "session_id": "abc-123",
                "hook_event_name": "PreToolUse",
                "tool_name": "SomeFutureUnknownTool",
                "tool_input": {"a": "\(firstValue)", "b": "yy"}
            }
            """)

            let event = try XCTUnwrap(AgentEvent.decode(from: data))

            let summary = try XCTUnwrap(event.toolSummary)
            XCTAssertEqual(summary, "a: " + firstValue, "first value of \(firstValueLength) characters")
            XCTAssertFalse(summary.hasSuffix(","), "first value of \(firstValueLength) characters")
            XCTAssertFalse(summary.hasSuffix(", "), "first value of \(firstValueLength) characters")
        }
    }

    /// A structured value's element separator follows the same rule: it
    /// is only written when a character of the element behind it still
    /// fits, so an array cut by the cap never ends on a dangling `,`.
    func test_decode_unknownToolArrayCutInsideElementSeparator_toolSummaryHasNoDanglingSeparator() throws {
        let expected = [
            492: "a: [\"" + String(repeating: "x", count: 492) + "\",\"",
            493: "a: [\"" + String(repeating: "x", count: 493) + "\"]"
        ]
        for elementLength in [492, 493] {
            let element = String(repeating: "x", count: elementLength)
            let data = json("""
            {
                "session_id": "abc-123",
                "hook_event_name": "PreToolUse",
                "tool_name": "SomeFutureUnknownTool",
                "tool_input": {"a": ["\(element)", "yy"]}
            }
            """)

            let event = try XCTUnwrap(AgentEvent.decode(from: data))

            let summary = try XCTUnwrap(event.toolSummary)
            XCTAssertEqual(summary, expected[elementLength], "element of \(elementLength) characters")
            XCTAssertEqual(summary.count, AgentToolSummary.maxSummaryLength, "element of \(elementLength) characters")
            XCTAssertFalse(summary.hasSuffix(","), "element of \(elementLength) characters")
        }
    }

    /// The same rule inside an object: the separator between two members
    /// is only written when a character of the member behind it still
    /// fits, so an object cut by the cap never ends on a dangling `,`.
    func test_decode_unknownToolObjectCutInsideMemberSeparator_toolSummaryHasNoDanglingSeparator() throws {
        let expected = [
            487: "a: {\"k1\":\"" + String(repeating: "x", count: 487) + "\",\"",
            488: "a: {\"k1\":\"" + String(repeating: "x", count: 488) + "\"}"
        ]
        for valueLength in [487, 488] {
            let value = String(repeating: "x", count: valueLength)
            let data = json("""
            {
                "session_id": "abc-123",
                "hook_event_name": "PreToolUse",
                "tool_name": "SomeFutureUnknownTool",
                "tool_input": {"a": {"k1": "\(value)", "k2": "yy"}}
            }
            """)

            let event = try XCTUnwrap(AgentEvent.decode(from: data))

            let summary = try XCTUnwrap(event.toolSummary)
            XCTAssertEqual(summary, expected[valueLength], "value of \(valueLength) characters")
            XCTAssertEqual(summary.count, AgentToolSummary.maxSummaryLength, "value of \(valueLength) characters")
            XCTAssertFalse(summary.hasSuffix(","), "value of \(valueLength) characters")
        }
    }
}
