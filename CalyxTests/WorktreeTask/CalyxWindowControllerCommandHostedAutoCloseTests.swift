//
//  CalyxWindowControllerCommandHostedAutoCloseTests.swift
//  CalyxTests
//
//  A passthrough worktree-task pane is created with a surface `command`,
//  and ghostty forces wait-after-command on for any such surface
//  (ghostty/src/apprt/embedded.zig), so `exit` in the pane would leave
//  ghostty's "[Process exited]" banner up. `processChildExited` must
//  close a surface registered in `CommandHostedSurfaces.shared`
//  synchronously, before the reconnect coordinator, and leave an
//  unregistered one to the existing path.
//
//  `performOpenTaskPane(app:cwd:spawnArgv:)` (the host extension's
//  testable body of `openTaskPane`; the host, not the coordinator, owns
//  registration) must register the surface on the passthrough path only.
//
//  Fixture mirrors CalyxWindowControllerHerdrAutoCloseTests: two
//  untracked panes, no SessionSurfaceMap entries.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCommandHostedAutoCloseTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.CalyxWindowControllerCommandHostedAutoCloseTests"
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    override func setUp() async throws {
        try await super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
        CommandHostedSurfaces.shared._testReset()
    }

    override func tearDown() async throws {
        CommandHostedSurfaces.shared._testReset()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    private struct Fixture {
        let controller: CalyxWindowController
        let tab: Tab
        let taskLeafID: UUID
        let taskSurfaceView: SurfaceView
        let otherLeafID: UUID
        let otherSurfaceView: SurfaceView
    }

    private func makeWindow() -> CalyxWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    private func makeFixture() -> Fixture {
        let registry = SurfaceRegistry()
        let taskLeafID = UUID()
        let otherLeafID = UUID()
        let taskView = SurfaceView(frame: .zero)
        let otherView = SurfaceView(frame: .zero)
        registry._testInsert(view: taskView, id: taskLeafID)
        registry._testInsert(view: otherView, id: otherLeafID)
        let root = SplitNode.split(SplitData(
            direction: .horizontal, ratio: 0.5,
            first: .leaf(id: taskLeafID), second: .leaf(id: otherLeafID)
        ))
        let tab = Tab(splitTree: SplitTree(root: root, focusedLeafID: taskLeafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = CalyxWindowController(window: makeWindow(), windowSession: session, restoring: true)
        return Fixture(controller: controller, tab: tab,
                       taskLeafID: taskLeafID, taskSurfaceView: taskView,
                       otherLeafID: otherLeafID, otherSurfaceView: otherView)
    }

    // MARK: - processChildExited

    func test_processChildExited_commandHostedSurface_closesThePane_beforeReconnectCoordinator() {
        let fixture = makeFixture()
        CommandHostedSurfaces.shared.register(fixture.taskLeafID)
        var killObserverFired = false
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { _, _ in killObserverFired = true }

        fixture.controller.processChildExited(surfaceView: fixture.taskSurfaceView)

        XCTAssertNil(fixture.controller._childExitedTasksForTesting[fixture.taskLeafID],
                     "A command-hosted surface must return before the childExitedTasks insert")
        XCTAssertFalse(fixture.tab.splitTree.allLeafIDs().contains(fixture.taskLeafID),
                       "A command-hosted surface's child exit must close the pane instead of leaving " +
                       "ghostty's forced wait-after-command banner up")
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.otherLeafID),
                      "The sibling pane must remain untouched")
        XCTAssertFalse(killObserverFired, "No session exists, nothing must be killed")
    }

    func test_processChildExited_unregisteredSurface_isNotClosed_defersToExistingPath() async {
        let fixture = makeFixture()

        fixture.controller.processChildExited(surfaceView: fixture.otherSurfaceView)

        let task = fixture.controller._childExitedTasksForTesting[fixture.otherLeafID]
        XCTAssertNotNil(task, "An unregistered surface must still defer to the reconnect coordinator path")
        await task?.value
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(fixture.otherLeafID),
                      "An unregistered surface must not be auto-closed")
    }

    // MARK: - performOpenTaskPane registration

    private func makeEmptyController() -> CalyxWindowController {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: makeWindow(), windowSession: session, restoring: true)
    }

    func test_performOpenTaskPane_passthrough_registersReturnedSurface() {
        SessionSettings.persistentSessionsEnabled = false
        let controller = makeEmptyController()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let result = controller.performOpenTaskPane(app: dummyApp, cwd: "/tmp", spawnArgv: ["claude"])

        XCTAssertEqual(result, newSurfaceID)
        XCTAssertTrue(CommandHostedSurfaces.shared.contains(newSurfaceID),
                      "A passthrough task pane must be registered for auto-close on child exit")
    }

    func test_performOpenTaskPane_surfaceWithSession_isNotRegistered() {
        SessionSettings.persistentSessionsEnabled = false
        let controller = makeEmptyController()
        let newSurfaceID = UUID()
        let sessionID = "test-command-hosted-\(UUID().uuidString)"
        // Simulates the persistent branch's registration: a surface that
        // owns a session goes through SessionReconnectCoordinator instead.
        controller._createManagedSurfaceHookForTesting = {
            SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: newSurfaceID)
            return newSurfaceID
        }
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        _ = controller.performOpenTaskPane(app: dummyApp, cwd: "/tmp", spawnArgv: ["claude"])

        XCTAssertFalse(CommandHostedSurfaces.shared.contains(newSurfaceID),
                       "A persistent-session task pane must not be registered")
    }
}
