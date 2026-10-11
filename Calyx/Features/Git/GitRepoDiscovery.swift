// GitRepoDiscovery.swift
// Calyx
//
// Resolves the repositories shown as Changes sidebar sections.

import Foundation

struct GitRepoDiscoveryResult: Equatable, Sendable {
    let sections: [GitRepoDescriptor]
    /// What the run could not check. A displayed section these cover was
    /// not looked at, so its absence from `sections` is not evidence that
    /// it is gone.
    let gaps: GitRepoDiscoveryGaps
    /// Set only when no section could be built and at least one seed failed
    /// for a reason other than not being a git repository. Empty sections
    /// with no message mean none of the seeds was a repository.
    let failureMessage: String?
}

/// The parts of the file system a discovery run could not read, each with
/// the failure that stopped it. Separating "not checked" from "not there"
/// is what keeps a repository that answered late, or not at all, from
/// disappearing out of the sidebar.
struct GitRepoDiscoveryGaps: Equatable, Sendable {
    /// Directories whose repository could not be resolved.
    var workDirs: [String: String] = [:]
    /// Git common directories whose worktree list could not be read, which
    /// leaves every worktree of that repository unconfirmed.
    var commonDirectories: [String: String] = [:]

    /// Why the run could not check `descriptor`, or `nil` when it did.
    func message(for descriptor: GitRepoDescriptor) -> String? {
        if let message = commonDirectories[descriptor.location.gitCommonDirectory] {
            return message
        }
        let root = descriptor.rootPath
        for workDir in workDirs.keys.sorted()
        where workDir == root || workDir.hasPrefix(root + "/") {
            return workDirs[workDir]
        }
        return nil
    }

    mutating func formUnion(_ other: GitRepoDiscoveryGaps) {
        workDirs.merge(other.workDirs) { existing, _ in existing }
        commonDirectories.merge(other.commonDirectories) { existing, _ in existing }
    }
}

extension GitRepoDiscoveryGaps {
    /// Why the run could not check `descriptor`, or `nil` when it did. A
    /// submodule is enumerated by the work tree containing it, so a gap
    /// over that work tree leaves the submodule unchecked as well.
    func message(
        for descriptor: GitRepoDescriptor,
        containedBy containers: [String: GitRepoDescriptor]
    ) -> String? {
        var section = descriptor
        while true {
            if let message = message(for: section) { return message }
            guard section.kind == .submodule,
                  let container = containers[section.rootPath] else { return nil }
            section = container
        }
    }
}

/// Remembers the file system's own spelling of the paths it has resolved.
/// Reading that spelling is a file system access, a shell reports its
/// working directory on every prompt, and every pane's directory is
/// resolved on each of those reports, so the same directories would
/// otherwise be read over and over for an answer that only changes when a
/// pane moves. `keepOnly` bounds what is held to the directories in use.
final class GitPathStandardizer {
    private let resolve: (String) -> String
    private var spellings: [String: String] = [:]

    init(resolve: @escaping (String) -> String = GitRepositoryLocation.standardize) {
        self.resolve = resolve
    }

    func standardize(_ path: String) -> String {
        if let known = spellings[path] { return known }
        let spelling = resolve(path)
        spellings[path] = spelling
        return spelling
    }

    /// Forgets every path outside `paths`, which are resolved again if they
    /// are ever asked for once more.
    func keepOnly(_ paths: Set<String>) {
        spellings = spellings.filter { paths.contains($0.key) }
    }
}

/// How the displayed sections account for the terminal panes' directories.
/// Discovery is what turns a directory no section covers into a section, so
/// a change in either half is a change only discovery can resolve: a new
/// repository on one side, the last pane leaving a repository on the other.
struct GitSeedCoverage: Equatable, Sendable {
    var ownerRepoIDs: Set<String> = []
    var uncoveredWorkDirs: Set<String> = []
}

enum GitRepoDiscovery {
    /// Expands terminal working directories into the full set of sections
    /// to display: every seed's repository, the other worktrees sharing
    /// its Git directory, the superprojects above it, and the submodules
    /// each of those has checked out. Bare, prunable, and missing
    /// worktrees are dropped, duplicates collapse by root path, and the
    /// result is in the fixed display order (families by root path, main
    /// worktree before linked worktrees before submodules).
    static func discover(seedWorkDirs: [String]) async -> GitRepoDiscoveryResult {
        var seeds: [String] = []
        var seenSeeds: Set<String> = []
        for workDir in seedWorkDirs where seenSeeds.insert(workDir).inserted {
            seeds.append(workDir)
        }
        guard !seeds.isEmpty else {
            return GitRepoDiscoveryResult(sections: [], gaps: GitRepoDiscoveryGaps(), failureMessage: nil)
        }

        let resolutions = await resolveSeeds(seeds)
        var gaps = GitRepoDiscoveryGaps()
        for resolution in resolutions {
            guard let failureMessage = resolution.failureMessage else { continue }
            gaps.workDirs[GitRepositoryLocation.standardize(resolution.workDir)] = failureMessage
        }

        // A pane inside a submodule is a pane inside the repository that
        // contains it, so the superprojects above the seeds are sections
        // of their own and bring their other worktrees with them.
        let seedLocations = resolutions.compactMap(\.location)
        let walk = await superprojectAncestors(of: seedLocations)
        gaps.formUnion(walk.gaps)
        let ancestorResolutions = await resolveSeeds(walk.workTrees)
        for resolution in ancestorResolutions {
            guard let failureMessage = resolution.failureMessage else { continue }
            gaps.workDirs[GitRepositoryLocation.standardize(resolution.workDir)] = failureMessage
        }

        let families = groupIntoFamilies(seedLocations + ancestorResolutions.compactMap(\.location))
        let expanded = await expandFamilies(families)
        for expansion in expanded {
            gaps.formUnion(expansion.gaps)
        }

        let sections = ordered(expanded.flatMap(\.descriptors))
        // Seeds that are simply not repositories are the normal case for a
        // terminal pane, so only the other failures are worth reporting,
        // and only when they left nothing to show.
        let failureMessage = sections.isEmpty
            ? resolutions.compactMap(\.failureMessage).first
            : nil
        return GitRepoDiscoveryResult(sections: sections, gaps: gaps, failureMessage: failureMessage)
    }

    /// What to display after a run: everything it confirmed, plus the
    /// displayed sections it could not check, in the fixed order. A section
    /// is dropped only by a run that looked where it lives and did not find
    /// it there.
    static func merge(
        discovered: [GitRepoDescriptor],
        keeping displayed: [GitRepoDescriptor],
        gaps: GitRepoDiscoveryGaps
    ) -> [GitRepoDescriptor] {
        let discoveredIDs = Set(discovered.map(\.id))
        let containers = containingSections(of: discovered + displayed)
        let unchecked = displayed.filter {
            !discoveredIDs.contains($0.id)
                && gaps.message(for: $0, containedBy: containers) != nil
        }
        return ordered(discovered + unchecked)
    }

    /// The fixed display order: repositories sharing a Git directory stay
    /// together, ordered by the root path of their first section, and
    /// within one of those families the repository itself comes before its
    /// linked worktrees and those before its submodules. Duplicate root
    /// paths collapse onto one section.
    static func ordered(_ descriptors: [GitRepoDescriptor]) -> [GitRepoDescriptor] {
        let sections = collapseDuplicateRootPaths(descriptors)
        var byFamily: [String: [GitRepoDescriptor]] = [:]
        let containers = containingSections(of: sections)
        for descriptor in sections {
            byFamily[familyKey(of: descriptor, containers: containers), default: []]
                .append(descriptor)
        }

        let families: [(sortKey: String, descriptors: [GitRepoDescriptor])] =
            byFamily.values.compactMap { family in
                let sorted = family.sorted {
                    ($0.kind.sortRank, $0.rootPath) < ($1.kind.sortRank, $1.rootPath)
                }
                // The main worktree sorts first when the family has one; a
                // bare family orders by its alphabetically first worktree,
                // because git does not specify the order it lists them in.
                guard let first = sorted.first else { return nil }
                return (first.rootPath, sorted)
            }
        return families.sorted { $0.sortKey < $1.sortKey }.flatMap(\.descriptors)
    }

    /// One section per root path, keeping the first occurrence except
    /// where a later one classifies the same path as a submodule. A
    /// repository a pane sits inside is discovered as a family root of
    /// its own as well as a submodule of the repository containing it;
    /// the submodule is where it belongs on screen, and which of the two
    /// arrives first is an accident of the run.
    private static func collapseDuplicateRootPaths(
        _ descriptors: [GitRepoDescriptor]
    ) -> [GitRepoDescriptor] {
        var positions: [String: Int] = [:]
        var sections: [GitRepoDescriptor] = []
        for descriptor in descriptors {
            guard let position = positions[descriptor.rootPath] else {
                positions[descriptor.rootPath] = sections.count
                sections.append(descriptor)
                continue
            }
            if descriptor.kind == .submodule, sections[position].kind != .submodule {
                sections[position] = descriptor
            }
        }
        return sections
    }

    /// Which family a section belongs to: its own Git directory, except
    /// for a submodule, which belongs to the repository containing it. A
    /// submodule's Git directory lies below its superproject's rather
    /// than being the same one, so grouping on that alone would give it a
    /// family of its own and separate it from the repository it is part
    /// of. A submodule of a submodule follows the chain up to the section
    /// that is not one; a submodule whose superproject is not displayed
    /// heads its own family.
    private static func familyKey(
        of descriptor: GitRepoDescriptor,
        containers: [String: GitRepoDescriptor]
    ) -> String {
        var owner = descriptor
        while owner.kind == .submodule, let container = containers[owner.rootPath] {
            owner = container
        }
        return owner.location.gitCommonDirectory
    }

    /// For each section, the section it sits inside: the longest root
    /// path that is a proper ancestor of its own. Matching is on path
    /// components, so `/a/Calyx` never claims `/a/Calyx-worktrees/x`.
    /// Every step up shortens the root path, so following the result
    /// repeatedly terminates.
    static func containingSections(
        of descriptors: [GitRepoDescriptor]
    ) -> [String: GitRepoDescriptor] {
        var containers: [String: GitRepoDescriptor] = [:]
        for descriptor in descriptors {
            for candidate in descriptors
            where descriptor.rootPath.hasPrefix(candidate.rootPath + "/") {
                if candidate.rootPath.count > (containers[descriptor.rootPath]?.rootPath.count ?? -1) {
                    containers[descriptor.rootPath] = candidate
                }
            }
        }
        return containers
    }

    /// The section owning `workDir`: the longest `rootPath` that equals it
    /// or is one of its ancestors. Matching is on path components, so
    /// `/a/Calyx` never claims `/a/Calyx-worktrees/x`. `standardizer` is
    /// how the caller's repeated questions about the same directories are
    /// answered without reading the file system again; the default one is
    /// empty, which resolves every path it is given.
    static func activeRepoID(
        for workDir: String?,
        in sections: [GitRepoDescriptor],
        standardizer: GitPathStandardizer = GitPathStandardizer()
    ) -> String? {
        guard let workDir else { return nil }
        let path = standardizer.standardize(workDir)

        var match: String?
        for section in sections {
            let rootPath = section.rootPath
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { continue }
            if rootPath.count > (match?.count ?? -1) {
                match = rootPath
            }
        }
        return match
    }

    /// Which sections own `workDirs` and which of them no section covers.
    /// Two runs of this that agree mean the panes are still inside the same
    /// repositories, whatever subdirectory they moved to.
    static func coverage(
        of workDirs: [String],
        in sections: [GitRepoDescriptor],
        standardizer: GitPathStandardizer = GitPathStandardizer()
    ) -> GitSeedCoverage {
        var coverage = GitSeedCoverage()
        for workDir in workDirs {
            if let owner = activeRepoID(for: workDir, in: sections, standardizer: standardizer) {
                coverage.ownerRepoIDs.insert(owner)
            } else {
                coverage.uncoveredWorkDirs.insert(standardizer.standardize(workDir))
            }
        }
        return coverage
    }

    // MARK: - Seeds

    /// One seed's outcome. `failureMessage` stays nil when the seed is
    /// merely outside any repository, which is not a failure to report.
    private struct SeedResolution: Sendable {
        let index: Int
        let workDir: String
        let location: GitRepositoryLocation?
        let failureMessage: String?
    }

    private static func resolveSeeds(_ seeds: [String]) async -> [SeedResolution] {
        let resolutions = await withTaskGroup(of: SeedResolution.self) { group in
            for (index, workDir) in seeds.enumerated() {
                group.addTask {
                    do {
                        let location = try await GitService.repositoryLocation(workDir: workDir)
                        return SeedResolution(
                            index: index,
                            workDir: workDir,
                            location: location.standardized,
                            failureMessage: nil
                        )
                    } catch GitService.GitError.notARepository {
                        return SeedResolution(
                            index: index,
                            workDir: workDir,
                            location: nil,
                            failureMessage: nil
                        )
                    } catch {
                        return SeedResolution(
                            index: index,
                            workDir: workDir,
                            location: nil,
                            failureMessage: error.localizedDescription
                        )
                    }
                }
            }
            var resolutions: [SeedResolution] = []
            for await resolution in group {
                resolutions.append(resolution)
            }
            return resolutions
        }
        // Child tasks finish in whatever order git answers, while both the
        // reported failure and the dedupe below follow seed order.
        return resolutions.sorted { $0.index < $1.index }
    }

    // MARK: - Families

    /// The worktrees sharing one Git directory, plus the work tree the
    /// `git worktree list` call runs in.
    private struct Family: Sendable {
        let commonDirectory: String
        let seedLocations: [GitRepositoryLocation]

        var listWorkDir: String {
            seedLocations[0].workTree
        }
    }

    private struct FamilyExpansion: Sendable {
        let descriptors: [GitRepoDescriptor]
        let gaps: GitRepoDiscoveryGaps
    }

    private static func groupIntoFamilies(
        _ locations: [GitRepositoryLocation]
    ) -> [Family] {
        var seedsByCommonDirectory: [String: [GitRepositoryLocation]] = [:]
        for location in locations {
            var seeds = seedsByCommonDirectory[location.gitCommonDirectory] ?? []
            if !seeds.contains(where: { $0.workTree == location.workTree }) {
                seeds.append(location)
                seedsByCommonDirectory[location.gitCommonDirectory] = seeds
            }
        }
        return seedsByCommonDirectory
            .map { commonDirectory, seeds in
                Family(
                    commonDirectory: commonDirectory,
                    seedLocations: seeds.sorted { $0.workTree < $1.workTree }
                )
            }
            .sorted { $0.commonDirectory < $1.commonDirectory }
    }

    private static func expandFamilies(_ families: [Family]) async -> [FamilyExpansion] {
        await withTaskGroup(of: FamilyExpansion.self) { group in
            for family in families {
                group.addTask { await expand(family) }
            }
            var expanded: [FamilyExpansion] = []
            for await expansion in group {
                expanded.append(expansion)
            }
            return expanded
        }
    }

    private static func expand(_ family: Family) async -> FamilyExpansion {
        var listed: [GitRepoDescriptor] = []
        var gaps = GitRepoDiscoveryGaps()
        do {
            let infos = try await GitService.worktreeList(workDir: family.listWorkDir)
            let described = await describe(infos)
            listed = described.descriptors
            gaps = described.gaps
        } catch {
            // Without the list, the worktrees of this repository other than
            // the seeds cannot be confirmed either way.
            gaps.commonDirectories[family.commonDirectory] = error.localizedDescription
        }

        // The seeds resolved to repositories that exist, so they are
        // sections whether or not the list mentions them. A worktree that
        // has been moved is listed at the path it no longer occupies.
        let listedRootPaths = Set(listed.map(\.rootPath))
        let seeds = family.seedLocations
            .filter { !listedRootPaths.contains($0.workTree) }
            .map { location in
                GitRepoDescriptor(
                    rootPath: location.workTree,
                    displayName: (location.workTree as NSString).lastPathComponent,
                    kind: kind(of: location),
                    branch: nil,
                    headShortHash: nil,
                    location: location
                )
            }

        let worktrees = listed + seeds
        let submodules = await submoduleSections(ofWorktreeRoots: worktrees.map(\.rootPath))
        gaps.formUnion(submodules.gaps)
        return FamilyExpansion(descriptors: worktrees + submodules.descriptors, gaps: gaps)
    }

    private struct DescribedWorktrees: Sendable {
        let descriptors: [GitRepoDescriptor]
        let gaps: GitRepoDiscoveryGaps
    }

    private enum WorktreeOutcome: Sendable {
        case described(GitRepoDescriptor)
        case unverified(workDir: String, message: String)
    }

    private static func describe(_ infos: [GitWorktreeInfo]) async -> DescribedWorktrees {
        let candidates = infos.filter { info in
            !info.isBare
                && !info.isPrunable
                && FileManager.default.fileExists(atPath: info.path)
        }

        return await withTaskGroup(of: WorktreeOutcome.self) { group in
            for info in candidates {
                group.addTask {
                    let location: GitRepositoryLocation
                    do {
                        location = try await GitService.repositoryLocation(workDir: info.path)
                    } catch {
                        return .unverified(
                            workDir: GitRepositoryLocation.standardize(info.path),
                            message: error.localizedDescription
                        )
                    }
                    let standardized = location.standardized
                    let worktreeKind = kind(of: standardized)
                    // Only a linked worktree on a local branch can be a
                    // worktree task. The marker is decoration: a failed
                    // config read shows the section without the task menu
                    // rather than dropping the section.
                    var taskBase: String?
                    if worktreeKind == .worktree,
                       let ref = info.branchRef, ref.hasPrefix("refs/heads/") {
                        taskBase = try? await GitService.getBranchConfig(
                            branch: String(ref.dropFirst("refs/heads/".count)),
                            key: GitService.worktreeTaskBaseConfigKey,
                            workDir: standardized.workTree
                        )
                    }
                    return .described(
                        GitRepoDescriptor(
                            rootPath: standardized.workTree,
                            displayName: (standardized.workTree as NSString).lastPathComponent,
                            kind: worktreeKind,
                            branch: info.branchRef.map(branchName(fromRef:)),
                            headShortHash: info.headOID.map { String($0.prefix(shortHashLength)) },
                            location: standardized,
                            taskBase: taskBase
                        )
                    )
                }
            }
            var descriptors: [GitRepoDescriptor] = []
            var gaps = GitRepoDiscoveryGaps()
            for await outcome in group {
                switch outcome {
                case .described(let descriptor):
                    descriptors.append(descriptor)
                case .unverified(let workDir, let message):
                    gaps.workDirs[workDir] = message
                }
            }
            return DescribedWorktrees(descriptors: descriptors, gaps: gaps)
        }
    }

    // MARK: - Submodules

    private struct SubmoduleExpansion: Sendable {
        let descriptors: [GitRepoDescriptor]
        let gaps: GitRepoDiscoveryGaps
    }

    private enum SubmoduleListing: Sendable {
        case listed(workDirs: [String])
        case unlisted(workDir: String, message: String)
    }

    private enum SubmoduleOutcome: Sendable {
        case described(GitRepoDescriptor)
        case notCheckedOut
        case unverified(workDir: String, message: String)
    }

    /// The checked-out submodules of `worktreeRoots`, pooled across the
    /// family and ordered by root path, so a submodule declared on a
    /// linked worktree lands beside one declared on the main worktree.
    /// Only the direct submodules of those work trees: a submodule of a
    /// submodule is a section of the family its own superproject heads.
    private static func submoduleSections(
        ofWorktreeRoots worktreeRoots: [String]
    ) async -> SubmoduleExpansion {
        let listings = await withTaskGroup(of: SubmoduleListing.self) { group in
            for worktreeRoot in worktreeRoots {
                group.addTask {
                    do {
                        let submodules = try await GitService.submoduleList(repoRoot: worktreeRoot)
                        return .listed(
                            workDirs: submodules.map {
                                (worktreeRoot as NSString).appendingPathComponent($0.path)
                            }
                        )
                    } catch {
                        return .unlisted(
                            workDir: worktreeRoot, message: error.localizedDescription
                        )
                    }
                }
            }
            var listings: [SubmoduleListing] = []
            for await listing in group {
                listings.append(listing)
            }
            return listings
        }

        var candidates: [String] = []
        var gaps = GitRepoDiscoveryGaps()
        for listing in listings {
            switch listing {
            case .listed(let workDirs):
                candidates += workDirs
            case .unlisted(let workDir, let message):
                gaps.workDirs[workDir] = message
            }
        }

        return await withTaskGroup(of: SubmoduleOutcome.self) { group in
            for candidate in candidates {
                group.addTask { await describeSubmodule(at: candidate) }
            }
            var descriptors: [GitRepoDescriptor] = []
            for await outcome in group {
                switch outcome {
                case .described(let descriptor):
                    descriptors.append(descriptor)
                case .notCheckedOut:
                    break
                case .unverified(let workDir, let message):
                    gaps.workDirs[workDir] = message
                }
            }
            return SubmoduleExpansion(
                descriptors: descriptors.sorted { $0.rootPath < $1.rootPath }, gaps: gaps
            )
        }
    }

    /// The section for one gitlink the index records, or nothing when the
    /// path holds no repository to open. The index keeps a gitlink whether
    /// or not the directory below it is filled in: `git submodule deinit`
    /// empties it, a fresh clone never fills it, and `git worktree add`
    /// leaves the same empty directory in the new worktree. All three
    /// leave no `.git` behind, which is what tells them apart from a
    /// checked-out submodule.
    private static func describeSubmodule(at workDir: String) async -> SubmoduleOutcome {
        let gitPath = (workDir as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitPath) else { return .notCheckedOut }
        let rootPath = GitRepositoryLocation.standardize(workDir)

        let location: GitRepositoryLocation
        do {
            location = try await GitService.repositoryLocation(workDir: workDir)
        } catch {
            return .unverified(workDir: rootPath, message: error.localizedDescription)
        }
        let standardized = location.standardized
        guard standardized.workTree == rootPath else { return .notCheckedOut }

        // The superproject's worktree list covers its own worktrees and
        // says nothing about a submodule's HEAD.
        let head: GitHeadSummary
        do {
            head = try await GitService.headSummary(workDir: standardized.workTree)
        } catch {
            return .unverified(
                workDir: standardized.workTree, message: error.localizedDescription
            )
        }
        return .described(
            GitRepoDescriptor(
                rootPath: standardized.workTree,
                displayName: (standardized.workTree as NSString).lastPathComponent,
                kind: .submodule,
                branch: head.branch,
                headShortHash: head.shortHash,
                location: standardized
            )
        )
    }

    // MARK: - Superprojects

    private struct SuperprojectWalk: Sendable {
        let workTrees: [String]
        let gaps: GitRepoDiscoveryGaps
    }

    /// How far up the chain of superprojects a seed is followed. Nesting
    /// this deep does not occur in a repository anyone works in.
    private static let superprojectWalkLimit = 8

    /// Every superproject above `locations`, without repeats, so several
    /// panes inside one submodule are walked up once.
    private static func superprojectAncestors(
        of locations: [GitRepositoryLocation]
    ) async -> SuperprojectWalk {
        var startPoints: [String] = []
        var seenStartPoints: Set<String> = []
        for location in locations where seenStartPoints.insert(location.workTree).inserted {
            startPoints.append(location.workTree)
        }

        return await withTaskGroup(of: SuperprojectWalk.self) { group in
            for startPoint in startPoints {
                group.addTask { await superprojectChain(from: startPoint) }
            }
            var workTrees: [String] = []
            var seenWorkTrees: Set<String> = []
            var gaps = GitRepoDiscoveryGaps()
            for await walk in group {
                for workTree in walk.workTrees where seenWorkTrees.insert(workTree).inserted {
                    workTrees.append(workTree)
                }
                gaps.formUnion(walk.gaps)
            }
            return SuperprojectWalk(workTrees: workTrees, gaps: gaps)
        }
    }

    /// The chain of superprojects above `workTree`, closest first, up to
    /// `superprojectWalkLimit` of them. A step that cannot be taken ends
    /// the walk with what it reached and records that the rest was not
    /// checked, which is not the same as having reached the outermost
    /// repository.
    private static func superprojectChain(from workTree: String) async -> SuperprojectWalk {
        var workTrees: [String] = []
        var current = workTree
        for _ in 0..<superprojectWalkLimit {
            do {
                guard let superproject = try await GitService.superprojectWorkTree(workDir: current)
                else { break }
                workTrees.append(superproject)
                current = superproject
            } catch {
                return SuperprojectWalk(
                    workTrees: workTrees,
                    gaps: GitRepoDiscoveryGaps(
                        workDirs: [
                            GitRepositoryLocation.standardize(current): error.localizedDescription
                        ]
                    )
                )
            }
        }
        return SuperprojectWalk(workTrees: workTrees, gaps: GitRepoDiscoveryGaps())
    }

    private static let shortHashLength = 7

    private static func kind(of location: GitRepositoryLocation) -> GitRepoKind {
        // A linked worktree has its own Git directory below the shared one.
        location.gitDirectory == location.gitCommonDirectory ? .repository : .worktree
    }

    private static func branchName(fromRef ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }
}

private extension GitRepoKind {
    /// Position within a family: the repository itself, then its linked
    /// worktrees, then its submodules.
    var sortRank: Int {
        switch self {
        case .repository: 0
        case .worktree: 1
        case .submodule: 2
        }
    }
}
