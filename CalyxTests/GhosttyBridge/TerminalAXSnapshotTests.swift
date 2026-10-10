// TerminalAXSnapshotTests.swift
// CalyxTests
//
// UTF-16 text model for the terminal AX text area.
//
// Fixture `s` (columns 4): rows "ab", "日c", "", "x" (two trailing empty rows trimmed).
//   text  = "ab\n日c\n\nx"
//   utf16 = a0 b1 \n2 日3 c4 \n5 \n6 x7  (count 8)
//   row utf16Start = 0, 3, 6, 7
//   row 1 cells: 日 col 0-1 (spacer tail col 1), c col 2

import Foundation
import Testing
@testable import Calyx

private let s = TerminalAXSnapshot(rowTexts: ["ab", "日c", "", "x", "", ""], columns: 4)
private typealias Span = TerminalAXSnapshot.CellSpan

@Suite("TerminalAXSnapshot")
struct TerminalAXSnapshotTests {

    // MARK: - Construction

    @Test func joinsRowsAndTrimsTrailingEmptyRowsOnly() {
        #expect(s.text == "ab\n日c\n\nx")
        #expect(s.utf16Count == 8)
        #expect(s.columns == 4)
        #expect(s.rows.map(\.text) == ["ab", "日c", "", "x"])
        #expect(s.rows.map(\.utf16Start) == [0, 3, 6, 7])
        #expect(s.rows[1].cells == TerminalCellWidth.cellStarts(in: "日c"))
    }

    @Test func allEmptyRowsYieldEmptyText() {
        let e = TerminalAXSnapshot(rowTexts: ["", ""], columns: 4)
        #expect(e.text == "")
        #expect(e.utf16Count == 0)
        #expect(e.rows.isEmpty)
    }

    // MARK: - line(forUTF16Index:)

    @Test func lineForIndex() {
        #expect(s.line(forUTF16Index: 0) == 0)
        #expect(s.line(forUTF16Index: 1) == 0)
        #expect(s.line(forUTF16Index: 2) == 0) // "\n" belongs to line it ends
        #expect(s.line(forUTF16Index: 3) == 1)
        #expect(s.line(forUTF16Index: 4) == 1)
        #expect(s.line(forUTF16Index: 5) == 1)
        #expect(s.line(forUTF16Index: 6) == 2)
        #expect(s.line(forUTF16Index: 7) == 3)
        #expect(s.line(forUTF16Index: 8) == 3) // == utf16Count
        #expect(s.line(forUTF16Index: 100) == 3)
        #expect(s.line(forUTF16Index: -5) == 0)
    }

    // MARK: - range(forLine:)

    @Test func rangeForLine() {
        #expect(s.range(forLine: 0) == NSRange(location: 0, length: 3))
        #expect(s.range(forLine: 1) == NSRange(location: 3, length: 3))
        #expect(s.range(forLine: 2) == NSRange(location: 6, length: 1))
        #expect(s.range(forLine: 3) == NSRange(location: 7, length: 1))
        #expect(s.range(forLine: 9) == NSRange(location: 7, length: 1))
        #expect(s.range(forLine: -1) == NSRange(location: 0, length: 3))
    }

    // MARK: - string(for:)

    @Test func stringForRange() {
        #expect(s.string(for: NSRange(location: 1, length: 3)) == "b\n日")
        #expect(s.string(for: NSRange(location: 6, length: 10)) == "\nx")
        #expect(s.string(for: NSRange(location: 0, length: 8)) == s.text)
        #expect(s.string(for: NSRange(location: 2, length: 0)) == nil)
        #expect(s.string(for: NSRange(location: 8, length: 1)) == nil)
        #expect(s.string(for: NSRange(location: 50, length: 2)) == nil)
    }

    // MARK: - cell(forUTF16Index:)

    @Test func cellForIndex() {
        #expect(s.cell(forUTF16Index: 0) == (0, 0))
        #expect(s.cell(forUTF16Index: 2) == (0, 2)) // on "\n": after last cell
        #expect(s.cell(forUTF16Index: 3) == (1, 0))
        #expect(s.cell(forUTF16Index: 4) == (1, 2)) // c after wide 日
        #expect(s.cell(forUTF16Index: 5) == (1, 3))
        #expect(s.cell(forUTF16Index: 7) == (3, 0))
    }

    @Test func cellForIndexOnTrailingSurrogate() {
        // a0, 😀 1-2, b3
        let e = TerminalAXSnapshot(rowTexts: ["a😀b"], columns: 5)
        #expect(e.cell(forUTF16Index: 1) == (0, 1))
        #expect(e.cell(forUTF16Index: 2) == (0, 1))
        #expect(e.cell(forUTF16Index: 3) == (0, 3))
        #expect(e.cell(forUTF16Index: 4) == (0, 4))
    }

    // MARK: - utf16Index(forCell:) / utf16IndexAfterCell

    @Test func utf16IndexForCell() {
        #expect(s.utf16Index(forCell: 0, col: 1) == 1)
        #expect(s.utf16Index(forCell: 1, col: 0) == 3)
        #expect(s.utf16Index(forCell: 1, col: 1) == 3) // spacer tail -> wide start
        #expect(s.utf16Index(forCell: 1, col: 2) == 4)
        #expect(s.utf16Index(forCell: 1, col: 3) == 5) // past last written -> row end
        #expect(s.utf16Index(forCell: 0, col: 3) == 2)
        #expect(s.utf16Index(forCell: 2, col: 0) == 6)
        #expect(s.utf16Index(forCell: 99, col: 0) == 7) // row clamped to 3
    }

    @Test func utf16IndexAfterCell() {
        #expect(s.utf16IndexAfterCell(row: 0, col: 0) == 1)
        #expect(s.utf16IndexAfterCell(row: 1, col: 0) == 4)
        #expect(s.utf16IndexAfterCell(row: 1, col: 1) == 4)
        #expect(s.utf16IndexAfterCell(row: 1, col: 2) == 5)
        #expect(s.utf16IndexAfterCell(row: 1, col: 3) == 5)
        #expect(s.utf16IndexAfterCell(row: 3, col: 0) == 8)
    }

    // MARK: - selectedRange(offsetStart:offsetLen:)

    @Test func selectedSingleCell() {
        #expect(s.selectedRange(offsetStart: 1, offsetLen: 0) == NSRange(location: 1, length: 1))
    }

    @Test func selectedAsciiSpanWithinRow() {
        #expect(s.selectedRange(offsetStart: 0, offsetLen: 1) == NSRange(location: 0, length: 2))
    }

    @Test func selectedSpanEndingOnWideChar() {
        // row 1, cols 0..1 -> whole 日
        #expect(s.selectedRange(offsetStart: 4, offsetLen: 1) == NSRange(location: 3, length: 1))
        #expect(s.selectedRange(offsetStart: 4, offsetLen: 0) == NSRange(location: 3, length: 1))
        #expect(s.selectedRange(offsetStart: 4, offsetLen: 2) == NSRange(location: 3, length: 2))
    }

    @Test func selectedSpanCrossingNewline() {
        // (0,3) .. (1,0): from row 0 end through 日
        #expect(s.selectedRange(offsetStart: 3, offsetLen: 1) == NSRange(location: 2, length: 2))
        #expect(s.string(for: s.selectedRange(offsetStart: 3, offsetLen: 1)) == "\n日")
    }

    @Test func selectedSpanPastWrittenText() {
        // row 0 cols 0..3; text is only "ab"
        #expect(s.selectedRange(offsetStart: 0, offsetLen: 3) == NSRange(location: 0, length: 2))
    }

    @Test func selectedRowsBeyondCountClamped() {
        #expect(s.selectedRange(offsetStart: 40, offsetLen: 0) == NSRange(location: 7, length: 1))
        #expect(s.selectedRange(offsetStart: 12, offsetLen: 30) == NSRange(location: 7, length: 1))
    }

    // MARK: - cellSpans(forUTF16Range:)

    @Test func cellSpansSingleRow() {
        #expect(s.cellSpans(forUTF16Range: NSRange(location: 0, length: 2)) == [Span(row: 0, colStart: 0, colEnd: 1)])
        #expect(s.cellSpans(forUTF16Range: NSRange(location: 3, length: 1)) == [Span(row: 1, colStart: 0, colEnd: 1)])
    }

    @Test func cellSpansMultiRow() {
        // "b\n日c": row 0 from b (the "\n" maps to the end of row 0, i.e. last cell col 1), row 1 cols 0..2
        #expect(s.cellSpans(forUTF16Range: NSRange(location: 1, length: 4)) == [
            Span(row: 0, colStart: 1, colEnd: 1),
            Span(row: 1, colStart: 0, colEnd: 2),
        ])
    }

    @Test func cellSpansEmptyRangeIsCaretCell() {
        #expect(s.cellSpans(forUTF16Range: NSRange(location: 4, length: 0)) == [Span(row: 1, colStart: 2, colEnd: 2)])
    }

    // MARK: - Empty snapshot

    @Test func emptySnapshotNeverTraps() {
        let e = TerminalAXSnapshot.empty
        #expect(e.text == "")
        #expect(e.utf16Count == 0)
        #expect(e.rows.isEmpty)
        #expect(e.line(forUTF16Index: 0) == 0)
        #expect(e.line(forUTF16Index: 5) == 0)
        #expect(e.range(forLine: 0) == NSRange(location: 0, length: 0))
        #expect(e.range(forLine: 3) == NSRange(location: 0, length: 0))
        #expect(e.string(for: NSRange(location: 0, length: 1)) == nil)
        #expect(e.cell(forUTF16Index: 3) == (0, 0))
        #expect(e.utf16Index(forCell: 2, col: 2) == 0)
        #expect(e.utf16IndexAfterCell(row: 2, col: 2) == 0)
        #expect(e.selectedRange(offsetStart: 5, offsetLen: 3) == NSRange(location: 0, length: 0))
        _ = e.cellSpans(forUTF16Range: NSRange(location: 0, length: 4))
    }

    @Test func stringForHugeLengthDoesNotOverflow() {
        #expect(s.string(for: NSRange(location: 0, length: Int.max)) == "ab\n日c\n\nx")
        #expect(s.string(for: NSRange(location: 7, length: Int.max)) == "x")
    }

    @Test func stringForNotFoundLocationIsNil() {
        #expect(s.string(for: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    @Test func cellSpansHugeLengthDoesNotOverflow() {
        let spans = s.cellSpans(forUTF16Range: NSRange(location: 7, length: Int.max))
        #expect(spans == [Span(row: 3, colStart: 0, colEnd: 0)])
    }

    @Test func cellSpansNotFoundLocationIsCaretAtEnd() {
        let spans = s.cellSpans(forUTF16Range: NSRange(location: NSNotFound, length: 1))
        #expect(spans == [Span(row: 3, colStart: 1, colEnd: 1)])
    }

    @Test func extremeIndicesDoNotTrap() {
        #expect(s.line(forUTF16Index: Int.max) == 3)
        #expect(s.line(forUTF16Index: Int.min) == 0)
        #expect(s.cell(forUTF16Index: Int.max).row == 3)
        #expect(s.range(forLine: Int.max) == NSRange(location: 7, length: 1))
        #expect(s.range(forLine: Int.min) == NSRange(location: 0, length: 3))
        _ = s.selectedRange(offsetStart: Int.max, offsetLen: Int.max)
    }
}
