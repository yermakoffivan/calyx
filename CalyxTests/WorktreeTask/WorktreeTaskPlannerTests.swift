// WorktreeTaskPlannerTests.swift
// CalyxTests
//
// Pins WorktreeTaskPlanner, the pure half of Worktree Tasks: where a
// task's worktree lives, what gets typed into the new tab for each agent
// CLI, which worktree hosts a branch, which panes sit inside a worktree,
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

    @Test func test_agentKind_baseCommands() {
        #expect(WorktreeTaskAgentKind.claudeCode.baseCommand == "claude")
        #expect(WorktreeTaskAgentKind.codex.baseCommand == "codex")
        #expect(WorktreeTaskAgentKind.openCode.baseCommand == "opencode")
        #expect(WorktreeTaskAgentKind.hermes.baseCommand == "hermes chat")
        #expect(WorktreeTaskAgentKind.grok.baseCommand == "grok")
        #expect(WorktreeTaskAgentKind.pi.baseCommand == "pi")
        #expect(WorktreeTaskAgentKind.allCases.count == 6)
    }

    @Test func test_agentKind_displayNamesAreNonEmptyAndDistinct() {
        let names = WorktreeTaskAgentKind.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    // MARK: - launchPlan: positional-argument kinds

    /// `'` becomes `'\''` and the newline survives inside the quotes.
    private let trickyPrompt = "  fix Bob's bug\nthen test \n"
    private let quotedTricky = "'fix Bob'\\''s bug\nthen test'"

    @Test func test_launchPlan_claudeCode_quotesTrimmedPromptAsArgument() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "claude " + quotedTricky, deferredPrompt: nil))
    }

    @Test func test_launchPlan_codex_quotesTrimmedPromptAsArgument() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .codex, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "codex " + quotedTricky, deferredPrompt: nil))
    }

    @Test func test_launchPlan_grok_quotesTrimmedPromptAsArgument() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .grok, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "grok " + quotedTricky, deferredPrompt: nil))
    }

    @Test func test_launchPlan_claudeCode_simplePrompt() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: "add tests")
        #expect(plan == WorktreeTaskLaunchPlan(command: "claude 'add tests'", deferredPrompt: nil))
    }

    // MARK: - launchPlan: typed-prompt kinds

    @Test func test_launchPlan_openCode_bareCommandAndDeferredPromptWithNewlinesCollapsed() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .openCode, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "opencode", deferredPrompt: "fix Bob's bug then test"))
    }

    @Test func test_launchPlan_hermes_bareCommandAndDeferredPrompt() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .hermes, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "hermes chat", deferredPrompt: "fix Bob's bug then test"))
    }

    @Test func test_launchPlan_pi_bareCommandAndDeferredPrompt() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .pi, prompt: trickyPrompt)
        #expect(plan == WorktreeTaskLaunchPlan(command: "pi", deferredPrompt: "fix Bob's bug then test"))
    }

    // MARK: - launchPlan: empty prompt

    @Test func test_launchPlan_emptyOrWhitespacePrompt_isBareCommandWithNoDeferredPrompt() {
        let expected: [WorktreeTaskAgentKind: String] = [
            .claudeCode: "claude", .codex: "codex", .openCode: "opencode",
            .hermes: "hermes chat", .grok: "grok", .pi: "pi",
        ]
        for kind in WorktreeTaskAgentKind.allCases {
            for prompt in ["", "  \n "] {
                let plan = WorktreeTaskPlanner.launchPlan(agent: kind, prompt: prompt)
                #expect(plan == WorktreeTaskLaunchPlan(command: expected[kind]!, deferredPrompt: nil),
                        "kind \(kind.rawValue), prompt \(prompt.debugDescription)")
            }
        }
    }

    // MARK: - Delays

    @Test func test_delays_launchDelayAndPromptReadinessWait() {
        #expect(WorktreeTaskPlanner.launchCommandDelay == .milliseconds(800))
        #expect(WorktreeTaskPlanner.deferredPromptPollInterval == .milliseconds(250))
        #expect(WorktreeTaskPlanner.deferredPromptTimeout == .seconds(30))
    }

    // MARK: - launchPlan: prompt starting with "-"

    @Test func test_launchPlan_dashPrompt_positionalKindsGetOptionTerminator() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .claudeCode, prompt: "  --help me ")
        #expect(plan == WorktreeTaskLaunchPlan(command: "claude -- '--help me'", deferredPrompt: nil))
        for kind in WorktreeTaskAgentKind.allCases where kind.acceptsPromptArgument {
            let command = WorktreeTaskPlanner.launchPlan(agent: kind, prompt: "-x").command
            #expect(command == kind.baseCommand + " -- '-x'", "kind \(kind.rawValue)")
        }
    }

    @Test func test_launchPlan_dashPrompt_deferredKindsUnchanged() {
        for kind in WorktreeTaskAgentKind.allCases where !kind.acceptsPromptArgument {
            let plan = WorktreeTaskPlanner.launchPlan(agent: kind, prompt: "-x")
            #expect(plan == WorktreeTaskLaunchPlan(command: kind.baseCommand, deferredPrompt: "-x"))
        }
    }

    @Test func test_launchPlan_innerDashPrompt_noOptionTerminator() {
        let plan = WorktreeTaskPlanner.launchPlan(agent: .codex, prompt: "fix -x")
        #expect(plan.command == "codex 'fix -x'")
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
