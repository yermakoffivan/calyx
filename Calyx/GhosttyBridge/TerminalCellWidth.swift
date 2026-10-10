// TerminalCellWidth.swift
// Calyx
//
// Per-scalar terminal cell width matching ghostty v1.3.1's default print
// path (mode 2027 off): src/terminal/Terminal.zig:546 uses width 1 for
// `c <= 0xFF`, otherwise the uucode table width configured in
// src/build/uucode_config.zig:33-36 over uucode's
// src/x/config_x/wcwidth.zig compute().
//
// Deliberately code-point based (not grapheme based): the existing
// Character-level `unicodeDisplayWidth` treats emoji as width 1 and does
// not match ghostty's grid.

enum TerminalCellWidth {

    /// One terminal cell that starts at a scalar of width > 0.
    struct CellStart: Equatable, Sendable {
        /// UTF-16 offset of the starting scalar within the row string.
        let utf16Offset: Int
        /// Grid column of the cell.
        let column: Int
        /// Cell width (1 or 2).
        let width: Int
    }

    /// Cell width of a single scalar: 0, 1 or 2.
    nonisolated static func width(of scalar: Unicode.Scalar) -> Int {
        let v = scalar.value
        if v <= 0xFF { return 1 }

        let props = scalar.properties
        switch props.generalCategory {
        case .control, .surrogate, .lineSeparator, .paragraphSeparator:
            return 0
        default:
            break
        }
        if props.isDefaultIgnorableCodePoint { return 0 }
        switch props.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return 0
        default:
            break
        }
        if isGraphemeBreakVowelOrTrailing(v) { return 0 }
        if v == 0x2E3A || v == 0x2E3B { return 2 }
        if EastAsianWidthTable.isWideOrFullwidth(v) { return 2 }
        if (0x1F1E6...0x1F1FF).contains(v) { return 2 }
        return 1
    }

    /// Cells of `row` in order. A scalar of width > 0 starts a cell at the
    /// running column; width-0 scalars attach to the previous cell. A
    /// leading width-0 scalar (no previous cell) produces no entry.
    nonisolated static func cellStarts(in row: String) -> [CellStart] {
        // ASCII fast path: every byte is one cell of width 1 and
        // column == UTF-16 offset == byte index.
        let utf8 = row.utf8
        if utf8.allSatisfy({ $0 < 0x80 }) {
            return (0..<utf8.count).map { CellStart(utf16Offset: $0, column: $0, width: 1) }
        }
        var result: [CellStart] = []
        var utf16Offset = 0
        var column = 0
        for scalar in row.unicodeScalars {
            let w = width(of: scalar)
            if w > 0 {
                result.append(CellStart(utf16Offset: utf16Offset, column: column, width: w))
                column += w
            }
            utf16Offset += scalar.utf16.count
        }
        return result
    }

    /// Grapheme_Cluster_Break V or T, from GraphemeBreakProperty.txt
    /// (UCD 17.0.0, shipped with uucode-0.2.0):
    ///   1160..11A7 ; V   D7B0..D7C6 ; V   16D63 ; V   16D67..16D6A ; V
    ///   11A8..11FF ; T   D7CB..D7FB ; T
    private nonisolated static func isGraphemeBreakVowelOrTrailing(_ v: UInt32) -> Bool {
        switch v {
        case 0x1160...0x11A7, 0xD7B0...0xD7C6, 0x16D63, 0x16D67...0x16D6A,
             0x11A8...0x11FF, 0xD7CB...0xD7FB:
            return true
        default:
            return false
        }
    }
}
