//
//  CalyxWindowControllerChildExitedTasksTests.swift
//  CalyxTests
//
//  `processChildExited`'s `Task`, tracked in `childExitedTasks` (added so
//  `windowWillClose` could cancel it alongside its `diffTasks`/
//  `expandTasks` siblings), never removes its own entry once it
//  completes, unlike `expandTasks[hash]`'s Task (see
//  `expandCommit(hash:)`), which does `self.expandTasks.removeValue
//  (forKey: hash)` at the end of its own body. A completed
//  `childExitedTasks` entry is therefore retained forever (until the
//  window closes), an unbounded-lifetime leak for any window with
//  repeated persistent-session disconnects.
//
//  Fixture: a single ordinary (non-persistent-session) pane -- its
//  leaf id is registered with the tab's `SurfaceRegistry` (so
//  `processChildExited`'s own `findTab`/`registry.id(for:)` lookup
//  resolves it) but deliberately NOT registered with
//  `SessionSurfaceMap.shared`. `SessionReconnectCoordinator.childExited
//  (surfaceID:)` gates solely on `surfaceMap.sessionID(for:) != nil`
//  (see that method's own doc comment), so for this fixture it returns
//  immediately without any real daemon round-trip -- exactly the "fake/
//  quick coordinator path" this test needs, using the coordinator's own
//  already-documented no-op gate rather than a new injection seam.
//
//  The task-registry assertions drive `processChildExited(surfaceView:)`
//  directly rather than posting the real `.ghosttyShowChildExited`
//  notification: that method is not `private` (mirroring
//  `handleSessionReconnectDecision`'s own precedent, see its doc
//  comment) so these tests can observe `childExitedTasks` without also
//  exercising the notification handler.
//
//  The handler's own ownership resolution is covered separately by
//  `test_showChildExitedNotification_forSurfaceDetachedFromWindow_
//  stillReachesProcessChildExited`, which posts the real notification.
//  `handleShowChildExitedNotification` resolves ownership through
//  `findTab(for:)` (i.e. via `windowSession`), not the surface's view
//  hierarchy, so a fixture `SurfaceView` detached from any window -- the
//  same state as a surface in a background tab -- still qualifies.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerChildExitedTasksTests: XCTestCase {

    private struct OrdinaryPaneFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
        let leafID: UUID
    }

    /// Single-pane/single-tab/single-group window whose sole leaf carries
    /// no `SessionRef` and no `SessionSurfaceMap.shared` entry -- an
    /// ordinary pane, exactly the case `SessionReconnectCoordinator
    /// .childExited(surfaceID:)`'s own doc comment describes as a no-op
    /// (its `surfaceMap.sessionID(for:)` lookup finds nothing).
    private func makeOrdinaryPaneFixture() -> OrdinaryPaneFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return OrdinaryPaneFixture(controller: controller, surfaceView: surfaceView, leafID: leafID)
    }

    /// `processChildExited`'s `Task` must
    /// remove its own `childExitedTasks[surfaceID]` entry once it
    /// completes, mirroring `expandTasks[hash]`'s self-removing Task
    /// (`expandCommit(hash:)`). Against the CURRENT code, the Task never
    /// touches `childExitedTasks` itself (only `windowWillClose`'s
    /// teardown loop and a same-key re-insert ever remove an entry), so
    /// the entry is still present after the Task has fully completed.
    func test_processChildExited_removesItsOwnEntry_fromChildExitedTasks_onceTaskCompletes() async {
        let fixture = makeOrdinaryPaneFixture()

        fixture.controller.processChildExited(surfaceView: fixture.surfaceView)

        let task = fixture.controller._childExitedTasksForTesting[fixture.leafID]
        XCTAssertNotNil(task,
                        "processChildExited must insert a Task into childExitedTasks keyed by the " +
                        "surface's id as a precondition for this test")

        await task?.value

        XCTAssertNil(fixture.controller._childExitedTasksForTesting[fixture.leafID],
                    "childExitedTasks must self-remove its entry once the Task completes, mirroring " +
                    "expandTasks' pattern -- otherwise a completed entry is retained forever")
    }

    // MARK: - Notification post ("Tactic A")

    /// Background tabs' SurfaceViews are removed from the window hierarchy
    /// by `SplitContainerView`, so their `view.window` is nil. The fixture's
    /// `surfaceView` is likewise in no window -- exactly that state. Posting
    /// the real `.ghosttyShowChildExited` notification must still reach
    /// `processChildExited` (observable as a `childExitedTasks` entry keyed
    /// by the surface's leaf id); a `view.window === self.window` ownership
    /// guard silently drops it, so the background pane never closes.
    func test_showChildExitedNotification_forSurfaceDetachedFromWindow_stillReachesProcessChildExited() async {
        let fixture = makeOrdinaryPaneFixture()
        XCTAssertNil(fixture.surfaceView.window,
                     "Precondition: the fixture surface must be detached from any window (background-tab state)")
        XCTAssertNil(fixture.controller._childExitedTasksForTesting[fixture.leafID],
                     "Precondition: no childExitedTasks entry before the notification")

        NotificationCenter.default.post(Notification(
            name: .ghosttyShowChildExited,
            object: fixture.surfaceView,
            userInfo: ["exit_code": Int32(0), "runtime_ms": UInt64(15000)]
        ))

        let task = fixture.controller._childExitedTasksForTesting[fixture.leafID]
        XCTAssertNotNil(task,
                        "A .ghosttyShowChildExited notification for a surface owned by one of this window's " +
                        "tabs (but detached from the window, as background tabs are) must reach " +
                        "processChildExited and insert a childExitedTasks entry")
        await task?.value
    }
}
