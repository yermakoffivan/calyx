// UsageIngestor.swift
// Calyx
//
// Tails one session's transcripts into the usage store: the main
// transcript, then its subagent transcripts, each from its stored
// checkpoint, one batch per bounded read so the checkpoint commits with
// exactly the records read up to it. The ingestor holds no state between
// calls; everything persistent lives in the store, which is also the only
// place records are folded (`UsageRecord.winner`).

import Foundation

// MARK: - Dependencies

/// Maps a working directory to the repository root usage is attributed
/// to; nil when the directory is not inside a repository.
protocol ProjectRootResolving: Sendable {
    func projectRoot(forCWD cwd: String) async throws -> String?
}

/// The part of the store the ingestor needs (`UsageStore` conforms).
protocol UsageBatchStoring: Sendable {
    func checkpoint(forPath path: String) async throws -> TranscriptCheckpoint?
    func session(_ sessionID: String) async throws -> UsageSessionMeta?
    func apply(_ batch: UsageBatch) async throws
}

// MARK: - Result

struct UsageIngestFileResult: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case read
        /// Nothing exists at the path (yet).
        case missing
        /// The item at the path is not a regular file: a symbolic link
        /// at the final component, a directory, a FIFO or a device.
        case notARegularFile
        /// The file opened IS regular, but the descriptor's real path is
        /// not the path that was validated: a directory above it was
        /// replaced by a link, or the file was reached under another
        /// spelling. Nothing is read from it.
        case redirected
        /// A SUBAGENT file whose open, examination or read failed with
        /// this errno. The counters say how far it got; batches applied
        /// before the failure stay applied. The main transcript never has
        /// this status: its failure is thrown.
        case failed(errno: Int32)
    }

    let path: String
    let status: Status
    /// Lines delivered by the reader, whether or not they held a record.
    let linesRead: Int
    /// Records the parser produced, before the store folds repeated keys.
    let recordsEmitted: Int
    let oversizeLinesSkipped: Int
    let batchesApplied: Int
}

struct UsageIngestResult: Sendable, Equatable {
    /// One entry per file processed: the main transcript first, then the
    /// subagent transcripts in name order.
    let files: [UsageIngestFileResult]
    /// The resolver threw; the session's root fell back to the cwd.
    let projectRootResolutionFailed: Bool
}

// MARK: - UsageIngestor

struct UsageIngestor: Sendable {
    /// Longest line parsed: 16 MiB. Longer lines are skipped and counted.
    static let defaultMaxLineBytes = 16 * 1_024 * 1_024
    /// Bytes after which a read stops, and so the usual size of a batch:
    /// 4 MiB. The reader checks it only after a finished line, so it does
    /// NOT bound one synchronous stretch of file I/O between awaits: a
    /// read runs past the budget to the end of the line it is in, and for
    /// an unterminated or over-long line that is up to the rest of the
    /// file. (Memory stays bounded by `maxLineBytes` plus one chunk
    /// regardless.) The subagents directory listing is likewise one
    /// synchronous pass over the directory.
    static let defaultByteBudget = 4 * 1_024 * 1_024

    private let store: any UsageBatchStoring
    private let resolver: any ProjectRootResolving
    private let maxLineBytes: Int
    private let byteBudget: Int

    init(
        store: any UsageBatchStoring, resolver: any ProjectRootResolving,
        maxLineBytes: Int = UsageIngestor.defaultMaxLineBytes, byteBudget: Int = UsageIngestor.defaultByteBudget
    ) {
        self.store = store
        self.resolver = resolver
        self.maxLineBytes = maxLineBytes
        self.byteBudget = byteBudget
    }

    /// Reads everything new in the session's transcripts into the store.
    ///
    /// - The main transcript anchors the session: when it is missing
    ///   (SessionStart can fire before Claude Code writes it), is not a
    ///   regular file, or is redirected, the ingest stops there. Subagent
    ///   files are not even listed and nothing is stored. Any other
    ///   failure to open or read it is thrown.
    /// - Under "subagents/" a condition of ONE file is that file's status
    ///   (`.missing`, `.notARegularFile`, `.redirected`, `.failed(errno:)`) and the next
    ///   file is still read, so one unreadable file cannot keep the files
    ///   sorting after it from ever being ingested. A failure to LIST the
    ///   directory is a condition of the call and is thrown, after the
    ///   main file's batches were applied.
    /// - A thrown store call propagates immediately: no retry. Batches
    ///   already applied stay applied with their checkpoints, so the next
    ///   ingest resumes after them.
    func ingest(_ location: ClaudeTranscriptLocation) async throws -> UsageIngestResult {
        var root = ProjectRootDecision()
        let main = try await ingestFile(atPath: location.mainPath, mainOf: location, root: &root)
        var files = [main]
        if main.status == .read {
            for path in try ClaudeTranscriptLocator.subagentTranscripts(in: location) {
                files.append(try await ingestFile(atPath: path, mainOf: nil, root: &root))
            }
        }
        return UsageIngestResult(files: files, projectRootResolutionFailed: root.resolutionFailed)
    }

    // MARK: - Project root

    /// The session's project root as far as this `ingest` call knows it.
    /// A local of that call, handed from batch to batch, so the store and
    /// the resolver are asked at most once per call.
    private struct ProjectRootDecision {
        /// The root already stored for the session, or the one resolved in
        /// this call; nil while undecided.
        var root: String?
        var resolutionFailed = false
    }

    /// Decides the session's project root from a main-file batch, unless
    /// it is already decided.
    ///
    /// The root comes from the first main-thread record with a `cwd`, in
    /// file order: a sidechain or advisor record describes where an agent
    /// ran, not where the session was started. The store is consulted
    /// first (only once such a record exists, since without one there is
    /// nothing to decide) and a root it already holds is final; the first
    /// stored root wins in the store anyway.
    ///
    /// When the resolver returns nil (not a repository) OR throws, the
    /// `cwd` itself is the root. This is a deliberate rule, not error
    /// swallowing: usage in a directory git cannot describe still belongs
    /// to that directory, and losing the attribution, or failing the
    /// whole ingest, over a failed git call would be worse. The throw is
    /// reported through `UsageIngestResult.projectRootResolutionFailed`.
    private func decideProjectRoot(
        from records: [UsageRecord], sessionID: String, decision: inout ProjectRootDecision
    ) async throws {
        guard decision.root == nil else { return }
        var candidate: String?
        for record in records where record.thread == .main {
            if let cwd = record.cwd {
                candidate = cwd
                break
            }
        }
        guard let cwd = candidate else { return }
        if let stored = try await store.session(sessionID)?.projectRoot {
            decision.root = stored
            return
        }
        do {
            decision.root = try await resolver.projectRoot(forCWD: cwd) ?? cwd
        } catch {
            decision.root = cwd
            decision.resolutionFailed = true
        }
    }

    // MARK: - One file

    /// Reads one transcript from its checkpoint to the last complete line.
    /// `location` is non-nil for the main transcript only: its batches
    /// carry the session meta and may decide the project root, and its
    /// file errors are thrown instead of becoming `.failed(errno:)`.
    private func ingestFile(
        atPath path: String, mainOf location: ClaudeTranscriptLocation?, root: inout ProjectRootDecision
    ) async throws -> UsageIngestFileResult {
        var linesRead = 0
        var recordsEmitted = 0
        var oversizeLinesSkipped = 0
        var batchesApplied = 0
        func result(_ status: UsageIngestFileResult.Status) -> UsageIngestFileResult {
            UsageIngestFileResult(
                path: path, status: status, linesRead: linesRead, recordsEmitted: recordsEmitted,
                oversizeLinesSkipped: oversizeLinesSkipped, batchesApplied: batchesApplied)
        }
        /// A file error: thrown for the main transcript, a status for a
        /// subagent file.
        func fileFailure(_ code: Int32) throws -> UsageIngestFileResult {
            guard location == nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            return result(.failed(errno: code))
        }

        let file: OpenedTranscript
        switch Self.openTranscript(atPath: path) {
        case .opened(let opened): file = opened
        case .unavailable(let status): return result(status)
        case .failed(let code): return try fileFailure(code)
        }
        defer { close(file.descriptor) }

        // Never a raw stored offset: the reader does not validate one past
        // the end of the file, and the path may name a new file.
        var offset = TranscriptLineReader.resumeOffset(
            checkpoint: try await store.checkpoint(forPath: path), inode: file.inode, size: file.size)

        while true {
            var records: [UsageRecord] = []
            let read: TranscriptReadResult
            do {
                read = try TranscriptLineReader.read(
                    fd: file.descriptor, from: offset, maxLineBytes: maxLineBytes, byteBudget: byteBudget
                ) { line in
                    records.append(contentsOf: ClaudeTranscriptParser.records(fromLine: line))
                }
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                // The lines of the failed read are dropped with it: its
                // checkpoint was never applied, so they are read again.
                guard let code = Int32(exactly: error.code) else { throw error }
                return try fileFailure(code)
            }
            linesRead += read.linesRead
            recordsEmitted += records.count
            oversizeLinesSkipped += read.oversizeLinesSkipped

            // Consumed bytes, not delivered lines: a read that only
            // skipped an over-long line must still move the checkpoint.
            if read.nextOffset != offset {
                var session: UsageSessionMeta?
                if let location {
                    try await decideProjectRoot(from: records, sessionID: location.sessionID, decision: &root)
                    session = UsageSessionMeta(
                        sessionID: location.sessionID, transcriptPath: location.mainPath, projectRoot: root.root)
                }
                try await store.apply(UsageBatch(
                    records: records,
                    session: session,
                    fileCheckpoint: UsageFileCheckpoint(
                        path: path, checkpoint: TranscriptCheckpoint(inode: file.inode, offset: read.nextOffset))))
                batchesApplied += 1
                offset = read.nextOffset
            }
            if read.reachedEnd { break }
        }

        return result(.read)
    }

    // MARK: - Opening

    private struct OpenedTranscript {
        let descriptor: Int32
        let inode: UInt64
        let size: UInt64
    }

    private enum OpenOutcome {
        case opened(OpenedTranscript)
        case unavailable(UsageIngestFileResult.Status)
        /// Any other errno of the open or of examining the descriptor.
        case failed(Int32)
    }

    /// Opens a transcript for reading, or says why it is not one. `path`
    /// is the path the locator produced, which it spelled with the same
    /// `fcntl(F_GETPATH)` used below; a path spelled any other way
    /// (`realpath(3)` included) can differ for the very same file.
    ///
    /// - O_NOFOLLOW rejects a symbolic link at the LAST component only
    ///   (ELOOP). A directory above it that was replaced by a link since
    ///   the path was validated is still followed by the open.
    /// - O_NONBLOCK: a FIFO put at the path would otherwise block the
    ///   open until a writer appears, i.e. possibly forever. It has no
    ///   effect on reading a regular file.
    /// - The type is taken from the DESCRIPTOR (`fstat`); a directory or
    ///   FIFO opens fine and is rejected here.
    /// - The descriptor's real path (`fcntl(F_GETPATH)`) must equal `path`
    ///   byte for byte. This is the check that covers the directories
    ///   above the file: an open redirected through a link anywhere in
    ///   the path, or reaching the file under another spelling, reports a
    ///   different real path and is `.redirected`. Together with
    ///   `fstat` it makes the file that is read a regular file whose real
    ///   path, at open time, was the validated one.
    ///
    /// The caller owns (and closes) the returned descriptor.
    private static func openTranscript(atPath path: String) -> OpenOutcome {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let openErrno = errno
            switch openErrno {
            case ENOENT: return .unavailable(.missing)
            case ELOOP: return .unavailable(.notARegularFile)
            default: return .failed(openErrno)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let statErrno = errno
            close(descriptor)
            return .failed(statErrno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return .unavailable(.notARegularFile)
        }
        var realPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &realPath) == 0 else {
            let pathErrno = errno
            close(descriptor)
            return .failed(pathErrno)
        }
        guard strcmp(realPath, path) == 0 else {
            close(descriptor)
            return .unavailable(.redirected)
        }
        return .opened(OpenedTranscript(
            descriptor: descriptor, inode: UInt64(status.st_ino), size: UInt64(status.st_size)))
    }
}
