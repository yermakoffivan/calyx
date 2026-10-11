//
//  AppDelegateFileMenuWorktreeTaskItemTests.swift
//  CalyxTests
//
//  Pins the File menu's "New Worktree Task…" item: Cmd+Shift+T, nil
//  target (resolved through the key window's responder chain like the
//  other New items), placed immediately after "New Tab". Same bare
//  `AppDelegate().setupMainMenu()` approach as
//  `AppDelegateFileMenuCloseItemsTests`.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateFileMenuWorktreeTaskItemTests: XCTestCase {

    private func fileMenu() throws -> NSMenu {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let fileMenuItem = try XCTUnwrap(
            mainMenu.items.first(where: { $0.submenu?.title == "File" }),
            "setupMainMenu must build a \"File\" menu"
        )
        return try XCTUnwrap(fileMenuItem.submenu, "The File menu item must have a submenu")
    }

    func test_fileMenu_newWorktreeTaskItem_shortcutActionAndNilTarget() throws {
        let menu = try fileMenu()
        let item = try XCTUnwrap(
            menu.items.first(where: { $0.title == "New Worktree Task\u{2026}" }),
            "File menu must contain \"New Worktree Task…\""
        )

        XCTAssertEqual(item.keyEquivalent, "t")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item.action, #selector(CalyxWindowController.newWorktreeTask(_:)))
        XCTAssertNil(item.target, "nil target so the key window's controller receives it")
    }

    func test_fileMenu_newWorktreeTaskItem_immediatelyFollowsNewTab() throws {
        let menu = try fileMenu()
        let titles = menu.items.map(\.title)
        let newTabIndex = try XCTUnwrap(titles.firstIndex(of: "New Tab"))
        let taskIndex = try XCTUnwrap(titles.firstIndex(of: "New Worktree Task\u{2026}"))

        XCTAssertEqual(taskIndex, newTabIndex + 1)
    }
}
