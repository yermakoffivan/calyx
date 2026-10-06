//
//  UsageTelemetryFixtureSupport.swift
//  CalyxTests
//
//  What the token-telemetry tests share: the sanitized captures of real
//  Claude Code OTLP/JSON metric exports in
//  `CalyxTests/Fixtures/UsageTelemetry/` (loaded from the source tree via
//  `#filePath`, never bundled), the totals each capture's README states,
//  an INDEPENDENT reader of the token points (plain JSONSerialization, so
//  expected values never come from the decoder under test), builders for
//  synthetic export bodies, and an adjustable clock.
//
//  Nothing here reads ~/.claude, Application Support or UserDefaults.
//

import os
import XCTest
@testable import Calyx

/// The four token kinds by their wire names, in a fixed order.
let usageTelemetryKindNames = ["input", "output", "cacheRead", "cacheCreation"]

/// The personal values the captures still carry (replaced by sentinels).
let usageTelemetrySentinels = [
    "fixture@example.invalid",
    "fixture-user-id-0000000000000000",
    "00000000-0000-4000-8000-0000000000aa",
]

/// The attribute keys that never take part in a series' identity.
let usageTelemetryPersonalKeys: Set<String> = [
    "session.id", "user.email", "user.id", "user.account_uuid", "user.account_id", "organization.id",
]

enum UsageTelemetryFixtureError: Error {
    case missing(String)
    case unexpectedShape(String)
}

/// Totals keyed by model, then by wire kind name.
typealias UsageTotalsByModel = [String: [String: Int64]]

/// One `claude_code.token.usage` data point as read by the test's own
/// reader.
struct UsageRawTokenPoint: Equatable {
    let startNs: Int64
    let timeNs: Int64
    let value: Int64
    let attributes: [String: String]

    var sessionID: String { attributes["session.id"] ?? "" }
    var model: String { attributes["model"] ?? "" }
    var kind: String { attributes["type"] ?? "" }

    /// Identity of the series, built by the test: every non-personal
    /// attribute sorted by key, plus the session and the start time.
    var seriesKey: String {
        let identity = attributes
            .filter { !usageTelemetryPersonalKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key.count):\($0.key)=\($0.value.count):\($0.value)" }
            .joined(separator: ";")
        return "\(sessionID)|\(startNs)|\(identity)"
    }
}

enum UsageTelemetryFixtures {
    /// `CalyxTests/Fixtures/UsageTelemetry`, found from this file's path.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Usage/
            .deletingLastPathComponent() // Features/
            .deletingLastPathComponent() // CalyxTests/
            .appendingPathComponent("Fixtures/UsageTelemetry", isDirectory: true)
    }

    /// The export bodies of one run, in arrival order (by file name).
    static func exportURLs(run: String) throws -> [URL] {
        let runDirectory = directory.appendingPathComponent(run, isDirectory: true)
        guard FileManager.default.fileExists(atPath: runDirectory.path) else {
            throw UsageTelemetryFixtureError.missing(runDirectory.path)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: runDirectory.path)
            .filter { $0.hasPrefix("export-") && $0.hasSuffix(".json") }
            .sorted()
        guard !names.isEmpty else { throw UsageTelemetryFixtureError.missing("exports of \(run)") }
        return names.map { runDirectory.appendingPathComponent($0) }
    }

    static func exports(run: String) throws -> [Data] {
        try exportURLs(run: run).map { try Data(contentsOf: $0) }
    }

    /// `expected-cost-state.json` of a run, restricted to the four kinds
    /// (its `thinking` entry is not a token kind of the metric).
    static func expectedTotals(run: String) throws -> UsageTotalsByModel {
        let url = directory.appendingPathComponent(run, isDirectory: true)
            .appendingPathComponent("expected-cost-state.json")
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        guard let models = object as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape(url.path)
        }
        var totals: UsageTotalsByModel = [:]
        for (model, entry) in models {
            guard let kinds = entry as? [String: Any] else {
                throw UsageTelemetryFixtureError.unexpectedShape("\(url.path): \(model)")
            }
            var row: [String: Int64] = [:]
            for kind in usageTelemetryKindNames {
                guard let number = kinds[kind] as? NSNumber else {
                    throw UsageTelemetryFixtureError.unexpectedShape("\(url.path): \(model).\(kind)")
                }
                row[kind] = number.int64Value
            }
            totals[model] = row
        }
        return totals
    }

    /// When an export was collected: the largest `timeUnixNano` of any
    /// data point of any metric in it. Tests use it as the export's receive
    /// time (live, the two differ by milliseconds).
    static func collectionTimeNs(of body: Data) throws -> Int64 {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape("root")
        }
        var latest: Int64?
        for resource in root["resourceMetrics"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeMetrics"] as? [[String: Any]] ?? [] {
                for metric in scope["metrics"] as? [[String: Any]] ?? [] {
                    let points = (metric["sum"] as? [String: Any])?["dataPoints"] as? [[String: Any]] ?? []
                    for point in points {
                        guard let time = (point["timeUnixNano"] as? String).flatMap({ Int64($0) }) else { continue }
                        latest = max(latest ?? time, time)
                    }
                }
            }
        }
        guard let latest else { throw UsageTelemetryFixtureError.unexpectedShape("export without timestamps") }
        return latest
    }

    // MARK: Independent reader

    /// The token points of one export body, in document order. Throws on
    /// anything the captures are not expected to contain.
    static func rawTokenPoints(in body: Data) throws -> [UsageRawTokenPoint] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw UsageTelemetryFixtureError.unexpectedShape("root")
        }
        var points: [UsageRawTokenPoint] = []
        for resource in root["resourceMetrics"] as? [[String: Any]] ?? [] {
            for scope in resource["scopeMetrics"] as? [[String: Any]] ?? [] {
                for metric in scope["metrics"] as? [[String: Any]] ?? [] {
                    guard metric["name"] as? String == "claude_code.token.usage" else { continue }
                    guard let sum = metric["sum"] as? [String: Any],
                          let dataPoints = sum["dataPoints"] as? [[String: Any]] else {
                        throw UsageTelemetryFixtureError.unexpectedShape("token.usage without sum")
                    }
                    for point in dataPoints {
                        points.append(try rawPoint(point))
                    }
                }
            }
        }
        return points
    }

    private static func rawPoint(_ point: [String: Any]) throws -> UsageRawTokenPoint {
        guard let start = (point["startTimeUnixNano"] as? String).flatMap({ Int64($0) }),
              let time = (point["timeUnixNano"] as? String).flatMap({ Int64($0) }),
              let double = (point["asDouble"] as? NSNumber)?.doubleValue,
              double >= 0, double < 1e15, double == double.rounded(),
              let attributeList = point["attributes"] as? [[String: Any]] else {
            throw UsageTelemetryFixtureError.unexpectedShape("data point")
        }
        var attributes: [String: String] = [:]
        for attribute in attributeList {
            guard let key = attribute["key"] as? String,
                  let value = (attribute["value"] as? [String: Any])?["stringValue"] as? String else {
                throw UsageTelemetryFixtureError.unexpectedShape("attribute")
            }
            attributes[key] = value
        }
        return UsageRawTokenPoint(startNs: start, timeNs: time, value: Int64(double), attributes: attributes)
    }

    /// For each series (by the test's own key), the value of its LAST point
    /// across `exports`; then summed by model and kind.
    static func lastValueTotals(of exports: [[UsageRawTokenPoint]]) -> UsageTotalsByModel {
        var last: [String: UsageRawTokenPoint] = [:]
        for export in exports {
            for point in export {
                last[point.seriesKey] = point
            }
        }
        return sumByModel(last.values.map { ($0.model, $0.kind, $0.value) })
    }

    /// Sums `(model, kind, tokens)` entries; every model present gets all
    /// four kinds (0 when absent).
    static func sumByModel(_ entries: [(String, String, Int64)]) -> UsageTotalsByModel {
        var totals: UsageTotalsByModel = [:]
        for (model, kind, tokens) in entries {
            var row = totals[model] ?? Dictionary(uniqueKeysWithValues: usageTelemetryKindNames.map { ($0, Int64(0)) })
            // Never traps: an overflowing sum (only a broken store could
            // produce one) becomes Int64.min, which no expectation equals.
            let (sum, overflow) = (row[kind] ?? 0).addingReportingOverflow(tokens)
            row[kind] = overflow ? Int64.min : sum
            totals[model] = row
        }
        return totals
    }

    /// The store's rows summed by model, keyed like `expectedTotals`.
    static func totals(of rows: [UsagePointRow]) -> UsageTotalsByModel {
        sumByModel(rows.flatMap { row in
            [
                (row.model, "input", row.inputTokens),
                (row.model, "output", row.outputTokens),
                (row.model, "cacheRead", row.cacheReadTokens),
                (row.model, "cacheCreation", row.cacheCreationTokens),
            ]
        })
    }

    // MARK: Synthetic bodies

    static func stringAttribute(_ key: String, _ value: String) -> [String: Any] {
        ["key": key, "value": ["stringValue": value]]
    }

    static func attributes(_ pairs: KeyValuePairs<String, String>) -> [[String: Any]] {
        pairs.map { stringAttribute($0.key, $0.value) }
    }

    /// A data point in the captures' own shape: decimal-string timestamps
    /// and a whole-number `asDouble`.
    static func point(
        attributes: [[String: Any]],
        startNs: Int64 = 1_791_183_410_362_000_000,
        timeNs: Int64 = 1_791_183_415_040_000_000,
        asDouble: Double = 42
    ) -> [String: Any] {
        [
            "attributes": attributes,
            "startTimeUnixNano": String(startNs),
            "timeUnixNano": String(timeNs),
            "asDouble": asDouble,
        ]
    }

    static func metric(
        name: String = "claude_code.token.usage",
        temporality: Any? = 2,
        points: [[String: Any]]
    ) -> [String: Any] {
        var sum: [String: Any] = ["isMonotonic": true, "dataPoints": points]
        if let temporality { sum["aggregationTemporality"] = temporality }
        return ["name": name, "unit": "tokens", "sum": sum]
    }

    static func body(metrics: [[String: Any]]) throws -> Data {
        try body(resourceMetrics: [["resource": ["attributes": []], "scopeMetrics": [["metrics": metrics]]]])
    }

    static func body(resourceMetrics: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resourceMetrics": resourceMetrics])
    }
}

/// A clock a test can move. `now` is handed to the store.
final class UsageTestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ date: Date) { state = OSAllocatedUnfairLock(initialState: date) }

    func set(_ date: Date) { state.withLock { $0 = date } }

    var now: @Sendable () -> Date {
        { [state] in state.withLock { $0 } }
    }
}
