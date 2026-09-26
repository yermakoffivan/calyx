// CalyxUITestCase.swift
// CalyxUITests
//
// Base class for all Calyx XCUITests with common helpers.

import AppKit
import XCTest

@MainActor
class CalyxUITestCase: XCTestCase {
    var app: XCUIApplication!
    private var sessionTempDir: String?
    /// Per-test-unique `UserDefaults` suite name, read by
    /// `SessionSettings.uiTestSuite` via `CALYX_UITEST_DEFAULTS_SUITE`.
    ///
    /// INCIDENT THAT MADE THIS MANDATORY: before this fix, this base
    /// `setUp()` (the launch path every subclass here uses unless it
    /// overrides `setUp()` with its own launch, e.g.
    /// `SettingsSessionsToggleE2ETests`) launched the app-under-test with
    /// no defaults isolation and no `HOME` override at all. During a
    /// window when the developer's real `com.calyx.terminal.e2e` defaults
    /// domain happened to have `persistentSessionsEnabled=1`, every
    /// tab/rename/reorder suite's app instance read that real domain,
    /// found persistence on, and created REAL persistent sessions against
    /// the developer's real `~/.calyx` daemon on every launch -- 47 zombie
    /// shells accumulated in one day of running these suites. Setting this
    /// suite name before `app.launch()` mirrors
    /// `SettingsSessionsToggleE2ETests`'s own established isolation (see
    /// that file's header for why a dedicated suite, not just a `HOME`
    /// override, is required: `UserDefaults.standard` is mediated by
    /// `cfprefsd` and keyed by the real macOS account, not by `HOME`).
    private var defaultsSuiteName: String?

    /// Switches the Mac's active keyboard input source to ABC/US for the
    /// duration of a test, so `typeText` keystrokes reach the app under
    /// test literally instead of being composed by an IME (see
    /// `InputSourceGuard`'s header). Activated once per test from
    /// `terminateStaleAppUnderTestInstances()`, restored in `tearDown()`.
    private let inputSourceGuard = InputSourceGuard()

    /// Override in subclasses to add extra launch arguments (e.g. UserDefaults overrides).
    var additionalLaunchArguments: [String] { [] }

    /// Bundle identifier of the DebugUITesting build of Calyx launched by
    /// these tests (`PRODUCT_BUNDLE_IDENTIFIER` set on the `DebugUITesting`
    /// config in `project.yml`), distinct from the production
    /// `com.calyx.terminal` used by every other config.
    private static let appUnderTestBundleIdentifier = "com.calyx.terminal.e2e"

    /// An aborted UI test run leaves the app under test running (its
    /// process is never sent `terminate()` because `tearDown()` never
    /// executes). That stale instance then blocks the next run's XCUITest
    /// automation session: the new run's `app.launch()` hangs before
    /// establishing the automation connection ("hung before establishing
    /// connection" / "Timed out while enabling automation mode"), or the
    /// run proceeds but every interaction crawls. Terminating any stale
    /// instance before launching a fresh one removes the blocker at its
    /// root.
    ///
    /// Scoped to instances whose bundle URL is under a `DebugUITesting`
    /// build product directory, so this never touches a user's own Calyx
    /// installed from `/Applications` or a plain `Debug` build running on
    /// the same machine.
    func terminateStaleAppUnderTestInstances() {
        inputSourceGuard.activate()

        let staleInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.appUnderTestBundleIdentifier)
            .filter { $0.bundleURL?.path.contains("/DebugUITesting/") == true }

        for instance in staleInstances {
            instance.forceTerminate()
            let deadline = Date().addingTimeInterval(5)
            while !instance.isTerminated, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        try? FileManager.default.removeItem(atPath: "/tmp/.calyx-test-lock")
    }

    /// Re-selects the keyboard input source recorded by
    /// `terminateStaleAppUnderTestInstances()`'s `inputSourceGuard.activate()`
    /// call. `tearDown()` calls this itself; a subclass that overrides
    /// `tearDown()` without calling `super.tearDown()` must call this
    /// directly so the developer's own input source is always restored.
    func restoreInputSource() {
        inputSourceGuard.restore()
    }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        terminateStaleAppUnderTestInstances()
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments

        let tempDir = NSTemporaryDirectory() + "CalyxUITests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        sessionTempDir = tempDir
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = tempDir

        let suiteName = "com.calyx.tests.e2e.CalyxUITestCase-\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        app.launchEnvironment["CALYX_UITEST_DEFAULTS_SUITE"] = suiteName

        app.launch()
    }

    override func tearDown() async throws {
        restoreInputSource()
        app.terminate()
        if let dir = sessionTempDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
        if let suiteName = defaultsSuiteName {
            // Best-effort only, mirroring SettingsSessionsToggleE2ETests's
            // own cleanup and its documented cfprefsd-flush caveat: the
            // app-under-test is a SEPARATE process, and cfprefsd flushes a
            // just-terminated process's writes to its on-disk plist on its
            // own schedule, sometimes after this point. A leftover plist
            // is harmless -- `suiteName` is a fresh UUID every run, so it
            // is never read by anything again, and this never touches the
            // real `com.calyx.terminal.e2e` domain.
            // `try?`: a cancelled sleep only shortens the flush wait; cleanup below must still run.
            try? await Task.sleep(for: .seconds(1))
            UserDefaults().removePersistentDomain(forName: suiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(suiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        wait(for: [expectation], timeout: timeout)
    }

    func menuAction(_ menuName: String, item: String) {
        app.menuBars.menuBarItems[menuName].click()
        app.menuBars.menuItems[item].click()
    }

    func createNewTabViaMenu() {
        menuAction("File", item: "New Tab")
    }

    /// GitHub issue #45: the File menu's "Close Tab" item still exists
    /// (now at Cmd+Option+W, wired to `CalyxWindowController.closeTab(_:)`
    /// unchanged) — only its shortcut moved, since plain Cmd+W is now
    /// "Close" (`NSWindow.calyxPerformClose(_:)`, which closes the
    /// focused PANE, not necessarily the whole tab). This helper still
    /// targets the always-whole-tab-scoped item by title, so it is
    /// unaffected by that shortcut move.
    func closeTabViaMenu() {
        menuAction("File", item: "Close Tab")
    }

    func toggleSidebarViaMenu() {
        menuAction("View", item: "Toggle Sidebar")
    }

    func openCommandPaletteViaMenu() {
        menuAction("View", item: "Command Palette")
    }

    func countElements(matching prefix: String, excludingSuffix: String? = nil) -> Int {
        let predicate: NSPredicate
        if let suffix = excludingSuffix {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", prefix, suffix)
        } else {
            predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        }
        return app.descendants(matching: .any)
            .matching(predicate)
            .count
    }

    /// Matches exactly "calyx.tabBar.tab.<UUID>" and nothing else (no
    /// `.closeButton` suffix).
    func tabBarTabsQuery() -> XCUIElementQuery {
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let predicate = NSPredicate(format: "identifier MATCHES %@", "calyx\\.tabBar\\.tab\\.\(uuidPattern)")
        return app.descendants(matching: .any).matching(predicate)
    }

    func countTabBarTabs() -> Int {
        tabBarTabsQuery().count
    }

    /// Matches exactly the sidebar group header container elements:
    /// identifiers beginning with `calyx.sidebar.group.` but excluding
    /// the header's own `.closeAllButton` child. The collapse chevron
    /// (`calyx.sidebar.groupCollapseButton.<id>`) never matches this
    /// prefix in the first place, so no clause is needed for it.
    func groupHeadersQuery() -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'calyx.sidebar.group.' AND NOT identifier CONTAINS '.closeAllButton'"
            ))
    }

    func groupHeaderCount() -> Int {
        groupHeadersQuery().count
    }

    /// Creates a new group via the command palette's "New Group" command
    /// and waits until `groupHeaderCount()` reaches `count`.
    func createGroupViaCommandPalette(expectingGroupCount count: Int) {
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette search field should appear")

        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)

        XCTAssertEqual(
            waitForCount(groupHeaderCount, toEqual: count), count,
            "Should have \(count) groups after creating a new one"
        )

        // The sidebar's hosting view is rebuilt once more shortly after the
        // new group appears (the controller refreshes it again when the palette
        // closes and focus is restored). A header element resolved before that
        // rebuild is stale by the time a click is synthesized on it
        // ("No matches found for Descendant with identity binding"), so let the
        // rebuild land before returning.
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// The identifiers of every tab currently shown in the horizontal tab
    /// bar (`calyx.tabBar.tab.<UUID>`, excluding `.closeButton` children),
    /// i.e. the tabs belonging to whichever group is CURRENTLY ACTIVE
    /// (`MainContentView.mainContent` feeds `TabBarContentView` from
    /// `windowSession.activeGroup?.tabs` alone, so switching the active
    /// group changes exactly this set). Used to prove a group-switching
    /// action actually moved the active group, rather than merely
    /// leaving the group COUNT unchanged (which a no-op switch would also
    /// satisfy).
    func currentTabBarTabIdentifiers() -> Set<String> {
        Set(tabBarTabsQuery().allElementsBoundByIndex.map { $0.identifier })
    }

    /// Polls `read()` until it returns `expected` or `timeout` elapses,
    /// pumping the run loop 50 ms at a time between checks so the app's own
    /// run loop keeps processing. Returns the last observed value.
    @discardableResult
    func waitForCount(_ read: () -> Int, toEqual expected: Int, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = read()
        while observed != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            observed = read()
        }
        return observed
    }

    /// Polls `countTabBarTabs()` until it equals `count` or `timeout`
    /// elapses. Returns whether the count was reached.
    @discardableResult
    func waitForTabCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        waitForCount(countTabBarTabs, toEqual: count, timeout: timeout) == count
    }

    /// Fixed scratch directory the team lead reads screenshots from by
    /// hand after a run -- NOT a general-purpose artifact location, so
    /// don't add unrelated files here. ONE level under `/tmp`,
    /// deliberately -- field-verified (not assumed) that this depth
    /// succeeds where a deeper, nested scratchpad path does not: the
    /// sandboxed runner failed an equivalent nested `mkdir` under the
    /// scratchpad with `NSCocoaErrorDomain Code=513 "Operation not
    /// permitted"`, while a one-level `/tmp/<name>` directory (the same
    /// depth `SessionBrowserAttachKillE2ETests`'s own per-test `homeDir`
    /// already succeeds at creating, see that file's `setUp()`) works.
    static let uiShotDir = "/tmp/cxshots"

    /// Saves a full-screen `XCUIScreen` screenshot (not a single
    /// element's, so window chrome/toolbar icons are visible exactly as
    /// a human eyeballing the result would see them) named `name`, via
    /// BOTH of two independent channels: (a) an `XCTAttachment`/`add(_:)`
    /// on the current test -- always succeeds, lands in the run's
    /// `.xcresult` regardless of sandboxing -- and (b) a raw PNG file
    /// under `uiShotDir`, a plain one-level `/tmp` path a human can open
    /// directly without extracting it from the `.xcresult` bundle first.
    /// (b) is a best-effort supplement, not a substitute for (a): if the
    /// write fails for any reason, this logs the failure and falls back
    /// to the attachment alone rather than failing the test over a
    /// diagnostic-only write.
    func saveScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let filePath = "\(Self.uiShotDir)/\(name).png"
        do {
            try FileManager.default.createDirectory(atPath: Self.uiShotDir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: filePath))
            print("[saveScreenshot] \"\(name)\": attached to test result AND wrote \(filePath)")
        } catch {
            print(
                "[saveScreenshot] \"\(name)\": attached to test result, but failed to " +
                "write \(filePath) (\(error)) -- see the test's XCTAttachment instead."
            )
        }
    }
}
