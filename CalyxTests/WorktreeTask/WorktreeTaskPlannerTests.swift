// WorktreeTaskPlannerTests.swift
// CalyxTests
//
// Pins WorktreeTaskPlanner, the pure half of Worktree Tasks: where a
// task's worktree lives, the argv each agent CLI is spawned with,
// which worktree hosts a branch, which panes sit inside a worktree,
// and whether closing them would empty the window.

import Foundation
import Testing
@testable import Calyx

struct WorktreeTaskPlannerTests {

    // MARK: - worktreePath

    @Test func test_worktreePath_replacesSlashesInBranchWithDashes() {
        let path = WorktreeTaskPlanner.worktreePath(
            sessionRoot: "/Users/dev",
            repoDisplayName: "Calyx",
            branch: "task/fix/login"
        )
        #expect(path == "/Users/dev/.calyx/worktrees/Calyx/task-fix-login")
    }

    @Test func test_worktreePath_plainBranch() {
        let path = WorktreeTaskPlanner.worktreePath(
            sessionRoot: "/Users/dev",
            repoDisplayName: "repo",
            branch: "demo"
        )
        #expect(path == "/Users/dev/.calyx/worktrees/repo/demo")
    }

    // MARK: - Agent kinds

    @Test func test_agentKind_baseArgv() {
        #expect(WorktreeTaskAgentKind.claudeCode.baseArgv == ["claude"])
        #expect(WorktreeTaskAgentKind.codex.baseArgv == ["codex"])
        #expect(WorktreeTaskAgentKind.openCode.baseArgv == ["opencode"])
        #expect(WorktreeTaskAgentKind.hermes.baseArgv == ["hermes", "chat"])
        #expect(WorktreeTaskAgentKind.grok.baseArgv == ["grok"])
        #expect(WorktreeTaskAgentKind.pi.baseArgv == ["pi"])
        #expect(WorktreeTaskAgentKind.allCases.count == 6)
    }

    @Test func test_agentKind_displayNamesAreNonEmptyAndDistinct() {
        let names = WorktreeTaskAgentKind.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    // MARK: - launchPlan: positional-argument kinds

    /// Trimmed, but the inner `'` and newline survive verbatim: the
    /// prompt is one argv element, never parsed by a shell.
    private let trickyPrompt = "  fix Bob's bug\nthen test \n"
    private let trimmedTricky = "fix Bob's bug\nthen test"

    @Test func test_launchPlan_claudeCode_promptIsOneArgvElement() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["claude", trimmedTricky]))
    }

    @Test func test_launchPlan_codex_promptIsOneArgvElement() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .codex, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["codex", trimmedTricky]))
    }

    @Test func test_launchPlan_grok_promptIsOneArgvElement() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .grok, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["grok", trimmedTricky]))
    }

    @Test func test_launchPlan_pi_promptIsOneArgvElement() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .pi, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["pi", trimmedTricky]))
    }

    @Test func test_launchPlan_claudeCode_simplePrompt() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: "add tests")
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["claude", "add tests"]))
    }

    // MARK: - launchPlan: flag kinds

    @Test func test_launchPlan_openCode_promptAfterPromptFlag() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .openCode, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["opencode", "--prompt", trimmedTricky]))
    }

    /// `hermes chat -q` is single-query mode (answers once and exits),
    /// so Hermes launches interactive and the prompt is ignored.
    @Test func test_launchPlan_hermes_ignoresPrompt() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .hermes, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["hermes", "chat"]))
    }

    // MARK: - launchPlan: empty prompt

    @Test func test_launchPlan_emptyOrWhitespacePrompt_isBareArgv() {
        let expected: [WorktreeTaskAgentKind: [String]] = [
            .claudeCode: ["claude"], .codex: ["codex"], .openCode: ["opencode"],
            .hermes: ["hermes", "chat"], .grok: ["grok"], .pi: ["pi"],
        ]
        for kind in WorktreeTaskAgentKind.allCases {
            for prompt in ["", "  \n "] {
                let plan = WorktreeTaskPlanner.launchPlan(agent: kind, prompt: prompt)
                #expect(plan == WorktreeTaskLaunchPlan(argv: expected[kind]!),
                        "kind \(kind.rawValue), prompt \(prompt.debugDescription)")
            }
        }
    }

    // MARK: - launchPlan: prompt starting with "-"

    @Test func test_launchPlan_dashPrompt_positionalKindsGetOptionTerminator() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: "  --help me ")
        #expect(plan == WorktreeTaskLaunchPlan(argv: ["claude", "--", "--help me"]))
        let expected: [WorktreeTaskAgentKind: [String]] = [
            .claudeCode: ["claude", "--", "-x"], .codex: ["codex", "--", "-x"],
            .grok: ["grok", "--", "-x"], .pi: ["pi", "--", "-x"],
        ]
        for (kind, argv) in expected {
            #expect(WorktreeTaskPlanner.launchPlan(agent: kind, prompt: "-x").argv == argv, "kind \(kind.rawValue)")
        }
    }

    @Test func test_launchPlan_dashPrompt_flagKindsGetNoOptionTerminator() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .openCode, prompt: "-x")
            == WorktreeTaskLaunchPlan(argv: ["opencode", "--prompt", "-x"]))
        #expect(WorktreeTaskPlanner.launchPlan(agent: .hermes, prompt: "-x")
            == WorktreeTaskLaunchPlan(argv: ["hermes", "chat"]))
    }

    @Test func test_launchPlan_innerDashPrompt_noOptionTerminator() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .codex, prompt: "fix -x")
        #expect(plan.argv == ["codex", "fix -x"])
    }

    // MARK: - launchPlan with arguments

    private let args = ["--model", "opus", "-x"]

    @Test func test_launchPlan_arguments_doubleDashKinds_terminatorBeforePrompt() {
        for (kind, program) in [(WorktreeTaskAgentKind.claudeCode, "claude"), (.codex, "codex"), (.grok, "grok")] {
            #expect(WorktreeTaskPlanner.launchPlan(agent: kind, arguments: args, prompt: " fix it ").argv
                == [program, "--model", "opus", "-x", "--", "fix it"], "\(kind.rawValue)")
        }
    }

    /// pi's handling of `--` after other options is unverified, so it
    /// keeps the dash-only rule.
    @Test func test_launchPlan_arguments_pi_terminatorOnlyForDashPrompt() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .pi, arguments: args, prompt: " fix it ").argv
            == ["pi", "--model", "opus", "-x", "fix it"])
        #expect(WorktreeTaskPlanner.launchPlan(agent: .pi, arguments: args, prompt: "-y").argv
            == ["pi", "--model", "opus", "-x", "--", "-y"])
    }

    @Test func test_launchPlan_noArguments_plainPrompt_noTerminator() {
        for (kind, program) in [(WorktreeTaskAgentKind.claudeCode, "claude"), (.codex, "codex"), (.grok, "grok"), (.pi, "pi")] {
            #expect(WorktreeTaskPlanner.launchPlan(agent: kind, arguments: [], prompt: "fix it").argv
                == [program, "fix it"], "\(kind.rawValue)")
        }
    }

    @Test func test_launchPlan_arguments_dashPrompt_terminatorOnlyBeforePrompt() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .claudeCode, arguments: ["--model", "opus"], prompt: "-x").argv
            == ["claude", "--model", "opus", "--", "-x"])
        #expect(WorktreeTaskPlanner.launchPlan(agent: .codex, arguments: ["--model", "opus"], prompt: "-x").argv
            == ["codex", "--model", "opus", "--", "-x"])
    }

    @Test func test_launchPlan_arguments_openCode_beforePromptFlag() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .openCode, arguments: args, prompt: "go").argv
            == ["opencode", "--model", "opus", "-x", "--prompt", "go"])
    }

    @Test func test_launchPlan_arguments_hermes_afterChatPromptIgnored() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .hermes, arguments: args, prompt: "go").argv
            == ["hermes", "chat", "--model", "opus", "-x"])
    }

    @Test func test_launchPlan_arguments_emptyPrompt_baseArgvPlusArguments() {
        let expected: [WorktreeTaskAgentKind: [String]] = [
            .claudeCode: ["claude", "-a", "b c"], .codex: ["codex", "-a", "b c"],
            .openCode: ["opencode", "-a", "b c"], .hermes: ["hermes", "chat", "-a", "b c"],
            .grok: ["grok", "-a", "b c"], .pi: ["pi", "-a", "b c"],
        ]
        for kind in WorktreeTaskAgentKind.allCases {
            #expect(WorktreeTaskPlanner.launchPlan(agent: kind, arguments: ["-a", "b c"], prompt: "  ").argv
                == expected[kind], "\(kind.rawValue)")
        }
    }

    @Test func test_launchPlan_arguments_passedVerbatimWithoutTerminatorOrTrimming() {
        let verbatim = ["--", "-", " spaced ", "", "--prompt"]
        #expect(WorktreeTaskPlanner.launchPlan(agent: .claudeCode, arguments: verbatim, prompt: "").argv
            == ["claude", "--", "-", " spaced ", "", "--prompt"])
    }

    @Test func test_launchPlan_defaultArguments_isUnchanged() {
        #expect(WorktreeTaskPlanner.launchPlan(agent: .claudeCode, arguments: [], prompt: "hi").argv == ["claude", "hi"])
    }

    // MARK: - spawnArgv

    @Test func test_spawnArgv_wrapsInInteractiveLoginShellExecWithEveryTokenQuoted() {
        let argv = WorktreeTaskPlanner.spawnArgv(
            launchArgv: ["claude", "fix Bob's bug\nthen test"],
            loginShell: "/bin/zsh"
        )
        #expect(argv == ["/bin/zsh", "-i", "-l", "-c", "'claude' 'fix Bob'\\''s bug\nthen test'; exec '/bin/zsh' -i -l"])
    }

    @Test func test_spawnArgv_bareArgvAndOtherShell() {
        let argv = WorktreeTaskPlanner.spawnArgv(launchArgv: ["hermes", "chat"], loginShell: "/opt/homebrew/bin/bash")
        #expect(argv == ["/opt/homebrew/bin/bash", "-i", "-l", "-c", "'hermes' 'chat'; exec '/opt/homebrew/bin/bash' -i -l"])
    }

    /// Writes a stub agent named `claude` (prints its argv NUL-separated,
    /// then exits with `$STUB_AGENT_EXIT`, default 0) and a stub login
    /// shell into a fresh temp dir. The stub shell, given `-i -l` alone
    /// (the trailing `exec <shell> -i -l`), prints `SHELL-STARTED`;
    /// otherwise it runs its `-c` string in interactive zsh (history
    /// expansion on, rc files off via -f).
    private func makeStubs() throws -> (dir: URL, shell: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-loginshell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agent = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf '%s\\0' "$(basename "$0")" "$@"
        exit "${STUB_AGENT_EXIT:-0}"

        """.write(to: agent, atomically: true, encoding: .utf8)
        let shell = dir.appendingPathComponent("fake-login-shell")
        try """
        #!/bin/sh
        if [ "$#" -eq 2 ] && [ "$1" = "-i" ] && [ "$2" = "-l" ]; then printf 'SHELL-STARTED'; exit 0; fi
        for last; do :; done
        exec /bin/zsh -f -i -l -c "$last"

        """.write(to: shell, atomically: true, encoding: .utf8)
        for file in [agent, shell] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return (dir, shell.path)
    }

    /// Runs `spawnArgv` through ghostty's layer-1 wrapper
    /// (`/bin/bash --noprofile --norc -c "exec -l <command>"`, see
    /// ghostty/src/termio/Exec.zig) and returns stdout.
    private func runThroughGhosttyLayer(_ argv: [String], stubDir: URL, agentExit: Int32 = 0) throws -> String {
        let command = argv.map(SessionCommandSynthesizer.shSafeToken).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l " + command]
        process.environment = [
            "PATH": stubDir.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
            "STUB_AGENT_EXIT": String(agentExit),
        ]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Splits stub output into the agent's argv and asserts the login
    /// shell marker follows it (the shell starts after the agent exits).
    private func agentArgvThenShell(_ text: String, _ comment: Comment) -> [String] {
        let marker = "SHELL-STARTED"
        #expect(text.hasSuffix(marker), comment)
        var tokens = String(text.dropLast(text.hasSuffix(marker) ? marker.count : 0)).components(separatedBy: "\0")
        if tokens.last == "" { tokens.removeLast() }
        return tokens
    }

    /// The `-c` string must hand the agent exactly the original argv
    /// (quote and newline intact), then start the login shell whether
    /// the agent exited zero or non-zero.
    @Test func test_spawnArgv_runsAgentThenInteractiveLoginShellRegardlessOfExitStatus() throws {
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs.dir) }
        let launch = ["claude", "%s|", "it's", "a\nb", "--x"]
        let argv = WorktreeTaskPlanner.spawnArgv(launchArgv: launch, loginShell: stubs.shell)
        #expect(argv.dropLast() == [stubs.shell, "-i", "-l", "-c"])
        for status: Int32 in [0, 1, 127] {
            let text = try runThroughGhosttyLayer(argv, stubDir: stubs.dir, agentExit: status)
            #expect(agentArgvThenShell(text, "exit \(status)") == launch, "exit \(status)")
        }
    }

    /// Regression guard for shell injection through the prompt. Emulates
    /// both shell layers the passthrough spawn relies on:
    /// - Layer 1 (ghostty on macOS, ghostty/src/termio/Exec.zig, `.shell`
    ///   case): `/bin/bash --noprofile --norc -c "exec -l <command>"` where
    ///   `<command>` is built exactly like `CalyxWindowController.createManagedSurface`.
    /// - Layer 2: the login shell `[shell, "-i", "-l", "-c", "'<tok>' ...; exec '<shell>' -i -l"]`
    ///   from `spawnArgv`, emulated by interactive zsh with a stub `claude`
    ///   on PATH that dumps its argv.
    @Test func test_spawnArgv_hostilePrompts_surviveGhosttyAndLoginShellLayersWithoutExecution() throws {
        let pwned = "/tmp/CALYX_PWNED"
        defer { try? FileManager.default.removeItem(atPath: pwned) }
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs.dir) }

        let corpus = [
            "fix Bob's bug\nthen test", "$(touch /tmp/CALYX_PWNED) `id`", "!! !$ ^foo^bar",
            "say \"hi\" ; rm -rf x", "--help me", "a\\b\\\\c", "日本語 'quoted'", "$HOME ${HOME} ~",
            "*.swift ?", "#comment", "&& echo x | cat > /dev/null", "", "   ",
        ]
        let arguments = ["--model", "opus", "--effort", "it's high"]
        for prompt in corpus {
            for args in [[], arguments] {
                let expected = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, arguments: args, prompt: prompt).argv
                #expect(Array(expected.prefix(args.count + 1)) == ["claude"] + args)
                let argv = WorktreeTaskPlanner.spawnArgv(launchArgv: expected, loginShell: stubs.shell)
                let text = try runThroughGhosttyLayer(argv, stubDir: stubs.dir)
                let comment: Comment = "arguments \(args), prompt: \(prompt.debugDescription)"
                #expect(agentArgvThenShell(text, comment) == expected, comment)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: pwned))
    }

    // MARK: - loginShell

    @Test func test_loginShell_prefersPasswdThenEnvironmentThenZsh() {
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: "/bin/bash", environmentShell: "/bin/ksh") == "/bin/bash")
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: nil, environmentShell: "/bin/ksh") == "/bin/ksh")
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: "", environmentShell: "/bin/ksh") == "/bin/ksh")
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: nil, environmentShell: nil) == "/bin/zsh")
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: nil, environmentShell: "") == "/bin/zsh")
    }

    @Test func test_loginShell_nonPOSIXShellFallsBackToZsh() {
        for shell in ["/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/opt/homebrew/bin/nu"] {
            #expect(WorktreeTaskPlanner.loginShell(passwdShell: shell, environmentShell: "/bin/bash") == "/bin/zsh",
                    "\(shell)")
            #expect(WorktreeTaskPlanner.loginShell(passwdShell: nil, environmentShell: shell) == "/bin/zsh", "\(shell)")
        }
        #expect(WorktreeTaskPlanner.loginShell(passwdShell: "/usr/local/bin/fishy", environmentShell: nil)
            == "/usr/local/bin/fishy", "only exact basenames are non-POSIX")
    }

    // MARK: - acceptsInitialPrompt

    @Test func test_acceptsInitialPrompt_falseOnlyForHermes() {
        for kind in WorktreeTaskAgentKind.allCases {
            #expect(kind.acceptsInitialPrompt == (kind != .hermes), "kind \(kind.rawValue)")
        }
    }

    @Test @MainActor func test_sheetModel_acceptsPromptFollowsSelectedAgent() {
        let model = WorktreeTaskSheetModel()
        #expect(model.acceptsPrompt)
        model.agent = .hermes
        #expect(!model.acceptsPrompt)
        model.agent = .codex
        #expect(model.acceptsPrompt)
    }

    // MARK: - Sheet model arguments

    @MainActor private func readyModel() -> WorktreeTaskSheetModel {
        let model = WorktreeTaskSheetModel()
        model.apply(WorktreeTaskRepositoryDescription(
            location: GitRepositoryLocation(workTree: "/r", gitDirectory: "/r/.git", gitCommonDirectory: "/r/.git"),
            displayName: "r", localBranches: ["main"], headBranch: "main"
        ))
        model.branch = "task/x"
        return model
    }

    @Test @MainActor func test_sheetModel_requestArgumentsParsedFromText() {
        let model = readyModel()
        #expect(model.request.arguments == [])
        model.argumentsText = "--model opus --effort 'very high'"
        #expect(model.argumentsError == nil)
        #expect(model.canCreate)
        #expect(model.request.arguments == ["--model", "opus", "--effort", "very high"])
    }

    @Test @MainActor func test_sheetModel_invalidArgumentsBlockCreateUntilFixed() {
        let model = readyModel()
        #expect(model.canCreate)
        model.argumentsText = "--x 'oops"
        #expect(model.argumentsError != nil)
        #expect(model.argumentsError?.isEmpty == false)
        #expect(!model.canCreate)
        model.argumentsText = "--x 'oops'"
        #expect(model.argumentsError == nil)
        #expect(model.canCreate)
        #expect(model.request.arguments == ["--x", "oops"])
    }

    @Test @MainActor func test_sheetModel_danglingEscapeSetsError_escapedBackslashDoesNot() {
        let model = readyModel()
        model.argumentsText = "--x tail\\"          // text: --x tail\   (dangling)
        #expect(model.argumentsError != nil)
        #expect(!model.canCreate)
        model.argumentsText = "--x tail\\\\"        // text: --x tail\\  (escaped backslash)
        #expect(model.argumentsError == nil)
        #expect(model.request.arguments == ["--x", "tail\\"])
    }

    @Test @MainActor func test_sheetModel_beginCreate_marksBusyAtOnceSoASecondIsRefused() throws {
        let model = readyModel()

        let first = try #require(model.beginCreate())
        #expect(first.request.branch == "task/x")
        #expect(model.isLoading)
        #expect(model.beginCreate() == nil)
    }

    @Test @MainActor func test_sheetModel_agentChangeKeepsTextAndRevalidates() {
        let model = readyModel()
        model.argumentsText = "'broken"
        #expect(model.argumentsError != nil)
        model.agent = .codex
        #expect(model.argumentsText == "'broken", "switching agents keeps the typed text")
        #expect(model.argumentsError != nil)
        #expect(!model.canCreate)
        model.argumentsText = "--model o3"
        model.agent = .claudeCode
        #expect(model.argumentsText == "--model o3")
        #expect(model.argumentsError == nil)
        #expect(model.canCreate)
    }

    // MARK: - worktreeHosting

    @Test func test_worktreeHosting_returnsPathOfWorktreeWithBranch() {
        let worktrees = [
            GitWorktreeInfo(path: "/r/main", branchRef: "refs/heads/main"),
            GitWorktreeInfo(path: "/r/feature", branchRef: "refs/heads/feature"),
        ]
        #expect(WorktreeTaskPlanner.worktreeHosting(branch: "main", in: worktrees) == "/r/main")
        #expect(WorktreeTaskPlanner.worktreeHosting(branch: "feature", in: worktrees) == "/r/feature")
    }

    @Test func test_worktreeHosting_skipsBareAndPrunable() {
        let worktrees = [
            GitWorktreeInfo(path: "/r/bare.git", branchRef: "refs/heads/main", isBare: true),
            GitWorktreeInfo(path: "/r/gone", branchRef: "refs/heads/main", isPrunable: true),
            GitWorktreeInfo(path: "/r/live", branchRef: "refs/heads/main"),
        ]
        #expect(WorktreeTaskPlanner.worktreeHosting(branch: "main", in: worktrees) == "/r/live")
        #expect(WorktreeTaskPlanner.worktreeHosting(branch: "main", in: Array(worktrees.prefix(2))) == nil)
    }

    @Test func test_worktreeHosting_nilWhenNoMatchAndDoesNotPrefixMatch() {
        let worktrees = [
            GitWorktreeInfo(path: "/r/a", branchRef: "refs/heads/main-old"),
            GitWorktreeInfo(path: "/r/b", headOID: "abc", isDetached: true),
        ]
        #expect(WorktreeTaskPlanner.worktreeHosting(branch: "main", in: worktrees) == nil)
    }

    // MARK: - surfacesInside

    private func pane(_ id: UUID, cwd: String?) -> CockpitPaneInfo {
        CockpitPaneInfo(
            surfaceID: id, windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "Shell", title: nil, cwd: cwd, isFocused: false,
            agentKind: nil, calyxSessionID: nil
        )
    }

    @Test func test_surfacesInside_matchesExactAndDescendantPathsOnly() {
        let exact = UUID(), nested = UUID(), sibling = UUID(), outside = UUID(), noCwd = UUID()
        let panes = [
            pane(exact, cwd: "/w/t"),
            pane(nested, cwd: "/w/t/src/app"),
            pane(sibling, cwd: "/w/t2"),
            pane(outside, cwd: "/w"),
            pane(noCwd, cwd: nil),
        ]
        #expect(WorktreeTaskPlanner.surfacesInside(path: "/w/t", panes: panes) == [exact, nested])
    }

    @Test func test_surfacesInside_emptyWhenNone() {
        #expect(WorktreeTaskPlanner.surfacesInside(path: "/w/t", panes: [pane(UUID(), cwd: "/x")]).isEmpty)
    }

    // MARK: - needsReplacementTab

    @Test func test_needsReplacementTab() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [a, b], closing: [a, b]) == true)
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [a], closing: [a, c]) == true)
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [a, b], closing: [a]) == false)
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [a], closing: []) == false)
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [], closing: [a]) == false)
        #expect(WorktreeTaskPlanner.needsReplacementTab(windowLeafIDs: [], closing: []) == false)
    }
}
