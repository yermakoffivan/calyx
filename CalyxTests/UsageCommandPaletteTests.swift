//
//  UsageCommandPaletteTests.swift
//  CalyxTests
//
//  Pins the command palette's entry for the Usage window: `usage.show`,
//  titled "Usage…" (one ellipsis character) in the View category, with
//  no shortcut, registered by `CalyxWindowController
//  .setupCommandRegistry`. Queries `commandRegistry.allCommands`
//  directly, like `SessionCommandPaletteTests`. The handler is not run:
//  it opens the shared Usage window, whose model reads the app's real
//  usage ledger.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class UsageCommandPaletteTests: XCTestCase {

    /// `restoring: true` skips the terminal surface, which needs a live
    /// Ghostty app (same shape as `SessionCommandPaletteTests.makeController()`).
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

    func test_usageShow_isRegistered_titledUsageEllipsis_inTheViewCategory() throws {
        let controller = makeController()
        let matches = controller.commandRegistry.allCommands.filter { $0.id == "usage.show" }

        XCTAssertEqual(matches.count, 1, "usage.show must be registered exactly once")
        let command = try XCTUnwrap(matches.first)
        XCTAssertEqual(command.title, "Usage\u{2026}")
        XCTAssertEqual(command.category, "View")
        XCTAssertNil(command.shortcut)
    }
}
