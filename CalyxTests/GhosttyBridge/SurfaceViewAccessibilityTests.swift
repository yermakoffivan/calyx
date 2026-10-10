// SurfaceViewAccessibilityTests.swift
// CalyxTests
//
// SurfaceView as AXTextArea with no ghostty surface (surfaceController nil),
// plus snapshot TTL caching through the DEBUG text-source override.

import AppKit
import Testing
@testable import Calyx

@MainActor
@Suite("SurfaceView Accessibility")
struct SurfaceViewAccessibilityTests {

    @Test func identityAttributes() {
        let v = SurfaceView(frame: .zero)
        #expect(v.isAccessibilityElement())
        #expect(v.accessibilityRole() == .textArea)
        #expect(v.accessibilityLabel() == "Terminal")
        #expect(v.accessibilityIdentifier() == "calyx.terminal.pane")
        #expect(v.accessibilityHelp() == "Terminal content area")
    }

    @Test func paneIdentifierFormat() {
        let id = UUID()
        #expect(AccessibilityID.Terminal.panePrefix == "calyx.terminal.pane.")
        #expect(AccessibilityID.Terminal.pane(id) == "calyx.terminal.pane." + id.uuidString)
    }

    @Test func emptyValuesWithoutSurface() {
        let v = SurfaceView(frame: .zero)
        #expect(v.accessibilityValue() as? String == "")
        #expect(v.accessibilityNumberOfCharacters() == 0)
        #expect(v.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: 0))
        #expect(v.accessibilityLine(for: 0) == 0)
        #expect(v.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 0))
        #expect(v.accessibilityString(for: NSRange(location: 0, length: 1)) == nil)
        #expect(v.accessibilitySelectedTextRange() == NSRange(location: 0, length: 0))
        #expect(v.accessibilitySelectedText() == nil)
        _ = v.accessibilityFrame(for: NSRange(location: 0, length: 1))
        #expect((v.accessibilityChildren() ?? []).isEmpty)
    }

    #if DEBUG
    @Test func valueReflectsSourceAndSnapshotIsCachedForTTL() {
        let v = SurfaceView(frame: .zero)
        let src = FakeAXTextSource(
            size: TerminalAXGridSize(columns: 10, rows: 3, cellWidthPx: 16, cellHeightPx: 34),
            rowReads: [
                0: TerminalAXRowRead(text: "hello", tlPxX: 2, tlPxY: 2),
                1: TerminalAXRowRead(text: "world", tlPxX: 2, tlPxY: 19),
            ])
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        v.axNow = { now }
        v.axTextSourceOverrideForTesting = src
        #expect(v.axSnapshotTTL == 0.1)

        #expect(v.accessibilityValue() as? String == "hello\nworld")
        now = now.addingTimeInterval(0.05)
        #expect(v.accessibilityValue() as? String == "hello\nworld")
        #expect(src.gridSizeCalls == 1)
        #expect(v.accessibilityNumberOfCharacters() == 11)
        #expect(v.accessibilityRange(forLine: 1) == NSRange(location: 6, length: 5))

        now = now.addingTimeInterval(0.2)
        src.rowReads[1] = TerminalAXRowRead(text: "there", tlPxX: 2, tlPxY: 19)
        #expect(v.accessibilityValue() as? String == "hello\nthere")
        #expect(src.gridSizeCalls == 2)
    }
    #endif
}
