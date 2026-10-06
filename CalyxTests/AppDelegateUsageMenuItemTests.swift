//
//  AppDelegateUsageMenuItemTests.swift
//  CalyxTests
//
//  Pins the View menu's "Usage" item, which opens the Usage window
//  (`UsageWindowController.shared.showUsage()` through
//  `AppDelegate.openUsageWindow(_:)`): it sits directly after "Session
//  Browser", the other app-level window opened from that menu, and has
//  the key equivalent Option-Command-U (Shift-Command-U is "Jump to
//  Unread Tab"; R5f).
//
//  The action is pinned by its selector NAME, so this file compiles
//  without the method; a missing item fails at runtime. As in
//  `AppDelegateSessionBrowserMenuItemTests`, `setupMainMenu()` only
//  builds menus and assigns `NSApp.mainMenu`, so it is safe to call on
//  a bare `AppDelegate()` here. The uniqueness test guards that adding
//  the item did not introduce a shortcut collision anywhere.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateUsageMenuItemTests: XCTestCase {

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return [item] + allItems(in: submenu)
            }
            return [item]
        }
    }

    private func viewMenu() throws -> NSMenu {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        return try XCTUnwrap(
            mainMenu.items.compactMap(\.submenu).first { $0.title == "View" }, "the main menu has a View menu")
    }

    func test_viewMenu_hasUsageDirectlyAfterSessionBrowser() throws {
        let items = try viewMenu().items
        let browserIndex = try XCTUnwrap(items.firstIndex { $0.title == "Session Browser" })

        XCTAssertLessThan(browserIndex + 1, items.count, "nothing follows Session Browser")
        guard browserIndex + 1 < items.count else { return }
        XCTAssertEqual(items[browserIndex + 1].title, "Usage")
        XCTAssertEqual(items.filter { $0.title == "Usage" }.count, 1)
    }

    func test_usageItem_opensTheUsageWindow_andHasOptionCommandU() throws {
        let item = try XCTUnwrap(try viewMenu().items.first { $0.title == "Usage" }, "View > Usage is missing")

        XCTAssertEqual(item.action.map(NSStringFromSelector), "openUsageWindow:")
        XCTAssertEqual(item.keyEquivalent, "u")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNil(item.submenu)
    }

    func test_optionCommandU_isUsedOnlyByTheUsageItem() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let users = allItems(in: mainMenu).filter {
            $0.keyEquivalent.lowercased() == "u"
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option]
        }
        XCTAssertEqual(users.map(\.title), ["Usage"])
    }

    /// AppKit clears the key equivalent of a menu item that collides with
    /// one already in the tree, so a Usage item on Shift-Command-U would
    /// leave the uniqueness test below green and silently take the
    /// shortcut from "Jump to Unread Tab". Pin the neighbour directly.
    func test_jumpToUnreadTab_keepsShiftCommandU() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let item = try XCTUnwrap(allItems(in: mainMenu).first { $0.title == "Jump to Unread Tab" })
        XCTAssertEqual(item.keyEquivalent, "u")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    /// Same invariant as the Session Browser menu test: no two items in
    /// the whole tree share a (keyEquivalent, modifier mask) pair. Case
    /// is significant ("z" and "Z" are Undo and Redo).
    func test_setupMainMenu_everyShortcutInTheMenuTree_isUnique() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let shortcutItems = allItems(in: mainMenu).filter { !$0.keyEquivalent.isEmpty }

        let grouped = Dictionary(grouping: shortcutItems) { item in
            "\(item.keyEquivalent)+\(item.keyEquivalentModifierMask.rawValue)"
        }
        let duplicates = grouped.filter { $0.value.count > 1 }

        XCTAssertTrue(duplicates.isEmpty, "colliding shortcuts: \(duplicates.mapValues { $0.map(\.title) })")
    }
}
