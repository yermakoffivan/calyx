// OTLPTokenUsageDecoder.swift
// Calyx
//
// Decodes Claude Code's `claude_code.token.usage` metric from an OTLP/JSON
// metrics export (`ExportMetricsServiceRequest`) into per-series cumulative
// samples, plus the process starts announced by `claude_code.session.count`.
// The metric is the source of the usage ledger because Claude Code
// increments it in the same function that updates its own session totals,
// unlike the transcripts, which lack final usage for most subagent
// responses.
//
// Pure: no I/O, no clock. Nothing personal leaves the decoder: the series
// identity is a hash that excludes the personal attributes, and only the
// validated labels below are carried into a sample.

import CryptoKit
import Foundation

enum UsageTokenKind: String, Sendable, CaseIterable {
    case input, output, cacheRead, cacheCreation
}

/// One data point of one series: the series' cumulative token count at
/// `timeNs`.
struct UsageSeriesSample: Sendable, Equatable {
    /// Validated `session.id`.
    let sessionID: String
    /// Lowercase hex SHA-256 over the point's non-personal attributes.
    let seriesID: String
    /// `startTimeUnixNano`: when the series started counting.
    let startNs: Int64
    /// `timeUnixNano`.
    let timeNs: Int64
    let kind: UsageTokenKind
    /// Cumulative tokens since `startNs`, >= 0.
    let value: Int64
    /// `UsageLabel.model` of the attribute `model`.
    let model: String
    /// Validated attribute `effort`.
    let effort: String?
    /// Validated attribute `query_source` (main / subagent / auxiliary).
    let thread: String?
    /// Validated attribute `agent.name`.
    let agent: String?
}

/// One Claude Code process start, from the metric `claude_code.session.count`.
struct UsageProcessStart: Sendable, Equatable {
    /// Validated `session.id`.
    let sessionID: String
    /// The data point's `startTimeUnixNano`.
    let startNs: Int64
    /// Validated attribute `start_type`: fresh / resume / continue / agents_view.
    let startType: String?
}

struct OTLPTokenUsageBatch: Sendable, Equatable {
    struct Skipped: Sendable, Equatable {
        /// Points of a token.usage metric whose temporality is not cumulative.
        var nonCumulativePoints = 0
        /// No valid `session.id`.
        var missingSession = 0
        /// Value or timestamps missing / not representable.
        var malformedPoints = 0
        /// `type` missing or not one of the four kinds.
        var unknownKind = 0
    }

    var samples: [UsageSeriesSample]
    var processStarts: [UsageProcessStart]
    var skipped: Skipped
}

enum OTLPTokenUsageDecodeError: Error, Equatable {
    /// The body is not a JSON object.
    case undecodable
}

enum OTLPTokenUsageDecoder {
    static let metricName = "claude_code.token.usage"

    /// Announces a process start once, then is re-sent unchanged by every
    /// cumulative export of that process.
    private static let sessionCountMetricName = "claude_code.session.count"

    /// Never part of a series' identity: the session is stored in its own
    /// column, and the others are personal values that must not influence
    /// anything the store keeps.
    private static let excludedIdentityKeys: Set<String> = [
        "session.id", "user.email", "user.id", "user.account_uuid", "user.account_id", "organization.id",
    ]

    /// `AGGREGATION_TEMPORALITY_CUMULATIVE` as the proto enum number.
    private static let cumulativeNumber: Int64 = 2
    private static let cumulativeName = "AGGREGATION_TEMPORALITY_CUMULATIVE"

    /// 2^63 as a Double, the first value above Int64's range. Int64.max
    /// itself is not representable as a Double, so the bound is exclusive.
    private static let int64UpperBound = 9_223_372_036_854_775_808.0

    static func decode(_ body: Data) throws -> OTLPTokenUsageBatch {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw OTLPTokenUsageDecodeError.undecodable
            }
            root = object
        } catch {
            throw OTLPTokenUsageDecodeError.undecodable
        }

        var batch = OTLPTokenUsageBatch(samples: [], processStarts: [], skipped: OTLPTokenUsageBatch.Skipped())
        // The body comes from a network route, so duplicates are found in
        // constant time per point rather than by scanning the list.
        var seenStarts: Set<StartKey> = []
        for resource in elements(root["resourceMetrics"]) {
            for scope in elements(resource["scopeMetrics"]) {
                for metric in elements(scope["metrics"]) {
                    guard let name = metric["name"] as? String, let sum = metric["sum"] as? [String: Any] else {
                        continue
                    }
                    switch name {
                    case metricName:
                        decodeTokenUsage(sum, into: &batch)
                    case sessionCountMetricName:
                        decodeSessionCount(sum, into: &batch, seen: &seenStarts)
                    default:
                        continue
                    }
                }
            }
        }
        return batch
    }

    // MARK: - Metrics

    /// Identifies one process start within an export.
    private struct StartKey: Hashable {
        let sessionID: String
        let startNs: Int64
    }

    private static func decodeTokenUsage(_ sum: [String: Any], into batch: inout OTLPTokenUsageBatch) {
        let points = elements(sum["dataPoints"])
        // Summing a delta stream as if it were cumulative would produce
        // wrong totals, so it is refused, never guessed at.
        guard isCumulative(sum["aggregationTemporality"]) else {
            batch.skipped.nonCumulativePoints += points.count
            return
        }
        for point in points {
            let attributes = Attributes(point["attributes"])
            guard let kindName = attributes.string("type"), let kind = UsageTokenKind(rawValue: kindName) else {
                batch.skipped.unknownKind += 1
                continue
            }
            guard let sessionID = UsageLabel.validated(attributes.string("session.id")) else {
                batch.skipped.missingSession += 1
                continue
            }
            guard let value = pointValue(point),
                  let startNs = nonNegativeInt64(point["startTimeUnixNano"]),
                  let timeNs = nonNegativeInt64(point["timeUnixNano"]) else {
                batch.skipped.malformedPoints += 1
                continue
            }
            batch.samples.append(UsageSeriesSample(
                sessionID: sessionID,
                seriesID: seriesID(of: attributes),
                startNs: startNs,
                timeNs: timeNs,
                kind: kind,
                value: value,
                model: UsageLabel.model(attributes.string("model")),
                effort: UsageLabel.validated(attributes.string("effort")),
                thread: UsageLabel.validated(attributes.string("query_source")),
                agent: UsageLabel.validated(attributes.string("agent.name"))))
        }
    }

    /// Only the start matters: the value, `timeUnixNano` and the other
    /// attributes of the point are not used. A non-cumulative stream is
    /// ignored without being counted, since it carries no tokens.
    private static func decodeSessionCount(
        _ sum: [String: Any], into batch: inout OTLPTokenUsageBatch, seen: inout Set<StartKey>
    ) {
        guard isCumulative(sum["aggregationTemporality"]) else { return }
        for point in elements(sum["dataPoints"]) {
            let attributes = Attributes(point["attributes"])
            guard let sessionID = UsageLabel.validated(attributes.string("session.id")),
                  let startNs = nonNegativeInt64(point["startTimeUnixNano"]) else { continue }
            // Document order is kept and the first one wins.
            guard seen.insert(StartKey(sessionID: sessionID, startNs: startNs)).inserted else { continue }
            batch.processStarts.append(UsageProcessStart(
                sessionID: sessionID, startNs: startNs,
                startType: UsageLabel.validated(attributes.string("start_type"))))
        }
    }

    // MARK: - Fields

    /// The elements of a JSON array that are JSON objects; anything else
    /// (a missing field, a non-array, a non-object element) is skipped.
    private static func elements(_ value: Any?) -> [[String: Any]] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    /// The number 2 or the enum name; the string "2" is not the proto3
    /// JSON form of the enum and is refused.
    private static func isCumulative(_ value: Any?) -> Bool {
        if let name = value as? String { return name == cumulativeName }
        guard let number = value as? NSNumber, !isBoolean(number) else { return false }
        return wholeInt64(number) == cumulativeNumber
    }

    /// `asInt` (decimal string or JSON number) or else `asDouble` (JSON
    /// number), as a whole number in 0...Int64.max.
    private static func pointValue(_ point: [String: Any]) -> Int64? {
        if let asInt = point["asInt"] {
            return nonNegativeInt64(asInt)
        }
        guard let asDouble = point["asDouble"] as? NSNumber, !isBoolean(asDouble) else { return nil }
        return wholeInt64(asDouble).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// A decimal-digit string or a JSON number, whole and in 0...Int64.max.
    private static func nonNegativeInt64(_ value: Any?) -> Int64? {
        let parsed: Int64?
        if let string = value as? String {
            // Int64(_:) alone would also accept a leading "+" or "-".
            guard !string.isEmpty, string.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            parsed = Int64(string)
        } else if let number = value as? NSNumber, !isBoolean(number) {
            parsed = wholeInt64(number)
        } else {
            parsed = nil
        }
        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }

    /// The exact Int64 a JSON number stands for, or nil when it is
    /// fractional, non-finite or outside Int64's range. Floating values
    /// are range-checked before conversion so the conversion cannot trap.
    private static func wholeInt64(_ number: NSNumber) -> Int64? {
        switch String(cString: number.objCType) {
        case "d", "f":
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(.towardZero),
                  double >= -int64UpperBound, double < int64UpperBound else { return nil }
            return Int64(double)
        case "Q", "L", "I", "S", "C":
            let unsigned = number.uint64Value
            guard unsigned <= UInt64(Int64.max) else { return nil }
            return Int64(unsigned)
        default:
            return number.int64Value
        }
    }

    /// JSONSerialization returns JSON booleans as NSNumber too; they are
    /// never a count or a timestamp.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Attributes

    /// A data point's `attributes` list. Lookups use the first attribute
    /// with a given key; labels are read only from `stringValue`.
    private struct Attributes {
        /// Every well-formed attribute (a string key), in document order.
        let entries: [(key: String, value: Any?)]

        init(_ value: Any?) {
            entries = OTLPTokenUsageDecoder.elements(value).compactMap { attribute in
                guard let key = attribute["key"] as? String else { return nil }
                return (key, attribute["value"])
            }
        }

        func string(_ key: String) -> String? {
            guard let entry = entries.first(where: { $0.key == key }) else { return nil }
            return (entry.value as? [String: Any])?["stringValue"] as? String
        }
    }

    /// SHA-256 over a canonical encoding of every attribute but the
    /// excluded ones. Each attribute is encoded as its key followed by its
    /// whole `value` object, with a type tag and a length or terminator on
    /// every part (see `CanonicalEncoder`), so no two different attribute
    /// sets share an encoding. The encoded attributes are sorted by key
    /// (then by their encoding, which orders duplicate keys), so the order
    /// in the JSON does not matter; duplicates are all kept.
    private static func seriesID(of attributes: Attributes) -> String {
        let encoded = attributes.entries
            .filter { !excludedIdentityKeys.contains($0.key) }
            .map { entry -> (key: String, bytes: [UInt8]) in
                var encoder = CanonicalEncoder()
                encoder.encodeString(entry.key)
                encoder.encode(entry.value)
                return (entry.key, encoder.bytes)
            }
            .sorted { lhs, rhs in
                // Keys are compared by their UTF-8 bytes throughout: String
                // `==` is canonical equivalence, and mixing it with a byte
                // order would not be a strict ordering, letting the result
                // depend on the input order.
                if !lhs.key.utf8.elementsEqual(rhs.key.utf8) {
                    return lhs.key.utf8.lexicographicallyPrecedes(rhs.key.utf8)
                }
                return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
            }
        var encoder = CanonicalEncoder()
        encoder.appendASCII("\(encoded.count):")
        for entry in encoded {
            encoder.bytes.append(contentsOf: entry.bytes)
        }
        return SHA256.hash(data: encoder.bytes).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// A prefix-free encoding of a JSON value tree: every value starts
    /// with a one-byte type tag; strings, arrays and objects carry their
    /// length before their content, numbers end with a terminator. Object
    /// members are sorted by key so key order never matters.
    private struct CanonicalEncoder {
        var bytes: [UInt8] = []

        mutating func appendASCII(_ text: String) {
            bytes.append(contentsOf: text.utf8)
        }

        mutating func encodeString(_ string: String) {
            appendASCII("s\(string.utf8.count):")
            bytes.append(contentsOf: string.utf8)
        }

        mutating func encode(_ value: Any?) {
            switch value {
            case nil:
                // The `value` field is absent.
                appendASCII("x")
            case let string as String:
                encodeString(string)
            case let number as NSNumber:
                if OTLPTokenUsageDecoder.isBoolean(number) {
                    appendASCII(number.boolValue ? "t" : "f")
                } else if ["d", "f"].contains(String(cString: number.objCType)) {
                    // By its exact bit pattern, so no two doubles collide.
                    appendASCII("d\(number.doubleValue.bitPattern);")
                } else if let integer = OTLPTokenUsageDecoder.wholeInt64(number) {
                    appendASCII("i\(integer);")
                } else {
                    // An unsigned integer above Int64.max.
                    appendASCII("q\(number.uint64Value);")
                }
            case let array as [Any]:
                appendASCII("a\(array.count):")
                for element in array {
                    encode(element)
                }
            case let object as [String: Any]:
                appendASCII("o\(object.count):")
                for key in object.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    encodeString(key)
                    encode(object[key])
                }
            case is NSNull:
                appendASCII("n")
            default:
                // JSONSerialization produces no other type.
                appendASCII("u")
            }
        }
    }
}
