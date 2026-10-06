// UsageRunLogReader.swift
// Calyx
//
// Reads one session's MAIN transcript incrementally into its stored run
// log (`UsageRunLog`): Claude Code's own `cost-state` totals, which reach
// Calyx even for a process that exited while Calyx was not running. Then
// decides the session's project root from the log's cwd. The reader holds
// no state between calls; the log and its checkpoint live in the store,
// saved together after every bounded read.

import Foundation

// MARK: - Result

struct UsageRunLogReadResult: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case read
        /// No transcript of the session was found, or it vanished before
        /// it was opened.
        case missing
        /// The item opened is not a regular file.
        case notARegularFile
        /// The file opened is not the one the path names (see
        /// `TranscriptFile.Outcome.redirected`).
        case redirected
    }

    let status: Status
    /// Lines delivered by the line reader in this call.
    let linesRead: Int
    /// Closed runs the stored log gained in this call; after a restart,
    /// the number of runs in the rebuilt log.
    let runsClosed: Int
    /// The stored log was discarded and the file read from the start.
    let restarted: Bool
    /// The resolver threw or answered with an invalid label; no root was
    /// stored, and a later call asks again.
    let projectRootResolutionFailed: Bool
}

// MARK: - Directory state

/// What can be said about a cwd's directory right now.
enum UsageDirectoryState: Sendable, Equatable {
    /// It exists as a directory.
    case present
    /// Nothing is there, or something that is not a directory.
    case gone
    /// It could not be checked (a permission error on a parent, an
    /// unmounted volume, an I/O error); it may be back later.
    case unknown
}

// MARK: - UsageRunLogReader

struct UsageRunLogReader: Sendable {
    private let store: UsageStore
    private let resolver: any ProjectRootResolving
    private let projectsRoot: @Sendable () -> String
    private let directoryState: @Sendable (String) -> UsageDirectoryState
    private let maxLineBytes: Int
    private let byteBudget: Int

    /// - `projectsRoot`: Claude Code's projects directory, asked on every
    ///   call (`AgentToolPaths` decides it).
    /// - `directoryState`: what a cwd's directory is right now; injected
    ///   so tests decide it.
    init(
        store: UsageStore, resolver: any ProjectRootResolving,
        projectsRoot: @escaping @Sendable () -> String,
        directoryState: @escaping @Sendable (String) -> UsageDirectoryState = UsageRunLogReader.directoryState,
        maxLineBytes: Int = TranscriptLineReader.defaultMaxLineBytes,
        byteBudget: Int = TranscriptLineReader.defaultByteBudget
    ) {
        self.store = store
        self.resolver = resolver
        self.projectsRoot = projectsRoot
        self.directoryState = directoryState
        self.maxLineBytes = maxLineBytes
        self.byteBudget = byteBudget
    }

    /// What `stat` (links followed) says about `path`: `.present` for an
    /// existing directory; `.gone` for ENOENT / ENOTDIR or an item that is
    /// not a directory; `.unknown` for every other failure, which says
    /// nothing about whether the directory still exists.
    static func directoryState(_ path: String) -> UsageDirectoryState {
        var status = stat()
        guard stat(path, &status) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .gone
            default: return .unknown
            }
        }
        return (status.st_mode & S_IFMT) == S_IFDIR ? .present : .gone
    }

    /// Reads everything new in the session's main transcript into the
    /// stored run log, then decides the project root.
    ///
    /// - The transcript is the stored path while the locator still
    ///   accepts it, otherwise the one `locate(sessionID:root:)` finds.
    ///   None is `.missing` and stores nothing: the session may never have
    ///   had a transcript.
    /// - The file is opened with `TranscriptFile.open`; `.missing`,
    ///   `.notARegularFile` and `.redirected` end the call with that
    ///   status and store nothing. Any other open or read failure is
    ///   thrown as an `NSPOSIXErrorDomain` error.
    /// - A stored log whose checkpoint does not describe this file (the
    ///   path or the inode changed, or the file is shorter than the stored
    ///   offset) is discarded and the file read from 0 (`restarted`), so a
    ///   rewritten file never leaves stale or doubled runs. The discard is
    ///   saved at once, so it holds even when the file yields no bytes.
    /// - Each bounded read that consumed bytes is applied and saved with
    ///   its checkpoint in one store call, so a later failure leaves a
    ///   consistent prefix stored and the next call resumes after it.
    /// - A store failure is thrown; nothing is retried here.
    ///
    /// `@concurrent`: the file I/O between awaits must not run on the
    /// caller's actor, whichever actor that is.
    @concurrent
    func read(sessionID: String, resolveProjectRoot: Bool = true) async throws -> UsageRunLogReadResult {
        func result(_ status: UsageRunLogReadResult.Status) -> UsageRunLogReadResult {
            UsageRunLogReadResult(
                status: status, linesRead: 0, runsClosed: 0, restarted: false, projectRootResolutionFailed: false)
        }

        let root = projectsRoot()
        let stored = try await store.runLog(forSession: sessionID)
        let storedLocation = stored.flatMap {
            ClaudeTranscriptLocator.locate(transcriptPath: $0.file.path, sessionID: sessionID, root: root)
        }
        guard let location = storedLocation ?? ClaudeTranscriptLocator.locate(sessionID: sessionID, root: root) else {
            return result(.missing)
        }
        let path = location.mainPath

        let file: TranscriptFile.Opened
        switch TranscriptFile.open(atPath: path) {
        case .opened(let opened): file = opened
        case .missing: return result(.missing)
        case .notARegularFile: return result(.notARegularFile)
        case .redirected: return result(.redirected)
        case .failed(let code): throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { close(file.descriptor) }

        var log: UsageRunLog
        var offset: UInt64
        var restarted = false
        if let stored {
            let describesThisFile = stored.file.path.utf8.elementsEqual(path.utf8)
                && stored.file.checkpoint.inode == file.inode && file.size >= stored.file.checkpoint.offset
            if describesThisFile {
                log = stored.log
                // Never a raw stored offset (see `resumeOffset`).
                offset = TranscriptLineReader.resumeOffset(
                    checkpoint: stored.file.checkpoint, inode: file.inode, size: file.size)
            } else {
                log = UsageRunLog()
                offset = 0
                restarted = true
                try await store.saveRunLog(
                    log, file: UsageRunLogFile(path: path, checkpoint: TranscriptCheckpoint(inode: file.inode, offset: 0)),
                    forSession: sessionID)
            }
        } else {
            log = UsageRunLog()
            offset = 0
        }
        let runsBefore = log.runs.count

        var linesRead = 0
        while true {
            var events: [ClaudeTranscriptRunEvent] = []
            let read = try TranscriptLineReader.read(
                fd: file.descriptor, from: offset, maxLineBytes: maxLineBytes, byteBudget: byteBudget
            ) { line in
                if let event = ClaudeCostStateReader.event(fromLine: line, sessionID: sessionID) {
                    events.append(event)
                }
            }
            linesRead += read.linesRead
            // Consumed bytes, not delivered lines: a read that only skipped
            // an over-long line must still move the checkpoint.
            if read.nextOffset != offset {
                for event in events {
                    log.apply(event)
                }
                try await store.saveRunLog(
                    log,
                    file: UsageRunLogFile(
                        path: path, checkpoint: TranscriptCheckpoint(inode: file.inode, offset: read.nextOffset)),
                    forSession: sessionID)
                offset = read.nextOffset
            }
            if read.reachedEnd { break }
        }

        var resolutionFailed = false
        if resolveProjectRoot, let cwd = log.cwd {
            resolutionFailed = try await decideProjectRoot(cwd: cwd, sessionID: sessionID)
        }
        return UsageRunLogReadResult(
            status: .read, linesRead: linesRead, runsClosed: max(0, log.runs.count - runsBefore),
            restarted: restarted, projectRootResolutionFailed: resolutionFailed)
    }

    // MARK: - Project root

    /// Stores the session's project root from `cwd` unless one is stored;
    /// returns whether the resolver failed.
    ///
    /// - A cwd whose directory is `.gone` is stored itself: git can never
    ///   describe a directory that is gone, and a deleted worktree must
    ///   not be asked about forever.
    /// - `.unknown` (it cannot be checked now, e.g. its volume is not
    ///   mounted) stores nothing and is reported like a resolver failure,
    ///   so a passing condition never fixes the cwd as the root.
    /// - Otherwise the resolver's answer is stored when it is, verbatim, a
    ///   valid cwd label (`TranscriptLabel.isCWD`: every string in the
    ///   store passed the label rule, and git's answer gets no exemption);
    ///   nil (not a repository) stores the cwd.
    /// - A throw or an invalid answer stores NOTHING and is reported, so a
    ///   later call asks again even when the file has no new bytes: one
    ///   failed git call must not attribute the session to its cwd for
    ///   good.
    private func decideProjectRoot(cwd: String, sessionID: String) async throws -> Bool {
        guard try await store.session(sessionID)?.projectRoot == nil else { return false }
        let root: String
        switch directoryState(cwd) {
        case .gone:
            root = cwd
        case .unknown:
            return true
        case .present:
            let resolved: String?
            do {
                resolved = try await resolver.projectRoot(forCWD: cwd)
            } catch {
                return true
            }
            if let resolved {
                guard TranscriptLabel.isCWD(resolved) else { return true }
                root = resolved
            } else {
                root = cwd
            }
        }
        try await store.setProjectRootIfUnset(root, forSession: sessionID)
        return false
    }
}
