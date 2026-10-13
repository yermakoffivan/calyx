// MissionMapGitPoller.swift
// Calyx
//
// Keeps Mission Map's per-pane Git badges (branch, uncommitted file
// count) current while the map is open. Polled rather than watched: the
// map is shown briefly, and a few cheap git calls every few seconds for
// that time cost less than standing up a file watcher per repository.

import Foundation

@MainActor
@Observable
final class MissionMapGitPoller {

    static let interval: TimeInterval = 5

    /// Badges keyed by pane cwd -- `MissionMapSnapshotBuilder` looks a
    /// card's badge up by its pane's cwd.
    private(set) var badges: [String: MissionMapGitBadge] = [:]
    /// The last git failure per cwd, other than the cwd simply not being
    /// in a repository. A failed cwd has no badge; the reason stays here
    /// so it is inspectable rather than lost.
    private(set) var failures: [String: String] = [:]
    /// Worktree-task badges keyed by pane cwd, like `badges`: present for
    /// a cwd inside a linked worktree whose branch carries a
    /// `branch.<b>.calyxbase` marker.
    private(set) var worktreeTasks: [String: MissionMapWorktreeTaskBadge] = [:]

    /// cwd -> repository location (standardized), or `nil` for a cwd known to be
    /// outside any repository. Resolved once per open rather than every
    /// tick, and cleared by `start()` so each open re-resolves: a cwd can
    /// become (or stop being) a repository between opens.
    private var repositoryLocations: [String: GitRepositoryLocation?] = [:]
    private var pollTask: Task<Void, Never>?
    /// Bumped by `start()` and `stop()`. A refresh belongs to the
    /// generation it started in and only writes results while that
    /// generation is still current, so a refresh outliving a close or
    /// reopen can neither overwrite newer state nor block the new poll.
    private var generation = 0
    /// The generation whose refresh is in flight. A refresh can outlast
    /// `interval` on a slow repository; this keeps one generation's
    /// ticks from overlapping without making a new generation wait on a
    /// stale one.
    private var refreshingGeneration: Int?

    /// Starts polling the cwds `cwdsProvider` returns, refreshing once
    /// immediately. Restarts cleanly if already polling.
    func start(cwdsProvider: @escaping () -> [String]) {
        stop()
        repositoryLocations = [:]
        failures = [:]
        let generation = self.generation
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // A released poller ends the loop instead of sleeping on
                // forever with nothing to refresh.
                guard (await self?.refresh(cwds: cwdsProvider(), generation: generation)) != nil else { return }
                do {
                    try await Task.sleep(for: .seconds(Self.interval))
                } catch {
                    // Only cancellation interrupts the sleep: stop() ran.
                    return
                }
            }
        }
    }

    /// Stops polling. Badges stay as last read, so reopening the map
    /// shows them immediately until the first new refresh lands.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation &+= 1
    }

    private func refresh(cwds: [String], generation: Int) async {
        guard refreshingGeneration != generation else { return }
        refreshingGeneration = generation
        defer {
            if refreshingGeneration == generation {
                refreshingGeneration = nil
            }
        }

        var nextBadges: [String: MissionMapGitBadge] = [:]
        var nextFailures: [String: String] = [:]
        var badgesByRoot: [String: MissionMapGitBadge] = [:]
        var nextWorktreeTasks: [String: MissionMapWorktreeTaskBadge] = [:]
        var worktreeTasksByRoot: [String: MissionMapWorktreeTaskBadge?] = [:]
        for cwd in Set(cwds) {
            do {
                guard let location = try await repositoryLocation(for: cwd, generation: generation) else { continue }
                let root = location.workTree
                if let badge = badgesByRoot[root] {
                    nextBadges[cwd] = badge
                    if let task = worktreeTasksByRoot[root] ?? nil {
                        nextWorktreeTasks[cwd] = task
                    }
                    continue
                }
                let summary = try await Self.loadRepositorySummary(at: location)
                badgesByRoot[root] = summary.badge
                worktreeTasksByRoot[root] = .some(summary.worktreeTask)
                nextBadges[cwd] = summary.badge
                if let task = summary.worktreeTask {
                    nextWorktreeTasks[cwd] = task
                }
            } catch {
                nextFailures[cwd] = error.localizedDescription
            }
        }
        guard generation == self.generation else { return }
        badges = nextBadges
        failures = nextFailures
        worktreeTasks = nextWorktreeTasks
    }

    /// The git badge and worktree-task badge of the work tree at
    /// `location`. Shared by `refresh` (which caches results per root)
    /// and `MCPCockpitBridge`'s `agent_status`, so both compute a cwd's
    /// badges the same way. Throws when HEAD or `git status` cannot be
    /// read; a failed task-marker read yields no task badge but keeps
    /// the git badge (see `worktreeTaskBadge`).
    nonisolated static func loadRepositorySummary(
        at location: GitRepositoryLocation
    ) async throws -> (badge: MissionMapGitBadge, worktreeTask: MissionMapWorktreeTaskBadge?) {
        let root = location.workTree
        async let head = GitService.headSummary(workDir: root)
        async let status = GitService.gitStatus(workDir: root)
        let badge = try await MissionMapGitBadge(
            branch: head.branch,
            shortHash: head.shortHash,
            changedFileCount: Set(status.map(\.path)).count
        )
        let task = await worktreeTaskBadge(branch: badge.branch, location: location)
        return (badge, task)
    }

    /// The task badge for the work tree at `location` on `branch`, or nil
    /// when the work tree is the repository's main one (a task always
    /// lives in a linked worktree; the same rule as `GitRepoDiscovery`'s
    /// kind: a linked worktree's Git directory differs from the common
    /// one), HEAD is detached, the branch carries no task marker, or the marker
    /// cannot be read (the task badge is optional decoration; a read
    /// failure must not cost the pane its git badge).
    private nonisolated static func worktreeTaskBadge(branch: String?, location: GitRepositoryLocation) async -> MissionMapWorktreeTaskBadge? {
        guard location.gitDirectory != location.gitCommonDirectory else { return nil }
        guard let branch else { return nil }
        let root = location.workTree
        guard let base = try? await GitService.getBranchConfig(
            branch: branch, key: GitService.worktreeTaskBaseConfigKey, workDir: root
        ) else { return nil }
        return MissionMapWorktreeTaskBadge(branch: branch, base: base, worktreePath: root)
    }

    /// The repository location (standardized) containing `cwd`, or `nil` when `cwd` is outside
    /// any repository. Throws any other git failure without caching it,
    /// so the next tick retries. A stale `generation`'s result is
    /// returned but not cached, so it cannot leak into a newer open.
    private func repositoryLocation(for cwd: String, generation: Int) async throws -> GitRepositoryLocation? {
        if let cached = repositoryLocations[cwd] {
            return cached
        }
        let location: GitRepositoryLocation?
        do {
            location = try await GitService.repositoryLocation(workDir: cwd).standardized
        } catch GitService.GitError.notARepository {
            location = nil
        }
        if generation == self.generation {
            repositoryLocations[cwd] = .some(location)
        }
        return location
    }
}
