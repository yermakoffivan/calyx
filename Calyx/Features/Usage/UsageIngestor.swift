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
    /// The resolver threw, or answered with a path that is not a valid
    /// cwd label; the session's root fell back to the cwd.
    let projectRootResolutionFailed: Bool
}

// MARK: - UsageIngestor

struct UsageIngestor: Sendable {
    /// `TranscriptLineReader.defaultMaxLineBytes`.
    static let defaultMaxLineBytes = TranscriptLineReader.defaultMaxLineBytes
    /// `TranscriptLineReader.defaultByteBudget`. The subagents directory
    /// listing is one synchronous pass over the directory as well.
    static let defaultByteBudget = TranscriptLineReader.defaultByteBudget

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
    ///
    /// A root the resolver returns is stored only when it is, verbatim,
    /// a valid cwd label (`TranscriptLabel.isCWD`). Every
    /// other string in the store passed the parser's label rule, because
    /// these strings later reach other agents over MCP and the UI; git's
    /// answer is a path of its own (links resolved, whatever bytes the
    /// directory names hold) and gets no exemption. An answer that fails
    /// the rule is treated exactly like a throw: the cwd is the root and
    /// the failure is reported.
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
        let resolved: String?
        do {
            resolved = try await resolver.projectRoot(forCWD: cwd)
        } catch {
            decision.root = cwd
            decision.resolutionFailed = true
            return
        }
        guard let resolved else {
            decision.root = cwd
            return
        }
        if TranscriptLabel.isCWD(resolved) {
            decision.root = resolved
        } else {
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

        let file: TranscriptFile.Opened
        switch TranscriptFile.open(atPath: path) {
        case .opened(let opened): file = opened
        case .missing: return result(.missing)
        case .notARegularFile: return result(.notARegularFile)
        case .redirected: return result(.redirected)
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
}
