// WorktreeTask.swift
// Calyx
//
// Value types for Worktree Tasks: an agent CLI running in its own linked
// git worktree on a new branch, merged back into (or discarded from) the
// base branch it was created from. The task marker lives on disk as
// `git config branch.<branch>.calyxbase <base>`.

import Foundation

/// The agent CLIs a worktree task can launch.
enum WorktreeTaskAgentKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case claudeCode
    case codex
    case openCode
    case hermes
    case grok
    case pi

    var id: String { rawValue }

    /// The `AgentEntry.kind` this CLI reports through its hooks.
    var agentEntryKind: String {
        switch self {
        case .claudeCode: AgentEntry.claudeCodeKind
        case .codex: AgentEntry.codexKind
        case .openCode: AgentEntry.openCodeKind
        case .hermes: AgentEntry.hermesKind
        case .grok: AgentEntry.grokKind
        case .pi: AgentEntry.piKind
        }
    }

    var displayName: String {
        AgentEntry.displayName(forKind: agentEntryKind)
    }

    /// The command typed into the new tab, before any prompt argument.
    var baseCommand: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        case .hermes: "hermes chat"
        case .grok: "grok"
        case .pi: "pi"
        }
    }

    /// Whether the CLI takes the initial prompt as a positional argument.
    /// The others are started bare and the prompt is typed into their TUI
    /// once it is up.
    var acceptsPromptArgument: Bool {
        switch self {
        case .claudeCode, .codex, .grok: true
        case .openCode, .hermes, .pi: false
        }
    }
}

/// A worktree task as it exists on disk.
struct WorktreeTask: Equatable, Sendable {
    /// Location of the repository the task was created from.
    let repositoryLocation: GitRepositoryLocation
    /// Last path component of the repository's main worktree.
    let repoDisplayName: String
    let branch: String
    let base: String
    /// The task's linked worktree.
    let path: String
}

/// What the New Worktree Task sheet collects.
struct WorktreeTaskRequest: Equatable, Sendable {
    let branch: String
    let base: String
    let agent: WorktreeTaskAgentKind
    let prompt: String
}

/// What gets typed into the task's new tab.
struct WorktreeTaskLaunchPlan: Equatable, Sendable {
    /// Typed first, followed by Return.
    let command: String
    /// Typed `WorktreeTaskPlanner.deferredPromptDelay` after `command`,
    /// for CLIs that cannot take the prompt as an argument.
    let deferredPrompt: String?
}

/// The repository a New Worktree Task sheet is opened against.
struct WorktreeTaskRepositoryDescription: Equatable, Sendable {
    /// Location of the repository containing the pane's cwd.
    let location: GitRepositoryLocation
    /// Last path component of the main worktree, so tasks created from a
    /// linked worktree still land under the repository's own name.
    let displayName: String
    /// Local branch short names, sorted.
    let localBranches: [String]
    /// The branch checked out at the pane's cwd; nil when detached.
    let headBranch: String?
}
