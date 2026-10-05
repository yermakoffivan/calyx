//
//  OTLPTokenUsageDecoderTests.swift
//  CalyxTests
//
//  Pins OTLPTokenUsageDecoder, the pure decoder of Claude Code's
//  `claude_code.token.usage` metric in an OTLP/JSON metrics export:
//  which metrics and points become samples, how values, timestamps and
//  labels are read, what is skipped and counted, and the series identity
//  (a SHA-256 over every non-personal attribute), and the process starts
//  read from `claude_code.session.count`.
//
//  The captured exports in CalyxTests/Fixtures/UsageTelemetry are real
//  runs whose final cumulative sums equal Claude Code's own totals; the
//  expected values come from each run's expected-cost-state.json and from
//  the test's own JSONSerialization reader, never from the decoder.
//

import XCTest
@testable import Calyx

final class OTLPTokenUsageDecoderTests: XCTestCase {

    private typealias Fixtures = UsageTelemetryFixtures

    // MARK: - Helpers

    /// The attributes of a typical main-thread point of the captures.
    private func baseAttributes(type: String = "input") -> [[String: Any]] {
        Fixtures.attributes([
            "user.id": "fixture-user-id-0000000000000000",
            "session.id": "11111111-1111-4111-8111-111111111111",
            "organization.id": "00000000-0000-4000-8000-0000000000aa",
            "user.email": "fixture@example.invalid",
            "terminal.type": "xterm-256color",
            "model": "claude-sonnet-5-5",
            "query_source": "main",
            "effort": "medium",
            "type": type,
        ])
    }

    private func decodePoints(_ points: [[String: Any]], temporality: Any? = 2) throws -> OTLPTokenUsageBatch {
        try OTLPTokenUsageDecoder.decode(try Fixtures.body(metrics: [Fixtures.metric(temporality: temporality, points: points)]))
    }

    private func decodeOne(_ point: [String: Any]) throws -> OTLPTokenUsageBatch {
        try decodePoints([point])
    }

    /// The single sample a one-point body must produce.
    private func onlySample(
        _ point: [String: Any], file: StaticString = #filePath, line: UInt = #line
    ) throws -> UsageSeriesSample {
        let batch = try decodeOne(point)
        XCTAssertEqual(batch.samples.count, 1, "Expected exactly one sample", file: file, line: line)
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(), file: file, line: line)
        return try XCTUnwrap(batch.samples.first, file: file, line: line)
    }

    private func seriesID(attributes: [[String: Any]]) throws -> String {
        try onlySample(Fixtures.point(attributes: attributes)).seriesID
    }

    private func replacing(_ key: String, with value: String, in attributes: [[String: Any]]) -> [[String: Any]] {
        attributes.map { ($0["key"] as? String) == key ? Fixtures.stringAttribute(key, value) : $0 }
    }

    private func removing(_ key: String, from attributes: [[String: Any]]) -> [[String: Any]] {
        attributes.filter { ($0["key"] as? String) != key }
    }

    /// A point whose value fields are exactly `valueFields` (no asDouble
    /// unless listed).
    private func pointWithValue(_ valueFields: [String: Any]) -> [String: Any] {
        var point = Fixtures.point(attributes: baseAttributes())
        point["asDouble"] = nil
        for (key, value) in valueFields { point[key] = value }
        return point
    }

    private func assertMalformed(
        _ point: [String: Any], _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let batch = try decodeOne(point)
        XCTAssertEqual(batch.samples, [], message, file: file, line: line)
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(malformedPoints: 1), message, file: file, line: line)
    }

    // MARK: - Fixtures: whole runs

    func test_metricName() {
        XCTAssertEqual(OTLPTokenUsageDecoder.metricName, "claude_code.token.usage")
    }

    func test_everyFixtureExport_decodesWithoutErrorOrSkips_andMatchesTheIndependentReader() throws {
        for run in ["run1", "run2", "run3", "run4"] {
            for url in try Fixtures.exportURLs(run: run) {
                let body = try Data(contentsOf: url)
                let batch = try OTLPTokenUsageDecoder.decode(body)
                XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(), url.lastPathComponent)
                let raw = try Fixtures.rawTokenPoints(in: body)
                XCTAssertEqual(batch.samples.count, raw.count, "\(run)/\(url.lastPathComponent)")
                for (sample, point) in zip(batch.samples, raw) {
                    XCTAssertEqual(sample.sessionID, point.sessionID)
                    XCTAssertEqual(sample.startNs, point.startNs)
                    XCTAssertEqual(sample.timeNs, point.timeNs)
                    XCTAssertEqual(sample.kind.rawValue, point.kind)
                    XCTAssertEqual(sample.value, point.value)
                    XCTAssertEqual(sample.model, point.model)
                    XCTAssertEqual(sample.effort, point.attributes["effort"])
                    XCTAssertEqual(sample.thread, point.attributes["query_source"])
                    XCTAssertEqual(sample.agent, point.attributes["agent.name"])
                }
            }
        }
    }

    func test_run1_firstExportCarriesNoTokenUsage_onlyItsProcessStart() throws {
        let first = try XCTUnwrap(try Fixtures.exports(run: "run1").first)
        let batch = try OTLPTokenUsageDecoder.decode(first)
        XCTAssertEqual(batch, OTLPTokenUsageBatch(
            samples: [],
            processStarts: [UsageProcessStart(
                sessionID: "11111111-1111-4111-8111-111111111111", startNs: 1_791_183_405_041_000_000, startType: "fresh")],
            skipped: OTLPTokenUsageBatch.Skipped()))
    }

    /// Last sample per (session, series, start), summed by model and kind.
    private func lastSampleTotals(runs: [String]) throws -> UsageTotalsByModel {
        var last: [String: UsageSeriesSample] = [:]
        for run in runs {
            for body in try Fixtures.exports(run: run) {
                for sample in try OTLPTokenUsageDecoder.decode(body).samples {
                    last["\(sample.sessionID)|\(sample.seriesID)|\(sample.startNs)"] = sample
                }
            }
        }
        return Fixtures.sumByModel(last.values.map { ($0.model, $0.kind.rawValue, $0.value) })
    }

    func test_run1_lastSamplePerSeries_sumsToExpectedCostState() throws {
        XCTAssertEqual(try lastSampleTotals(runs: ["run1"]), try Fixtures.expectedTotals(run: "run1"))
    }

    func test_run2_lastSamplePerSeries_sumsToExpectedCostState() throws {
        XCTAssertEqual(try lastSampleTotals(runs: ["run2"]), try Fixtures.expectedTotals(run: "run2"))
    }

    func test_run3_resumeOfRun2_run2ThenRun3_sumsToRun3ExpectedCostState() throws {
        XCTAssertEqual(try lastSampleTotals(runs: ["run2", "run3"]), try Fixtures.expectedTotals(run: "run3"))
    }

    func test_run4_lastSamplePerSeries_sumsToExpectedCostState() throws {
        XCTAssertEqual(try lastSampleTotals(runs: ["run4"]), try Fixtures.expectedTotals(run: "run4"))
    }

    func test_fixtureTotals_matchTheREADMEFigures() throws {
        // Guards the fixture copy itself: run1's totals are stated in the README.
        XCTAssertEqual(try Fixtures.expectedTotals(run: "run1"), [
            "claude-sonnet-5-5": ["input": 24, "output": 2114, "cacheRead": 176_467, "cacheCreation": 51_986],
        ])
    }

    func test_run2_carriesAdvisorAuxiliaryAndExploreLabels() throws {
        let last = try XCTUnwrap(try Fixtures.exports(run: "run2").last)
        let samples = try OTLPTokenUsageDecoder.decode(last).samples

        let advisor = samples.filter { $0.model == "claude-fable-5-1" }
        XCTAssertEqual(advisor.count, 4)
        for sample in advisor {
            XCTAssertEqual(sample.thread, "main")
            XCTAssertNil(sample.effort)
            XCTAssertNil(sample.agent)
        }
        XCTAssertEqual(advisor.first { $0.kind == .input }?.value, 41_788)

        XCTAssertTrue(samples.contains { $0.thread == "auxiliary" && $0.model == "claude-haiku-4-5-20251001" })
        let explore = samples.filter { $0.agent == "Explore" }
        XCTAssertEqual(explore.count, 4)
        for sample in explore {
            XCTAssertEqual(sample.thread, "subagent")
            XCTAssertEqual(sample.effort, "medium")
        }
        XCTAssertEqual(Set(samples.map(\.sessionID)), ["22222222-2222-4222-8222-222222222222"])
    }

    func test_run4_carriesSuffixedModelAndXhighEffort() throws {
        let only = try XCTUnwrap(try Fixtures.exports(run: "run4").first)
        let samples = try OTLPTokenUsageDecoder.decode(only).samples
        XCTAssertEqual(samples.count, 4)
        for sample in samples {
            XCTAssertEqual(sample.model, "claude-opus-5-5[1m]")
            XCTAssertEqual(sample.effort, "xhigh")
            XCTAssertEqual(sample.thread, "main")
        }
        XCTAssertEqual(Set(samples.map(\.kind)), Set(UsageTokenKind.allCases))
        XCTAssertEqual(samples.first { $0.kind == .cacheCreation }?.value, 16_899)
    }

    func test_decodedFixtureBatches_neverDescribeAPersonalValue() throws {
        for run in ["run1", "run2", "run3", "run4"] {
            for body in try Fixtures.exports(run: run) {
                let description = String(describing: try OTLPTokenUsageDecoder.decode(body))
                for sentinel in usageTelemetrySentinels {
                    XCTAssertFalse(description.contains(sentinel), "\(run): \(sentinel) leaked into the batch")
                }
            }
        }
    }

    // MARK: - Body shape

    func test_decode_notJSON_throwsUndecodable() {
        XCTAssertThrowsError(try OTLPTokenUsageDecoder.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? OTLPTokenUsageDecodeError, .undecodable)
        }
        XCTAssertThrowsError(try OTLPTokenUsageDecoder.decode(Data())) { error in
            XCTAssertEqual(error as? OTLPTokenUsageDecodeError, .undecodable)
        }
    }

    func test_decode_jsonArrayOrScalar_throwsUndecodable() {
        for text in ["[]", "[{\"resourceMetrics\":[]}]", "42", "\"text\"", "null"] {
            XCTAssertThrowsError(try OTLPTokenUsageDecoder.decode(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? OTLPTokenUsageDecodeError, .undecodable, text)
            }
        }
    }

    func test_decode_emptyObject_isAnEmptyExport() throws {
        let batch = try OTLPTokenUsageDecoder.decode(Data("{}".utf8))
        XCTAssertEqual(batch, OTLPTokenUsageBatch(samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()))
    }

    func test_decode_emptyResourceMetrics_isAnEmptyExport() throws {
        let batch = try OTLPTokenUsageDecoder.decode(Data(#"{"resourceMetrics":[]}"#.utf8))
        XCTAssertEqual(batch, OTLPTokenUsageBatch(samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()))
    }

    func test_decode_wrongShapedElements_areIgnored_andValidPointsStillDecode() throws {
        let valid = Fixtures.point(attributes: baseAttributes(), asDouble: 7)
        let resourceMetrics: [Any] = [
            42,
            "text",
            ["scopeMetrics": "not an array"],
            ["scopeMetrics": [7, ["metrics": "not an array"], ["metrics": [
                "not a metric",
                ["name": 5, "sum": ["aggregationTemporality": 2, "dataPoints": [valid]]],
                ["name": "claude_code.token.usage", "sum": "not an object"],
                ["name": "claude_code.token.usage", "sum": ["aggregationTemporality": 2, "dataPoints": "x"]],
                Fixtures.metric(points: [valid]),
            ]]]],
        ]
        let batch = try OTLPTokenUsageDecoder.decode(try Fixtures.body(resourceMetrics: resourceMetrics))
        XCTAssertEqual(batch.samples.map(\.value), [7])
    }

    func test_decode_resourceMetricsNotAnArray_isEmpty() throws {
        let batch = try OTLPTokenUsageDecoder.decode(Data(#"{"resourceMetrics":"nope"}"#.utf8))
        XCTAssertEqual(batch.samples, [])
    }

    // MARK: - Which metrics are read

    func test_decode_costUsageWithIdenticalPoints_yieldsNothing() throws {
        let point = Fixtures.point(attributes: baseAttributes(), asDouble: 0.25)
        let whole = Fixtures.point(attributes: baseAttributes(), asDouble: 12)
        let body = try Fixtures.body(metrics: [
            Fixtures.metric(name: "claude_code.cost.usage", points: [point, whole]),
            Fixtures.metric(name: "claude_code.active_time.total", points: [whole]),
            Fixtures.metric(name: "claude_code.lines_of_code.count", points: [whole]),
        ])
        let batch = try OTLPTokenUsageDecoder.decode(body)
        XCTAssertEqual(batch, OTLPTokenUsageBatch(samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()))
    }

    func test_decode_onlyTheTokenMetricOfAMixedPayloadIsRead() throws {
        let whole = Fixtures.point(attributes: baseAttributes(), asDouble: 12)
        let body = try Fixtures.body(metrics: [
            Fixtures.metric(name: "claude_code.cost.usage", points: [whole]),
            Fixtures.metric(points: [Fixtures.point(attributes: baseAttributes(), asDouble: 5)]),
            Fixtures.metric(name: "claude_code.token.usage.extra", points: [whole]),
            Fixtures.metric(name: "Claude_code.token.usage", points: [whole]),
        ])
        let batch = try OTLPTokenUsageDecoder.decode(body)
        XCTAssertEqual(batch.samples.map(\.value), [5])
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped())
    }

    func test_decode_tokenMetricAsGaugeInsteadOfSum_isIgnored() throws {
        let gauge: [String: Any] = [
            "name": "claude_code.token.usage",
            "gauge": ["dataPoints": [Fixtures.point(attributes: baseAttributes())]],
        ]
        let batch = try OTLPTokenUsageDecoder.decode(try Fixtures.body(metrics: [gauge]))
        XCTAssertEqual(batch, OTLPTokenUsageBatch(samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()))
    }

    // MARK: - Temporality

    func test_decode_cumulativeAsNumber2_isAccepted() throws {
        let batch = try decodePoints([Fixtures.point(attributes: baseAttributes())], temporality: 2)
        XCTAssertEqual(batch.samples.count, 1)
    }

    func test_decode_cumulativeAsEnumString_isAccepted() throws {
        let batch = try decodePoints(
            [Fixtures.point(attributes: baseAttributes())], temporality: "AGGREGATION_TEMPORALITY_CUMULATIVE")
        XCTAssertEqual(batch.samples.count, 1)
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped())
    }

    func test_decode_nonCumulativeTemporality_refusesEveryPointOfThatMetric() throws {
        let points = [
            Fixtures.point(attributes: baseAttributes(type: "input"), asDouble: 3),
            Fixtures.point(attributes: baseAttributes(type: "output"), asDouble: 4),
            Fixtures.point(attributes: baseAttributes(type: "bogus"), asDouble: 5),
        ]
        let cases: [(String, Any?)] = [
            ("delta as number", 1),
            ("delta as string", "AGGREGATION_TEMPORALITY_DELTA"),
            ("unspecified as number", 0),
            ("unspecified as string", "AGGREGATION_TEMPORALITY_UNSPECIFIED"),
            ("missing", nil),
            ("2 written as a string", "2"),
            ("lowercase name", "aggregation_temporality_cumulative"),
        ]
        for (name, temporality) in cases {
            let batch = try decodePoints(points, temporality: temporality)
            XCTAssertEqual(batch.samples, [], name)
            XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(nonCumulativePoints: 3), name)
        }
    }

    func test_decode_deltaMetricBesideCumulativeMetric_onlyTheCumulativeOneIsRead() throws {
        let body = try Fixtures.body(metrics: [
            Fixtures.metric(temporality: 1, points: [Fixtures.point(attributes: baseAttributes(), asDouble: 100)]),
            Fixtures.metric(temporality: 2, points: [Fixtures.point(attributes: baseAttributes(), asDouble: 9)]),
        ])
        let batch = try OTLPTokenUsageDecoder.decode(body)
        XCTAssertEqual(batch.samples.map(\.value), [9])
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(nonCumulativePoints: 1))
    }

    // MARK: - Values

    func test_value_asIntDecimalString() throws {
        XCTAssertEqual(try onlySample(pointWithValue(["asInt": "123"])).value, 123)
    }

    func test_value_asIntJSONNumber() throws {
        XCTAssertEqual(try onlySample(pointWithValue(["asInt": 123])).value, 123)
    }

    func test_value_asDoubleWholeNumber() throws {
        XCTAssertEqual(try onlySample(pointWithValue(["asDouble": 2114.0])).value, 2114)
    }

    func test_value_zero_isAccepted() throws {
        XCTAssertEqual(try onlySample(pointWithValue(["asInt": "0"])).value, 0)
        XCTAssertEqual(try onlySample(pointWithValue(["asDouble": 0.0])).value, 0)
    }

    func test_value_asIntInt64Max_isAccepted() throws {
        XCTAssertEqual(try onlySample(pointWithValue(["asInt": "9223372036854775807"])).value, Int64.max)
    }

    func test_value_fraction_isMalformed() throws {
        try assertMalformed(pointWithValue(["asDouble": 1.5]), "asDouble 1.5")
        try assertMalformed(pointWithValue(["asDouble": 0.25]), "asDouble 0.25")
        try assertMalformed(pointWithValue(["asInt": 1.5]), "asInt number 1.5")
        try assertMalformed(pointWithValue(["asInt": "1.5"]), "asInt string 1.5")
    }

    func test_value_negative_isMalformed() throws {
        try assertMalformed(pointWithValue(["asDouble": -1.0]), "asDouble -1")
        try assertMalformed(pointWithValue(["asInt": -1]), "asInt number -1")
        try assertMalformed(pointWithValue(["asInt": "-1"]), "asInt string -1")
    }

    /// A body whose single point carries `asDouble` written exactly as
    /// `literal` in the JSON text (so `-1.0` stays a floating-point token).
    private func bodyWithLiteralAsDouble(_ literal: String) throws -> Data {
        let point = Fixtures.point(attributes: baseAttributes(), asDouble: 1)
        var withPlaceholder = point
        withPlaceholder["asDouble"] = "ASDOUBLE-PLACEHOLDER"
        let text = String(decoding: try Fixtures.body(metrics: [Fixtures.metric(points: [withPlaceholder])]), as: UTF8.self)
        let replaced = text.replacingOccurrences(of: "\"ASDOUBLE-PLACEHOLDER\"", with: literal)
        XCTAssertNotEqual(replaced, text, "Fixture error: placeholder not found")
        return Data(replaced.utf8)
    }

    func test_value_floatingPointLiterals_wholeAccepted_negativeMalformed() throws {
        let whole = try OTLPTokenUsageDecoder.decode(try bodyWithLiteralAsDouble("12.0"))
        XCTAssertEqual(whole.samples.map(\.value), [12])
        let exponent = try OTLPTokenUsageDecoder.decode(try bodyWithLiteralAsDouble("1.2e1"))
        XCTAssertEqual(exponent.samples.map(\.value), [12])
        for literal in ["-1.0", "-12.0", "-1e1"] {
            let batch = try OTLPTokenUsageDecoder.decode(try bodyWithLiteralAsDouble(literal))
            XCTAssertEqual(batch.samples, [], literal)
            XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(malformedPoints: 1), literal)
        }
    }

    func test_value_aboveInt64Max_isMalformed() throws {
        try assertMalformed(pointWithValue(["asInt": "9223372036854775808"]), "asInt string Int64.max + 1")
        try assertMalformed(pointWithValue(["asDouble": 9_223_372_036_854_775_808.0]), "asDouble 2^63")
        try assertMalformed(pointWithValue(["asDouble": 1e19]), "asDouble 1e19")
        try assertMalformed(pointWithValue(["asDouble": 1e300]), "asDouble 1e300")
    }

    func test_value_nonDigitString_isMalformed() throws {
        for text in ["", "12a", "+5", "abc", " 5", "0x10"] {
            try assertMalformed(pointWithValue(["asInt": text]), "asInt \(text.debugDescription)")
        }
    }

    func test_value_wrongJSONType_isMalformed() throws {
        try assertMalformed(pointWithValue(["asDouble": "12"]), "asDouble as a string")
        try assertMalformed(pointWithValue(["asInt": true]), "asInt as a bool")
        try assertMalformed(pointWithValue(["asInt": NSNull()]), "asInt as null")
    }

    func test_value_missingBothFields_isMalformed() throws {
        try assertMalformed(pointWithValue([:]), "no value")
    }

    // MARK: - Timestamps

    func test_timestamps_decimalStrings_areReadExactly() throws {
        var point = Fixtures.point(attributes: baseAttributes())
        point["startTimeUnixNano"] = "1791183410362000001"
        point["timeUnixNano"] = "1791183415040000003"
        let sample = try onlySample(point)
        XCTAssertEqual(sample.startNs, 1_791_183_410_362_000_001)
        XCTAssertEqual(sample.timeNs, 1_791_183_415_040_000_003)
    }

    func test_timestamps_jsonNumbers_areReadExactly() throws {
        var point = Fixtures.point(attributes: baseAttributes())
        point["startTimeUnixNano"] = NSNumber(value: Int64(1_791_183_410_362_000_001))
        point["timeUnixNano"] = NSNumber(value: Int64(1_791_183_415_040_000_003))
        let sample = try onlySample(point)
        XCTAssertEqual(sample.startNs, 1_791_183_410_362_000_001)
        XCTAssertEqual(sample.timeNs, 1_791_183_415_040_000_003)
    }

    func test_timestamps_zeroAndInt64Max_areAccepted() throws {
        var point = Fixtures.point(attributes: baseAttributes())
        point["startTimeUnixNano"] = "0"
        point["timeUnixNano"] = "9223372036854775807"
        let sample = try onlySample(point)
        XCTAssertEqual(sample.startNs, 0)
        XCTAssertEqual(sample.timeNs, Int64.max)
    }

    func test_timestamps_unusable_areMalformed() throws {
        let bad: [(String, Any?)] = [
            ("missing", nil),
            ("negative string", "-1"),
            ("negative number", -1),
            ("above Int64.max", "9223372036854775808"),
            ("not digits", "soon"),
            ("empty", ""),
            ("bool", true),
        ]
        for field in ["startTimeUnixNano", "timeUnixNano"] {
            for (name, value) in bad {
                var point = Fixtures.point(attributes: baseAttributes())
                point[field] = value
                try assertMalformed(point, "\(field) \(name)")
            }
        }
    }

    // MARK: - Kind

    func test_kind_eachOfTheFourWireNames() throws {
        let expected: [String: UsageTokenKind] = [
            "input": .input, "output": .output, "cacheRead": .cacheRead, "cacheCreation": .cacheCreation,
        ]
        for (wire, kind) in expected {
            XCTAssertEqual(try onlySample(Fixtures.point(attributes: baseAttributes(type: wire))).kind, kind, wire)
        }
        XCTAssertEqual(UsageTokenKind.allCases.count, 4)
    }

    func test_kind_unknownMissingOrNonString_isUnknownKind() throws {
        let variants: [(String, [[String: Any]])] = [
            ("unknown name", baseAttributes(type: "thinking")),
            ("wrong case", baseAttributes(type: "Input")),
            ("snake case", baseAttributes(type: "cache_read")),
            ("empty", baseAttributes(type: "")),
            ("missing", removing("type", from: baseAttributes())),
            ("intValue", removing("type", from: baseAttributes()) + [["key": "type", "value": ["intValue": "1"]]]),
        ]
        for (name, attributes) in variants {
            let batch = try decodeOne(Fixtures.point(attributes: attributes))
            XCTAssertEqual(batch.samples, [], name)
            XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(unknownKind: 1), name)
        }
    }

    // MARK: - Session

    func test_session_missingInvalidOrNonString_isMissingSession() throws {
        let variants: [(String, [[String: Any]])] = [
            ("missing", removing("session.id", from: baseAttributes())),
            ("empty", replacing("session.id", with: "", in: baseAttributes())),
            ("space", replacing("session.id", with: "1111 2222", in: baseAttributes())),
            ("non-ASCII", replacing("session.id", with: "séance", in: baseAttributes())),
            ("129 scalars", replacing("session.id", with: String(repeating: "a", count: 129), in: baseAttributes())),
            ("intValue", removing("session.id", from: baseAttributes())
                + [["key": "session.id", "value": ["intValue": "11"]]]),
        ]
        for (name, attributes) in variants {
            let batch = try decodeOne(Fixtures.point(attributes: attributes))
            XCTAssertEqual(batch.samples, [], name)
            XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(missingSession: 1), name)
        }
    }

    func test_session_validIsCarried() throws {
        XCTAssertEqual(try onlySample(Fixtures.point(attributes: baseAttributes())).sessionID,
                       "11111111-1111-4111-8111-111111111111")
    }

    // MARK: - Order of the skip checks

    func test_skipOrder_unknownKindIsCheckedBeforeSessionAndValue() throws {
        var point = Fixtures.point(attributes: removing("session.id", from: baseAttributes(type: "bogus")))
        point["asDouble"] = 1.5
        let batch = try decodeOne(point)
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(unknownKind: 1))
    }

    func test_skipOrder_missingSessionIsCheckedBeforeValue() throws {
        var point = Fixtures.point(attributes: removing("session.id", from: baseAttributes()))
        point["asDouble"] = -3.0
        point["timeUnixNano"] = nil
        let batch = try decodeOne(point)
        XCTAssertEqual(batch.skipped, OTLPTokenUsageBatch.Skipped(missingSession: 1))
    }

    func test_skipped_countsAccumulateAcrossPoints_andValidPointsStillDecode() throws {
        var malformed = Fixtures.point(attributes: baseAttributes())
        malformed["asDouble"] = 0.5
        let points = [
            Fixtures.point(attributes: baseAttributes(type: "input"), asDouble: 1),
            Fixtures.point(attributes: baseAttributes(type: "x")),
            malformed,
            Fixtures.point(attributes: removing("session.id", from: baseAttributes())),
            Fixtures.point(attributes: baseAttributes(type: "nope")),
            Fixtures.point(attributes: baseAttributes(type: "output"), asDouble: 2),
        ]
        let batch = try decodePoints(points)
        XCTAssertEqual(batch.samples.map(\.value), [1, 2])
        XCTAssertEqual(batch.skipped,
                       OTLPTokenUsageBatch.Skipped(nonCumulativePoints: 0, missingSession: 1, malformedPoints: 1, unknownKind: 2))
    }

    // MARK: - Labels

    func test_labels_validAreCarried() throws {
        let attributes = baseAttributes() + [Fixtures.stringAttribute("agent.name", "Explore")]
        let sample = try onlySample(Fixtures.point(attributes: replacing("query_source", with: "subagent", in: attributes)))
        XCTAssertEqual(sample.model, "claude-sonnet-5-5")
        XCTAssertEqual(sample.effort, "medium")
        XCTAssertEqual(sample.thread, "subagent")
        XCTAssertEqual(sample.agent, "Explore")
    }

    func test_labels_absentOptionalLabels_areNil() throws {
        var attributes = removing("effort", from: baseAttributes())
        attributes = removing("query_source", from: attributes)
        let sample = try onlySample(Fixtures.point(attributes: attributes))
        XCTAssertNil(sample.effort)
        XCTAssertNil(sample.thread)
        XCTAssertNil(sample.agent)
    }

    func test_labels_invalidModel_becomesUnknown_andKeepsItsTokens() throws {
        for model in ["claude <opus>", "", "モデル"] {
            let point = Fixtures.point(attributes: replacing("model", with: model, in: baseAttributes()), asDouble: 77)
            let sample = try onlySample(point)
            XCTAssertEqual(sample.model, "unknown", model)
            XCTAssertEqual(sample.value, 77, model)
        }
    }

    func test_labels_missingOrNonStringModel_becomesUnknown_andKeepsItsTokens() throws {
        let missing = try onlySample(Fixtures.point(attributes: removing("model", from: baseAttributes()), asDouble: 5))
        XCTAssertEqual(missing.model, "unknown")
        XCTAssertEqual(missing.value, 5)
        let nonString = removing("model", from: baseAttributes()) + [["key": "model", "value": ["intValue": "3"]]]
        let typed = try onlySample(Fixtures.point(attributes: nonString, asDouble: 6))
        XCTAssertEqual(typed.model, "unknown")
        XCTAssertEqual(typed.value, 6)
    }

    func test_labels_invalidEffortThreadAgent_becomeNil_andKeepTheirTokens() throws {
        var attributes = replacing("effort", with: "x high", in: baseAttributes())
        attributes = replacing("query_source", with: "séance", in: attributes)
        attributes.append(Fixtures.stringAttribute("agent.name", "<script>"))
        let sample = try onlySample(Fixtures.point(attributes: attributes, asDouble: 31))
        XCTAssertNil(sample.effort)
        XCTAssertNil(sample.thread)
        XCTAssertNil(sample.agent)
        XCTAssertEqual(sample.value, 31)
        XCTAssertEqual(sample.model, "claude-sonnet-5-5")
    }

    func test_labels_nonStringValues_areNotRead() throws {
        var attributes = removing("effort", from: baseAttributes())
        attributes.append(["key": "effort", "value": ["intValue": "5"]])
        attributes.append(["key": "agent.name", "value": ["boolValue": true]])
        let sample = try onlySample(Fixtures.point(attributes: attributes))
        XCTAssertNil(sample.effort)
        XCTAssertNil(sample.agent)
    }

    // MARK: - Sample order

    func test_samples_followDocumentOrderAcrossResourcesScopesMetricsAndPoints() throws {
        func points(_ values: [Double]) -> [[String: Any]] {
            values.map { Fixtures.point(attributes: baseAttributes(), asDouble: $0) }
        }
        let resourceMetrics: [[String: Any]] = [
            ["scopeMetrics": [
                ["metrics": [Fixtures.metric(points: points([5, 3])), Fixtures.metric(points: points([9]))]],
                ["metrics": [Fixtures.metric(points: points([1]))]],
            ]],
            ["scopeMetrics": [["metrics": [Fixtures.metric(points: points([8, 2, 7]))]]]],
        ]
        let batch = try OTLPTokenUsageDecoder.decode(try Fixtures.body(resourceMetrics: resourceMetrics))
        XCTAssertEqual(batch.samples.map(\.value), [5, 3, 9, 1, 8, 2, 7])
    }

    // MARK: - Process starts

    private func sessionCountPoint(
        session: String? = "11111111-1111-4111-8111-111111111111",
        startType: String? = "fresh",
        startNs: Any? = "1791183405041000000",
        timeNs: Any? = "1791183410039000000"
    ) -> [String: Any] {
        var attributes = Fixtures.attributes([
            "user.id": "fixture-user-id-0000000000000000",
            "organization.id": "00000000-0000-4000-8000-0000000000aa",
            "user.email": "fixture@example.invalid",
            "terminal.type": "xterm-256color",
        ])
        if let session { attributes.append(Fixtures.stringAttribute("session.id", session)) }
        if let startType { attributes.append(Fixtures.stringAttribute("start_type", startType)) }
        var point: [String: Any] = ["attributes": attributes, "asDouble": 1.0]
        point["startTimeUnixNano"] = startNs
        point["timeUnixNano"] = timeNs
        return point
    }

    private func decodeSessionCount(_ points: [[String: Any]], temporality: Any? = 2) throws -> OTLPTokenUsageBatch {
        try OTLPTokenUsageDecoder.decode(try Fixtures.body(metrics: [
            Fixtures.metric(name: "claude_code.session.count", temporality: temporality, points: points),
        ]))
    }

    private let freshStart = UsageProcessStart(
        sessionID: "11111111-1111-4111-8111-111111111111", startNs: 1_791_183_405_041_000_000, startType: "fresh")

    func test_processStarts_eachFixtureRunHasOneStart_beforeEverySeries_withItsStartType() throws {
        let expected: [(String, String, Int64)] = [
            ("run1", "fresh", 1_791_183_405_041_000_000),
            ("run2", "fresh", 1_791_183_586_797_000_000),
            ("run3", "resume", 1_791_183_681_268_000_000),
            ("run4", "fresh", 1_791_183_710_265_000_000),
        ]
        for (run, startType, startNs) in expected {
            var starts: [UsageProcessStart] = []
            var sampleStarts: [Int64] = []
            for body in try Fixtures.exports(run: run) {
                let batch = try OTLPTokenUsageDecoder.decode(body)
                XCTAssertEqual(batch.processStarts.count, 1, "\(run): one start per export")
                for start in batch.processStarts where !starts.contains(start) {
                    starts.append(start)
                }
                sampleStarts += batch.samples.map(\.startNs)
            }
            let start = try XCTUnwrap(starts.first, run)
            XCTAssertEqual(starts.count, 1, "\(run): \(starts)")
            XCTAssertEqual(start.startType, startType, run)
            XCTAssertEqual(start.startNs, startNs, run)
            XCTAssertFalse(sampleStarts.isEmpty, run)
            XCTAssertTrue(sampleStarts.allSatisfy { $0 > start.startNs }, run)
        }
    }

    func test_processStarts_resumeHasTheSameSessionAsTheRunItResumes() throws {
        let run2 = try OTLPTokenUsageDecoder.decode(try XCTUnwrap(try Fixtures.exports(run: "run2").first))
        let run3 = try OTLPTokenUsageDecoder.decode(try XCTUnwrap(try Fixtures.exports(run: "run3").first))
        XCTAssertEqual(run2.processStarts.map(\.sessionID), ["22222222-2222-4222-8222-222222222222"])
        XCTAssertEqual(run3.processStarts.map(\.sessionID), ["22222222-2222-4222-8222-222222222222"])
    }

    func test_processStarts_sessionCountNeverProducesSamples() throws {
        var point = sessionCountPoint()
        var attributes = point["attributes"] as? [[String: Any]] ?? []
        attributes.append(Fixtures.stringAttribute("type", "input"))
        attributes.append(Fixtures.stringAttribute("model", "claude-sonnet-5-5"))
        point["attributes"] = attributes
        point["asDouble"] = 5000.0
        let batch = try decodeSessionCount([point])
        XCTAssertEqual(batch, OTLPTokenUsageBatch(
            samples: [], processStarts: [freshStart], skipped: OTLPTokenUsageBatch.Skipped()))
    }

    func test_processStarts_sameSessionAndStart_collapseToOne() throws {
        let batch = try decodeSessionCount([
            sessionCountPoint(timeNs: "1791183410039000000"),
            sessionCountPoint(timeNs: "1791183415040000000"),
        ])
        XCTAssertEqual(batch.processStarts, [freshStart])
    }

    func test_processStarts_sameStartInTwoMetricsOfOneExport_collapseToOne() throws {
        let body = try Fixtures.body(resourceMetrics: [
            ["scopeMetrics": [["metrics": [Fixtures.metric(name: "claude_code.session.count", points: [sessionCountPoint()])]]]],
            ["scopeMetrics": [["metrics": [Fixtures.metric(name: "claude_code.session.count", points: [sessionCountPoint()])]]]],
        ])
        XCTAssertEqual(try OTLPTokenUsageDecoder.decode(body).processStarts, [freshStart])
    }

    func test_processStarts_differentStartsOrSessions_areKeptApart() throws {
        let batch = try decodeSessionCount([
            sessionCountPoint(),
            sessionCountPoint(startType: "resume", startNs: "1791183681268000000"),
            sessionCountPoint(session: "22222222-2222-4222-8222-222222222222"),
        ])
        let sorted = batch.processStarts.sorted { ($0.sessionID, $0.startNs) < ($1.sessionID, $1.startNs) }
        XCTAssertEqual(sorted, [
            freshStart,
            UsageProcessStart(sessionID: "11111111-1111-4111-8111-111111111111", startNs: 1_791_183_681_268_000_000, startType: "resume"),
            UsageProcessStart(sessionID: "22222222-2222-4222-8222-222222222222", startNs: 1_791_183_405_041_000_000, startType: "fresh"),
        ])
    }

    func test_processStarts_invalidOrMissingStartType_isNil_andTheStartIsKept() throws {
        for startType in ["re sume", "<fresh>", "", nil] as [String?] {
            let batch = try decodeSessionCount([sessionCountPoint(startType: startType)])
            XCTAssertEqual(batch.processStarts, [
                UsageProcessStart(sessionID: freshStart.sessionID, startNs: freshStart.startNs, startType: nil),
            ], String(describing: startType))
        }
    }

    func test_processStarts_startAsJSONNumber_isAccepted_andTimeAndValueAreNotNeeded() throws {
        var point = sessionCountPoint(startNs: NSNumber(value: Int64(1_791_183_405_041_000_001)), timeNs: nil)
        point["asDouble"] = nil
        let batch = try decodeSessionCount([point])
        XCTAssertEqual(batch.processStarts, [
            UsageProcessStart(sessionID: freshStart.sessionID, startNs: 1_791_183_405_041_000_001, startType: "fresh"),
        ])
    }

    func test_processStarts_withoutValidSessionOrStart_areDropped() throws {
        let points: [(String, [String: Any])] = [
            ("no session", sessionCountPoint(session: nil)),
            ("invalid session", sessionCountPoint(session: "not valid")),
            ("no start", sessionCountPoint(startNs: nil)),
            ("negative start", sessionCountPoint(startNs: "-1")),
            ("start above Int64.max", sessionCountPoint(startNs: "9223372036854775808")),
            ("start not digits", sessionCountPoint(startNs: "soon")),
        ]
        for (name, point) in points {
            let batch = try decodeSessionCount([point])
            XCTAssertEqual(batch, OTLPTokenUsageBatch(
                samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()), name)
        }
    }

    func test_processStarts_nonCumulativeSessionCount_yieldsNone_andIsNotCounted() throws {
        for temporality in [1, "AGGREGATION_TEMPORALITY_DELTA", nil] as [Any?] {
            let batch = try decodeSessionCount([sessionCountPoint()], temporality: temporality)
            XCTAssertEqual(batch, OTLPTokenUsageBatch(
                samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped()), String(describing: temporality))
        }
        let string = try decodeSessionCount([sessionCountPoint()], temporality: "AGGREGATION_TEMPORALITY_CUMULATIVE")
        XCTAssertEqual(string.processStarts, [freshStart])
    }

    func test_processStarts_sessionCountAsGauge_isIgnored() throws {
        let gauge: [String: Any] = ["name": "claude_code.session.count", "gauge": ["dataPoints": [sessionCountPoint()]]]
        XCTAssertEqual(try OTLPTokenUsageDecoder.decode(try Fixtures.body(metrics: [gauge])).processStarts, [])
    }

    func test_processStarts_costUsageWithAStartType_yieldsNone() throws {
        let body = try Fixtures.body(metrics: [Fixtures.metric(name: "claude_code.cost.usage", points: [sessionCountPoint()])])
        XCTAssertEqual(try OTLPTokenUsageDecoder.decode(body).processStarts, [])
    }

    // MARK: - Series identity

    func test_seriesID_is64LowercaseHex() throws {
        let id = try seriesID(attributes: baseAttributes())
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) }, id)
    }

    func test_seriesID_isIndependentOfAttributeOrder() throws {
        let attributes = baseAttributes()
        XCTAssertEqual(try seriesID(attributes: attributes), try seriesID(attributes: attributes.reversed()))
        let rotated = Array(attributes.dropFirst(3) + attributes.prefix(3))
        XCTAssertEqual(try seriesID(attributes: attributes), try seriesID(attributes: rotated))
    }

    func test_seriesID_isUnchangedWhenOnlyPersonalAttributesChange() throws {
        let base = try seriesID(attributes: baseAttributes())
        var changed = replacing("user.email", with: "someone@example.invalid", in: baseAttributes())
        changed = replacing("user.id", with: "another-user", in: changed)
        changed = replacing("organization.id", with: "another-org", in: changed)
        changed = replacing("session.id", with: "33333333-3333-4333-8333-333333333333", in: changed)
        changed.append(Fixtures.stringAttribute("user.account_uuid", "acct-uuid"))
        changed.append(Fixtures.stringAttribute("user.account_id", "acct-id"))
        XCTAssertEqual(try seriesID(attributes: changed), base)

        var stripped = baseAttributes()
        for key in ["user.email", "user.id", "organization.id"] {
            stripped = removing(key, from: stripped)
        }
        XCTAssertEqual(try seriesID(attributes: stripped), base)
    }

    func test_seriesID_eachPersonalKeyAlone_doesNotChangeIt() throws {
        let base = try seriesID(attributes: baseAttributes())
        for key in ["user.email", "user.id", "user.account_uuid", "user.account_id", "organization.id"] {
            let attributes = removing(key, from: baseAttributes()) + [Fixtures.stringAttribute(key, "changed-\(key)")]
            XCTAssertEqual(try seriesID(attributes: attributes), base, key)
        }
        let otherSession = replacing("session.id", with: "33333333-3333-4333-8333-333333333333", in: baseAttributes())
        XCTAssertEqual(try seriesID(attributes: otherSession), base, "session.id")
    }

    func test_seriesID_differsWhenAnUnlistedAttributeIsAdded() throws {
        let base = try seriesID(attributes: baseAttributes())
        for key in ["speed", "user.name", "account", "session", "session.id.extra"] {
            let extra = try seriesID(attributes: baseAttributes() + [Fixtures.stringAttribute(key, "fast")])
            XCTAssertNotEqual(extra, base, key)
        }
    }

    func test_seriesID_differsWhenAnyOtherAttributeChanges() throws {
        let base = try seriesID(attributes: baseAttributes())
        let changes: [(String, String)] = [
            ("terminal.type", "vscode"), ("model", "claude-opus-5-5"), ("query_source", "subagent"),
            ("effort", "high"),
        ]
        for (key, value) in changes {
            XCTAssertNotEqual(try seriesID(attributes: replacing(key, with: value, in: baseAttributes())), base, key)
        }
        XCTAssertNotEqual(try seriesID(attributes: removing("effort", from: baseAttributes())), base, "effort removed")
        XCTAssertNotEqual(try seriesID(attributes: removing("terminal.type", from: baseAttributes())), base,
                          "terminal.type removed")
    }

    func test_seriesID_differsPerType() throws {
        let ids = try usageTelemetryKindNames.map { try seriesID(attributes: baseAttributes(type: $0)) }
        XCTAssertEqual(Set(ids).count, 4)
    }

    func test_seriesID_differsForInvalidLabelsThatMapToTheSameStoredLabel() throws {
        // Both models are stored as "unknown", but they are two series.
        let first = try seriesID(attributes: replacing("model", with: "bad model", in: baseAttributes()))
        let second = try seriesID(attributes: replacing("model", with: "other bad", in: baseAttributes()))
        XCTAssertNotEqual(first, second)
    }

    func test_seriesID_encodingIsUnambiguous() throws {
        let type = Fixtures.stringAttribute("type", "input")
        let session = Fixtures.stringAttribute("session.id", "11111111-1111-4111-8111-111111111111")
        func id(_ pairs: [(String, String)]) throws -> String {
            try seriesID(attributes: [type, session] + pairs.map { Fixtures.stringAttribute($0.0, $0.1) })
        }
        let pairs: [([(String, String)], [(String, String)])] = [
            ([("ab", "c")], [("a", "bc")]),
            ([("a", "b=c")], [("a=b", "c")]),
            ([("a", "b:c")], [("a:b", "c")]),
            ([("a", "b"), ("c", "d")], [("a", "b,c=d")]),
            ([("a", "b"), ("c", "d")], [("a", "b;c=d")]),
            ([("a", "b"), ("c", "d")], [("a", "b\nc=d")]),
            ([("a", "b"), ("c", "d")], [("a", "b\u{0}c\u{0}d")]),
            ([("a", "b"), ("c", "d")], [("a", "b|c|d")]),
            ([("a", "b"), ("c", "d")], [("a", "b\tc\td")]),
            ([("a", "b"), ("c", "d")], [("a", "b\",\"c\":\"d")]),
            ([("a", "")], [("a", " ")]),
            ([("a", "")], []),
        ]
        for (left, right) in pairs {
            XCTAssertNotEqual(try id(left), try id(right), "\(left) vs \(right)")
        }
    }
}
