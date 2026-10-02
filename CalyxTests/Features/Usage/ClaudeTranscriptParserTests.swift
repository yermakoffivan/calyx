//
//  ClaudeTranscriptParserTests.swift
//  CalyxTests
//
//  Pins ClaudeTranscriptParser.records(fromLine:), which turns ONE line of
//  Claude Code's transcript JSONL into numeric usage records: only a
//  top-level "assistant" object yields records, an advisor iteration
//  becomes its own "<message.id>#adv<i>" record, transcript-derived labels
//  are length- and character-limited, and nothing ever throws.
//
//  Every fixture is synthetic. No fixture contains real conversation text.
//

import XCTest
@testable import Calyx

final class ClaudeTranscriptParserTests: XCTestCase {

    // MARK: - Fixture constants

    private let sessionID = "11111111-2222-3333-4444-555555555555"
    /// 2026-10-02T10:27:29.765Z as UTC epoch milliseconds (computed by hand,
    /// outside the code under test).
    private let timestampMs: Int64 = 1_790_936_849_765
    /// 2026-10-02T10:27:29Z as UTC epoch milliseconds.
    private let timestampMsWholeSecond: Int64 = 1_790_936_849_000

    // MARK: - Fixture builders

    private func baseUsage() -> [String: Any] {
        [
            "input_tokens": 3,
            "output_tokens": 420,
            "cache_read_input_tokens": 90_000,
            "cache_creation_input_tokens": 1_200,
            "cache_creation": ["ephemeral_1h_input_tokens": 1_000, "ephemeral_5m_input_tokens": 200],
            "output_tokens_details": ["thinking_tokens": 150],
            "iterations": [
                [
                    "type": "message", "input_tokens": 3, "output_tokens": 420,
                    "cache_read_input_tokens": 90_000, "cache_creation_input_tokens": 1_200,
                ] as [String: Any],
            ],
            "speed": "standard",
        ]
    }

    private func baseMessage() -> [String: Any] {
        [
            "id": "msg_01ABC",
            "model": "claude-opus-5-5",
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "x"]],
            "usage": baseUsage(),
        ]
    }

    private func baseTop() -> [String: Any] {
        [
            "type": "assistant",
            "sessionId": sessionID,
            "timestamp": "2026-10-02T10:27:29.765Z",
            "cwd": "/tmp/project",
            "gitBranch": "main",
            "version": "2.1.283",
            "effort": "high",
            "perTurnEffort": "high",
            "isSidechain": false,
            "message": baseMessage(),
        ]
    }

    private func encode(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    /// Applies overrides to a dictionary: an inner `nil` REMOVES the key,
    /// `NSNull()` sets JSON null, anything else replaces the value.
    private func apply(_ overrides: [String: Any?], to dictionary: inout [String: Any]) {
        for (key, value) in overrides {
            if let value {
                dictionary[key] = value
            } else {
                dictionary.removeValue(forKey: key)
            }
        }
    }

    /// The canonical main-thread final line, with per-level overrides.
    private func line(
        top: [String: Any?] = [:],
        message: [String: Any?] = [:],
        usage: [String: Any?] = [:]
    ) -> Data {
        var usageObject = baseUsage()
        apply(usage, to: &usageObject)
        var messageObject = baseMessage()
        messageObject["usage"] = usageObject
        apply(message, to: &messageObject)
        var topObject = baseTop()
        topObject["message"] = messageObject
        apply(top, to: &topObject)
        return encode(topObject)
    }

    /// A raw-text line so the exact JSON number spelling (12.0, -5, "abc")
    /// reaches the parser unchanged.
    private func rawLine(usageJSON: String) -> Data {
        let text = #"{"type":"assistant","sessionId":"11111111-2222-3333-4444-555555555555","#
            + #""timestamp":"2026-10-02T10:27:29.765Z","isSidechain":false,"#
            + #""message":{"id":"msg_01ABC","model":"claude-opus-5-5","stop_reason":"end_turn","#
            + #""usage":"# + usageJSON + "}}"
        return Data(text.utf8)
    }

    private func makeRecord(
        key: String = "msg_01ABC",
        sessionID: String = "11111111-2222-3333-4444-555555555555",
        timestampMs: Int64 = 1_790_936_849_765,
        model: String = "claude-opus-5-5",
        effort: String? = "high",
        thread: UsageRecord.Thread = .main,
        agentID: String? = nil,
        agentType: String? = nil,
        gitBranch: String? = "main",
        cwd: String? = "/tmp/project",
        inputTokens: Int64 = 3,
        outputTokens: Int64 = 420,
        thinkingTokens: Int64 = 150,
        cacheReadTokens: Int64 = 90_000,
        cacheCreationTokens: Int64 = 1_200,
        cacheCreation1hTokens: Int64 = 1_000,
        isFinal: Bool = true
    ) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID,
            timestampMs: timestampMs,
            model: model,
            effort: effort,
            thread: thread,
            agentID: agentID,
            agentType: agentType,
            gitBranch: gitBranch,
            cwd: cwd,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            isFinal: isFinal
        )
    }

    private func advisorIteration(model: Any? = "claude-fable-5-1") -> [String: Any] {
        var iteration: [String: Any] = [
            "type": "advisor_message",
            "input_tokens": 125_008,
            "output_tokens": 10_278,
            "cache_read_input_tokens": 77,
            "cache_creation_input_tokens": 55,
        ]
        if let model { iteration["model"] = model }
        return iteration
    }

    private func messageIteration() -> [String: Any] {
        [
            "type": "message", "input_tokens": 3, "output_tokens": 420,
            "cache_read_input_tokens": 90_000, "cache_creation_input_tokens": 1_200,
        ]
    }

    private func parse(_ data: Data) -> [UsageRecord] {
        ClaudeTranscriptParser.records(fromLine: data)
    }

    // MARK: - Main record: field mapping

    func test_records_mainThreadFinalLine_mapsEveryField() {
        let records = parse(line())

        XCTAssertEqual(records, [
            UsageRecord(
                key: "msg_01ABC",
                sessionID: "11111111-2222-3333-4444-555555555555",
                timestampMs: 1_790_936_849_765,
                model: "claude-opus-5-5",
                effort: "high",
                thread: .main,
                agentID: nil,
                agentType: nil,
                gitBranch: "main",
                cwd: "/tmp/project",
                inputTokens: 3,
                outputTokens: 420,
                thinkingTokens: 150,
                cacheReadTokens: 90_000,
                cacheCreationTokens: 1_200,
                cacheCreation1hTokens: 1_000,
                isFinal: true
            ),
        ])
    }

    func test_records_rawTextLineInTranscriptShape_yieldsOneRecordWithExactTimestamp() {
        let text = #"{"type":"assistant","sessionId":"11111111-2222-3333-4444-555555555555","timestamp":"2026-10-02T10:27:29.765Z","cwd":"/tmp/project","gitBranch":"main","version":"2.1.283","effort":"high","perTurnEffort":"high","isSidechain":false,"message":{"id":"msg_01ABC","model":"claude-opus-5-5","stop_reason":"end_turn","content":[],"usage":{"input_tokens":3,"output_tokens":420,"cache_read_input_tokens":90000,"cache_creation_input_tokens":1200,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":200},"output_tokens_details":{"thinking_tokens":150},"iterations":[{"type":"message","input_tokens":3,"output_tokens":420,"cache_read_input_tokens":90000,"cache_creation_input_tokens":1200}],"speed":"standard"}}}"#

        let records = parse(Data(text.utf8))

        XCTAssertEqual(records, [makeRecord()])
        XCTAssertEqual(records.first?.timestampMs, timestampMs)
    }

    func test_records_timestampWithoutFractionalSeconds_parsesToWholeSecondMillis() {
        let records = parse(line(top: ["timestamp": "2026-10-02T10:27:29Z"]))

        XCTAssertEqual(records, [makeRecord(timestampMs: timestampMsWholeSecond)])
    }

    func test_records_tokenValueBeyondInt32_isKeptExactly() {
        let records = parse(line(usage: ["cache_read_input_tokens": 5_000_000_000]))

        XCTAssertEqual(records, [makeRecord(cacheReadTokens: 5_000_000_000)])
    }

    // MARK: - Effort

    func test_records_effortMissing_fallsBackToPerTurnEffort() {
        let records = parse(line(top: ["effort": nil, "perTurnEffort": "medium"]))

        XCTAssertEqual(records, [makeRecord(effort: "medium")])
    }

    func test_records_effortNull_fallsBackToPerTurnEffort() {
        let records = parse(line(top: ["effort": NSNull(), "perTurnEffort": "medium"]))

        XCTAssertEqual(records, [makeRecord(effort: "medium")])
    }

    func test_records_effortPresent_winsOverPerTurnEffort() {
        let records = parse(line(top: ["effort": "low", "perTurnEffort": "max"]))

        XCTAssertEqual(records, [makeRecord(effort: "low")])
    }

    func test_records_neitherEffortNorPerTurnEffort_effortIsNil() {
        let records = parse(line(top: ["effort": nil, "perTurnEffort": nil]))

        XCTAssertEqual(records, [makeRecord(effort: nil)])
    }

    func test_records_bothEffortKeysNull_effortIsNil() {
        let records = parse(line(top: ["effort": NSNull(), "perTurnEffort": NSNull()]))

        XCTAssertEqual(records, [makeRecord(effort: nil)])
    }

    // MARK: - Lines that yield nothing

    func test_records_nonAssistantTypes_yieldNothing() {
        let types = ["user", "attachment", "system", "queue-operation", "file-history-snapshot", "summary"]

        for type in types {
            XCTAssertEqual(parse(line(top: ["type": type])), [], "type \(type) must yield no records")
        }
    }

    func test_records_typeMissingOrNotAString_yieldsNothing() {
        XCTAssertEqual(parse(line(top: ["type": nil])), [])
        XCTAssertEqual(parse(line(top: ["type": NSNull()])), [])
        XCTAssertEqual(parse(line(top: ["type": 1])), [])
    }

    func test_records_syntheticModel_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["model": "<synthetic>"])), [])
    }

    func test_records_userLineWithNestedAssistantShapedObject_yieldsNothing() {
        // A complete assistant-shaped object sits INSIDE a user line, both
        // as structured JSON and as escaped text.
        let nestedText = String(decoding: line(), as: UTF8.self)
        let userLine: [String: Any] = [
            "type": "user",
            "sessionId": sessionID,
            "timestamp": "2026-10-02T10:27:29.765Z",
            "isSidechain": false,
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "content": nestedText] as [String: Any],
                ],
            ] as [String: Any],
            "toolUseResult": baseTop(),
            "nested": ["type": "assistant", "message": baseMessage()] as [String: Any],
        ]

        XCTAssertEqual(parse(encode(userLine)), [])
    }

    func test_records_userLineCarryingAssistantMessageDirectly_yieldsNothing() {
        // Identical to a valid assistant line except for the top-level type.
        XCTAssertEqual(parse(line(top: ["type": "user"])), [])
    }

    func test_records_malformedJSON_yieldsNothing() {
        let valid = String(decoding: line(), as: UTF8.self)
        let truncated = String(valid.dropLast(5))

        XCTAssertEqual(parse(Data(truncated.utf8)), [])
        XCTAssertEqual(parse(Data(#"{"type":"assistant","#.utf8)), [])
        XCTAssertEqual(parse(Data("not json at all".utf8)), [])
    }

    func test_records_emptyOrInvalidUTF8Data_yieldsNothing() {
        XCTAssertEqual(parse(Data()), [])
        XCTAssertEqual(parse(Data([0xFF, 0xFE, 0xC0, 0x80])), [])
    }

    func test_records_nonObjectJSON_yieldsNothing() {
        XCTAssertEqual(parse(encode([baseTop()])), [], "A top-level array must yield nothing")
        XCTAssertEqual(parse(Data(#""assistant""#.utf8)), [])
        XCTAssertEqual(parse(Data("42".utf8)), [])
        XCTAssertEqual(parse(Data("null".utf8)), [])
        XCTAssertEqual(parse(Data("true".utf8)), [])
    }

    // MARK: - Required fields

    func test_records_messageMissingOrNotAnObject_yieldsNothing() {
        XCTAssertEqual(parse(line(top: ["message": nil])), [])
        XCTAssertEqual(parse(line(top: ["message": NSNull()])), [])
        XCTAssertEqual(parse(line(top: ["message": "msg_01ABC"])), [])
    }

    func test_records_messageIDMissing_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["id": nil])), [])
        XCTAssertEqual(parse(line(message: ["id": NSNull()])), [])
        XCTAssertEqual(parse(line(message: ["id": 7])), [])
    }

    func test_records_modelMissing_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["model": nil])), [])
        XCTAssertEqual(parse(line(message: ["model": NSNull()])), [])
    }

    func test_records_usageMissingOrNotAnObject_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["usage": nil])), [])
        XCTAssertEqual(parse(line(message: ["usage": NSNull()])), [])
        XCTAssertEqual(parse(line(message: ["usage": "420"])), [])
        XCTAssertEqual(parse(line(message: ["usage": [3, 420]])), [])
    }

    func test_records_sessionIDMissing_yieldsNothing() {
        XCTAssertEqual(parse(line(top: ["sessionId": nil])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": NSNull()])), [])
    }

    func test_records_timestampMissingOrUnparsable_yieldsNothing() {
        XCTAssertEqual(parse(line(top: ["timestamp": nil])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": NSNull()])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": "yesterday"])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": ""])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": 1_790_936_849_765])), [])
    }

    // MARK: - isFinal

    func test_records_nullStopReason_isNonFinalWithInputSideTokensIntact() {
        let records = parse(line(message: ["stop_reason": NSNull()], usage: ["output_tokens": 8]))

        XCTAssertEqual(records, [makeRecord(outputTokens: 8, isFinal: false)])
        XCTAssertEqual(records.first?.inputTokens, 3)
        XCTAssertEqual(records.first?.cacheReadTokens, 90_000)
        XCTAssertEqual(records.first?.cacheCreationTokens, 1_200)
        XCTAssertEqual(records.first?.cacheCreation1hTokens, 1_000)
    }

    func test_records_stopReasonMissing_isNonFinal() {
        XCTAssertEqual(parse(line(message: ["stop_reason": nil])), [makeRecord(isFinal: false)])
    }

    func test_records_stopReasonNotAString_isNonFinal() {
        XCTAssertEqual(parse(line(message: ["stop_reason": 5])), [makeRecord(isFinal: false)])
    }

    func test_records_stopReasonToolUse_isFinal() {
        XCTAssertEqual(parse(line(message: ["stop_reason": "tool_use"])), [makeRecord(isFinal: true)])
    }

    // MARK: - Subagent

    func test_records_sidechainLine_mapsSubagentThreadAgentIDAndAgentType() {
        let records = parse(line(top: [
            "isSidechain": true, "agentId": "a1b2c3", "attributionAgent": "swift-specialist",
        ]))

        XCTAssertEqual(records, [
            makeRecord(thread: .subagent, agentID: "a1b2c3", agentType: "swift-specialist"),
        ])
    }

    func test_records_sidechainLineWithNullAttributionAgent_agentTypeIsNil() {
        let records = parse(line(top: [
            "isSidechain": true, "agentId": "a1b2c3", "attributionAgent": NSNull(),
        ]))

        XCTAssertEqual(records, [makeRecord(thread: .subagent, agentID: "a1b2c3", agentType: nil)])
    }

    func test_records_sidechainLineWithoutAgentId_isStillSubagentThread() {
        let records = parse(line(top: ["isSidechain": true]))

        XCTAssertEqual(records, [makeRecord(thread: .subagent, agentID: nil, agentType: nil)])
    }

    func test_records_isSidechainMissing_isMainThread() {
        let records = parse(line(top: ["isSidechain": nil]))

        XCTAssertEqual(records, [makeRecord(thread: .main)])
    }

    func test_records_isSidechainFalseWithAgentId_isMainThreadAndKeepsAgentID() {
        let records = parse(line(top: ["isSidechain": false, "agentId": "a1b2c3"]))

        XCTAssertEqual(records, [makeRecord(thread: .main, agentID: "a1b2c3")])
    }

    // MARK: - Advisor iterations

    func test_records_advisorIterationAtIndex1_emitsSecondRecordWithIndexedKey() {
        let records = parse(line(usage: ["iterations": [messageIteration(), advisorIteration()]]))

        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(makeRecord()), "The main record must be unchanged by the advisor iteration")
        XCTAssertTrue(records.contains(
            UsageRecord(
                key: "msg_01ABC#adv1",
                sessionID: "11111111-2222-3333-4444-555555555555",
                timestampMs: 1_790_936_849_765,
                model: "claude-fable-5-1",
                effort: nil,
                thread: .advisor,
                agentID: nil,
                agentType: nil,
                gitBranch: "main",
                cwd: "/tmp/project",
                inputTokens: 125_008,
                outputTokens: 10_278,
                thinkingTokens: 0,
                cacheReadTokens: 77,
                cacheCreationTokens: 55,
                cacheCreation1hTokens: 0,
                isFinal: true
            )
        ), "Got: \(records)")
    }

    func test_records_advisorIterationWithCacheCreationObject_takes1hTokensFromTheIteration() {
        var advisor = advisorIteration()
        advisor["cache_creation"] = ["ephemeral_1h_input_tokens": 44, "ephemeral_5m_input_tokens": 11]

        let records = parse(line(usage: ["iterations": [messageIteration(), advisor]]))

        let advisorRecord = records.first { $0.thread == .advisor }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(advisorRecord?.key, "msg_01ABC#adv1")
        XCTAssertEqual(advisorRecord?.cacheCreation1hTokens, 44)
        XCTAssertEqual(advisorRecord?.cacheCreationTokens, 55)
        XCTAssertEqual(advisorRecord?.thinkingTokens, 0)
    }

    func test_records_twoAdvisorIterations_keysUseIndexWithinWholeIterationsArray() {
        var secondAdvisor = advisorIteration(model: "claude-fable-5-2")
        secondAdvisor["output_tokens"] = 9

        let records = parse(line(usage: [
            "iterations": [messageIteration(), advisorIteration(), messageIteration(), secondAdvisor],
        ]))

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(records.map(\.key)), ["msg_01ABC", "msg_01ABC#adv1", "msg_01ABC#adv3"])
        let third = records.first { $0.key == "msg_01ABC#adv3" }
        XCTAssertEqual(third?.model, "claude-fable-5-2")
        XCTAssertEqual(third?.outputTokens, 9)
        XCTAssertEqual(third?.thread, .advisor)
    }

    func test_records_advisorIterationOnSubagentLine_sharesSessionAgentBranchAndCwd() {
        let records = parse(line(
            top: ["isSidechain": true, "agentId": "a1b2c3", "attributionAgent": "swift-specialist"],
            usage: ["iterations": [messageIteration(), advisorIteration()]]
        ))

        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains(
            makeRecord(thread: .subagent, agentID: "a1b2c3", agentType: "swift-specialist")))
        XCTAssertTrue(records.contains(
            makeRecord(
                key: "msg_01ABC#adv1", model: "claude-fable-5-1", effort: nil, thread: .advisor,
                agentID: "a1b2c3", agentType: "swift-specialist",
                inputTokens: 125_008, outputTokens: 10_278, thinkingTokens: 0,
                cacheReadTokens: 77, cacheCreationTokens: 55, cacheCreation1hTokens: 0
            )
        ), "Got: \(records)")
    }

    func test_records_advisorIterationOnNonFinalLine_bothRecordsAreNonFinal() {
        let records = parse(line(
            message: ["stop_reason": NSNull()],
            usage: ["iterations": [messageIteration(), advisorIteration()]]
        ))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.key)), ["msg_01ABC", "msg_01ABC#adv1"])
        XCTAssertEqual(records.map(\.isFinal), [false, false])
    }

    func test_records_messageOnlyIterations_emitsOnlyTheMainRecord() {
        let records = parse(line(usage: ["iterations": [messageIteration(), messageIteration()]]))

        XCTAssertEqual(records, [makeRecord()])
    }

    func test_records_iterationsMissingOrNotAnArray_emitsOnlyTheMainRecord() {
        XCTAssertEqual(parse(line(usage: ["iterations": nil])), [makeRecord()])
        XCTAssertEqual(parse(line(usage: ["iterations": NSNull()])), [makeRecord()])
        XCTAssertEqual(parse(line(usage: ["iterations": "advisor_message"])), [makeRecord()])
    }

    func test_records_advisorIterationWithoutValidModel_isSkippedButMainRecordRemains() {
        let invalidModels: [(String, Any?)] = [
            ("missing", nil),
            ("null", NSNull()),
            ("number", 5),
            ("empty", ""),
            ("whitespace", "   "),
            ("newline", "claude\nfable"),
            ("129 chars", String(repeating: "m", count: 129)),
        ]

        for (name, model) in invalidModels {
            let records = parse(line(usage: ["iterations": [messageIteration(), advisorIteration(model: model)]]))
            XCTAssertEqual(records, [makeRecord()], "advisor model \(name)")
        }
    }

    func test_records_advisorTokensAreNotAddedToTheMainRecord() {
        let records = parse(line(usage: ["iterations": [advisorIteration(), messageIteration()]]))

        let main = records.first { $0.key == "msg_01ABC" }
        XCTAssertEqual(main, makeRecord())
        XCTAssertEqual(Set(records.map(\.key)), ["msg_01ABC", "msg_01ABC#adv0"])
    }

    // MARK: - Missing optional parts

    func test_records_missingOptionalUsageSubObjects_tokensAreZero() {
        let records = parse(line(usage: [
            "cache_creation": nil, "output_tokens_details": nil, "iterations": nil,
        ]))

        XCTAssertEqual(records, [makeRecord(thinkingTokens: 0, cacheCreation1hTokens: 0)])
    }

    func test_records_emptyUsageObject_allTokensAreZero() {
        let records = parse(rawLine(usageJSON: "{}"))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 0, outputTokens: 0, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0
            ),
        ])
    }

    func test_records_optionalTopLevelLabelsMissing_areNil() {
        let records = parse(line(top: ["gitBranch": nil, "cwd": nil]))

        XCTAssertEqual(records, [makeRecord(gitBranch: nil, cwd: nil)])
    }

    func test_records_unknownKeysAtEveryLevel_areIgnored() {
        var iteration = messageIteration()
        iteration["futureIterationKey"] = ["a": 1]
        let records = parse(line(
            top: ["futureTopKey": ["x": [1, 2, 3]], "requestId": "req_1", "uuid": "u-1"],
            message: ["futureMessageKey": true, "role": "assistant", "stop_sequence": NSNull()],
            usage: [
                "futureUsageKey": 99,
                "service_tier": "standard",
                "server_tool_use": ["web_search_requests": 4],
                "iterations": [iteration],
            ]
        ))

        XCTAssertEqual(records, [makeRecord()])
    }

    // MARK: - Numeric leniency

    func test_records_integralDoubleTokenValues_areAccepted() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":12.0,"output_tokens":420.0,"cache_read_input_tokens":90000.0,"#
            + #""cache_creation_input_tokens":1200.0,"cache_creation":{"ephemeral_1h_input_tokens":1000.0},"#
            + #""output_tokens_details":{"thinking_tokens":150.0}}"#))

        XCTAssertEqual(records, [makeRecord(effort: nil, gitBranch: nil, cwd: nil, inputTokens: 12)])
    }

    func test_records_negativeTokenValues_becomeZero() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":-5,"output_tokens":-1,"cache_read_input_tokens":-90000,"#
            + #""cache_creation_input_tokens":-2.0,"cache_creation":{"ephemeral_1h_input_tokens":-7},"#
            + #""output_tokens_details":{"thinking_tokens":-3}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 0, outputTokens: 0, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0
            ),
        ])
    }

    func test_records_nonNumericTokenValues_becomeZeroAndOthersSurvive() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":"abc","output_tokens":420,"cache_read_input_tokens":null,"#
            + #""cache_creation_input_tokens":{"n":1},"cache_creation":{"ephemeral_1h_input_tokens":[1000]},"#
            + #""output_tokens_details":{"thinking_tokens":"150"}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 0, outputTokens: 420, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0
            ),
        ])
    }

    func test_records_usageSubObjectsOfWrongType_tokensAreZero() {
        let records = parse(line(usage: ["cache_creation": 1_000, "output_tokens_details": "150"]))

        XCTAssertEqual(records, [makeRecord(thinkingTokens: 0, cacheCreation1hTokens: 0)])
    }

    func test_records_negativeAdvisorTokenValue_becomesZero() {
        var advisor = advisorIteration()
        advisor["input_tokens"] = -4
        advisor["cache_read_input_tokens"] = "77"

        let records = parse(line(usage: ["iterations": [messageIteration(), advisor]]))

        let advisorRecord = records.first { $0.key == "msg_01ABC#adv1" }
        XCTAssertEqual(advisorRecord?.inputTokens, 0)
        XCTAssertEqual(advisorRecord?.cacheReadTokens, 0)
        XCTAssertEqual(advisorRecord?.outputTokens, 10_278)
    }

    // MARK: - Label hygiene: required labels

    func test_records_requiredLabelAtMaxLength128_isAccepted() {
        let id = String(repeating: "k", count: 128)
        let model = String(repeating: "m", count: 128)
        let session = String(repeating: "s", count: 128)

        XCTAssertEqual(parse(line(message: ["id": id])), [makeRecord(key: id)])
        XCTAssertEqual(parse(line(message: ["model": model])), [makeRecord(model: model)])
        XCTAssertEqual(parse(line(top: ["sessionId": session])), [makeRecord(sessionID: session)])
    }

    func test_records_requiredLabelOver128Characters_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["id": String(repeating: "k", count: 129)])), [])
        XCTAssertEqual(parse(line(message: ["model": String(repeating: "m", count: 129)])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": String(repeating: "s", count: 129)])), [])
    }

    func test_records_requiredLabelEmptyOrWhitespaceOnly_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["id": ""])), [])
        XCTAssertEqual(parse(line(message: ["id": "   "])), [])
        XCTAssertEqual(parse(line(message: ["model": ""])), [])
        XCTAssertEqual(parse(line(message: ["model": " \t "])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": ""])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": "  "])), [])
    }

    func test_records_requiredLabelWithControlCharacterOrNewline_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["id": "msg_01\nABC"])), [])
        XCTAssertEqual(parse(line(message: ["id": "msg_01\u{1}ABC"])), [])
        XCTAssertEqual(parse(line(message: ["model": "claude\r\nopus"])), [])
        XCTAssertEqual(parse(line(message: ["model": "claude\u{1B}[31mopus"])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": "session\u{0}id"])), [])
        XCTAssertEqual(parse(line(top: ["sessionId": "session\u{7F}id"])), [])
    }

    // MARK: - Label hygiene: optional labels

    func test_records_optionalLabelAtMaxLength_isKept() {
        let effort = String(repeating: "e", count: 64)
        let agentID = String(repeating: "a", count: 128)
        let agentType = String(repeating: "t", count: 128)
        let branch = String(repeating: "b", count: 255)
        let cwd = "/" + String(repeating: "c", count: 1_023)

        let records = parse(line(top: [
            "effort": effort, "perTurnEffort": nil, "isSidechain": true,
            "agentId": agentID, "attributionAgent": agentType, "gitBranch": branch, "cwd": cwd,
        ]))

        XCTAssertEqual(records, [
            makeRecord(
                effort: effort, thread: .subagent, agentID: agentID, agentType: agentType,
                gitBranch: branch, cwd: cwd
            ),
        ])
    }

    func test_records_optionalLabelOverMaxLength_becomesNil() {
        let records = parse(line(top: [
            "effort": String(repeating: "e", count: 65),
            "perTurnEffort": nil,
            "isSidechain": true,
            "agentId": String(repeating: "a", count: 129),
            "attributionAgent": String(repeating: "t", count: 129),
            "gitBranch": String(repeating: "b", count: 256),
            "cwd": "/" + String(repeating: "c", count: 1_024),
        ]))

        XCTAssertEqual(records, [
            makeRecord(effort: nil, thread: .subagent, agentID: nil, agentType: nil, gitBranch: nil, cwd: nil),
        ])
    }

    func test_records_optionalLabelEmptyOrWhitespaceOnly_becomesNil() {
        let records = parse(line(top: [
            "effort": "", "perTurnEffort": nil, "isSidechain": true,
            "agentId": "  ", "attributionAgent": "", "gitBranch": " \t ", "cwd": "",
        ]))

        XCTAssertEqual(records, [
            makeRecord(effort: nil, thread: .subagent, agentID: nil, agentType: nil, gitBranch: nil, cwd: nil),
        ])
    }

    func test_records_optionalLabelWithControlCharacterOrNewline_becomesNil() {
        let records = parse(line(top: [
            "effort": "hi\ngh", "perTurnEffort": nil, "isSidechain": true,
            "agentId": "a1\u{1}b2", "attributionAgent": "swift\r\nspecialist",
            "gitBranch": "main\u{1B}[0m", "cwd": "/tmp/pro\u{7}ject",
        ]))

        XCTAssertEqual(records, [
            makeRecord(effort: nil, thread: .subagent, agentID: nil, agentType: nil, gitBranch: nil, cwd: nil),
        ])
    }

    func test_records_optionalLabelOfNonStringType_becomesNil() {
        let records = parse(line(top: [
            "effort": 3, "perTurnEffort": nil, "isSidechain": true,
            "agentId": 42, "attributionAgent": ["swift"], "gitBranch": true, "cwd": ["path": "/tmp"],
        ]))

        XCTAssertEqual(records, [
            makeRecord(effort: nil, thread: .subagent, agentID: nil, agentType: nil, gitBranch: nil, cwd: nil),
        ])
    }

    func test_records_invalidOptionalLabel_doesNotDropTheLineOrOtherLabels() {
        let records = parse(line(top: ["gitBranch": "bad\nbranch"]))

        XCTAssertEqual(records, [makeRecord(gitBranch: nil)])
    }

    // MARK: - Pinned decisions

    func test_records_invalidEffortWithValidPerTurnEffort_fallsBackToPerTurnEffort() {
        let withNewline = parse(line(top: ["effort": "hi\ngh", "perTurnEffort": "medium"]))
        let tooLong = parse(line(top: ["effort": String(repeating: "e", count: 65), "perTurnEffort": "medium"]))

        XCTAssertEqual(withNewline, [makeRecord(effort: "medium")])
        XCTAssertEqual(tooLong, [makeRecord(effort: "medium")])
    }

    func test_records_effortAndPerTurnEffortBothInvalid_effortIsNil() {
        let records = parse(line(top: [
            "effort": "hi\ngh", "perTurnEffort": String(repeating: "p", count: 65),
        ]))

        XCTAssertEqual(records, [makeRecord(effort: nil)])
    }

    func test_records_requiredLabelsWithSurroundingWhitespace_areStoredTrimmed() {
        let records = parse(line(
            top: ["sessionId": "  11111111-2222-3333-4444-555555555555\t"],
            message: ["id": "\tmsg_01ABC  ", "model": " claude-opus-5-5 "]
        ))

        XCTAssertEqual(records, [makeRecord()])
    }

    func test_records_optionalLabelsWithSurroundingWhitespace_areStoredTrimmed() {
        let records = parse(line(top: [
            "effort": "  high  ", "perTurnEffort": nil, "isSidechain": true,
            "agentId": " a1b2c3\t", "attributionAgent": "\tswift-specialist ",
            "gitBranch": "  main ", "cwd": " /tmp/project  ",
        ]))

        XCTAssertEqual(records, [
            makeRecord(thread: .subagent, agentID: "a1b2c3", agentType: "swift-specialist"),
        ])
    }

    func test_records_nonIntegralDoubleTokenValue_becomesZero() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":12.5,"output_tokens":420,"cache_read_input_tokens":0.9,"#
            + #""cache_creation_input_tokens":1200,"output_tokens_details":{"thinking_tokens":150.25}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 0, outputTokens: 420, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 1_200, cacheCreation1hTokens: 0
            ),
        ])
    }

    func test_records_booleanTokenValues_becomeZeroNeverOne() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":true,"output_tokens":420,"cache_read_input_tokens":false,"#
            + #""cache_creation_input_tokens":true,"cache_creation":{"ephemeral_1h_input_tokens":true},"#
            + #""output_tokens_details":{"thinking_tokens":true}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 0, outputTokens: 420, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0
            ),
        ])
    }

    func test_records_messageIDOfExactly128CharactersWithAdvisor_emitsBothWithUnshortenedAdvisorKey() {
        let id = String(repeating: "k", count: 128)

        let records = parse(line(
            message: ["id": id],
            usage: ["iterations": [messageIteration(), advisorIteration()]]
        ))

        XCTAssertEqual(records.map(\.key), [id, id + "#adv1"])
        XCTAssertEqual(records.last?.key.count, 133)
        XCTAssertEqual(records.map(\.thread), [.main, .advisor])
    }

    func test_records_mainRecordFirstThenAdvisorRecordsInIterationOrder() {
        var later = advisorIteration(model: "claude-fable-5-2")
        later["output_tokens"] = 9

        let records = parse(line(usage: [
            "iterations": [advisorIteration(), messageIteration(), later],
        ]))

        XCTAssertEqual(records.map(\.key), ["msg_01ABC", "msg_01ABC#adv0", "msg_01ABC#adv2"])
        XCTAssertEqual(records.map(\.model), ["claude-opus-5-5", "claude-fable-5-1", "claude-fable-5-2"])
        XCTAssertEqual(records.map(\.thread), [.main, .advisor, .advisor])
    }

    // MARK: - Regression pins: literal 1 and 0 are numbers, not booleans

    func test_records_literalOneAndZeroTokenValues_areKeptAsOneAndZero() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"#
            + #""cache_creation_input_tokens":1,"cache_creation":{"ephemeral_1h_input_tokens":1},"#
            + #""output_tokens_details":{"thinking_tokens":1}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 1, outputTokens: 1, thinkingTokens: 1,
                cacheReadTokens: 0, cacheCreationTokens: 1, cacheCreation1hTokens: 1
            ),
        ])
    }

    func test_records_advisorIterationLiteralOneAndZeroTokenValues_areKeptAsOneAndZero() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":3,"output_tokens":420,"iterations":["#
            + #"{"type":"message","input_tokens":3,"output_tokens":420},"#
            + #"{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":1,"output_tokens":1,"#
            + #""cache_read_input_tokens":0,"cache_creation_input_tokens":1,"#
            + #""cache_creation":{"ephemeral_1h_input_tokens":1}}]}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 3, outputTokens: 420, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 0, cacheCreation1hTokens: 0
            ),
            makeRecord(
                key: "msg_01ABC#adv1", model: "claude-fable-5-1", effort: nil, thread: .advisor,
                gitBranch: nil, cwd: nil,
                inputTokens: 1, outputTokens: 1, thinkingTokens: 0,
                cacheReadTokens: 0, cacheCreationTokens: 1, cacheCreation1hTokens: 1
            ),
        ])
    }

    func test_records_integralDoubleOnePointZero_isKeptAsOne() {
        let records = parse(rawLine(usageJSON:
            #"{"input_tokens":1.0,"output_tokens":1.0,"cache_read_input_tokens":0.0,"#
            + #""cache_creation_input_tokens":1.0,"cache_creation":{"ephemeral_1h_input_tokens":1.0},"#
            + #""output_tokens_details":{"thinking_tokens":1.0}}"#))

        XCTAssertEqual(records, [
            makeRecord(
                effort: nil, gitBranch: nil, cwd: nil,
                inputTokens: 1, outputTokens: 1, thinkingTokens: 1,
                cacheReadTokens: 0, cacheCreationTokens: 1, cacheCreation1hTokens: 1
            ),
        ])
    }

    // MARK: - Review group A1: length caps count Unicode scalars

    private let combiningAcute = "\u{301}"

    func test_records_messageIDOverCapInScalarsButOneGrapheme_yieldsNothing() {
        // 1 grapheme, 201 scalars: over the 128-scalar cap.
        let id = "k" + String(repeating: combiningAcute, count: 200)
        XCTAssertEqual(id.count, 1, "Fixture error: must be a single grapheme")
        XCTAssertEqual(id.unicodeScalars.count, 201)

        XCTAssertEqual(parse(line(message: ["id": id])), [])
    }

    func test_records_gitBranchOverCapInScalarsButOneGrapheme_becomesNil() {
        // 1 grapheme, 301 scalars: over the 255-scalar cap.
        let branch = "e" + String(repeating: combiningAcute, count: 300)
        XCTAssertEqual(branch.count, 1, "Fixture error: must be a single grapheme")

        XCTAssertEqual(parse(line(top: ["gitBranch": branch])), [makeRecord(gitBranch: nil)])
    }

    func test_records_effortOverCapInScalarsButOneGrapheme_becomesNil() {
        // 1 grapheme, 101 scalars: over the 64-scalar cap.
        let effort = "e" + String(repeating: combiningAcute, count: 100)

        XCTAssertEqual(
            parse(line(top: ["effort": effort, "perTurnEffort": nil])), [makeRecord(effort: nil)])
    }

    func test_records_cwdOverCapInScalarsButOneGrapheme_becomesNil() {
        // 2 graphemes, 1_102 scalars: over the 1024-scalar cap.
        let cwd = "/e" + String(repeating: combiningAcute, count: 1_100)

        XCTAssertEqual(parse(line(top: ["cwd": cwd])), [makeRecord(cwd: nil)])
    }

    func test_records_requiredLabelOfExactlyCapScalarsInMultiScalarGraphemes_isAcceptedAndStored() {
        // 64 graphemes, 128 scalars: exactly at the cap.
        let model = String(repeating: "e" + combiningAcute, count: 64)
        XCTAssertEqual(model.unicodeScalars.count, 128)

        let records = parse(line(message: ["model": model]))

        XCTAssertEqual(records, [makeRecord(model: model)])
        XCTAssertEqual(records.first?.model.unicodeScalars.count, 128)
    }

    func test_records_requiredLabelOfCapPlusOneScalarsInMultiScalarGraphemes_yieldsNothing() {
        // 65 graphemes, 129 scalars: one scalar over the cap, far under it in graphemes.
        let model = String(repeating: "e" + combiningAcute, count: 64) + "e"
        XCTAssertEqual(model.unicodeScalars.count, 129)
        XCTAssertEqual(model.count, 65)

        XCTAssertEqual(parse(line(message: ["model": model])), [])
    }

    func test_records_optionalLabelOfExactlyCapScalarsInMultiScalarGraphemes_isKept() {
        // 128 graphemes, 255 scalars: exactly at the gitBranch cap.
        let branch = String(repeating: "e" + combiningAcute, count: 127) + "e"
        XCTAssertEqual(branch.unicodeScalars.count, 255)

        XCTAssertEqual(parse(line(top: ["gitBranch": branch])), [makeRecord(gitBranch: branch)])
    }

    func test_records_optionalLabelOfCapPlusOneScalarsInMultiScalarGraphemes_becomesNil() {
        // 128 graphemes, 256 scalars: one scalar over the gitBranch cap.
        let branch = String(repeating: "e" + combiningAcute, count: 128)
        XCTAssertEqual(branch.unicodeScalars.count, 256)
        XCTAssertEqual(branch.count, 128)

        XCTAssertEqual(parse(line(top: ["gitBranch": branch])), [makeRecord(gitBranch: nil)])
    }

    // MARK: - Review group A2: <synthetic> after trimming

    func test_records_syntheticModelWithSurroundingWhitespace_yieldsNothing() {
        XCTAssertEqual(parse(line(message: ["model": " <synthetic> "])), [])
        XCTAssertEqual(parse(line(message: ["model": "\t<synthetic>"])), [])
    }

    // MARK: - Review group A3: labels reject every scalar the approval banner escapes

    /// Scalars outside `.control` that ControlCharacterDisplay escapes.
    private let escapedScalars: [(name: String, scalar: String)] = [
        ("U+202E bidi override (format)", "\u{202E}"),
        ("U+200B zero-width space (format)", "\u{200B}"),
        ("U+200D zero-width joiner (format)", "\u{200D}"),
        ("U+FEFF byte order mark (format)", "\u{FEFF}"),
        ("U+E0041 tag character (format)", "\u{E0041}"),
        ("U+E000 private use", "\u{E000}"),
        ("U+2028 line separator", "\u{2028}"),
        ("U+2029 paragraph separator", "\u{2029}"),
    ]

    func test_records_optionalLabelContainingEscapedScalar_becomesNil() {
        for (name, scalar) in escapedScalars {
            let records = parse(line(top: [
                "effort": "hi\(scalar)gh", "perTurnEffort": nil, "isSidechain": true,
                "agentId": "a1\(scalar)b2", "attributionAgent": "swift\(scalar)specialist",
                "gitBranch": "ma\(scalar)in", "cwd": "/tmp/pro\(scalar)ject",
            ]))

            XCTAssertEqual(records.count, 1, "\(name): the line must still yield its record")
            XCTAssertNil(records.first?.effort, "effort containing \(name)")
            XCTAssertNil(records.first?.agentID, "agentID containing \(name)")
            XCTAssertNil(records.first?.agentType, "agentType containing \(name)")
            XCTAssertNil(records.first?.gitBranch, "gitBranch containing \(name)")
            XCTAssertNil(records.first?.cwd, "cwd containing \(name)")
        }
    }

    func test_records_messageIDContainingEscapedScalar_yieldsNothing() {
        for (name, scalar) in escapedScalars {
            XCTAssertEqual(parse(line(message: ["id": "msg_01\(scalar)ABC"])), [], "message.id containing \(name)")
        }
    }

    func test_records_sessionIDContainingEscapedScalar_yieldsNothing() {
        for (name, scalar) in escapedScalars {
            XCTAssertEqual(parse(line(top: ["sessionId": "session\(scalar)id"])), [], "sessionId containing \(name)")
        }
    }

    func test_records_modelContainingEscapedScalar_yieldsNothing() {
        for (name, scalar) in escapedScalars {
            XCTAssertEqual(parse(line(message: ["model": "claude\(scalar)opus"])), [], "message.model containing \(name)")
        }
    }

    func test_records_labelWithCombiningMarksAndNonASCIILetters_staysValidAndUnchanged() {
        // Japanese letters, a decomposed dakuten (U+3099) and a combining acute.
        let branch = "機能/ブランチ-か\u{3099}-e\u{301}"
        let cwd = "/tmp/プロジェクト/cafe\u{301}"

        let records = parse(line(top: ["gitBranch": branch, "cwd": cwd]))

        XCTAssertEqual(records, [makeRecord(gitBranch: branch, cwd: cwd)])
        XCTAssertEqual(records.first?.gitBranch.map { Array($0.unicodeScalars) }, Array(branch.unicodeScalars),
                       "The stored label must keep its scalars unchanged (no normalization)")
    }

    // MARK: - Review group B: timestamps

    func test_records_leapDayTimestamp_isAcceptedWithExactMillis() {
        // 2024-02-29T10:27:29.765Z, computed outside the code under test.
        let records = parse(line(top: ["timestamp": "2024-02-29T10:27:29.765Z"]))

        XCTAssertEqual(records, [makeRecord(timestampMs: 1_709_202_449_765)])
    }

    func test_records_impossibleCalendarDates_areRejected() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2023-02-29T10:27:29.765Z"])), [], "2023 is not a leap year")
        XCTAssertEqual(parse(line(top: ["timestamp": "1900-02-29T10:27:29.765Z"])), [], "1900 is not a leap year")
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-04-31T10:27:29.765Z"])), [], "April has 30 days")
    }

    func test_records_hour24OrSecond60_isRejected() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T24:00:00.000Z"])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:60.000Z"])), [])
    }

    func test_records_emptyFraction_isRejected() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.Z"])), [])
    }

    func test_records_fractionShorterOrLongerThanThreeDigits_isScaledOrTruncatedToMillis() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.7Z"])).map(\.timestampMs),
                       [1_790_936_849_700])
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.76Z"])).map(\.timestampMs),
                       [1_790_936_849_760])
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.7654321Z"])).map(\.timestampMs),
                       [1_790_936_849_765])
    }

    func test_records_numericOffsetSuffix_isRejected() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.765+00:00"])), [])
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29+00:00"])), [])
    }

    func test_records_lowercaseZSuffix_isRejected() {
        XCTAssertEqual(parse(line(top: ["timestamp": "2026-10-02T10:27:29.765z"])), [])
    }

    // MARK: - Review group B: other parser pins

    func test_records_tabInsideLabel_makesItInvalid() {
        XCTAssertEqual(parse(line(message: ["id": "msg\t01ABC"])), [])
        XCTAssertEqual(parse(line(message: ["model": "claude\topus"])), [])
        XCTAssertEqual(parse(line(top: ["gitBranch": "ma\tin"])), [makeRecord(gitBranch: nil)])
    }

    func test_records_c0ControlCharacterInsideLabel_makesItInvalid() {
        XCTAssertEqual(parse(line(top: ["sessionId": "session\u{1F}id"])), [])
        XCTAssertEqual(parse(line(message: ["model": "claude\u{8}opus"])), [])
        XCTAssertEqual(parse(line(top: ["cwd": "/tmp/pro\u{1F}ject"])), [makeRecord(cwd: nil)])
    }

    func test_records_numericIsSidechain_isMainThread() {
        XCTAssertEqual(parse(line(top: ["isSidechain": 1, "agentId": "a1b2c3"])),
                       [makeRecord(thread: .main, agentID: "a1b2c3")])
    }

    func test_records_advisorIterationWithThinkingAndOneHourCache_reportsThoseValues() {
        var advisor = advisorIteration()
        advisor["output_tokens_details"] = ["thinking_tokens": 33]
        advisor["cache_creation"] = ["ephemeral_1h_input_tokens": 44, "ephemeral_5m_input_tokens": 11]

        let records = parse(line(usage: ["iterations": [messageIteration(), advisor]]))

        XCTAssertEqual(records, [
            makeRecord(),
            makeRecord(
                key: "msg_01ABC#adv1", model: "claude-fable-5-1", effort: nil, thread: .advisor,
                inputTokens: 125_008, outputTokens: 10_278, thinkingTokens: 33,
                cacheReadTokens: 77, cacheCreationTokens: 55, cacheCreation1hTokens: 44
            ),
        ])
    }

    func test_records_spacedJSONOnOneLine_yieldsTheRecord() {
        let text = #"{ "type" : "assistant" , "sessionId" : "11111111-2222-3333-4444-555555555555" , "#
            + #""timestamp" : "2026-10-02T10:27:29.765Z" , "cwd" : "/tmp/project" , "gitBranch" : "main" , "#
            + #""effort" : "high" , "isSidechain" : false , "message" : { "id" : "msg_01ABC" , "#
            + #""model" : "claude-opus-5-5" , "stop_reason" : "end_turn" , "usage" : { "input_tokens" : 3 , "#
            + #""output_tokens" : 420 , "cache_read_input_tokens" : 90000 , "cache_creation_input_tokens" : 1200 , "#
            + #""cache_creation" : { "ephemeral_1h_input_tokens" : 1000 } , "#
            + #""output_tokens_details" : { "thinking_tokens" : 150 } } } }"#

        XCTAssertEqual(parse(Data(text.utf8)), [makeRecord()])
    }

    // MARK: - Review: only whitespace is trimmed; edge format scalars are rejected

    private let edgeFormatScalars: [(name: String, scalar: String)] = [
        ("U+FEFF", "\u{FEFF}"),
        ("U+200B", "\u{200B}"),
    ]

    /// Leading position only. U+FEFF is absent on purpose: JSONSerialization
    /// removes one leading U+FEFF from every string value, so the parser can
    /// never observe it there (see the single-leading-BOM test below).
    private let leadingFormatScalars: [(name: String, scalar: String)] = [
        ("U+200B", "\u{200B}"),
    ]

    func test_records_requiredLabelStartingWithFormatScalar_yieldsNothing() {
        for (name, scalar) in leadingFormatScalars {
            XCTAssertEqual(parse(line(message: ["id": "\(scalar)msg_01ABC"])), [], "message.id starting with \(name)")
            XCTAssertEqual(parse(line(top: ["sessionId": "\(scalar)session-id"])), [], "sessionId starting with \(name)")
            XCTAssertEqual(parse(line(message: ["model": "\(scalar)claude-opus-5-5"])), [], "message.model starting with \(name)")
        }
    }

    func test_records_optionalLabelStartingWithFormatScalar_becomesNil() {
        for (name, scalar) in leadingFormatScalars {
            let records = parse(line(top: [
                "effort": "\(scalar)high", "perTurnEffort": nil, "isSidechain": true,
                "agentId": "\(scalar)a1b2c3", "attributionAgent": "\(scalar)swift-specialist",
                "gitBranch": "\(scalar)main", "cwd": "\(scalar)/tmp/project",
            ]))

            XCTAssertEqual(records.count, 1, "\(name): the line must still yield its record")
            XCTAssertNil(records.first?.effort, "effort starting with \(name)")
            XCTAssertNil(records.first?.agentID, "agentID starting with \(name)")
            XCTAssertNil(records.first?.agentType, "agentType starting with \(name)")
            XCTAssertNil(records.first?.gitBranch, "gitBranch starting with \(name)")
            XCTAssertNil(records.first?.cwd, "cwd starting with \(name)")
        }
    }

    func test_records_labelWithWhitespaceThenFormatScalar_isStillInvalid() {
        for (name, scalar) in edgeFormatScalars {
            let optional = parse(line(top: ["gitBranch": " \(scalar)main"]))
            XCTAssertEqual(optional.count, 1, "\(name): the line must still yield its record")
            XCTAssertNil(optional.first?.gitBranch, "gitBranch with a space then \(name)")

            XCTAssertEqual(parse(line(message: ["model": " \t\(scalar)claude-opus-5-5"])), [],
                           "message.model with whitespace then \(name)")
        }
    }

    func test_records_labelEndingWithFormatScalar_isInvalid() {
        for (name, scalar) in edgeFormatScalars {
            let optional = parse(line(top: ["gitBranch": "main\(scalar)"]))
            XCTAssertEqual(optional.count, 1, "\(name): the line must still yield its record")
            XCTAssertNil(optional.first?.gitBranch, "gitBranch ending with \(name)")

            let padded = parse(line(top: ["gitBranch": "main\(scalar) "]))
            XCTAssertNil(padded.first?.gitBranch, "gitBranch ending with \(name) then a space")

            XCTAssertEqual(parse(line(message: ["id": "msg_01ABC\(scalar)"])), [], "message.id ending with \(name)")
        }
    }

    func test_records_labelWithSurroundingSpacesAndTabs_isStillStoredTrimmed() {
        let records = parse(line(top: ["gitBranch": "  main\t"]))

        XCTAssertEqual(records, [makeRecord(gitBranch: "main")])
    }

    // MARK: - Decision: no record ever has the model <synthetic>

    func test_records_advisorIterationWithSyntheticModel_emitsNoAdvisorRecord() {
        let records = parse(line(usage: [
            "iterations": [messageIteration(), advisorIteration(model: "<synthetic>")],
        ]))

        XCTAssertEqual(records, [makeRecord()])
    }

    func test_records_advisorIterationWithPaddedSyntheticModel_emitsNoAdvisorRecord() {
        let records = parse(line(usage: [
            "iterations": [messageIteration(), advisorIteration(model: " <synthetic> ")],
        ]))

        XCTAssertEqual(records, [makeRecord()])
    }

    func test_records_validAdvisorAfterSyntheticAdvisors_keepsItsOwnIndexInTheKey() {
        let records = parse(line(usage: [
            "iterations": [
                messageIteration(),
                advisorIteration(model: "<synthetic>"),
                advisorIteration(model: " <synthetic> "),
                advisorIteration(),
            ],
        ]))

        XCTAssertEqual(records.map(\.key), ["msg_01ABC", "msg_01ABC#adv3"])
        XCTAssertEqual(records.map(\.model), ["claude-opus-5-5", "claude-fable-5-1"])
    }

    // MARK: - Foundation boundary: a single leading BOM never reaches the parser

    /// Verified fact: `JSONSerialization.jsonObject` removes exactly ONE
    /// leading U+FEFF from every string value, for raw BOM bytes and for the
    /// ﻿ escape alike. A U+FEFF that is not the first scalar is
    /// untouched, and U+200B is never touched. The parser therefore cannot
    /// observe a single leading BOM; this test pins that boundary so a
    /// change in Foundation's behaviour is detected.
    func test_records_singleLeadingBOM_isRemovedByJSONSerializationBeforeTheParserSeesIt() {
        let branch = parse(line(top: ["gitBranch": "\u{FEFF}main"]))
        XCTAssertEqual(branch, [makeRecord(gitBranch: "main")])

        let model = parse(line(message: ["model": "\u{FEFF}claude-opus-5-5"]))
        XCTAssertEqual(model, [makeRecord(model: "claude-opus-5-5")])
    }

    /// Only the first of two leading BOMs is removed by JSONSerialization;
    /// the second reaches the parser and is rejected as a format scalar.
    func test_records_twoLeadingBOMs_areRejected() {
        XCTAssertEqual(parse(line(top: ["gitBranch": "\u{FEFF}\u{FEFF}main"])), [makeRecord(gitBranch: nil)])
        XCTAssertEqual(parse(line(message: ["id": "\u{FEFF}\u{FEFF}msg_01ABC"])), [])
    }
}
