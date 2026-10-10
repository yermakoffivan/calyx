// TerminalCellWidthTests.swift
// CalyxTests
//
// Per-scalar terminal cell width, matching ghostty v1.3.1 default path
// (mode 2027 off). Expected values are taken from the UCD property tables.

import Testing
@testable import Calyx

private func w(_ v: UInt32) -> Int {
    TerminalCellWidth.width(of: Unicode.Scalar(v)!)
}

private typealias CS = TerminalCellWidth.CellStart

@Suite("TerminalCellWidth")
struct TerminalCellWidthTests {

    // MARK: - width(of:)

    @Test func latin1IsOneIncludingSoftHyphenAndControls() {
        #expect(w(0x41) == 1)
        #expect(w(0x20) == 1)
        #expect(w(0xE9) == 1)
        #expect(w(0xAD) == 1)   // soft hyphen
        #expect(w(0x00) == 1)   // <= 0xFF rule comes first
        #expect(w(0x9F) == 1)
    }

    @Test func lineAndParagraphSeparatorsAreZero() {
        #expect(w(0x2028) == 0)
        #expect(w(0x2029) == 0)
    }

    @Test func defaultIgnorablesAreZero() {
        #expect(w(0x200D) == 0) // ZWJ
        #expect(w(0x200C) == 0) // ZWNJ
        #expect(w(0xFE0E) == 0) // VS15
        #expect(w(0xFE0F) == 0) // VS16
        #expect(w(0xE0067) == 0) // TAG LATIN SMALL LETTER G
        #expect(w(0x202E) == 0) // RLO
    }

    @Test func nonspacingAndEnclosingMarksAreZero() {
        #expect(w(0x0301) == 0)
        #expect(w(0x20E3) == 0)
        #expect(w(0x20DD) == 0)
    }

    @Test func hangulJamoVowelsAndTrailingConsonantsAreZero() {
        #expect(w(0x1160) == 0)
        #expect(w(0x11A7) == 0)
        #expect(w(0x11A8) == 0)
        #expect(w(0x11FF) == 0)
        #expect(w(0xD7B0) == 0)
        #expect(w(0xD7C6) == 0)
        #expect(w(0xD7CB) == 0)
        #expect(w(0xD7FB) == 0)
    }

    @Test func kiratRaiVowelsAreZero() {
        // GraphemeBreakProperty.txt (UCD 17.0.0): 16D63 ; V, 16D67..16D6A ; V
        #expect(w(0x16D63) == 0)
        #expect(w(0x16D67) == 0)
        #expect(w(0x16D6A) == 0)
    }

    @Test func hangulLeadingConsonantIsWide() {
        #expect(w(0x1100) == 2) // EAW W, GCB L
    }

    @Test func emojiModifiersAreTwo() {
        #expect(w(0x1F3FB) == 2)
        #expect(w(0x1F3FF) == 2)
    }

    @Test func prependIsOne() {
        #expect(w(0x0600) == 1)
    }

    @Test func eastAsianWideAndFullwidthAreTwo() {
        #expect(w(0x65E5) == 2) // 日
        #expect(w(0x3042) == 2) // あ
        #expect(w(0xAC00) == 2) // 가
        #expect(w(0xFF21) == 2) // Ａ
        #expect(w(0x1F600) == 2) // 😀
    }

    @Test func textPresentationEmojiIsOne() {
        #expect(w(0x2600) == 1) // ☀ EAW N
    }

    @Test func regionalIndicatorsAndTwoEmDashesAreTwo() {
        #expect(w(0x1F1E6) == 2)
        #expect(w(0x1F1FF) == 2)
        #expect(w(0x2E3A) == 2)
        #expect(w(0x2E3B) == 2)
    }

    @Test func ambiguousAndOtherAreOne() {
        #expect(w(0x2013) == 1)
        #expect(w(0x03B1) == 1) // α ambiguous
        #expect(w(0x0410) == 1) // А
    }

    // MARK: - cellStarts(in:)

    @Test func cellStartsEmpty() {
        #expect(TerminalCellWidth.cellStarts(in: "") == [])
    }

    @Test func cellStartsMixedWidth() {
        #expect(TerminalCellWidth.cellStarts(in: "a日b") == [
            CS(utf16Offset: 0, column: 0, width: 1),
            CS(utf16Offset: 1, column: 1, width: 2),
            CS(utf16Offset: 2, column: 3, width: 1),
        ])
    }

    @Test func cellStartsCombiningMarkAttachesToPrevious() {
        #expect(TerminalCellWidth.cellStarts(in: "e\u{301}x") == [
            CS(utf16Offset: 0, column: 0, width: 1),
            CS(utf16Offset: 2, column: 1, width: 1),
        ])
    }

    @Test func cellStartsZWJFamilyIsThreeWideCells() {
        #expect(TerminalCellWidth.cellStarts(in: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}") == [
            CS(utf16Offset: 0, column: 0, width: 2),
            CS(utf16Offset: 3, column: 2, width: 2),
            CS(utf16Offset: 6, column: 4, width: 2),
        ])
    }

    @Test func cellStartsSunWithVS16IsOneNarrowCell() {
        #expect(TerminalCellWidth.cellStarts(in: "\u{2600}\u{FE0F}") == [
            CS(utf16Offset: 0, column: 0, width: 1),
        ])
    }

    @Test func cellStartsFlagIsTwoWideCells() {
        #expect(TerminalCellWidth.cellStarts(in: "🇯🇵") == [
            CS(utf16Offset: 0, column: 0, width: 2),
            CS(utf16Offset: 2, column: 2, width: 2),
        ])
    }

    @Test func cellStartsKeycapIsOneNarrowCell() {
        #expect(TerminalCellWidth.cellStarts(in: "1\u{FE0F}\u{20E3}") == [
            CS(utf16Offset: 0, column: 0, width: 1),
        ])
    }
}
