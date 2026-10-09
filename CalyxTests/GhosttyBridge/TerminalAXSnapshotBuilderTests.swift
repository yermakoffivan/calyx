// TerminalAXSnapshotBuilderTests.swift
// CalyxTests

import AppKit
import Testing
@testable import Calyx

@MainActor
final class FakeAXTextSource: TerminalAXTextSource {
    var size: TerminalAXGridSize?
    var rowReads: [Int: TerminalAXRowRead] = [:]
    var gridSizeCalls = 0
    var readCalls: [(row: Int, columns: Int)] = []

    init(size: TerminalAXGridSize?, rowReads: [Int: TerminalAXRowRead] = [:]) {
        self.size = size
        self.rowReads = rowReads
    }

    func gridSize() -> TerminalAXGridSize? {
        gridSizeCalls += 1
        return size
    }

    func readViewportRow(_ row: Int, columns: Int) -> TerminalAXRowRead? {
        readCalls.append((row, columns))
        return rowReads[row]
    }
}

@MainActor
@Suite("TerminalAXSnapshotBuilder")
struct TerminalAXSnapshotBuilderTests {

    private func grid(_ cols: Int, _ rows: Int) -> TerminalAXGridSize {
        TerminalAXGridSize(columns: cols, rows: rows, cellWidthPx: 16, cellHeightPx: 34)
    }

    @Test func nilRowReadBecomesEmptyAndKeepsRowIndex() {
        let src = FakeAXTextSource(size: grid(10, 3), rowReads: [
            0: TerminalAXRowRead(text: "one", tlPxX: 2, tlPxY: 2),
            2: TerminalAXRowRead(text: "three", tlPxX: 2, tlPxY: 36),
        ])
        let r = TerminalAXSnapshotBuilder.build(from: src, scale: 2)
        #expect(r?.snapshot == TerminalAXSnapshot(rowTexts: ["one", "", "three"], columns: 10))
        #expect(r?.snapshot.text == "one\n\nthree")
    }

    @Test func leftPaddingFromFirstNonNegativeRow() {
        let src = FakeAXTextSource(size: grid(10, 3), rowReads: [
            0: TerminalAXRowRead(text: "a", tlPxX: -1, tlPxY: -1),
            1: TerminalAXRowRead(text: "b", tlPxX: 2.0, tlPxY: 19),
            2: TerminalAXRowRead(text: "c", tlPxX: 7.0, tlPxY: 36),
        ])
        #expect(TerminalAXSnapshotBuilder.build(from: src, scale: 2)?.leftPaddingPt == 2.0)
    }

    @Test func leftPaddingNilWhenNoRowHasPosition() {
        let src = FakeAXTextSource(size: grid(10, 2), rowReads: [
            0: TerminalAXRowRead(text: "a", tlPxX: -1, tlPxY: -1),
        ])
        let r = TerminalAXSnapshotBuilder.build(from: src, scale: 2)
        #expect(r != nil)
        #expect(r?.leftPaddingPt == nil)
    }

    @Test func readsExactlyGridRowsWithColumns() {
        let src = FakeAXTextSource(size: grid(7, 4))
        _ = TerminalAXSnapshotBuilder.build(from: src, scale: 1)
        #expect(src.readCalls.map(\.row) == [0, 1, 2, 3])
        #expect(src.readCalls.allSatisfy { $0.columns == 7 })
    }

    @Test func rowCountMatchesGridWhenAllRowsWritten() {
        let reads = Dictionary(uniqueKeysWithValues: (0..<5).map { ($0, TerminalAXRowRead(text: "r\($0)", tlPxX: 0, tlPxY: 0)) })
        let src = FakeAXTextSource(size: grid(4, 5), rowReads: reads)
        let r = TerminalAXSnapshotBuilder.build(from: src, scale: 1)
        #expect(r?.snapshot.rows.count == 5)
        #expect(r?.snapshot.text == "r0\nr1\nr2\nr3\nr4")
    }

    @Test func nilOrZeroGridReturnsNil() {
        #expect(TerminalAXSnapshotBuilder.build(from: FakeAXTextSource(size: nil), scale: 2) == nil)
        #expect(TerminalAXSnapshotBuilder.build(from: FakeAXTextSource(size: grid(0, 5)), scale: 2) == nil)
        #expect(TerminalAXSnapshotBuilder.build(from: FakeAXTextSource(size: grid(5, 0)), scale: 2) == nil)
    }
}
