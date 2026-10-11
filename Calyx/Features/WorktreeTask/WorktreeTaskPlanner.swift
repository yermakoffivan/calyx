// WorktreeTaskPlanner.swift
// Calyx
//
// The pure half of Worktree Tasks: where a task's worktree lives, what is
// spawned in its tab, which worktree hosts a branch, which panes sit
// inside a worktree, and whether closing them would empty a window.

import Foundation

enum WorktreeTaskPlanner {

    /// `<sessionRoot>/.calyx/worktrees/<repo>/<branch with "/" → "-">`.
    static func worktreePath(sessionRoot: String, repoDisplayName: String, branch: String) -> String {
        let leaf = branch.replacingOccurrences(of: "/", with: "-")
        return ((sessionRoot as NSString)
            .appendingPathComponent(".calyx/worktrees") as NSString)
            .appendingPathComponent(repoDisplayName + "/" + leaf)
    }

    /// The argv for `agent` with `prompt` trimmed and passed as one
    /// argument: positional for claude / codex / grok / pi (preceded by
    /// `--` when it starts with `-`, so it is not parsed as an option),
    /// `opencode --prompt <p>`. An empty prompt, or a kind that does not
    /// `acceptsInitialPrompt` (hermes), gives the bare `baseArgv`.
    static func launchPlan(agent: WorktreeTaskAgentKind, prompt: String) -> WorktreeTaskLaunchPlan {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agent.acceptsInitialPrompt, !trimmed.isEmpty else {
            return WorktreeTaskLaunchPlan(argv: agent.baseArgv)
        }
        switch agent {
        case .claudeCode, .codex, .grok, .pi:
            let separator = trimmed.hasPrefix("-") ? ["--"] : []
            return WorktreeTaskLaunchPlan(argv: agent.baseArgv + separator + [trimmed])
        case .openCode:
            return WorktreeTaskLaunchPlan(argv: agent.baseArgv + ["--prompt", trimmed])
        case .hermes:
            // Not `acceptsInitialPrompt`: handled by the guard above.
            return WorktreeTaskLaunchPlan(argv: agent.baseArgv)
        }
    }

    /// The argv the task's pane is spawned with: `launchArgv` exec'd by
    /// the user's shell as an interactive login shell,
    /// `[loginShell, "-i", "-l", "-c", "exec <tokens>"]`, every token
    /// single-quoted. `-i` makes zsh/bash source the rc files (`~/.zshrc`,
    /// `~/.bashrc`), where nvm and `~/.local/bin` PATH setup usually
    /// live; `-l` sources the profile files. On `.passthrough` ghostty
    /// already runs the surface `command` as
    /// `/bin/bash --noprofile --norc -c "exec -l <command>"`
    /// (ghostty/src/termio/Exec.zig), whose `exec -l` makes this shell a
    /// login shell anyway, but not an interactive one; on `.persistent`
    /// the session daemon execs this argv directly, so `-l` is needed.
    ///
    /// A failing agent (e.g. "command not found") stays visible on
    /// `.passthrough`: setting a surface `command` makes ghostty force
    /// `wait-after-command` on (ghostty/src/apprt/embedded.zig,
    /// `Surface.init`; see `SurfaceRegistry.createSurface(app:config:pwd:command:)`),
    /// so the pane is kept open after the exec'd process exits. On
    /// `.persistent` the session's process ends instead and the pane
    /// follows `SessionReconnectCoordinator`'s handling of an ended
    /// session.
    static func spawnArgv(launchArgv: [String], loginShell: String) -> [String] {
        let command = "exec " + launchArgv.map(SessionCommandSynthesizer.shSafeToken).joined(separator: " ")
        return [loginShell, "-i", "-l", "-c", command]
    }

    /// The shell `spawnArgv` wraps the agent in: the account's login
    /// shell (`passwdShell`, from `getpwuid`), else `$SHELL`
    /// (`environmentShell`), else `/bin/zsh`; empty strings count as
    /// absent. A shell that is not POSIX-compatible (csh, tcsh, fish,
    /// nu) is replaced by `/bin/zsh`, because the single-quoted
    /// `exec` string assumes POSIX quoting.
    static func loginShell(passwdShell: String?, environmentShell: String?) -> String {
        let candidate = [passwdShell, environmentShell]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? "/bin/zsh"
        let nonPOSIX: Set<String> = ["csh", "tcsh", "fish", "nu"]
        return nonPOSIX.contains((candidate as NSString).lastPathComponent) ? "/bin/zsh" : candidate
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
