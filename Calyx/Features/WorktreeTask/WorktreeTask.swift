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

    /// The CLI's argv before any prompt argument.
    var baseArgv: [String] {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .openCode: ["opencode"]
        case .hermes: ["hermes", "chat"]
        case .grok: ["grok"]
        case .pi: ["pi"]
        }
    }

    /// Whether the CLI can start an interactive session with an initial
    /// prompt. `hermes chat -q` is single-query, non-interactive mode
    /// (it answers once and exits) and Hermes has no flag for a first
    /// prompt in interactive mode, so Hermes starts without one.
    var acceptsInitialPrompt: Bool {
        switch self {
        case .claudeCode, .codex, .openCode, .grok, .pi: true
        case .hermes: false
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
    /// Extra CLI arguments, parsed from the sheet's "Arguments" field.
    var arguments: [String] = []
}

/// The agent CLI's argv for a task: the program the task's pane runs,
/// with the prompt as one argument (never typed into a shell).
struct WorktreeTaskLaunchPlan: Equatable, Sendable {
    let argv: [String]
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
