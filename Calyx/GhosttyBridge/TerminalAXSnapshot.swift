// TerminalAXSnapshot.swift
// Calyx
//
// UTF-16 text model of the terminal viewport for the AX text area.
// Rows are joined with "\n"; row index == viewport grid row index.
// Every API is in UTF-16 units, clamps its inputs, and never traps
// (including on `.empty`).

import Foundation

struct TerminalAXSnapshot: Sendable, Equatable {

    struct Row: Sendable, Equatable {
        let text: String
        /// UTF-16 offset of the row's first unit in `TerminalAXSnapshot.text`.
        let utf16Start: Int
        /// UTF-16 length of `text` (excluding the joining "\n").
        let utf16Length: Int
        let cells: [TerminalCellWidth.CellStart]
    }

    /// Inclusive column span on one row.
    struct CellSpan: Sendable, Equatable {
        let row: Int
        let colStart: Int
        let colEnd: Int
    }

    let rows: [Row]
    let columns: Int
    let text: String
    let utf16Count: Int

    static let empty = TerminalAXSnapshot(rowTexts: [], columns: 0)

    /// Trailing empty rows are trimmed; interior empty rows are kept.
    init(rowTexts: [String], columns: Int) {
        var texts = rowTexts
        while let last = texts.last, last.isEmpty {
            texts.removeLast()
        }
        var built: [Row] = []
        built.reserveCapacity(texts.count)
        var offset = 0
        for (i, t) in texts.enumerated() {
            let len = t.utf16.count
            built.append(Row(text: t, utf16Start: offset, utf16Length: len,
                             cells: TerminalCellWidth.cellStarts(in: t)))
            offset += len
            if i < texts.count - 1 { offset += 1 }
        }
        self.rows = built
        self.columns = columns
        self.text = texts.joined(separator: "\n")
        self.utf16Count = offset
    }

    // MARK: - Lines

    /// Line containing `index`; a row's "\n" belongs to that row.
    func line(forUTF16Index index: Int) -> Int {
        guard !rows.isEmpty else { return 0 }
        let i = clampIndex(index)
        var lo = 0
        var hi = rows.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rows[mid].utf16Start <= i { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of `line`, including its trailing "\n" except on the last line.
    func range(forLine line: Int) -> NSRange {
        guard !rows.isEmpty else { return NSRange(location: 0, length: 0) }
        let r = clampRow(line)
        let row = rows[r]
        let newline = r < rows.count - 1 ? 1 : 0
        return NSRange(location: row.utf16Start, length: row.utf16Length + newline)
    }

    /// Substring for `range` clipped to the text; nil if empty or out of range.
    func string(for range: NSRange) -> String? {
        guard range.location != NSNotFound else { return nil }
        let loc = clampIndex(range.location)
        let end = loc + min(max(0, range.length), utf16Count - loc)
        guard end > loc else { return nil }
        return (text as NSString).substring(with: NSRange(location: loc, length: end - loc))
    }

    // MARK: - Cells

    /// Cell at `index`. An index on the row's "\n" (or at the text end)
    /// maps to the column after the row's last cell.
    func cell(forUTF16Index index: Int) -> (row: Int, col: Int) {
        guard !rows.isEmpty else { return (0, 0) }
        let r = line(forUTF16Index: index)
        let row = rows[r]
        let off = clampIndex(index) - row.utf16Start
        if off >= row.utf16Length {
            return (r, Self.endColumn(of: row))
        }
        guard let c = Self.cellContaining(offset: off, in: row) else { return (r, 0) }
        return (r, c.column)
    }

    /// UTF-16 index of the cell at (`row`, `col`). A spacer-tail column maps
    /// to its wide cell; a column past the written text maps to the row end.
    func utf16Index(forCell row: Int, col: Int) -> Int {
        guard !rows.isEmpty else { return 0 }
        let rowData = rows[clampRow(row)]
        guard let i = Self.cellIndex(forColumn: col, in: rowData) else {
            return col < 0 ? rowData.utf16Start : rowData.utf16Start + rowData.utf16Length
        }
        return rowData.utf16Start + rowData.cells[i].utf16Offset
    }

    /// UTF-16 index just after the cell at (`row`, `col`) (including any
    /// attached zero-width scalars); the row end if past the written text.
    func utf16IndexAfterCell(row: Int, col: Int) -> Int {
        guard !rows.isEmpty else { return 0 }
        let rowData = rows[clampRow(row)]
        let rowEnd = rowData.utf16Start + rowData.utf16Length
        guard let i = Self.cellIndex(forColumn: max(0, col), in: rowData) else { return rowEnd }
        if i + 1 < rowData.cells.count {
            return rowData.utf16Start + rowData.cells[i + 1].utf16Offset
        }
        return rowEnd
    }

    // MARK: - Selection

    /// Converts ghostty's selection offsets (`offset_start = y*columns + x`,
    /// viewport relative; the last cell `offset_start + offset_len` is
    /// inclusive) into a UTF-16 range. Rows are clamped.
    func selectedRange(offsetStart: Int, offsetLen: Int) -> NSRange {
        guard !rows.isEmpty, columns > 0 else { return NSRange(location: 0, length: 0) }
        let s = max(0, offsetStart)
        let e = s + min(max(0, offsetLen), Int.max - s)
        let start = utf16Index(forCell: s / columns, col: s % columns)
        let end = utf16IndexAfterCell(row: e / columns, col: e % columns)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Inclusive column spans per row covered by `range`. An empty range
    /// yields the caret cell; a "\n" maps to its row's last cell.
    func cellSpans(forUTF16Range range: NSRange) -> [CellSpan] {
        guard !rows.isEmpty else { return [] }
        // Saturating: NSNotFound means "caret at end"; never add raw
        // caller-supplied values.
        let loc = range.location == NSNotFound ? utf16Count : clampIndex(range.location)
        let end = loc + min(max(0, range.length), utf16Count - loc)
        if end <= loc {
            let c = cell(forUTF16Index: loc)
            return [CellSpan(row: c.row, colStart: c.col, colEnd: c.col)]
        }
        let firstRow = line(forUTF16Index: loc)
        let lastRow = line(forUTF16Index: end - 1)
        var spans: [CellSpan] = []
        for r in firstRow...lastRow {
            let row = rows[r]
            let rowRange = self.range(forLine: r)
            let segStart = max(loc, rowRange.location) - row.utf16Start
            let segLast = min(end, rowRange.location + rowRange.length) - 1 - row.utf16Start
            guard segLast >= segStart else { continue }
            let a = Self.spanCell(offset: segStart, in: row)
            let b = Self.spanCell(offset: segLast, in: row)
            spans.append(CellSpan(row: r, colStart: a.column, colEnd: b.column + b.width - 1))
        }
        return spans
    }

    // MARK: - Helpers

    private func clampIndex(_ i: Int) -> Int { min(max(0, i), utf16Count) }
    private func clampRow(_ r: Int) -> Int { min(max(0, r), rows.count - 1) }

    private static func endColumn(of row: Row) -> Int {
        guard let last = row.cells.last else { return 0 }
        return last.column + last.width
    }

    /// Last cell starting at or before `offset`; the first cell if `offset`
    /// precedes it (leading zero-width scalar); nil for a row without cells.
    private static func cellContaining(offset: Int, in row: Row) -> TerminalCellWidth.CellStart? {
        guard let first = row.cells.first else { return nil }
        var found = first
        for c in row.cells {
            if c.utf16Offset <= offset { found = c } else { break }
        }
        return found
    }

    /// Cell used for frame spans: a "\n" (offset past the text) maps to the
    /// row's last cell; a row without cells maps to column 0.
    private static func spanCell(offset: Int, in row: Row) -> TerminalCellWidth.CellStart {
        let fallback = TerminalCellWidth.CellStart(utf16Offset: 0, column: 0, width: 1)
        if offset >= row.utf16Length { return row.cells.last ?? fallback }
        return cellContaining(offset: offset, in: row) ?? fallback
    }

    /// Index into `row.cells` of the cell covering `col`.
    private static func cellIndex(forColumn col: Int, in row: Row) -> Int? {
        guard col >= 0 else { return nil }
        return row.cells.firstIndex { col >= $0.column && col < $0.column + $0.width }
    }
}
