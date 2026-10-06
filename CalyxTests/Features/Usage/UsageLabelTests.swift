//
//  UsageLabelTests.swift
//  CalyxTests
//
//  Pins UsageLabel, the one rule every label arriving from the telemetry
//  wire (model, effort, thread, agent, session id) passes before it is
//  stored, shown in the UI or returned to an agent: 1...128 Unicode
//  scalars, each an ASCII letter, an ASCII digit, or one of - _ . : @ / [ ].
//

import XCTest
@testable import Calyx

final class UsageLabelTests: XCTestCase {

    // MARK: - Constants

    func test_maxScalars_is128() {
        XCTAssertEqual(UsageLabel.maxScalars, 128)
    }

    func test_unknownModel_isUnknown() {
        XCTAssertEqual(UsageLabel.unknownModel, "unknown")
    }

    // MARK: - Valid labels

    func test_isValid_realModelEffortThreadAgentAndSessionLabels() {
        let valid = [
            "claude-sonnet-5-5",
            "claude-opus-5-5[1m]",
            "claude-haiku-4-5-20251001",
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            "claude-sonnet-4-5@20250929",
            "arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude",
            "xhigh",
            "Explore",
            "main",
            "subagent",
            "auxiliary",
            "11111111-1111-4111-8111-111111111111",
            "6F9619FF-8B86-D011-B42D-00C04FC964FF",
        ]
        for label in valid {
            XCTAssertTrue(UsageLabel.isValid(label), "Must be valid: \(label)")
        }
    }

    func test_isValid_everyAllowedCharacterAlone() {
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:@/[]"
        for character in allowed {
            XCTAssertTrue(UsageLabel.isValid(String(character)), "Must be valid alone: \(character)")
        }
    }

    // MARK: - Length, counted in Unicode scalars

    func test_isValid_emptyString_isInvalid() {
        XCTAssertFalse(UsageLabel.isValid(""))
    }

    func test_isValid_128Scalars_isValid() {
        let label = String(repeating: "a", count: 128)
        XCTAssertEqual(label.unicodeScalars.count, 128, "Fixture error")
        XCTAssertTrue(UsageLabel.isValid(label))
    }

    func test_isValid_129Scalars_isInvalid() {
        let label = String(repeating: "a", count: 129)
        XCTAssertFalse(UsageLabel.isValid(label))
    }

    func test_isValid_128MixedAllowedScalars_isValid_and129_isInvalid() {
        let unit = "a-_.:@/[]0Z" // 11 scalars
        let long = String(repeating: unit, count: 12) // 132
        let exactly128 = String(long.prefix(128))
        let exactly129 = String(long.prefix(129))
        XCTAssertEqual(exactly128.unicodeScalars.count, 128, "Fixture error")
        XCTAssertEqual(exactly129.unicodeScalars.count, 129, "Fixture error")
        XCTAssertTrue(UsageLabel.isValid(exactly128))
        XCTAssertFalse(UsageLabel.isValid(exactly129))
    }

    // MARK: - Invalid characters

    func test_isValid_anyForbiddenASCIICharacter_isInvalid_aloneAndEmbedded() {
        let forbidden: [String] = [
            " ", "\"", "\\", "<", ">", ",", ";", "(", ")", "{", "}", "#", "%", "+", "=", "*", "?", "!",
            "|", "'", "`", "~", "$", "&", "^",
        ]
        for character in forbidden {
            XCTAssertFalse(UsageLabel.isValid(character), "Must be invalid alone: \(character.debugDescription)")
            XCTAssertFalse(UsageLabel.isValid("abc\(character)def"),
                           "Must be invalid embedded: \(character.debugDescription)")
            XCTAssertFalse(UsageLabel.isValid("abc\(character)"),
                           "Must be invalid at the end: \(character.debugDescription)")
            XCTAssertFalse(UsageLabel.isValid("\(character)abc"),
                           "Must be invalid at the start: \(character.debugDescription)")
        }
    }

    func test_isValid_spaces_areInvalid() {
        for label in ["claude sonnet", " claude", "claude ", "a\u{00A0}b", "a\u{3000}b"] {
            XCTAssertFalse(UsageLabel.isValid(label), "Must be invalid: \(label.debugDescription)")
        }
    }

    func test_isValid_controlCharacters_areInvalid() {
        for label in ["a\nb", "a\rb", "a\tb", "a\u{0}b", "a\u{7F}b", "a\u{1B}b", "\u{0}", "a\u{85}b"] {
            XCTAssertFalse(UsageLabel.isValid(label), "Must be invalid: \(label.debugDescription)")
        }
    }

    func test_isValid_nonASCIILetters_areInvalid() {
        let labels = [
            "café",              // precomposed é
            "cafe\u{0301}",      // e + combining acute accent
            "\u{FF41}bc",        // full-width a
            "\u{FF21}BC",        // full-width A
            "model\u{FF11}",     // full-width digit 1
            "\u{0430}bc",        // Cyrillic a
            "\u{03B1}",          // Greek alpha
            "モデル",
            "a\u{200B}b",        // zero-width space
            "a\u{FF0D}b",        // full-width hyphen
            "a\u{2010}b",        // Unicode hyphen
            "a\u{FF3B}b",        // full-width [
        ]
        for label in labels {
            XCTAssertFalse(UsageLabel.isValid(label), "Must be invalid: \(label.debugDescription)")
        }
    }

    // MARK: - validated

    func test_validated_validString_isReturnedUnchanged() {
        XCTAssertEqual(UsageLabel.validated("claude-opus-5-5[1m]"), "claude-opus-5-5[1m]")
        XCTAssertEqual(UsageLabel.validated("Explore"), "Explore")
    }

    func test_validated_nil_isNil() {
        XCTAssertNil(UsageLabel.validated(nil))
    }

    func test_validated_invalidStrings_areNil() {
        XCTAssertNil(UsageLabel.validated(""))
        XCTAssertNil(UsageLabel.validated("has space"))
        XCTAssertNil(UsageLabel.validated("café"))
        XCTAssertNil(UsageLabel.validated(String(repeating: "a", count: 129)))
    }

    // MARK: - model

    func test_model_validString_isReturnedUnchanged() {
        XCTAssertEqual(UsageLabel.model("claude-sonnet-5-5"), "claude-sonnet-5-5")
        XCTAssertEqual(UsageLabel.model("us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
                       "us.anthropic.claude-sonnet-4-5-20250929-v1:0")
    }

    func test_model_nilEmptyOrInvalid_isUnknown() {
        XCTAssertEqual(UsageLabel.model(nil), "unknown")
        XCTAssertEqual(UsageLabel.model(""), "unknown")
        XCTAssertEqual(UsageLabel.model("claude <opus>"), "unknown")
        XCTAssertEqual(UsageLabel.model(String(repeating: "m", count: 129)), "unknown")
    }
}
