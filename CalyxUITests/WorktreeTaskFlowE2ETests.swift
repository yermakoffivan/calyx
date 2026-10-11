// WorktreeTaskFlowE2ETests.swift
// CalyxUITests
//
// End-to-end Worktree Task flow (Revision 1): Cmd+Shift+N in a pane
// inside a real git repo, create `task/e2e`, check a new tab opened and
// the linked worktree exists under the session root, commit in it, then
// merge from the Changes sidebar's task menu and check the worktree,
// branch and tab are gone and main ends on a merge commit.
//
// Seams:
// - All git/filesystem work runs in a live pane's shell via `paneExec`:
//   the sandboxed runner cannot exec `/usr/bin/git` (xcrun shim) nor
//   write under /tmp.
// - `HOME` is overridden to a test-owned directory, because
//   `SessionRootResolver` reads `HOME` and the task worktree lands at
//   `<root>/.calyx/worktrees/<repo>/<branch>`; without this the test
//   would write into the developer's real `~/.calyx`. It is spelled
//   `/private/tmp/...` so the path git reports and the one asserted here
//   match.
// - `CALYX_UITEST_WORKTREE_TASK_ARGV` (fields separated by U+001F),
//   honoured only under `--uitesting`, replaces the agent CLI argv so no
//   real agent runs. The process reports its cwd via OSC 7 before
//   sleeping, so the task pane has a known cwd inside the worktree and
//   merge can find and close it. The stub then exits at once; production
//   spawns `<agent>; exec <shell> -i -l`, so the pane must continue as an
//   interactive login shell in the worktree, which the test drives.

import XCTest

final class WorktreeTaskFlowE2ETests: CalyxUITestCase {

    private var homeDir: String = ""
    private var repoDir: String = ""
    private let repoName = "e2erepo"
    private var counter = 0
    /// Tab-bar identifier of the tab whose pane runs a plain shell, recorded
    /// before the task tab opens so tearDown can return to it for cleanup.
    private var originalTabID: String?

    private static let fieldSeparator = "\u{1F}"
    private static let taskArgv = [
        "/bin/sh", "-c",
        "printf '\\033]7;file://localhost%s\\007' \"$PWD\"; exit 0",
    ]

    override var additionalLaunchEnvironment: [String: String] {
        [
            "HOME": homeDir,
            "CALYX_UITEST_WORKTREE_TASK_ARGV": Self.taskArgv.joined(separator: Self.fieldSeparator),
        ]
    }

    private var worktreePath: String {
        homeDir + "/.calyx/worktrees/" + repoName + "/task-e2e"
    }

    override func setUp() async throws {
        // Canonical spelling (/private/tmp, not /tmp) so the paths git and
        // the app report match the ones asserted here. The sandboxed runner
        // cannot create it; the pane's shell does, once the app is up.
        // Characters stay within typeIntoPane's layout-invariant set.
        homeDir = "/private/tmp/cxwt-" + UUID().uuidString.prefix(8).lowercased()
        repoDir = homeDir + "/" + repoName
        try await super.setUp()
    }

    override func tearDown() async throws {
        // The scratch HOME (repo, `.calyx/worktrees/...`) was created by the
        // pane's shell; the sandboxed test runner cannot delete it, so the
        // pane must remove it before super.tearDown() terminates the app.
        // Runs on failure too, since XCTest always calls tearDown.
        removeScratchHomeViaPane()
        try await super.tearDown()
        // Fallback only; normally fails silently under the runner sandbox.
        if !homeDir.isEmpty {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
    }

    private func removeScratchHomeViaPane() {
        guard !homeDir.isEmpty, let app, app.state == .runningForeground || app.state == .runningBackground else { return }
        // Dismiss the New Worktree Task sheet if a failure left it up.
        let sheet = element("calyx.worktreeTask.sheet")
        if sheet.exists {
            app.typeKey(.escape, modifierFlags: [])
            _ = waitUntil(timeout: 5) { !sheet.exists }
        }
        if let originalTabID {
            let tab = element(originalTabID)
            if tab.exists { tab.click() }
        }
        let pane = app.textViews
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.terminal.pane."))
            .firstMatch
        guard pane.waitForExistence(timeout: 5) else { return }
        pane.click()
        // cd out first: the pane's cwd may lie inside the tree being removed.
        _ = shell("cd / && rm -rf '\(homeDir)' && echo removed")
    }

    // MARK: - Helpers

    /// Runs `sh -c`-style git work in the focused pane's real shell with an
    /// isolated git config, returning its combined output.
    @discardableResult
    private func shell(_ script: String) -> String {
        paneExec("(export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C; \(script))", counter: &counter, timeoutAttempts: 40)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    // MARK: - Test

    func test_createTask_opensPaneInWorktree_andMergeRemovesIt() {
        XCTAssertTrue(waitFor(app.windows.firstMatch, timeout: 10), "main window did not appear")
        let pane = app.textViews
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.terminal.pane."))
            .firstMatch
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane AX text area not found")
        pane.click()

        let initOut = shell("mkdir -p '\(repoDir)' && cd '\(repoDir)' && git init -q -b main && git config user.name t && git config user.email t@e && git commit -q --allow-empty -m init && echo ready")
        XCTAssertEqual(initOut, "ready", "fixture repo setup failed: \(initOut)")
        typeIntoPane("cd \(repoDir)\n")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(shell("pwd"), repoDir, "pane cwd must be the fixture repo")

        let originalTabCount = countTabBarTabs()
        let originalTabIDs = currentTabBarTabIdentifiers()
        originalTabID = originalTabIDs.first

        // Create the task from the sheet.
        pane.click()
        app.typeKey("n", modifierFlags: [.command, .shift])
        let sheet = element("calyx.worktreeTask.sheet")
        XCTAssertTrue(waitFor(sheet, timeout: 10), "New Worktree Task sheet should appear on Cmd+Shift+N")
        let branchField = element("calyx.worktreeTask.branchField")
        XCTAssertTrue(waitFor(branchField))
        branchField.click()
        branchField.typeText("task/e2e")
        let createButton = element("calyx.worktreeTask.createButton")
        XCTAssertTrue(waitUntil(timeout: 10) { createButton.exists && createButton.isEnabled },
                      "Create should enable once the repository is described and a branch is typed")
        createButton.click()

        XCTAssertTrue(waitForTabCount(originalTabCount + 1, timeout: 15), "creating a task must open one new tab")
        // The new task tab takes focus. Its stub agent has already exited,
        // so the pane must now be a live login shell in the worktree:
        // drive it directly, without switching tabs.
        Thread.sleep(forTimeInterval: 2)
        var taskPwd = ""
        XCTAssertTrue(waitUntil(timeout: 30) {
            taskPwd = self.shell("pwd")
            return taskPwd == self.worktreePath
        }, "after the agent exits the task pane must be a shell in the worktree; pwd: \(taskPwd)")
        let worktreeList = shell("git -C '\(repoDir)' worktree list")
        XCTAssertTrue(worktreeList.contains(worktreePath), "git worktree list must contain the task: \(worktreeList)")

        // Work in the task, through the task pane's own shell.
        let commitOut = shell("echo task > '\(worktreePath)/task.txt' && git -C '\(worktreePath)' add task.txt && git -C '\(worktreePath)' commit -q -m 'task work' && echo committed")
        XCTAssertEqual(commitOut, "committed", "commit in worktree failed: \(commitOut)")

        // Return to the original tab (shell in the repo) for the merge,
        // since merge closes the task tab.
        if let originalTabID = originalTabIDs.first {
            element(originalTabID).click()
            Thread.sleep(forTimeInterval: 1)
            pane.click()
        }

        // Merge from the Changes sidebar.
        openCommandPaletteViaMenu()
        let searchField = element("calyx.commandPalette.searchField")
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")
        searchField.typeText("Show Git Changes")
        searchField.typeKey(.enter, modifierFlags: [])

        let taskMenu = element("calyx.git.taskMenu.\(worktreePath)")
        let taskMenuAppeared = waitFor(taskMenu, timeout: 20)
        if !taskMenuAppeared {
            let gitIDs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.git"))
                .allElementsBoundByIndex.map(\.identifier)
            print("WorktreeTaskFlowE2E git identifiers: \(gitIDs)")
        }
        XCTAssertTrue(taskMenuAppeared, "the task's menu must appear in the Changes sidebar")
        taskMenu.click()
        let mergeItem = element("calyx.git.taskMergeItem.\(worktreePath)")
        XCTAssertTrue(waitFor(mergeItem, timeout: 5), "the task menu must offer Merge")
        mergeItem.click()

        XCTAssertTrue(waitUntil(timeout: 15) { self.shell("test -d '\(self.worktreePath)' && echo yes || echo no") == "no" },
                      "merge must remove the task worktree")
        let parents = shell("git -C '\(repoDir)' rev-list --parents -n1 main")
        XCTAssertEqual(parents.split(separator: " ").count, 3, "main must end on a merge commit: \(parents)")
        XCTAssertTrue(shell("git -C '\(repoDir)' log --oneline main").contains("task work"))
        XCTAssertEqual(shell("git -C '\(repoDir)' branch --list task/e2e; echo end"), "end", "the task branch must be deleted")
        XCTAssertTrue(waitForTabCount(originalTabCount, timeout: 15), "the task's tab must close after merge")
        XCTAssertTrue(app.windows.firstMatch.exists, "the window must survive the merge")
        XCTAssertNotEqual(app.state, .notRunning, "the app must still be running")
    }
}
