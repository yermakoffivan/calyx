//
//  CalyxWindowControllerWorktreeTaskCommandTests.swift
//  CalyxTests
//
//  Pins the palette entry `git.newWorktreeTask`. Queries
//  `commandRegistry.allCommands` directly like `UsageCommandPaletteTests`;
//  the handler is not run (it presents a sheet).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerWorktreeTaskCommandTests: XCTestCase {

    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    func test_newWorktreeTask_isRegisteredOnce_withTitleShortcutAndCategory() throws {
        let controller = makeController()
        let matches = controller.commandRegistry.allCommands.filter { $0.id == "git.newWorktreeTask" }

        XCTAssertEqual(matches.count, 1, "git.newWorktreeTask must be registered exactly once")
        let command = try XCTUnwrap(matches.first)
        XCTAssertEqual(command.title, "New Worktree Task\u{2026}")
        XCTAssertEqual(command.shortcut, "Cmd+Shift+N")
        XCTAssertEqual(command.category, "Git")
    }
}
