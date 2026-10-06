//
//  UsageCardLineTests.swift
//  CalyxTests
//
//  Pins UsageCardLine, the one-line token summary a Mission Map card
//  shows for its Claude Code session, over the session's total
//  `UsageTokenTotals` (what Calyx received plus what it knows was not):
//  - compact(_:) at every tier boundary (plain, 1.0k-99.9k, 100k-999k,
//    then the same with M and B, whole billions with no upper limit),
//    truncating and never rounding up so a card never overstates usage,
//    and a negative value shown as 0
//  - text(for:): "<compact(output)> out \u{00B7} <compact(input +
//    cacheRead + cacheCreation)> in"; the sum saturates at Int64.max;
//    no U+2265 prefix for any input (the totals are not a lower bound)
//  - accessibilityLabel(for:) reads "Usage: <out> output tokens, <in>
//    input tokens", never "at least ", with the same compact numbers
//  - the output uses ASCII digits and "." only
//

import XCTest
@testable import Calyx

final class UsageCardLineTests: XCTestCase {

    private let atLeast = "\u{2265}"
    private let separator = " \u{00B7} "

    private func totals(
        input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheCreation: Int64 = 0
    ) -> UsageTokenTotals {
        UsageTokenTotals(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private func assertCompact(_ value: Int64, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(UsageCardLine.compact(value), expected, "compact(\(value))", file: file, line: line)
    }

    // MARK: - compact: below 1,000

    func test_compact_belowOneThousand_isThePlainNumber() {
        assertCompact(0, "0")
        assertCompact(7, "7")
        assertCompact(999, "999")
    }

    // MARK: - compact: thousands

    func test_compact_oneThousand_startsTheOneDecimalThousandsTier() {
        assertCompact(1_000, "1.0k")
    }

    /// 1,099 is 1.099k: one decimal truncates to 1.0k, a rounding
    /// formatter would say 1.1k.
    func test_compact_thousands_truncateTheDecimal() {
        assertCompact(1_099, "1.0k")
        assertCompact(1_100, "1.1k")
        assertCompact(1_999, "1.9k")
        assertCompact(45_250, "45.2k")
    }

    func test_compact_99999_staysInTheOneDecimalTier() {
        assertCompact(99_999, "99.9k")
    }

    func test_compact_oneHundredThousand_startsTheWholeThousandsTier() {
        assertCompact(100_000, "100k")
        assertCompact(199_999, "199k")
    }

    /// 999,999 must not round up into 1.0M.
    func test_compact_999999_isWholeThousandsTruncated() {
        assertCompact(999_999, "999k")
    }

    // MARK: - compact: millions

    func test_compact_oneMillion_startsTheOneDecimalMillionsTier() {
        assertCompact(1_000_000, "1.0M")
        assertCompact(1_099_999, "1.0M")
        assertCompact(1_999_999, "1.9M")
    }

    func test_compact_millionsTierBoundaries() {
        assertCompact(99_999_999, "99.9M")
        assertCompact(100_000_000, "100M")
        assertCompact(999_999_999, "999M")
    }

    // MARK: - compact: billions

    func test_compact_oneBillion_startsTheOneDecimalBillionsTier() {
        assertCompact(1_000_000_000, "1.0B")
        assertCompact(1_099_999_999, "1.0B")
    }

    func test_compact_billionsTierBoundaries() {
        assertCompact(99_999_999_999, "99.9B")
        assertCompact(100_000_000_000, "100B")
        assertCompact(999_999_999_999, "999B")
    }

    /// Whole billions have no upper tier: 1e12 is 1000B, not 1.0T.
    func test_compact_wholeBillions_haveNoUpperLimit() {
        assertCompact(1_000_000_000_000, "1000B")
        assertCompact(Int64.max, "9223372036B")
    }

    // MARK: - compact: negative

    func test_compact_negative_isZero() {
        assertCompact(-1, "0")
        assertCompact(-1_500, "0")
        assertCompact(Int64.min, "0")
    }

    // MARK: - compact: locale independence

    /// Whatever the user's locale, digits are ASCII and the decimal mark
    /// is ".", never "," or a grouping separator.
    func test_compact_usesOnlyAsciiDigitsAndDot() {
        let allowed = Set("0123456789.kMB")
        for value: Int64 in [0, 999, 1_234, 12_345, 123_456, 1_234_567, 12_345_678, 123_456_789, 1_234_567_890, Int64.max] {
            let text = UsageCardLine.compact(value)
            XCTAssertTrue(text.allSatisfy { allowed.contains($0) }, "compact(\(value)) = \(text)")
        }
    }

    // MARK: - text(for:)

    func test_text_documentedExample() {
        let line = UsageCardLine.text(for: totals(input: 1_000_000, output: 45_200, cacheRead: 200_000))
        XCTAssertEqual(line, "45.2k out \u{00B7} 1.2M in")
    }

    func test_text_plainNumbers() {
        let line = UsageCardLine.text(for: totals(input: 5, output: 42))
        XCTAssertEqual(line, "42 out" + separator + "5 in")
    }

    func test_text_allZero() {
        XCTAssertEqual(UsageCardLine.text(for: UsageTokenTotals()), "0 out" + separator + "0 in")
    }

    /// The totals are Claude Code's own count, not a lower bound: no
    /// input gives the U+2265 prefix (the old row's "some responses have
    /// no final line yet" has no counterpart here).
    func test_text_neverHasTheAtLeastPrefix() {
        let inputs: [UsageTokenTotals] = [
            UsageTokenTotals(),
            totals(input: 5, output: 42),
            totals(output: 0, cacheRead: 1),
            totals(input: 1_000_000, output: 45_200, cacheRead: 200_000),
            totals(input: Int64.max, output: Int64.max, cacheRead: Int64.max, cacheCreation: Int64.max),
            totals(input: -5, output: -1),
        ]
        for value in inputs {
            let line = UsageCardLine.text(for: value)
            XCTAssertFalse(line.contains(atLeast), "\(value): \(line)")
            XCTAssertTrue(line.hasSuffix(" in"), "\(value): \(line)")
            XCTAssertTrue(line.contains(" out" + separator), "\(value): \(line)")
        }
    }

    /// `in` is exactly input + cache read + cache creation: each part is
    /// distinct so dropping any one changes the number, and output is
    /// set so adding it shows.
    func test_text_input_sumsInputCacheReadAndCacheCreation() {
        let line = UsageCardLine.text(for: totals(input: 100, output: 9, cacheRead: 20, cacheCreation: 3))
        XCTAssertEqual(line, "9 out" + separator + "123 in")
    }

    func test_text_input_compactsTheSum() {
        let line = UsageCardLine.text(for: totals(input: 600, output: 1_500, cacheRead: 500, cacheCreation: 99))
        XCTAssertEqual(line, "1.5k out" + separator + "1.1k in")
    }

    func test_text_input_saturatesAtInt64Max() {
        let line = UsageCardLine.text(for: totals(input: Int64.max, output: 1, cacheRead: 1, cacheCreation: 0))
        XCTAssertEqual(line, "1 out" + separator + "9223372036B in")
    }

    func test_text_input_saturatesWhenTheThirdTermOverflows() {
        let line = UsageCardLine.text(for: totals(input: Int64.max - 1, output: 1, cacheRead: 1, cacheCreation: 1))
        XCTAssertEqual(line, "1 out" + separator + "9223372036B in")
    }

    func test_text_input_saturatesWithEveryPartAtMax() {
        let line = UsageCardLine.text(for: totals(
            input: Int64.max, output: Int64.max, cacheRead: Int64.max, cacheCreation: Int64.max
        ))
        XCTAssertEqual(line, "9223372036B out" + separator + "9223372036B in")
    }

    /// `out` is the output total alone, none of the input parts.
    func test_text_output_isTheOutputTotal() {
        let line = UsageCardLine.text(for: totals(input: 1, output: 999, cacheRead: 2, cacheCreation: 3))
        XCTAssertEqual(line, "999 out" + separator + "6 in")
    }

    // MARK: - accessibilityLabel(for:)

    func test_accessibilityLabel_documentedExample() {
        let label = UsageCardLine.accessibilityLabel(for: totals(input: 1_000_000, output: 45_200, cacheRead: 200_000))
        XCTAssertEqual(label, "Usage: 45.2k output tokens, 1.2M input tokens")
    }

    func test_accessibilityLabel_plainNumbers() {
        let label = UsageCardLine.accessibilityLabel(for: totals(input: 5, output: 42))
        XCTAssertEqual(label, "Usage: 42 output tokens, 5 input tokens")
    }

    func test_accessibilityLabel_allZero() {
        XCTAssertEqual(UsageCardLine.accessibilityLabel(for: UsageTokenTotals()), "Usage: 0 output tokens, 0 input tokens")
    }

    func test_accessibilityLabel_neverSaysAtLeast() {
        let inputs: [UsageTokenTotals] = [
            UsageTokenTotals(),
            totals(input: 5, output: 42),
            totals(input: 1_000_000, output: 45_200, cacheRead: 200_000),
            totals(input: Int64.max, output: Int64.max, cacheRead: Int64.max, cacheCreation: Int64.max),
        ]
        for value in inputs {
            let label = UsageCardLine.accessibilityLabel(for: value)
            XCTAssertFalse(label.contains("at least"), "\(value): \(label)")
            XCTAssertFalse(label.contains(atLeast), "\(value): \(label)")
            XCTAssertTrue(label.hasPrefix("Usage: "), "\(value): \(label)")
        }
    }

    /// Same three-part input sum and output as the card text.
    func test_accessibilityLabel_usesTheSameNumbersAsText() {
        let label = UsageCardLine.accessibilityLabel(for: totals(
            input: 600, output: 1_500, cacheRead: 500, cacheCreation: 99
        ))
        XCTAssertEqual(label, "Usage: 1.5k output tokens, 1.1k input tokens")
    }

    func test_accessibilityLabel_saturatedInput() {
        let label = UsageCardLine.accessibilityLabel(for: totals(
            input: Int64.max, output: 999_999, cacheRead: 1, cacheCreation: 1
        ))
        XCTAssertEqual(label, "Usage: 999k output tokens, 9223372036B input tokens")
    }
}
