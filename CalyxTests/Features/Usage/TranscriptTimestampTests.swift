//
//  TranscriptTimestampTests.swift
//  CalyxTests
//
//  Pins TranscriptTimestamp.epochMilliseconds(fromISO8601:), the parser
//  moved out of ClaudeTranscriptParser, and that the v1 name forwards to
//  it. Expected milliseconds were computed by hand (Python `datetime`,
//  UTC).
//

import XCTest
@testable import Calyx

final class TranscriptTimestampTests: XCTestCase {

    private let accepted: [(String, Int64)] = [
        ("1970-01-01T00:00:00Z", 0),
        ("1970-01-01T00:00:01.001Z", 1_001),
        ("2026-10-05T06:56:45.437Z", 1_791_183_405_437),
        ("2026-10-05T06:56:45Z", 1_791_183_405_000),
        // Digits beyond the third are truncated, not rounded.
        ("2026-10-05T06:56:45.4379Z", 1_791_183_405_437),
        ("2024-02-29T00:00:00.000Z", 1_709_164_800_000),
    ]

    private let rejected = [
        "", "2026-10-05", "2026-10-05 06:56:45Z", "2026-10-05T06:56:45", "2026-10-05T06:56:45+09:00",
        "2026-13-05T06:56:45Z", "2025-02-29T00:00:00Z", "2026-10-05T24:00:00Z", "2026-10-05T06:56:45.Z",
        "2026-10-05T06:56:45.4a7Z",
    ]

    func test_accepted_inputs_giveTheirEpochMilliseconds() {
        for (text, expected) in accepted {
            XCTAssertEqual(TranscriptTimestamp.epochMilliseconds(fromISO8601: text), expected, text)
        }
    }

    func test_rejected_inputs_areNil() {
        for text in rejected {
            XCTAssertNil(TranscriptTimestamp.epochMilliseconds(fromISO8601: text), text)
        }
    }

    func test_v1Forwarder_agreesForEveryInput() {
        for text in accepted.map(\.0) + rejected {
            XCTAssertEqual(ClaudeTranscriptParser.epochMilliseconds(fromISO8601: text),
                           TranscriptTimestamp.epochMilliseconds(fromISO8601: text), text)
        }
    }
}
