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

    // MARK: - spawnArgv

    @Test func test_spawnArgv_wrapsInInteractiveLoginShellExecWithEveryTokenQuoted() {
        let argv = WorktreeTaskPlanner.spawnArgv(
            launchArgv: ["claude", "fix Bob's bug\nthen test"],
            loginShell: "/bin/zsh"
        )
        #expect(argv == ["/bin/zsh", "-i", "-l", "-c", "exec 'claude' 'fix Bob'\\''s bug\nthen test'"])
    }

    @Test func test_spawnArgv_bareArgvAndOtherShell() {
        let argv = WorktreeTaskPlanner.spawnArgv(launchArgv: ["hermes", "chat"], loginShell: "/opt/homebrew/bin/bash")
        #expect(argv == ["/opt/homebrew/bin/bash", "-i", "-l", "-c", "exec 'hermes' 'chat'"])
    }

    /// The `-c` string, run by a real `/bin/sh`, must hand the agent
    /// exactly the original argv (quote and newline intact).
    @Test func test_spawnArgv_commandStringRoundTripsThroughRealShell() throws {
        let launch = ["/usr/bin/printf", "%s|", "it's", "a\nb", "--x"]
        let argv = WorktreeTaskPlanner.spawnArgv(launchArgv: launch, loginShell: "/bin/sh")
        #expect(argv.dropLast() == ["/bin/sh", "-i", "-l", "-c"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try #require(argv.last)]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text == "it's|a\nb|--x|")
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
