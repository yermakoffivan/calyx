//
//  TranscriptLabelTests.swift
//  CalyxTests
//
//  Pins TranscriptLabel, the label rule for values read from Claude
//  Code's transcripts: `label(_:maxScalars:)` (edge whitespace trimmed;
//  an escaped-category scalar, an empty or over-long value or a
//  non-string rejected), `isCWD` / `isIdentifier` (verbatim only), and
//  the limits.
//

import XCTest
@testable import Calyx

final class TranscriptLabelTests: XCTestCase {

    func test_limits() {
        XCTAssertEqual(TranscriptLabel.cwdMaxScalars, 1_024)
        XCTAssertEqual(TranscriptLabel.identifierMaxScalars, 128)
    }

    func test_label_acceptsAndTrimsEdgeWhitespace() {
        XCTAssertEqual(TranscriptLabel.label("main", maxScalars: 8), "main")
        XCTAssertEqual(TranscriptLabel.label("  main\t", maxScalars: 8), "main")
        XCTAssertEqual(TranscriptLabel.label("\u{00A0}a b\u{3000}", maxScalars: 8), "a b")
        XCTAssertEqual(TranscriptLabel.label("日本語", maxScalars: 3), "日本語")
    }

    func test_label_rejects() {
        XCTAssertNil(TranscriptLabel.label(nil, maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label(12, maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("", maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("   ", maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("abcd", maxScalars: 3))
        XCTAssertNil(TranscriptLabel.label("a\u{1B}b", maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("a\tb", maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("a\u{202E}b", maxScalars: 8))
        XCTAssertNil(TranscriptLabel.label("\u{200B}main", maxScalars: 8))
    }

    /// The label rule never sees a single leading U+FEFF of a JSON string:
    /// JSONSerialization removes exactly one (raw bytes or the `\ufeff`
    /// escape alike), so "\u{FEFF}main" in a transcript is labelled "main",
    /// while a second leading BOM survives and is rejected as a format
    /// scalar. Cited by `TranscriptLabel.label`'s documentation.
    func test_label_singleLeadingBOM_isRemovedByJSONSerializationBeforeTheLabelRuleSeesIt() throws {
        func decoded(_ json: String) throws -> Any? {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            return object?["v"]
        }

        XCTAssertEqual(TranscriptLabel.label(try decoded("{\"v\":\"\u{FEFF}main\"}"), maxScalars: 8), "main")
        XCTAssertEqual(TranscriptLabel.label(try decoded(#"{"v":"\ufeffmain"}"#), maxScalars: 8), "main")
        XCTAssertNil(TranscriptLabel.label(try decoded("{\"v\":\"\u{FEFF}\u{FEFF}main\"}"), maxScalars: 8))
        // Handed over directly, the BOM is a format scalar and rejected.
        XCTAssertNil(TranscriptLabel.label("\u{FEFF}main", maxScalars: 8))
    }

    func test_isCWD_isVerbatimOnly_andBoundedAt1024Scalars() {
        XCTAssertTrue(TranscriptLabel.isCWD("/fixture/project"))
        XCTAssertTrue(TranscriptLabel.isCWD("/" + String(repeating: "a", count: 1_023)))
        XCTAssertFalse(TranscriptLabel.isCWD("/" + String(repeating: "a", count: 1_024)))
        XCTAssertFalse(TranscriptLabel.isCWD(" /fixture/project"))
        XCTAssertFalse(TranscriptLabel.isCWD("/fixture/project "))
        XCTAssertFalse(TranscriptLabel.isCWD("/a\u{7}b"))
        XCTAssertFalse(TranscriptLabel.isCWD(""))
    }

    func test_isIdentifier_isVerbatimOnly_andBoundedAt128Scalars() {
        XCTAssertTrue(TranscriptLabel.isIdentifier("11111111-2222-4333-8444-555555555555"))
        XCTAssertTrue(TranscriptLabel.isIdentifier(String(repeating: "a", count: 128)))
        XCTAssertFalse(TranscriptLabel.isIdentifier(String(repeating: "a", count: 129)))
        XCTAssertFalse(TranscriptLabel.isIdentifier(" abc"))
        XCTAssertFalse(TranscriptLabel.isIdentifier("abc\u{0}"))
        XCTAssertFalse(TranscriptLabel.isIdentifier(""))
    }
}
