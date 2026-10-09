// TerminalAXGeometry.swift
// Calyx
//
// Pure geometry for the terminal AX text area: content-space (top-left
// origin, points) cell rectangles and the flip into view space.

import AppKit

struct TerminalAXGeometry: Sendable, Equatable {
    let cellSizePt: CGSize
    let leftPaddingPt: CGFloat
    let topPaddingPt: CGFloat

    /// Top padding derived from the IME point (bottom of the cursor cell in
    /// top-left points). The remainder is taken in integer pixels so that
    /// fractional point cell heights do not drift. Assumes
    /// padding.top < cell height.
    ///
    /// Do NOT derive this from a row read's `tl_px_y` as
    /// `tlPxY - row * cellHeight`: ghostty's `tl_px_y` is the row BASELINE
    /// (`row*cellH + cellH - cell_baseline + padding.top`, Surface.zig:1977-1992)
    /// and `cell_baseline` is not exposed, so that does not yield the cell top.
    /// Returns 0 for non-finite input, a non-positive scale or cell height,
    /// or a negative pixel position.
    nonisolated static func topPaddingPt(imePointY: Double, scale: CGFloat, cellHeightPx: Int) -> CGFloat {
        guard imePointY.isFinite, scale.isFinite, scale > 0, cellHeightPx > 0 else { return 0 }
        let px = Int((imePointY * Double(scale)).rounded())
        guard px >= 0 else { return 0 }
        return CGFloat(px % cellHeightPx) / scale
    }

    /// Content-space rect covering `colStart...colEnd` (inclusive) of `row`.
    func contentRect(row: Int, colStart: Int, colEnd: Int) -> NSRect {
        NSRect(
            x: leftPaddingPt + CGFloat(colStart) * cellSizePt.width,
            y: topPaddingPt + CGFloat(row) * cellSizePt.height,
            width: CGFloat(colEnd - colStart + 1) * cellSizePt.width,
            height: cellSizePt.height
        )
    }

    /// Flips a content-space rect into AppKit view space (bottom-left
    /// origin), subtracting the smooth-scroll offset like `firstRect`.
    nonisolated static func viewRect(contentRect: NSRect, viewHeight: CGFloat, smoothScrollPixelOffset: CGFloat) -> NSRect {
        NSRect(
            x: contentRect.minX,
            y: viewHeight - contentRect.maxY - smoothScrollPixelOffset,
            width: contentRect.width,
            height: contentRect.height
        )
    }
}
