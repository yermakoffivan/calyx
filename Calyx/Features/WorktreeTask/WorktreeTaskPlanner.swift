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

    /// The argv for `agent`: `baseArgv`, then `arguments` verbatim, then
    /// `prompt` trimmed and passed as one argument: positional for
    /// claude / codex / grok / pi, `opencode --prompt <p>`.
    /// For claude, codex and grok the prompt is preceded by `--` when
    /// `arguments` is non-empty or the prompt starts with `-`: their
    /// parsers (commander, clap) end option parsing at `--`, so a
    /// trailing option in `arguments` that takes an optional value
    /// cannot swallow the prompt, and a dash prompt is not read as an
    /// option. pi gets `--` only before a prompt starting with `-`: its
    /// handling of `--` after other options is unverified.
    /// An empty prompt, or a kind that does not `acceptsInitialPrompt`
    /// (hermes), gives `baseArgv + arguments`.
    static func launchPlan(
        agent: WorktreeTaskAgentKind,
        arguments: [String] = [],
        prompt: String
    ) -> WorktreeTaskLaunchPlan {
        let head = agent.baseArgv + arguments
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard agent.acceptsInitialPrompt, !trimmed.isEmpty else {
            return WorktreeTaskLaunchPlan(argv: head)
        }
        switch agent {
        case .claudeCode, .codex, .grok:
            let separator = (!arguments.isEmpty || trimmed.hasPrefix("-")) ? ["--"] : []
            return WorktreeTaskLaunchPlan(argv: head + separator + [trimmed])
        case .pi:
            let separator = trimmed.hasPrefix("-") ? ["--"] : []
            return WorktreeTaskLaunchPlan(argv: head + separator + [trimmed])
        case .openCode:
            return WorktreeTaskLaunchPlan(argv: head + ["--prompt", trimmed])
        case .hermes:
            // Not `acceptsInitialPrompt`: handled by the guard above.
            return WorktreeTaskLaunchPlan(argv: head)
        }
    }

    /// The argv the task's pane is spawned with: `launchArgv` run by the
    /// user's shell as an interactive login shell,
    /// `[loginShell, "-i", "-l", "-c", "<tokens>; exec <loginShell> -i -l"]`, every token
    /// single-quoted. `-i` makes zsh/bash source the rc files (`~/.zshrc`,
    /// `~/.bashrc`), where nvm and `~/.local/bin` PATH setup usually
    /// live; `-l` sources the profile files. On `.passthrough` ghostty
    /// already runs the surface `command` as
    /// `/bin/bash --noprofile --norc -c "exec -l <command>"`
    /// (ghostty/src/termio/Exec.zig), whose `exec -l` makes this shell a
    /// login shell anyway, but not an interactive one; on `.persistent`
    /// the session daemon execs this argv directly, so `-l` is needed.
    ///
    /// The `-c` string is `<OSC 7 cwd report>; <agent argv>; <cwd fallback>; exec <shell> -i -l`: once the
    /// agent exits (any status, e.g. Claude Code's `/exit` or "command
    /// not found"), the pane continues as an interactive login shell in
    /// the same worktree directory instead of leaving a dead pane.
    /// Setting a surface `command` makes ghostty force
    /// `wait-after-command` on (ghostty/src/apprt/embedded.zig,
    /// `Surface.init`; see `SurfaceRegistry.createSurface(app:config:pwd:command:)`);
    /// on `.passthrough` that now only applies when this final shell
    /// exits. On `.persistent` the session ends when the final shell
    /// exits and the pane follows `SessionReconnectCoordinator`'s
    /// handling of an ended session.
    ///
    /// Between the agent and the `exec`, `if ! [ -d "$PWD" ]; then cd
    /// <fallbackDirectory> 2>/dev/null || cd; fi` moves to
    /// `fallbackDirectory` (the repository the task was created from)
    /// when the agent deleted its own worktree (e.g. `git worktree
    /// remove` on its cwd); otherwise the follow-up shell would start in
    /// a deleted directory and zsh prints `getcwd` errors. If the
    /// fallback is gone too, `cd` goes to `$HOME`.
    ///
    /// Before the agent, `printf '\033]7;kitty-shell-cwd://localhost%s\007' "$PWD"`
    /// reports the start directory with OSC 7. Calyx learns a pane's cwd
    /// only from OSC 7 (ghostty's `pwd` action), which shell integration
    /// emits at each prompt; no prompt is shown before the agent starts,
    /// so without this the pane has no cwd until the agent exits. The
    /// form copies ghostty's own bash/zsh integration
    /// (ghostty/src/shell-integration/bash/ghostty.bash,
    /// zsh/ghostty-integration): the `kitty-shell-cwd` scheme makes
    /// ghostty take the path raw, unencoded (`raw_path` in
    /// ghostty/src/termio/stream_handler.zig, `reportPwd`), so paths
    /// with `%`, `?`, `#` or spaces need no percent-encoding, which a
    /// `file://` URL would. The host is `localhost`, which
    /// `internal_os.hostname.isLocal` always accepts.
    static func spawnArgv(launchArgv: [String], loginShell: String, fallbackDirectory: String) -> [String] {
        let agent = launchArgv.map(SessionCommandSynthesizer.shSafeToken).joined(separator: " ")
        let reportCwd = "printf '\\033]7;kitty-shell-cwd://localhost%s\\007' \"$PWD\"; "
        let command = reportCwd + agent
            + "; if ! [ -d \"$PWD\" ]; then cd " + SessionCommandSynthesizer.shSafeToken(fallbackDirectory)
            + " 2>/dev/null || cd; fi; exec " + SessionCommandSynthesizer.shSafeToken(loginShell) + " -i -l"
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
