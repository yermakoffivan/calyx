// TerminalAXSnapshotBuilder.swift
// Calyx
//
// Builds a TerminalAXSnapshot by reading the viewport one row at a time.

import AppKit

struct TerminalAXGridSize: Sendable, Equatable {
    let columns: Int
    let rows: Int
    let cellWidthPx: Int
    let cellHeightPx: Int
}

struct TerminalAXRowRead: Sendable, Equatable {
    let text: String
    /// ghostty's `tl_px_x` (points; negative when unavailable).
    let tlPxX: Double
    /// ghostty's `tl_px_y` (points; negative when unavailable). This is the
    /// row BASELINE, not the cell top: `row*cellH + cellH - cell_baseline +
    /// padding.top` (Surface.zig:1977-1992). `cell_baseline` is not exposed,
    /// so the top padding cannot be derived from it; see
    /// `TerminalAXGeometry.topPaddingPt`.
    let tlPxY: Double
}

@MainActor
protocol TerminalAXTextSource: AnyObject {
    func gridSize() -> TerminalAXGridSize?
    func readViewportRow(_ row: Int, columns: Int) -> TerminalAXRowRead?
}

@MainActor
enum TerminalAXSnapshotBuilder {
    struct Result: Equatable {
        let snapshot: TerminalAXSnapshot
        let leftPaddingPt: CGFloat?
    }

    /// Reads rows `0..<rows`; a nil row read becomes "" so row indices stay
    /// grid indices. `leftPaddingPt` is the `tlPxX` of the first row whose
    /// `tlPxX >= 0` (ghostty already reports it in points, so `scale` does
    /// not rescale it). Returns nil if the grid size is unavailable or empty.
    static func build(from source: TerminalAXTextSource, scale: CGFloat) -> Result? {
        guard let size = source.gridSize(), size.columns > 0, size.rows > 0 else { return nil }
        var texts: [String] = []
        texts.reserveCapacity(size.rows)
        var leftPadding: CGFloat?
        for row in 0..<size.rows {
            guard let read = source.readViewportRow(row, columns: size.columns) else {
                texts.append("")
                continue
            }
            texts.append(read.text)
            if leftPadding == nil, read.tlPxX >= 0 {
                leftPadding = CGFloat(read.tlPxX)
            }
        }
        return Result(
            snapshot: TerminalAXSnapshot(rowTexts: texts, columns: size.columns),
            leftPaddingPt: leftPadding
        )
    }
}
