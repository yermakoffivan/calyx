// TerminalAXGeometryTests.swift
// CalyxTests

import AppKit
import Testing
@testable import Calyx

@Suite("TerminalAXGeometry")
struct TerminalAXGeometryTests {

    @Test(arguments: [0, 5, 40])
    func topPaddingScale2(row: Int) {
        let y = Double((row + 1) * 34 + 4) / 2
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: y, scale: 2, cellHeightPx: 34) == 2.0)
    }

    @Test(arguments: [0, 7])
    func topPaddingScale1(row: Int) {
        let y = Double((row + 1) * 17 + 3)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: y, scale: 1, cellHeightPx: 17) == 3.0)
    }

    @Test func contentRectWithFractionalCellSize() {
        let g = TerminalAXGeometry(cellSizePt: CGSize(width: 8.75, height: 17.5), leftPaddingPt: 2, topPaddingPt: 3)
        #expect(g.contentRect(row: 3, colStart: 2, colEnd: 4) == NSRect(x: 19.5, y: 55.5, width: 26.25, height: 17.5))
        #expect(g.contentRect(row: 0, colStart: 0, colEnd: 0) == NSRect(x: 2, y: 3, width: 8.75, height: 17.5))
    }

    @Test func viewRectFlipsYAndSubtractsSmoothScroll() {
        // Same as firstRect: y = frame.height - contentY(bottom) - smoothScrollPixelOffset
        let c = NSRect(x: 10, y: 20, width: 30, height: 17.5)
        #expect(TerminalAXGeometry.viewRect(contentRect: c, viewHeight: 400, smoothScrollPixelOffset: 5)
                == NSRect(x: 10, y: 357.5, width: 30, height: 17.5))
        #expect(TerminalAXGeometry.viewRect(contentRect: c, viewHeight: 400, smoothScrollPixelOffset: -4)
                == NSRect(x: 10, y: 366.5, width: 30, height: 17.5))
        #expect(TerminalAXGeometry.viewRect(contentRect: c, viewHeight: 400, smoothScrollPixelOffset: 0)
                == NSRect(x: 10, y: 362.5, width: 30, height: 17.5))
    }

    @Test func topPaddingNonFiniteOrNegativeIsZero() {
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: .nan, scale: 2, cellHeightPx: 34) == 0)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: .infinity, scale: 2, cellHeightPx: 34) == 0)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: -.infinity, scale: 2, cellHeightPx: 34) == 0)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: 10, scale: .nan, cellHeightPx: 34) == 0)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: 10, scale: .infinity, cellHeightPx: 34) == 0)
        #expect(TerminalAXGeometry.topPaddingPt(imePointY: -5, scale: 2, cellHeightPx: 34) == 0)
    }
}
