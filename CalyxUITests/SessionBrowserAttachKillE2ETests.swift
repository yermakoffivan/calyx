// SessionBrowserAttachKillE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the session browser's Attach/Kill actions
// (`Calyx/Features/SessionBrowser/SessionBrowserWindowController.swift`,
// `SessionBrowserModel.swift`, `SessionBrowserView.swift`): opening the
// browser via the command palette shows every daemon-tracked Running
// session, clicking "Attach" on a Detached row adds a new TAB reattached
// to it in the existing window (`AppDelegate.attachSessionAsTab`, titled
// from its cwd, tilde-abbreviated -- NOT a new window, and NOT the
// "Terminal" default), and clicking "Kill" removes a session from both
// the daemon ledger and the browser's own list. The attach assertions
// check BOTH the daemon ledger (a client actually connected) AND these
// two user-visible outcomes -- a prior version of this suite asserted
// only the ledger and shipped both defects unnoticed.
//
// Isolation: reuses `SessionPersistenceE2ETests`'s exact harness (short
// `/tmp` HOME so the daemon's `sockaddr_un` path stays under
// `SUN_LEN`, `CALYX_UITEST_SESSION_DIR` for window/tab persistence,
// `CALYX_SESSION_BIN` pinning a specific built `calyx-session` binary)
// rather than inventing a new one -- see that file's own setUp() doc
// comment for the full rationale of each piece.
//
// Row/button lookup: `SessionBrowserRowView` and `RemoteHostRowView`
// (Calyx/Features/SessionBrowser/SessionBrowserView.swift) each carry
// per-row `.accessibilityIdentifier`s from `AccessibilityID.SessionBrowser`
// (Calyx/Helpers/AccessibilityID.swift), the same pattern
// `SidebarContentView`'s tab/group rows use via
// `AccessibilityID.Sidebar`. With two or more simultaneously-Running
// sessions (the normal case: this suite's own session A + session B),
// the browser renders two identically-labeled "Attach" buttons and two
// identically-labeled "Kill" buttons, so tests below look each button
// up by its row-scoped identifier (`calyx.sessionBrowser.row.<id>
// .attachButton` / `.killButton`) rather than by label.

import XCTest

final class SessionBrowserAttachKillE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!
    private var execCounter = 0

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    /// Mirrors `SessionPersistenceE2ETests.setUp()` exactly (see that
    /// file's own doc comment for why it does NOT call
    /// `super.setUp()`, why the root must stay short, and why `HOME`
    /// itself -- not some Calyx-internal setting -- is what redirects
    /// the daemon's on-disk state).
    override func setUp() async throws {
        continueAfterFailure = false

        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        launchApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let homeDir {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        try await super.tearDown()
    }

    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = CalyxUITestCase.builtSessionBinaryPath
        terminateStaleAppUnderTestInstances()
        app.launch()
    }

    private var ledger: DaemonLedgerReader { DaemonLedgerReader(homeDir: homeDir) }

    /// The macOS "abbreviate with tilde" convention, computed
    /// independently of whatever the app itself does internally: if
    /// `path` is `home` or a descendant of it, replace exactly that
    /// `home` prefix with `"~"`; otherwise return `path` unchanged.
    /// Deliberately NOT `(path as NSString).abbreviatingWithTildeInPath`
    /// -- that API resolves `~` against the CALLING process's own real
    /// `HOME` (this XCUITest runner's, not the isolated one this
    /// suite's `homeDir` launches Calyx.app with), so it would silently
    /// compare against the wrong home and never abbreviate here.
    private func tildeAbbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// Every currently-open window EXCEPT the session browser's own
    /// (title `"Sessions"`, set once in `SessionBrowserWindowController
    /// .init`'s `window.title = "Sessions"` and never renamed) -- i.e.
    /// the count of actual Calyx main (tab-hosting) windows, the thing
    /// E2E-A's window-count assertion below cares about. A tab created
    /// by attach must not change this count; only a brand-new WINDOW
    /// would.
    private func countMainWindows() -> Int {
        app.windows.matching(NSPredicate(format: "NOT (title == %@)", "Sessions")).count
    }

    /// The visible title (`tab.titleOverride ?? tab.title`, per
    /// `SidebarContentView.swift`'s own `visibleTitle`) of every tab
    /// currently shown in the SIDEBAR (not the horizontal tab bar --
    /// see below for why), read from each row's own descendant
    /// `StaticText.value` (this codebase's established pattern for
    /// hosted-SwiftUI text: exposed via `value`, not plain `label` --
    /// same as `SessionBrowserRowView`'s row text, per this file's own
    /// header comment).
    ///
    /// Deliberately sidebar, NOT `CalyxUITestCase.countTabBarTabs()`'s
    /// tab bar: field-verified across three separate accessibility
    /// snapshots (Xcode's own auto-attached failure diagnostics) that
    /// with the Session Browser panel ALSO open, the tab bar's own row
    /// `Group` elements expose NEITHER their `calyx.tabBar.tab.<UUID>`
    /// identifier NOR their `calyx.tabBar.tab.index.N` value under any
    /// window-focus arrangement tried (a direct click, a query scoped to
    /// the specific window element, and raising the window via the
    /// standard "Window" menu were all tried and all still showed the
    /// SAME missing attributes in the resulting snapshot) -- only the
    /// row's own nested close-button `Image` carries an identifier. The
    /// SIDEBAR's equivalent rows (`calyx.sidebar.tab.<UUID>`), by
    /// contrast, exposed their identifiers cleanly in every one of those
    /// same snapshots regardless of which window was key. Every existing
    /// test using `countTabBarTabs()` elsewhere in this codebase only
    /// ever has ONE window open at a time, so this suite is the first to
    /// hit the tab bar's own limitation here.
    private func sidebarTabTitles() -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calyx.sidebar.tab.", ".closeButton"))
        return Set(rows.allElementsBoundByIndex.map { row in
            row.descendants(matching: .staticText).firstMatch.value as? String ?? ""
        })
    }

    /// Accessibility identifiers (`calyx.sidebar.tab.<UUID>`) of every
    /// sidebar tab row currently shown, excluding each row's own
    /// `.closeButton` child. Identifier-based (not title-based like
    /// `sidebarTabTitles()`), because two tabs sharing one cwd share one
    /// title, which a title Set would collapse.
    private func sidebarTabRowIdentifiers() -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calyx.sidebar.tab.", ".closeButton"))
        // Zero matches (sidebar not yet rendered) must yield [] rather than
        // resolving an element that no longer matches, which XCUITest
        // reports as a hard "Failed to get matching snapshot" error.
        guard rows.count > 0 else { return [] }
        return Set(rows.allElementsBoundByIndex.filter { $0.exists }.map { $0.identifier })
    }

    /// The first sidebar tab row (any `calyx.sidebar.tab.<UUID>` element
    /// other than a `.closeButton`), for `waitFor`-style setup waits.
    private var firstSidebarTabRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calyx.sidebar.tab.", ".closeButton"))
            .firstMatch
    }

    /// Polls `sidebarTabRowIdentifiers()` once per second (up to
    /// `timeout` seconds) until `isDone` accepts it; returns the last read.
    private func pollSidebarTabRowIdentifiers(timeout: Int, until isDone: (Set<String>) -> Bool) -> Set<String> {
        var ids = sidebarTabRowIdentifiers()
        for _ in 0..<timeout where !isDone(ids) {
            Thread.sleep(forTimeInterval: 1)
            ids = sidebarTabRowIdentifiers()
        }
        return ids
    }

    /// Opens the session browser via the View menu's "Session Browser"
    /// item (added in the same UX round as the attach-as-tab fix). This
    /// deliberately does NOT go through the command palette: the plain
    /// command-palette UI tests are pre-existing bit-rot (they fail the
    /// same way at yesterday's baseline, independent of the session
    /// work), so routing through the palette here would couple this
    /// suite to that unrelated breakage. The menu item is the direct,
    /// user-facing entry point this round added and is what we want to
    /// exercise anyway.
    private func openSessionBrowserViaMenu() {
        menuAction("View", item: "Session Browser")
    }

    /// Full Attach/Kill round trip: session A (the initial window's
    /// own persistent pane) plus session B (created Detached via the
    /// calyx-session CLI, routed through A's own pane -- see
    /// `PaneCLIExec.paneExec`'s header for why a sandboxed XCUITest
    /// runner cannot spawn `calyx-session` itself). Opens the browser,
    /// confirms both rows render with the right Running/Detached
    /// state, attaches B (asserting the daemon ledger's
    /// `attached_clients` flips to >= 1, proving a NEW client actually
    /// connected -- not merely that the row was clicked), then kills A
    /// (asserting the ledger flips A to Exited and A's row disappears
    /// from the browser on its next 1s refresh, see
    /// `SessionBrowserView`'s `.task` poll loop).
    func test_sessionBrowser_attachDetachedSession_thenKillAnotherSession() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        // Resolved and validated ONCE, up front, in THIS RUNNER process
        // (never re-read inside a pane's shell -- see PaneCLIExec.swift's
        // header for why a bare `calyx-session`/`$CALYX_SESSION_BIN`
        // inside a pane silently resolves against the real HOME instead
        // of this test's isolated one). If `CALYX_SESSION_BIN` isn't set
        // on THIS process's own environment, `sessionBinaryPath` is
        // empty, and every pane command built below would start with a
        // bare space before `--runtime-dir`, which zsh's pane shell
        // reports as "command not found: --runtime-dir" -- a confusing
        // failure this assertion catches immediately, with the actual
        // cause named, instead of surfacing 15s later as "no output" or
        // a bogus captured session id.
        let sessionBinaryPath = CalyxUITestCase.builtSessionBinaryPath
        XCTAssertFalse(
            sessionBinaryPath.isEmpty,
            "CALYX_SESSION_BIN is empty in this test runner's own process environment, " +
            "so every calyx-session command this suite pastes into a pane would be " +
            "missing its binary path entirely (the pane's login-reset shell has no " +
            "such variable of its own to fall back on -- see PaneCLIExec.swift's " +
            "header). Set CALYX_SESSION_BIN as a build setting/env var when invoking " +
            "xcodebuild test, e.g. `xcodebuild test ... CALYX_SESSION_BIN=/path/to/" +
            "calyx-session`."
        )

        // Session A: the initial window's own persistent-session pane
        // registers with the daemon asynchronously; poll rather than
        // assume it's immediate (mirrors SessionPersistenceE2ETests).
        let initialPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in sessions.filter(self.ledger.isRunning) },
            until: { !$0.isEmpty }
        )
        guard let sessionARow = initialPoll.value.first, let sessionAID = ledger.id(of: sessionARow) else {
            XCTFail(
                "No \"Running\" session appeared in the daemon's ledger within ~30s of " +
                "launch, meaning the initial window's own persistent pane never " +
                "registered. Last ledger contents: \(initialPoll.raw)"
            )
            return
        }

        // Session B: created Detached (via `calyx-session new`, which
        // never attaches -- see calyx-session/crates/cli/src/commands/
        // new.rs's own doc comment) through session A's own pane.
        // `new` prints exactly the new session's id to stdout on
        // success (new.rs: `println!("{}", info.id)`), so the pasted
        // command's captured output IS session B's id -- matching the
        // ledger on this exact id (rather than "whichever OTHER
        // session showed up") rules out a false match against some
        // unrelated entry. Explicit `--runtime-dir`/`--state-dir` flags
        // (PaneCLIExec.swift's header) are REQUIRED here: without them
        // this would silently create session B against the developer's
        // REAL `~/.calyx`, not this test's isolated homeDir.
        //
        // `--cwd` is set explicitly to a directory UNDER this suite's
        // own isolated `homeDir` (created on disk first -- `new.rs`
        // spawns session B's shell immediately with this as its cwd,
        // via `Command::current_dir`, so a nonexistent path fails the
        // spawn) so this test can compute session B's expected
        // tilde-abbreviated title independently, from these two known
        // strings, without reading anything back from the daemon.
        //
        // Created from INSIDE the pane via `mkdir -p` -- the same
        // process context `calyx-session new`'s spawned child actually
        // chdirs into -- NOT from this XCUITest runner process.
        // Field-verified (not assumed): the runner IS App-Sandboxed
        // (this file's own header / PaneCLIExec.swift's header already
        // establish this for the daemon socket/HOME override) closely
        // enough that `FileManager.createDirectory` on a NEW subpath two
        // levels under `homeDir` fails with `NSCocoaErrorDomain Code=513
        // "Operation not permitted"` even though `homeDir` itself (created
        // the same way, one level up, in `setUp()`) succeeds -- so the
        // runner-side attempt was removed rather than kept as a
        // redundant no-op. `conn.rs`'s spawn-failed error formatting
        // always blames `argv[0]` even when the real ENOENT came from
        // `Command::current_dir` chdir'ing into a directory that doesn't
        // exist, which is exactly why this diagnostic output is captured
        // and attached to every failure message below rather than left
        // for a future debugging session to rediscover.
        let sessionBCwd = "\(homeDir!)/proj/nested"
        let paneMkdirOutput = paneExec(
            "mkdir -p \(sessionBCwd) && ls -ld \(sessionBCwd); echo rc=$?",
            counter: &execCounter
        )
        XCTAssertTrue(
            paneMkdirOutput.contains("rc=0"),
            "`mkdir -p \(sessionBCwd)` from inside the pane did not report rc=0: " +
            "\(paneMkdirOutput)"
        )
        // `sessionBinaryPath` single-quoted: this is the LITERAL path
        // resolved runner-side above (never a `$CALYX_SESSION_BIN`
        // reference evaluated inside the pane's own reset shell -- see
        // this test's own up-front assertion and PaneCLIExec.swift's
        // header for why that distinction matters here).
        let sessionBID = paneExec(
            "'\(sessionBinaryPath)' \(calyxSessionRootFlags(homeDir: homeDir)) new --name sessionB --cwd \(sessionBCwd)",
            counter: &execCounter
        )
        XCTAssertFalse(
            sessionBID.isEmpty || sessionBID == "(no output)",
            "`calyx-session new` produced no output when run through session A's pane, " +
            "meaning the CLI call routed through the pane never reached the daemon (or " +
            "CALYX_SESSION_BIN isn't inherited into the pane's environment -- see " +
            "SessionPersistenceE2ETests.swift's \"Constraint discovered while writing " +
            "this\")."
        )
        // `new.rs` prints ONLY a bare ULID on success; anything containing
        // "error" is the daemon's own error text (see conn.rs's
        // spawn-failed formatting), not a session id -- caught here,
        // with the pane's own `mkdir -p`/`ls -ld` output attached, rather
        // than surfacing 15s later as a more confusing "never appeared in
        // the ledger" failure.
        XCTAssertFalse(
            sessionBID.contains("error"),
            "`calyx-session new --cwd \(sessionBCwd)` returned an error instead of a " +
            "session id: \"\(sessionBID)\". Pane's own `mkdir -p`/`ls -ld` of that same " +
            "path: \(paneMkdirOutput)"
        )

        let sessionBPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionBID, in: sessions) },
            until: { $0 != nil }
        )
        guard let sessionBRow = sessionBPoll.value else {
            XCTFail(
                "Session B (id \(sessionBID), printed by `calyx-session new`) never " +
                "appeared in the daemon's ledger within ~15s. Last ledger contents: " +
                "\(sessionBPoll.raw). Pane's own `mkdir -p`/`ls -ld` of \(sessionBCwd): " +
                "\(paneMkdirOutput)"
            )
            return
        }
        XCTAssertEqual(
            ledger.attachedClients(of: sessionBRow), 0,
            "Session B should have 0 attached_clients right after `calyx-session new` " +
            "(it never attaches), so the browser's \"Detached\" badge has something " +
            "real to reflect. Row: \(sessionBRow)"
        )

        openSessionBrowserViaMenu()
        let browserWindow = app.windows["Sessions"]
        XCTAssertTrue(waitFor(browserWindow, timeout: 10), "Session browser window (\"Sessions\") did not open.")

        // Row presence: SessionBrowserRowView's identifying Text is
        // `row.info.name ?? row.info.id` -- A has no name (created by
        // Calyx itself, not this suite), so it renders its raw id; B
        // was explicitly named "sessionB" above.
        let rowAText = app.staticTexts[sessionAID]
        let rowBText = app.staticTexts["sessionB"]
        XCTAssertTrue(waitFor(rowAText, timeout: 10), "Session A's row (id \(sessionAID)) did not appear in the browser.")
        XCTAssertTrue(waitFor(rowBText, timeout: 10), "Session B's row (\"sessionB\") did not appear in the browser.")

        // Exactly one "Detached" badge: B (isOrphan, no local surface
        // anywhere in this Calyx process) but not A (isAttachedHere,
        // still the live main-window pane). SessionBrowserRow
        // .orphanBadgeLabel is the literal string this asserts against.
        // `.matching(identifier:)`, NOT a `label`-attribute predicate --
        // field-verified on this exact app that this hosted-SwiftUI
        // text exposes its string through a different accessibility
        // attribute than plain `label`. Polled (SessionBrowserView's
        // `.task` refreshes every 1s, and B's row can render on an
        // earlier pass than the one where SessionSurfaceMap's orphan
        // check has settled) rather than checked once immediately
        // after the row's own name text appears.
        var detachedBadgeCount = app.staticTexts.matching(identifier: "Detached").count
        for _ in 0..<8 where detachedBadgeCount != 1 {
            Thread.sleep(forTimeInterval: 1)
            detachedBadgeCount = app.staticTexts.matching(identifier: "Detached").count
        }
        XCTAssertEqual(
            detachedBadgeCount, 1,
            "Expected exactly one \"Detached\" badge (session B only) within ~8s of " +
            "both rows appearing; session A is still attached to the live main-window " +
            "pane and should not show one."
        )

        // Baseline for the user-visible assertions below (window count,
        // new tab's title): captured HERE, immediately before the click
        // that triggers the attach -- not at the very start of the test
        // (field-verified: session A's own sidebar tab row has not
        // necessarily rendered yet that early). By this point session
        // A's pane has been driven through two pane-pasted commands
        // already, so its row is definitely live.
        let mainWindowCountBeforeAttach = countMainWindows()
        let sidebarTitlesBeforeAttach = sidebarTabTitles()
        // Session A's own tab: the only sidebar row present before the
        // attach adds B's tab. Captured by identifier so the post-Kill
        // assertion below can name exactly this row.
        let sidebarRowIDsBeforeAttach = sidebarTabRowIdentifiers()
        XCTAssertEqual(
            sidebarRowIDsBeforeAttach.count, 1,
            "Expected exactly one sidebar tab row (session A's) before attaching B; got \(sidebarRowIDsBeforeAttach)."
        )
        let sessionATabRowID = sidebarRowIDsBeforeAttach.first ?? "<none>"

        // Attach B: row-scoped lookup via its own accessibility
        // identifier (AccessibilityID.SessionBrowser.attachButton),
        // not the shared "Attach" label every row's button carries.
        let attachButtonForB = app.buttons["calyx.sessionBrowser.row.\(sessionBID).attachButton"]
        XCTAssertTrue(waitFor(attachButtonForB), "Session B's \"Attach\" button (id \(sessionBID)) did not appear in the browser.")
        attachButtonForB.click()

        let afterAttachPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionBID, in: sessions) },
            until: { ($0.flatMap(self.ledger.attachedClients) ?? 0) >= 1 }
        )
        XCTAssertGreaterThanOrEqual(
            afterAttachPoll.value.flatMap(ledger.attachedClients) ?? 0, 1,
            "Session B's attached_clients never reached >= 1 within ~10s of clicking " +
            "\"Attach\" on its row, meaning the browser's Attach action never actually " +
            "attached a client to the daemon-held session. Last ledger contents: " +
            "\(afterAttachPoll.raw)"
        )

        // USER-VISIBLE outcome (a): attaching B must land as a NEW TAB
        // in session A's existing window (`AppDelegate
        // .attachSessionAsTab`/`SessionAttachRoutingPolicy`), not a
        // second window -- the ledger assertion above only proves a
        // client connected, not where its surface actually appeared. A
        // regression back to "always open a new window" would leave the
        // ledger assertion green while this one catches it.
        XCTAssertEqual(
            countMainWindows(), mainWindowCountBeforeAttach,
            "The number of Calyx main windows changed after attaching session B " +
            "(before: \(mainWindowCountBeforeAttach), after: \(countMainWindows())); " +
            "attach is expected to add a TAB to the existing window, not open a new one."
        )

        // USER-VISIBLE outcome (b): the newly attached tab's title must
        // be session B's cwd, tilde-abbreviated -- NOT the `Tab.init`
        // default `"Terminal"` that a title-less attach silently falls
        // back to (`AppDelegate.attachSessionAsNewTab` constructs
        // `Tab(pwd: cwd, ...)` with no `title:` argument). Read via the
        // SIDEBAR (`sidebarTabTitles()`'s own doc comment explains why
        // NOT the tab bar), as a set difference against the baseline
        // captured above -- avoids needing to know the new tab's index
        // or identifier, neither of which this suite can otherwise pin
        // down independently of the very thing being tested. Polled
        // rather than checked once: this suite's own established idiom
        // (`detachedBadgeCount` above) for a SwiftUI re-render that may
        // lag one beat behind the ledger state this line itself just
        // waited on.
        let expectedTabTitle = tildeAbbreviated(sessionBCwd, home: homeDir)
        var sidebarTitlesAfterAttach = sidebarTabTitles()
        for _ in 0..<8 where sidebarTitlesAfterAttach.count <= sidebarTitlesBeforeAttach.count {
            Thread.sleep(forTimeInterval: 1)
            sidebarTitlesAfterAttach = sidebarTabTitles()
        }
        XCTAssertEqual(
            sidebarTitlesAfterAttach.count, sidebarTitlesBeforeAttach.count + 1,
            "Sidebar tab count did not grow by exactly one after attaching session B " +
            "(before: \(sidebarTitlesBeforeAttach), after: \(sidebarTitlesAfterAttach))."
        )
        let newTitles = sidebarTitlesAfterAttach.subtracting(sidebarTitlesBeforeAttach)
        XCTAssertEqual(
            newTitles.count, 1,
            "Expected exactly one new sidebar tab title after attaching session B; " +
            "got \(newTitles) (before: \(sidebarTitlesBeforeAttach), after: " +
            "\(sidebarTitlesAfterAttach))."
        )
        let newTabLabel = newTitles.first ?? "<none>"

        // Saved BEFORE the strict title assertions below (not after):
        // with `continueAfterFailure = false`, a screenshot placed after
        // a failing assertion never gets taken at all. For the team
        // lead to eyeball: the attached tab's actual rendered title,
        // whatever it is right now.
        saveScreenshot(name: "session-browser-attach-result")

        XCTAssertNotEqual(
            newTabLabel, "Terminal",
            "The tab attached for session B (cwd \(sessionBCwd)) still shows the " +
            "default title \"Terminal\" instead of a cwd-derived one."
        )
        XCTAssertEqual(
            newTabLabel, expectedTabTitle,
            "The tab attached for session B should show its cwd, tilde-abbreviated " +
            "against this suite's own isolated HOME (\(homeDir!)), as its title."
        )

        // Re-invoking the palette command re-raises the SAME shared
        // `SessionBrowserWindowController.shared` window (`showWindow
        // (nil)` + `makeKeyAndOrderFront(nil)`, not a duplicate) so the
        // upcoming click lands on the browser's row, not on the tab bar
        // of the window attaching B just added a tab to (same screen
        // position).
        openSessionBrowserViaMenu()
        XCTAssertTrue(waitFor(browserWindow, timeout: 10), "Session browser window did not stay open/re-raise after attaching B.")

        // Kill A: a currently-attached (not just Running) session,
        // exercising the browser's Kill action against the more
        // demanding case (see this test's own doc comment for why A,
        // not B, is killed here). Row-scoped lookup via its own
        // accessibility identifier, same as the Attach button above.
        let killButtonForA = app.buttons["calyx.sessionBrowser.row.\(sessionAID).killButton"]
        XCTAssertTrue(waitFor(killButtonForA), "Session A's \"Kill\" button (id \(sessionAID)) did not appear in the browser.")
        killButtonForA.click()

        let afterKillPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionAID, in: sessions) },
            until: { session in session.map(self.ledger.isExited) ?? false }
        )
        XCTAssertTrue(
            afterKillPoll.value.map(ledger.isExited) ?? false,
            "Session A's ledger state never flipped to Exited within ~10s of clicking " +
            "\"Kill\" on its row. Last ledger contents: \(afterKillPoll.raw)"
        )

        // The browser filters Exited sessions out of `rows` entirely
        // (SessionBrowserModel.refresh()'s own doc comment), refreshed
        // on SessionBrowserView's 1s `.task` poll -- give it a couple
        // of cycles before asserting the row is gone.
        waitForNonExistence(rowAText, timeout: 8)

        // D2: killing A must also close A's TAB. A's tab is in the
        // BACKGROUND here (attaching B made B's tab active), so its
        // SurfaceView is detached from the window hierarchy by
        // SplitContainerView; the show_child_exited notification for
        // A's pane must still reach processChildExited -> .closePane.
        let rowIDsAfterKill = pollSidebarTabRowIdentifiers(timeout: 10) { !$0.contains(sessionATabRowID) }
        XCTAssertFalse(
            rowIDsAfterKill.contains(sessionATabRowID),
            "killed session's background tab must close: session A (\(sessionAID)) was killed " +
            "from the Session Browser and is Exited in the ledger, but its tab " +
            "(\(sessionATabRowID)) is still in the sidebar ~10s later. Rows: \(rowIDsAfterKill)"
        )
    }

    /// D2 (active-tab variant): from the initial single-tab window, open
    /// a second tab (File > New Tab), which stays the ACTIVE tab; kill
    /// its session from the Session Browser and assert that tab closes,
    /// leaving exactly one tab.
    func test_sessionBrowser_killActiveTabSession_closesThatTab() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        let initialPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in sessions.filter(self.ledger.isRunning) },
            until: { !$0.isEmpty }
        )
        guard let sessionARow = initialPoll.value.first, let sessionAID = ledger.id(of: sessionARow) else {
            XCTFail("Initial window's persistent pane never registered a Running session. Ledger: \(initialPoll.raw)")
            return
        }

        XCTAssertTrue(
            waitFor(firstSidebarTabRow, timeout: 15),
            "The initial tab's sidebar row never appeared (sidebar not visible or not yet rendered)."
        )
        let rowIDsBefore = pollSidebarTabRowIdentifiers(timeout: 8) { $0.count == 1 }
        XCTAssertEqual(rowIDsBefore.count, 1, "Expected exactly one sidebar tab row at launch; got \(rowIDsBefore).")

        createNewTabViaMenu()

        let rowIDsAfterNewTab = pollSidebarTabRowIdentifiers(timeout: 8) { $0.count == 2 }
        let newTabRowIDs = rowIDsAfterNewTab.subtracting(rowIDsBefore)
        XCTAssertEqual(newTabRowIDs.count, 1, "File > New Tab did not add exactly one sidebar tab row. Before: \(rowIDsBefore), after: \(rowIDsAfterNewTab)")
        let newTabRowID = newTabRowIDs.first ?? "<none>"

        let newSessionPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 1,
            transform: { sessions in
                sessions.first { self.ledger.isRunning($0) && self.ledger.id(of: $0) != sessionAID
                    && (self.ledger.attachedClients(of: $0) ?? 0) >= 1 }
            },
            until: { $0 != nil }
        )
        guard let newSessionRow = newSessionPoll.value, let newSessionID = ledger.id(of: newSessionRow) else {
            XCTFail("The new tab's pane never registered an attached Running session. Ledger: \(newSessionPoll.raw)")
            return
        }

        openSessionBrowserViaMenu()
        let browserWindow = app.windows["Sessions"]
        XCTAssertTrue(waitFor(browserWindow, timeout: 10), "Session browser window (\"Sessions\") did not open.")
        XCTAssertTrue(
            waitFor(app.staticTexts[newSessionID], timeout: 10),
            "The new (active) tab's session row (\(newSessionID)) did not appear in the browser."
        )

        let killButton = app.buttons["calyx.sessionBrowser.row.\(newSessionID).killButton"]
        XCTAssertTrue(waitFor(killButton), "Kill button for session \(newSessionID) did not appear.")
        killButton.click()

        let afterKillPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: newSessionID, in: sessions) },
            until: { $0.map(self.ledger.isExited) ?? false }
        )
        XCTAssertTrue(
            afterKillPoll.value.map(ledger.isExited) ?? false,
            "Session \(newSessionID) never flipped to Exited within ~10s of Kill. Ledger: \(afterKillPoll.raw)"
        )

        let rowIDsAfterKill = pollSidebarTabRowIdentifiers(timeout: 10) { !$0.contains(newTabRowID) && $0.count == 1 }
        XCTAssertFalse(
            rowIDsAfterKill.contains(newTabRowID),
            "killed session's active tab must close: session \(newSessionID) is Exited but its " +
            "tab (\(newTabRowID)) is still in the sidebar ~10s later. Rows: \(rowIDsAfterKill)"
        )
        XCTAssertEqual(
            rowIDsAfterKill.count, 1,
            "Window should be back to exactly one tab after killing the active tab's session. Rows: \(rowIDsAfterKill)"
        )
    }

    /// D1: a tab restored from a snapshot whose `sessionRefs` point at a
    /// session the daemon's ledger now holds as Exited must come back
    /// daemon-backed (its pane's `attach --create` respawns a session),
    /// and that session's row must appear in the Session Browser.
    ///
    /// Approach (NOT ledger pre-seeding): the sandboxed runner cannot
    /// create `<homeDir>/.calyx/state/` itself (see this file's own
    /// `sessionBCwd` comment on Code=513), so the Exited record is
    /// produced for real: session A's own pane schedules a delayed
    /// `calyx-session kill A` (nohup, backgrounded -- it runs inside the
    /// daemon-held shell, so it outlives Calyx.app), the app is quit via
    /// its menu so the snapshot is saved with A's sessionRef intact (the
    /// kill lands only after the app is gone, so no child-exit close can
    /// remove the tab from the snapshot), the ledger is polled until A
    /// is Exited, and the app is relaunched with the same HOME/session dir.
    func test_restoredTabWhoseSessionExited_isDaemonBackedAfterRelaunch() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")
        let sessionBinaryPath = CalyxUITestCase.builtSessionBinaryPath
        XCTAssertFalse(sessionBinaryPath.isEmpty, "CALYX_SESSION_BIN is empty in the test runner's environment.")

        let initialPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in
                sessions.first { self.ledger.isRunning($0) && (self.ledger.attachedClients(of: $0) ?? 0) >= 1 }
            },
            until: { $0 != nil }
        )
        guard let sessionARow = initialPoll.value, let sessionAID = ledger.id(of: sessionARow) else {
            XCTFail("Initial window's persistent pane never registered an attached Running session. Ledger: \(initialPoll.raw)")
            return
        }

        panePasteAndReturn(
            "nohup sh -c \"sleep 8; '\(sessionBinaryPath)' \(calyxSessionRootFlags(homeDir: homeDir)) kill \(sessionAID)\" >/dev/null 2>&1 &"
        )
        // Let the pane's shell actually fork the background job before quitting.
        Thread.sleep(forTimeInterval: 2)

        menuAction("Calyx", item: "Quit Calyx")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App did not terminate within 10s of Quit.")

        let exitedPoll = ledger.poll(
            timeoutAttempts: 20, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionAID, in: sessions) },
            until: { $0.map(self.ledger.isExited) ?? false }
        )
        XCTAssertTrue(
            exitedPoll.value.map(ledger.isExited) ?? false,
            "Setup: session A (\(sessionAID)) never became Exited after the delayed kill. Ledger: \(exitedPoll.raw)"
        )

        launchApp()
        XCTAssertTrue(waitFor(app.windows.firstMatch, timeout: 10), "App window did not reappear after relaunch.")

        // Expected: the restored tab's pane runs `attach <A> --create`,
        // which respawns a Running session (same id expected; any
        // Running+attached session is accepted in case the daemon
        // assigns a fresh id) with a client attached.
        let restoredPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in
                sessions.first { self.ledger.isRunning($0) && (self.ledger.attachedClients(of: $0) ?? 0) >= 1 }
            },
            until: { $0 != nil }
        )
        guard let restoredRow = restoredPoll.value, let restoredID = ledger.id(of: restoredRow) else {
            XCTFail(
                "restored tab must be daemon-backed: after relaunching with a snapshot whose tab " +
                "referenced Exited session \(sessionAID), no Running session with an attached " +
                "client appeared in the ledger within ~30s. Ledger: \(restoredPoll.raw)"
            )
            return
        }

        openSessionBrowserViaMenu()
        XCTAssertTrue(waitFor(app.windows["Sessions"], timeout: 10), "Session browser window did not open.")
        XCTAssertTrue(
            waitFor(app.staticTexts[restoredID], timeout: 10),
            "restored tab's session row must appear in the Session Browser: Running session " +
            "\(restoredID) (restored from Exited \(sessionAID)) has no row."
        )
    }
}
