//
//  ClaudeCostStateReaderTests.swift
//  CalyxTests
//
//  Pins ClaudeCostStateReader.event(fromLine:sessionID:), what one line of
//  a session's main transcript means for its run log, rule by rule in the
//  contract's order: not an object -> nil; a `cost-state` line -> its
//  totals per model label (unless another session's); a `forkedFrom` line
//  -> nil; a timestamped line -> activity in nanoseconds with its cwd;
//  anything else -> nil. Then every fixture cost-state line against the
//  fixture's expected files.
//
//  Lines are written out as raw JSON text so each test shows exactly the
//  bytes the reader sees. Expected nanoseconds were computed by hand
//  (Python `datetime`, UTC, milliseconds x 1_000_000), never by the code
//  under test.
//

import XCTest
@testable import Calyx

final class ClaudeCostStateReaderTests: XCTestCase {

    private let sessionID = "11111111-2222-4333-8444-555555555555"
    private let otherSessionID = "99999999-2222-4333-8444-555555555555"

    /// 2026-10-05T06:56:45.437Z in epoch nanoseconds.
    private let sampleTime = "2026-10-05T06:56:45.437Z"
    private let sampleNs: Int64 = 1_791_183_405_437_000_000

    private func event(_ text: String, sessionID: String? = nil) -> ClaudeTranscriptRunEvent? {
        ClaudeCostStateReader.event(fromLine: Data(text.utf8), sessionID: sessionID ?? self.sessionID)
    }

    /// A cost-state line of this test's session with `modelUsage` given as
    /// raw JSON text.
    private func costStateLine(_ modelUsage: String, sessionIDField: String? = nil) -> String {
        let id = sessionIDField ?? "\"\(sessionID)\""
        return #"{"type":"cost-state","sessionId":"# + id + #","totalCostUSD":0.5,"modelUsage":"# + modelUsage + "}"
    }

    /// The totals of a cost-state event; nil (and a failure) otherwise.
    private func costStateTotals(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) -> [String: UsageTokenTotals]? {
        guard case .costState(let totals)? = event(text) else {
            XCTFail("Expected a cost-state event for \(text)", file: file, line: line)
            return nil
        }
        return totals
    }

    /// The input total of model "m" when `inputTokens` is `value` (raw JSON).
    private func inputCount(_ value: String, file: StaticString = #filePath, line: UInt = #line) -> Int64? {
        costStateTotals(costStateLine(#"{"m":{"inputTokens":"# + value + "}}"), file: file, line: line)?["m"]?.input
    }

    // MARK: - UsageTokenTotals

    func test_tokenTotals_subscriptReadsAndWritesEachKindsOwnField() {
        var totals = UsageTokenTotals()
        totals[.input] = 1
        totals[.output] = 2
        totals[.cacheRead] = 3
        totals[.cacheCreation] = 4

        XCTAssertEqual(totals, UsageTokenTotals(input: 1, output: 2, cacheRead: 3, cacheCreation: 4))
        XCTAssertEqual(UsageTokenKind.allCases.map { totals[$0] }, [1, 2, 3, 4])
    }

    // MARK: - Rule 1: not a JSON object

    func test_rule1_malformedJSON_isNil() {
        XCTAssertNil(event(#"{"type":"cost-state","modelUsage":{}"#))
        XCTAssertNil(event("not json"))
        XCTAssertNil(event(""))
    }

    func test_rule1_jsonThatIsNotAnObject_isNil() {
        XCTAssertNil(event(#"[{"type":"cost-state","modelUsage":{}}]"#))
        XCTAssertNil(event(#""cost-state""#))
        XCTAssertNil(event("12"))
    }

    // MARK: - Rule 2: cost-state

    func test_rule2_costStateOfThisSession_yieldsTheFourTotalsPerModel() {
        let line = costStateLine(#"""
            {"claude-sonnet-5-5":{"inputTokens":24,"outputTokens":2114,"cacheReadInputTokens":176467,\#
            "cacheCreationInputTokens":51986,"thinkingTokens":91,"costUSD":0.25,"webSearchRequests":3}}
            """#)

        XCTAssertEqual(event(line), .costState(totals: [
            "claude-sonnet-5-5": UsageTokenTotals(input: 24, output: 2114, cacheRead: 176467, cacheCreation: 51986),
        ]))
    }

    func test_rule2_eachFieldLandsInItsOwnKind_andThinkingAndCostAreNeverRead() {
        let line = costStateLine(#"""
            {"m":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,\#
            "thinkingTokens":5,"costUSD":6,"webSearchRequests":7}}
            """#)

        XCTAssertEqual(costStateTotals(line), ["m": UsageTokenTotals(input: 1, output: 2, cacheRead: 3, cacheCreation: 4)])
    }

    func test_rule2_severalModels_eachKeepsItsOwnTotals() {
        let line = costStateLine(#"""
            {"claude-fable-5-1":{"inputTokens":41788,"outputTokens":1085},\#
            "claude-haiku-4-5-20251001":{"inputTokens":944,"outputTokens":11,"cacheReadInputTokens":0}}
            """#)

        XCTAssertEqual(costStateTotals(line), [
            "claude-fable-5-1": UsageTokenTotals(input: 41788, output: 1085),
            "claude-haiku-4-5-20251001": UsageTokenTotals(input: 944, output: 11),
        ])
    }

    func test_rule2_anotherSessionsSessionID_isNil() {
        let line = costStateLine(#"{"m":{"inputTokens":5}}"#, sessionIDField: "\"\(otherSessionID)\"")

        XCTAssertNil(event(line))
    }

    func test_rule2_sessionIDDifferingOnlyInCase_isNil() {
        let line = #"{"type":"cost-state","sessionId":"ABCDEF-SESSION","modelUsage":{"m":{"inputTokens":5}}}"#

        XCTAssertNil(event(line, sessionID: "abcdef-session"))
    }

    func test_rule2_matchingSessionIDOtherThanTheDefault_isAccepted() {
        let line = #"{"type":"cost-state","sessionId":"abcdef-session","modelUsage":{"m":{"inputTokens":5}}}"#

        XCTAssertEqual(event(line, sessionID: "abcdef-session"), .costState(totals: ["m": UsageTokenTotals(input: 5)]))
    }

    func test_rule2_missingSessionID_isAccepted() {
        let line = #"{"type":"cost-state","modelUsage":{"m":{"inputTokens":5}}}"#

        XCTAssertEqual(event(line), .costState(totals: ["m": UsageTokenTotals(input: 5)]))
    }

    /// Contract issue (recorded in the hand-back): a PRESENT sessionId that
    /// is not a string is read as "differs".
    func test_rule2_nonStringSessionID_isNil() {
        XCTAssertNil(event(costStateLine(#"{"m":{"inputTokens":5}}"#, sessionIDField: "12")))
        XCTAssertNil(event(costStateLine(#"{"m":{"inputTokens":5}}"#, sessionIDField: "null")))
    }

    func test_rule2_modelUsageNotAnObject_isNil() {
        XCTAssertNil(event(costStateLine(#"[{"m":{"inputTokens":5}}]"#)))
        XCTAssertNil(event(costStateLine(#""m""#)))
        XCTAssertNil(event(costStateLine("null")))
        XCTAssertNil(event(costStateLine("12")))
    }

    func test_rule2_missingModelUsage_isNil() {
        XCTAssertNil(event(#"{"type":"cost-state","sessionId":"\#(sessionID)","totalCostUSD":0.5}"#))
    }

    func test_rule2_emptyModelUsage_isAnEventWithNoModels() {
        XCTAssertEqual(event(costStateLine("{}")), .costState(totals: [:]))
    }

    func test_rule2_entryThatIsNotAnObject_isSkipped_andTheOthersCount() {
        let line = costStateLine(#"{"a":5,"b":{"inputTokens":7},"c":null,"d":[1],"e":"x"}"#)

        XCTAssertEqual(costStateTotals(line), ["b": UsageTokenTotals(input: 7)])
    }

    func test_rule2_modelKeyWithBrackets_isKeptAsItsLabel() {
        let line = costStateLine(#"{"claude-opus-5-5[1m]":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":10738,"cacheCreationInputTokens":16899}}"#)

        XCTAssertEqual(costStateTotals(line), [
            "claude-opus-5-5[1m]": UsageTokenTotals(input: 2, output: 4, cacheRead: 10738, cacheCreation: 16899),
        ])
    }

    func test_rule2_invalidModelKey_becomesUnknown() {
        let line = costStateLine(#"{"bad model":{"inputTokens":3}}"#)

        XCTAssertEqual(costStateTotals(line), ["unknown": UsageTokenTotals(input: 3)])
    }

    func test_rule2_twoInvalidModelKeys_areAddedUnderUnknown() {
        let line = costStateLine(#"{"bad model":{"inputTokens":3,"outputTokens":1},"<x>":{"inputTokens":4,"cacheReadInputTokens":9}}"#)

        XCTAssertEqual(costStateTotals(line), ["unknown": UsageTokenTotals(input: 7, output: 1, cacheRead: 9)])
    }

    func test_rule2_twoInvalidModelKeys_saturateAtInt64Max() {
        let line = costStateLine(#"""
            {"bad model":{"inputTokens":9223372036854775807,"outputTokens":9223372036854775000},\#
            "<x>":{"inputTokens":1,"outputTokens":9223372036854775000}}
            """#)

        XCTAssertEqual(costStateTotals(line), ["unknown": UsageTokenTotals(input: Int64.max, output: Int64.max)])
    }

    func test_rule2_validAndInvalidKeys_stayApart() {
        let line = costStateLine(#"{"claude-sonnet-5-5":{"inputTokens":3},"bad model":{"inputTokens":4}}"#)

        XCTAssertEqual(costStateTotals(line), [
            "claude-sonnet-5-5": UsageTokenTotals(input: 3),
            "unknown": UsageTokenTotals(input: 4),
        ])
    }

    // MARK: - Rule 2: token value forms

    func test_tokenValue_wholeNumber_counts() {
        XCTAssertEqual(inputCount("12"), 12)
    }

    func test_tokenValue_wholeNumberWrittenAsDouble_counts() {
        XCTAssertEqual(inputCount("12.0"), 12)
    }

    func test_tokenValue_fraction_countsAsZero() {
        XCTAssertEqual(inputCount("12.5"), 0)
    }

    func test_tokenValue_negative_countsAsZero() {
        XCTAssertEqual(inputCount("-1"), 0)
    }

    func test_tokenValue_boolean_countsAsZero() {
        XCTAssertEqual(inputCount("true"), 0)
    }

    func test_tokenValue_string_countsAsZero() {
        XCTAssertEqual(inputCount(#""12""#), 0)
    }

    func test_tokenValue_null_countsAsZero() {
        XCTAssertEqual(inputCount("null"), 0)
    }

    func test_tokenValue_missingField_countsAsZero() {
        let line = costStateLine(#"{"m":{"outputTokens":5}}"#)

        XCTAssertEqual(costStateTotals(line), ["m": UsageTokenTotals(input: 0, output: 5)])
    }

    func test_tokenValue_int64Max_countsExactly() {
        XCTAssertEqual(inputCount("9223372036854775807"), Int64.max)
    }

    func test_tokenValue_aboveInt64Max_countsAsZero() {
        XCTAssertEqual(inputCount("9223372036854775808"), 0)
        XCTAssertEqual(inputCount("1e30"), 0)
    }

    // MARK: - Rule order: cost-state before forkedFrom

    func test_ruleOrder_costStateWithForkedFrom_isStillACostState() {
        let line = #"{"type":"cost-state","sessionId":"\#(sessionID)","forkedFrom":{"sessionId":"x"},"modelUsage":{"m":{"inputTokens":5}}}"#

        XCTAssertEqual(event(line), .costState(totals: ["m": UsageTokenTotals(input: 5)]))
    }

    func test_ruleOrder_costStateWithATimestamp_isACostStateNotActivity() {
        let line = #"{"type":"cost-state","timestamp":"\#(sampleTime)","cwd":"/a","modelUsage":{"m":{"inputTokens":5}}}"#

        XCTAssertEqual(event(line), .costState(totals: ["m": UsageTokenTotals(input: 5)]))
    }

    // MARK: - Rule 3: forkedFrom

    func test_rule3_lineWithForkedFrom_isNilEvenWithAValidTimestamp() {
        let line = #"{"type":"user","timestamp":"\#(sampleTime)","sessionId":"\#(sessionID)","cwd":"/a","forkedFrom":{"sessionId":"\#(otherSessionID)","messageUuid":"00000000-0000-4000-8000-000000000000"}}"#

        XCTAssertNil(event(line))
    }

    func test_rule3_forkedFromWithANullValue_isStillNil() {
        let line = #"{"type":"assistant","timestamp":"\#(sampleTime)","forkedFrom":null}"#

        XCTAssertNil(event(line))
    }

    // MARK: - Rule 4: timestamped lines

    func test_rule4_eachTimestampedType_yieldsActivityInNanoseconds() {
        for type in ["user", "assistant", "attachment", "system", "queue-operation"] {
            let line = #"{"type":"\#(type)","timestamp":"\#(sampleTime)","sessionId":"\#(sessionID)","cwd":"/fixture/project"}"#

            XCTAssertEqual(event(line), .activity(timeNs: sampleNs, cwd: "/fixture/project"), type)
        }
    }

    func test_rule4_anotherSessionsSessionIDOnAnActivityLine_isStillActivity() {
        // Only cost-state lines are checked against the session.
        let line = #"{"type":"user","timestamp":"\#(sampleTime)","sessionId":"\#(otherSessionID)"}"#

        XCTAssertEqual(event(line), .activity(timeNs: sampleNs, cwd: nil))
    }

    func test_rule4_unknownTypeWithATimestamp_isActivity() {
        XCTAssertEqual(event(#"{"type":"progress","timestamp":"\#(sampleTime)"}"#), .activity(timeNs: sampleNs, cwd: nil))
        XCTAssertEqual(event(#"{"timestamp":"\#(sampleTime)"}"#), .activity(timeNs: sampleNs, cwd: nil))
    }

    func test_rule4_millisecondsAreKept() {
        // 1970-01-01T00:00:01.001Z = 1_001 ms.
        XCTAssertEqual(event(#"{"type":"user","timestamp":"1970-01-01T00:00:01.001Z"}"#),
                       .activity(timeNs: 1_001_000_000, cwd: nil))
    }

    func test_rule4_secondPrecisionTimestamp_isAccepted() {
        XCTAssertEqual(event(#"{"type":"user","timestamp":"2026-10-05T06:56:45Z"}"#),
                       .activity(timeNs: 1_791_183_405_000_000_000, cwd: nil))
    }

    func test_rule4_latestTimeThatFitsInt64Nanoseconds_isActivity() {
        // 2262-01-01T00:00:00Z = 9_214_646_400_000 ms; x 1e6 < Int64.max.
        XCTAssertEqual(event(#"{"type":"user","timestamp":"2262-01-01T00:00:00Z"}"#),
                       .activity(timeNs: 9_214_646_400_000_000_000, cwd: nil))
    }

    func test_rule4_timeWhoseNanosecondsOverflowInt64_isNil() {
        // 2263-01-01T00:00:00Z = 9_246_182_400_000 ms; x 1e6 > Int64.max.
        XCTAssertNil(event(#"{"type":"user","timestamp":"2263-01-01T00:00:00Z"}"#))
        XCTAssertNil(event(#"{"type":"user","timestamp":"9999-12-31T23:59:59.999Z"}"#))
    }

    func test_rule4_unparseableTimestamp_isNil() {
        XCTAssertNil(event(#"{"type":"user","timestamp":"2026-10-05 06:56:45Z"}"#))
        XCTAssertNil(event(#"{"type":"user","timestamp":"2026-10-05T06:56:45+09:00"}"#))
        XCTAssertNil(event(#"{"type":"user","timestamp":1791183405437}"#))
        XCTAssertNil(event(#"{"type":"user","timestamp":null}"#))
    }

    func test_rule4_missingTimestamp_isNil() {
        XCTAssertNil(event(#"{"type":"user","sessionId":"\#(sessionID)","cwd":"/a"}"#))
    }

    func test_rule4_cwdMissing_isNilCWD() {
        XCTAssertEqual(event(#"{"type":"user","timestamp":"\#(sampleTime)"}"#), .activity(timeNs: sampleNs, cwd: nil))
    }

    func test_rule4_cwdThatIsNotAVerbatimLabel_isNilCWD_butStillActivity() {
        let longPath = "/" + String(repeating: "a", count: 1_024)
        for cwd in [#"" /fixture/project""#, #""/fixture/project ""#, #""/a\u0007b""#, #""/a‮b""#, #""""#,
                    "12", "null", "\"\(longPath)\""] {
            let line = #"{"type":"user","timestamp":"\#(sampleTime)","cwd":"# + cwd + "}"

            XCTAssertEqual(event(line), .activity(timeNs: sampleNs, cwd: nil), cwd)
        }
    }

    func test_rule4_relativeCWD_isNilCWD_butTheTimestampStillCounts() {
        for cwd in ["src", "./x", "~/x", "fixture/project", "../up"] {
            let line = #"{"type":"user","timestamp":"\#(sampleTime)","cwd":"\#(cwd)"}"#

            XCTAssertEqual(event(line), .activity(timeNs: sampleNs, cwd: nil), cwd)
        }
    }

    func test_rule4_rootDirectoryCWD_isKept() {
        XCTAssertEqual(event(#"{"type":"user","timestamp":"\#(sampleTime)","cwd":"/"}"#),
                       .activity(timeNs: sampleNs, cwd: "/"))
    }

    func test_rule4_cwdOfExactly1024Scalars_isKept() {
        let path = "/" + String(repeating: "a", count: 1_023)
        XCTAssertEqual(path.unicodeScalars.count, 1_024, "Fixture error")

        XCTAssertEqual(event(#"{"type":"user","timestamp":"\#(sampleTime)","cwd":"\#(path)"}"#),
                       .activity(timeNs: sampleNs, cwd: path))
    }

    func test_rule4_nestedCostStateTypeInsideAnActivityLine_isActivity() {
        // No byte-level shortcut: the nested "type" is not the line's.
        let line = #"{"type":"user","timestamp":"\#(sampleTime)","message":{"type":"cost-state","modelUsage":{"m":{"inputTokens":5}}}}"#

        XCTAssertEqual(event(line), .activity(timeNs: sampleNs, cwd: nil))
    }

    // MARK: - Rule 5: everything else

    func test_rule5_eachUntimestampedType_isNil() {
        for type in ["last-prompt", "atis-latch", "mode", "permission-mode", "ai-title", "custom-title",
                     "agent-name", "file-history-snapshot"] {
            let line = #"{"type":"\#(type)","sessionId":"\#(sessionID)","cwd":"/fixture/project"}"#

            XCTAssertNil(event(line), type)
        }
    }

    func test_rule5_emptyObject_isNil() {
        XCTAssertNil(event("{}"))
    }

    // MARK: - Fixtures

    /// Every cost-state line of a skeleton, as the test itself reads them
    /// (by `type`), in file order.
    private func costStateLines(_ skeleton: UsageRunLogSkeleton) throws -> [Data] {
        let lines = try UsageRunLogFixtures.lines(skeleton)
        let objects = try UsageRunLogFixtures.objects(skeleton)
        return zip(lines, objects).filter { $0.1["type"] as? String == "cost-state" }.map(\.0)
    }

    private func totals(of line: Data, _ skeleton: UsageRunLogSkeleton) -> [String: UsageTokenTotals]? {
        guard case .costState(let totals)? = ClaudeCostStateReader.event(fromLine: line, sessionID: skeleton.sessionID) else {
            return nil
        }
        return totals
    }

    func test_fixtures_lastCostStateLineOfEverySkeleton_equalsItsExpectedFile() throws {
        for skeleton in UsageRunLogFixtures.all {
            let lines = try costStateLines(skeleton)
            guard let last = lines.last else {
                XCTFail("\(skeleton) has no cost-state line")
                continue
            }

            XCTAssertEqual(totals(of: last, skeleton), try UsageRunLogFixtures.expectedCostState(skeleton), "\(skeleton)")
        }
    }

    func test_fixtures_everyCostStateLine_parsesAsACostState() throws {
        for skeleton in UsageRunLogFixtures.all {
            for (index, line) in try costStateLines(skeleton).enumerated() {
                XCTAssertNotNil(totals(of: line, skeleton), "\(skeleton) cost-state #\(index + 1)")
            }
        }
    }

    func test_fixtures_run3_firstTwoCostStates_equalRun2sExpectedFile_andTheThirdRun3s() throws {
        let lines = try costStateLines(UsageRunLogFixtures.run3)
        XCTAssertEqual(lines.count, 3, "Fixture error: run3 has cost-state lines 62, 64 and 85")
        let run2 = try UsageRunLogFixtures.expectedCostState(run: "run2")
        let run3 = try UsageRunLogFixtures.expectedCostState(run: "run3")

        XCTAssertEqual(lines.map { totals(of: $0, UsageRunLogFixtures.run3) }, [run2, run2, run3])
    }

    func test_fixtures_run8Skeleton2_firstCostStateEqualsRun7Parent_andTheLastTwoRun8s() throws {
        let lines = try costStateLines(UsageRunLogFixtures.run8b)
        XCTAssertEqual(lines.count, 3, "Fixture error: run8 skeleton-2 has cost-state lines 34, 45 and 51")
        let parent = try UsageRunLogFixtures.expectedCostState(run: "run7", number: 1)
        let resumed = try UsageRunLogFixtures.expectedCostState(run: "run8", number: 2)

        XCTAssertEqual(lines.map { totals(of: $0, UsageRunLogFixtures.run8b) }, [parent, resumed, resumed])
    }

    func test_fixtures_run4_modelKeyWithBrackets() throws {
        let lines = try costStateLines(UsageRunLogFixtures.run4)
        let parsed = try XCTUnwrap(lines.last.flatMap { totals(of: $0, UsageRunLogFixtures.run4) })

        XCTAssertEqual(parsed, [
            "claude-opus-5-5[1m]": UsageTokenTotals(input: 2, output: 4, cacheRead: 10738, cacheCreation: 16899),
        ])
    }

    func test_fixtures_costStateRead_underAnotherSessionID_isNil() throws {
        let lines = try costStateLines(UsageRunLogFixtures.run1)
        let line = try XCTUnwrap(lines.last)

        XCTAssertNil(ClaudeCostStateReader.event(fromLine: line, sessionID: UsageRunLogFixtures.run2.sessionID))
    }

    func test_fixtures_run7Skeleton2_everyForkedFromLine_isNil() throws {
        let skeleton = UsageRunLogFixtures.run7b
        let lines = try UsageRunLogFixtures.lines(skeleton)
        let objects = try UsageRunLogFixtures.objects(skeleton)
        let forked = zip(lines, objects).filter { $0.1["forkedFrom"] != nil }.map(\.0)
        XCTAssertEqual(forked.count, 18, "Fixture error: lines 1-18 carry forkedFrom")

        for line in forked {
            XCTAssertNil(ClaudeCostStateReader.event(fromLine: line, sessionID: skeleton.sessionID))
        }
    }
}
