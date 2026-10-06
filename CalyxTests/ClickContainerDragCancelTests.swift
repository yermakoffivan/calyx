// ClickContainerDragCancelTests.swift
// CalyxTests
//
// A drag in `ClickContainerNSView` whose view leaves its window before the
// mouseUp arrives (e.g. the dragged sidebar row is torn down) must be
// cancelled: press/drag state cleared, `onDragCancelled` called exactly
// once, `onDragEnded` never called (now or on a later mouseUp).
//
// Hosting follows ClickContainerNSViewTrailingActionTests: the 200x36 view
// is the content view of a borderless window of the same size, so window
// coordinates map to local ones. The press lands at window (40, 18) on the
// tab body; a drag to (40, 8) is 10pt (> 5pt threshold), a drag to (40, 16)
// is 2pt (< threshold).

import XCTest
import AppKit
import SwiftUI
@testable import Calyx

@MainActor
final class ClickContainerDragCancelTests: XCTestCase {

    private var window: NSWindow!
    private var view: ClickContainerNSView!
    private var endedCount = 0
    private var cancelledCount = 0

    /// Builds the fixture on the main actor (setUp is nonisolated under Swift 6).
    private func makeFixture() {
        view = ClickContainerNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 36))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        endedCount = 0
        cancelledCount = 0
        view.onDragChanged = { _ in }
        view.onDragEnded = { [unowned self] in self.endedCount += 1 }
        view.onDragCancelled = { [unowned self] in self.cancelledCount += 1 }
    }

    private func tearDownFixture() {
        window = nil
        view = nil
    }

    private func event(_ type: NSEvent.EventType, _ location: NSPoint, windowNumber: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
    }

    private func pressAndDrag(to location: NSPoint) throws -> Int {
        let number = window.windowNumber
        view.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 40, y: 18), windowNumber: number))
        view.mouseDragged(with: try event(.leftMouseDragged, location, windowNumber: number))
        return number
    }

    /// Removes the view from its window, which sends viewWillMove(toWindow: nil).
    private func removeFromWindow() {
        view.removeFromSuperview()
        XCTAssertNil(view.window, "precondition: the view has left its window")
    }

    func test_removedDuringDrag_callsCancelledOnceAndNotEnded() throws {
        makeFixture()
        defer { tearDownFixture() }
        var changes: [CGSize] = []
        view.onDragChanged = { changes.append($0) }
        _ = try pressAndDrag(to: NSPoint(x: 40, y: 8))
        XCTAssertEqual(changes, [CGSize(width: 0, height: 10)], "precondition: the drag started")

        removeFromWindow()

        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(endedCount, 0)
    }

    func test_removedDuringDrag_laterMouseUpDoesNotEndDrag() throws {
        makeFixture()
        defer { tearDownFixture() }
        let number = try pressAndDrag(to: NSPoint(x: 40, y: 8))
        removeFromWindow()

        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 40, y: 8), windowNumber: number))

        XCTAssertEqual(endedCount, 0, "a cancelled drag must not also end")
        XCTAssertEqual(cancelledCount, 1, "the cancel fires exactly once")
    }

    func test_removedWhileIdle_callsNeither() {
        makeFixture()
        defer { tearDownFixture() }
        removeFromWindow()

        XCTAssertEqual(cancelledCount, 0)
        XCTAssertEqual(endedCount, 0)
    }

    func test_removedWhilePressedUnderThreshold_callsNeither() throws {
        makeFixture()
        defer { tearDownFixture() }
        _ = try pressAndDrag(to: NSPoint(x: 40, y: 16))

        removeFromWindow()

        XCTAssertEqual(cancelledCount, 0)
        XCTAssertEqual(endedCount, 0)
    }

    func test_removedAfterCompletedDrag_callsNeitherAgain() throws {
        makeFixture()
        defer { tearDownFixture() }
        let number = try pressAndDrag(to: NSPoint(x: 40, y: 8))
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 40, y: 8), windowNumber: number))
        XCTAssertEqual(endedCount, 1, "precondition: a normal drag ends via mouseUp")

        removeFromWindow()

        XCTAssertEqual(cancelledCount, 0)
        XCTAssertEqual(endedCount, 1)
    }

    /// The SwiftUI wrapper accepts the callback (defaulting to nil).
    func test_tabClickContainer_acceptsOnDragCancelled() {
        var called = false
        let container = TabClickContainer(
            isEnabled: true, onSingleClick: {}, onDoubleClick: {},
            onDragCancelled: { called = true }
        ) { EmptyView() }
        container.onDragCancelled?()
        XCTAssertTrue(called)
    }
}
