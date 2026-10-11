// WorktreeTaskPlanner.swift
// Calyx
//
// The pure half of Worktree Tasks: where a task's worktree lives, what is
// typed into its tab, which worktree hosts a branch, which panes sit
// inside a worktree, and whether closing them would empty a window.

import Foundation

enum WorktreeTaskPlanner {

    /// Delay between creating the task's tab and typing the launch
    /// command, so the shell has printed its prompt.
    static let launchCommandDelay: Duration = .milliseconds(800)

    /// How often to check whether the agent has registered (its hooks
    /// fired or its MCP connection initialized) before typing a deferred
    /// prompt.
    static let deferredPromptPollInterval: Duration = .milliseconds(250)

    /// How long to wait for the agent to register. When it elapses the
    /// deferred prompt is dropped rather than typed into what may still
    /// be the shell.
    static let deferredPromptTimeout: Duration = .seconds(30)

    /// `<sessionRoot>/.calyx/worktrees/<repo>/<branch with "/" → "-">`.
    static func worktreePath(sessionRoot: String, repoDisplayName: String, branch: String) -> String {
        let leaf = branch.replacingOccurrences(of: "/", with: "-")
        return ((sessionRoot as NSString)
            .appendingPathComponent(".calyx/worktrees") as NSString)
            .appendingPathComponent(repoDisplayName + "/" + leaf)
    }

    /// The command for `agent`, with `prompt` trimmed. Argument-taking
    /// CLIs get it shell-quoted as one positional argument (newlines kept
    /// inside the quotes, preceded by `--` when it starts with `-`); the others start bare and get the prompt typed
    /// later with newlines collapsed to spaces, because a typed newline
    /// would submit it early.
    static func launchPlan(agent: WorktreeTaskAgentKind, prompt: String) -> WorktreeTaskLaunchPlan {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorktreeTaskLaunchPlan(command: agent.baseCommand, deferredPrompt: nil)
        }
        if agent.acceptsPromptArgument {
            // `--` ends option parsing so a prompt starting with `-` stays
            // a positional argument.
            let separator = trimmed.hasPrefix("-") ? " --" : ""
            return WorktreeTaskLaunchPlan(
                command: agent.baseCommand + separator + " " + SessionCommandSynthesizer.shSafeToken(trimmed),
                deferredPrompt: nil
            )
        }
        let collapsed = trimmed.components(separatedBy: .newlines).joined(separator: " ")
        return WorktreeTaskLaunchPlan(command: agent.baseCommand, deferredPrompt: collapsed)
    }

    /// Path of the live (non-bare, non-prunable) worktree that has
    /// `branch` checked out, or nil.
    static func worktreeHosting(branch: String, in worktrees: [GitWorktreeInfo]) -> String? {
        let ref = "refs/heads/" + branch
        return worktrees.first { !$0.isBare && !$0.isPrunable && $0.branchRef == ref }?.path
    }

    /// Surface IDs of the panes whose cwd is `path` or below it, matched
    /// by whole path components after standardizing both sides.
    static func surfacesInside(path: String, panes: [CockpitPaneInfo]) -> [UUID] {
        let root = GitRepositoryLocation.standardize(path)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return panes.compactMap { pane in
            guard let cwd = pane.cwd else { return nil }
            let standardized = GitRepositoryLocation.standardize(cwd)
            return standardized == root || standardized.hasPrefix(prefix) ? pane.surfaceID : nil
        }
    }

    /// Whether closing `closing` would close every pane of a window that
    /// has panes, so a replacement tab must be opened first to keep the
    /// window alive.
    static func needsReplacementTab(windowLeafIDs: [UUID], closing: [UUID]) -> Bool {
        !windowLeafIDs.isEmpty && Set(windowLeafIDs).isSubset(of: Set(closing))
    }
}
