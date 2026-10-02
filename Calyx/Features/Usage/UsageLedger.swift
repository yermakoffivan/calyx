// UsageLedger.swift
// Calyx
//
// Sits between an accepted hook event and the usage store: decides when a
// session's transcripts are read, keeps one read per transcript in flight,
// owns the store's lifetime, and publishes each session's total after a
// successful read. It is the only place that consults the tracking
// setting: while tracking is off nothing is read from a transcript and
// nothing is created on disk.

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "UsageLedger")

// MARK: - Diagnostics

enum UsageLedgerDiagnostic: Sendable, Equatable {
    /// What failed, in two parts: text that may name a path (log it
    /// private) and the error's domain and code, which never do (log
    /// them public).
    struct Failure: Sendable, Equatable {
        /// `String(describing:)` of the error.
        let description: String
        /// The domain and code the error has as an `NSError`.
        let domain: String
        let code: Int

        init(_ error: any Error) {
            description = String(describing: error)
            let bridged = error as NSError
            domain = bridged.domain
            code = bridged.code
        }
    }

    /// An ingest, or a store call around it, threw.
    case ingestFailed(sessionID: String, error: Failure)
    /// The main transcript was there but could not be used:
    /// `.notARegularFile` or `.redirected`. Never reported for `.missing`.
    case mainTranscriptUnusable(sessionID: String, status: UsageIngestFileResult.Status)
    /// A subagent file whose status is not `.read`.
    case subagentFileNotRead(path: String, status: UsageIngestFileResult.Status)
    case projectRootResolutionFailed(sessionID: String)
    /// The store could not be opened or read outside an ingest.
    case storeUnavailable(error: Failure)
}

// MARK: - UsageLedger

actor UsageLedger {
    /// The events after which a transcript that was already ingested is
    /// read again: each ends a turn (of the session or of a subagent) or
    /// the session, so the transcript has gained final numbers.
    static let ingestTriggerEvents: Set<String> = ["Stop", "SubagentStop", "SessionEnd"]

    /// The calendar handed to the store for a session's total row. That
    /// query has no `groupBy`, so no calendar can change its result; a
    /// fixed one keeps the published row independent of the user's locale.
    private static let totalRowCalendar = Calendar(identifier: .gregorian)

    private let isEnabled: @Sendable () -> Bool
    private let projectsRoot: @Sendable () -> String
    private let storeDirectory: URL
    private let ingest: @Sendable (ClaudeTranscriptLocation, UsageStore) async throws -> UsageIngestResult
    private let publish: @Sendable (String, UsageRow?) async -> Void
    private let onDiagnostic: @Sendable (UsageLedgerDiagnostic) -> Void

    /// One transcript's ingest, from the trigger that started it until
    /// its last re-run has ended.
    private struct Flight {
        /// Tells this flight from a later one for the same transcript.
        let id: UInt64
        /// A trigger arrived since the current run started.
        var rerunRequested = false
    }

    /// The open store; nil before the first need and after `close()`.
    private var store: UsageStore?
    /// A store `close()` took out of `store` and whose close may not have
    /// finished. A second connection must not open the database while the
    /// first is still checkpointing it (there is no busy timeout), so
    /// every open waits for this one first (`awaitPendingClose`).
    private var closingStore: UsageStore?
    /// Calls into the store that are not part of a flight (`sessions`,
    /// `report`, `deleteAll`) and are still running. `close()` waits for
    /// them, so none of them finds its store closed underneath it.
    private var storeCallsInProgress = 0

    /// Running flights, keyed by `ClaudeTranscriptLocation.mainPath`.
    private var flights: [String: Flight] = [:]
    private var lastFlightID: UInt64 = 0
    /// Main paths ingested successfully in this process.
    private var ingested: Set<String> = []
    /// Session ids `publish` was called for with an ingest's row.
    private var published: Set<String> = []
    /// `deleteAll` calls that have not finished. While non-zero no ingest
    /// starts.
    private var deletionsInProgress = 0
    /// Resumed whenever a flight or a store call ends; each waiter then
    /// re-checks its own condition.
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Touches no file: the store is opened at the first need.
    ///
    /// - `isEnabled`: the tracking setting, read every time it matters.
    /// - `projectsRoot`: Claude Code's projects directory, the root every
    ///   transcript path is validated against.
    /// - `ingest`: reads one session's transcripts into the store
    ///   (`UsageIngestor.ingest`).
    /// - `publish`: receives a session's total row after each successful
    ///   ingest, and nil once the data was deleted.
    /// - `onDiagnostic`: receives everything that went wrong without
    ///   being thrown to a caller.
    init(
        isEnabled: @escaping @Sendable () -> Bool,
        projectsRoot: @escaping @Sendable () -> String,
        storeDirectory: URL,
        ingest: @escaping @Sendable (ClaudeTranscriptLocation, UsageStore) async throws -> UsageIngestResult,
        publish: @escaping @Sendable (String, UsageRow?) async -> Void,
        onDiagnostic: @escaping @Sendable (UsageLedgerDiagnostic) -> Void
    ) {
        self.isEnabled = isEnabled
        self.projectsRoot = projectsRoot
        self.storeDirectory = storeDirectory
        self.ingest = ingest
        self.publish = publish
        self.onDiagnostic = onDiagnostic
    }

    // MARK: - Events

    /// Registers a hook event and returns; the ingest it may start runs
    /// in a task of its own, so the caller never waits for file I/O.
    ///
    /// - Dropped while tracking is off or a `deleteAll` is in progress.
    /// - The path is located on every call. A path the locator rejects
    ///   (not this session's main transcript, not created yet, not
    ///   readable) is dropped without a diagnostic and without being
    ///   remembered: at `SessionStart` the file does not exist yet, and
    ///   the same path must be accepted once it does.
    /// - An ingest starts when the transcript was not ingested
    ///   successfully in this process yet, whatever the event, or when
    ///   the event is one of `ingestTriggerEvents`. "Ingested" is keyed
    ///   by the located main path, never by the hook's own spelling.
    /// - While that transcript's ingest is running, the trigger asks for
    ///   one re-run instead: the running read may already be past the
    ///   lines this event announces.
    ///
    /// The setting stops ingests from STARTING. An ingest that is already
    /// reading when tracking is turned off finishes and publishes: what
    /// it stores was produced while tracking was on. An ingest that was
    /// asked for but has not opened the store yet (a flight not begun, a
    /// requested re-run) is not run.
    func note(_ activity: UsageActivity) {
        guard isEnabled(), !isDeleting else { return }
        guard let location = ClaudeTranscriptLocator.locate(
            transcriptPath: activity.transcriptPath, sessionID: activity.sessionID, root: projectsRoot())
        else { return }
        guard !ingested.contains(location.mainPath) || Self.ingestTriggerEvents.contains(activity.hookEventName)
        else { return }
        _ = requestIngest(of: location)
    }

    /// Ingests every stored session that has a transcript path, one
    /// after another, and returns when the last one has ended. This is
    /// what picks up lines no hook event announced (events lost while
    /// Calyx was not running, a transcript that lagged its `Stop`).
    ///
    /// Does nothing while tracking is off or a `deleteAll` is in
    /// progress. Each stored path is located again, exactly like a hook's
    /// path, and one the locator rejects is skipped without a diagnostic.
    /// A transcript is ingested whether or not it already was in this
    /// process, through the same single flight as `note`. The ingests
    /// run in tasks of the ledger's own and this only waits for them, so
    /// cancelling the caller never cancels an ingest: a cancelled ingest
    /// would end the project root's git call, and the cwd it then falls
    /// back to would be stored as the session's root for good. Never
    /// throws: a session that fails is reported and the next one is
    /// still read; a store that cannot be opened or listed is
    /// `.storeUnavailable`.
    func reconcileKnown() async {
        guard isEnabled(), !isDeleting else { return }
        await awaitPendingClose()
        // The setting is read again in the same synchronous stretch as
        // the open: it may have changed across the suspension above, and
        // opening creates the database.
        guard isEnabled(), !isDeleting else { return }
        let sessions: [UsageSessionMeta]
        do {
            let store = try openedStore()
            sessions = try await storeCall { try await store.sessions() }
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        for session in sessions {
            // Every pass follows a suspension, so the state is read anew.
            guard isEnabled(), !isDeleting else { return }
            guard let transcriptPath = session.transcriptPath,
                  let location = ClaudeTranscriptLocator.locate(
                      transcriptPath: transcriptPath, sessionID: session.sessionID, root: projectsRoot())
            else { continue }
            let flight = requestIngest(of: location)
            // Ends when that flight does, re-run included. A `deleteAll`
            // beginning meanwhile ends the flight without a re-run, and
            // the guard above then ends this loop.
            while flights[location.mainPath]?.id == flight {
                await waitForChange()
            }
        }
    }

    // MARK: - Reading and deleting

    /// The Gold query over the store. While tracking is on, every known
    /// session is reconciled first, so the rows include what the
    /// transcripts hold now; a failed reconcile is reported through
    /// `onDiagnostic` and does not fail the report. While tracking is
    /// off nothing is read from a transcript, and the store is opened
    /// only if its database already exists (otherwise there are no rows
    /// and nothing is created). Errors of the read itself are thrown.
    func report(_ query: UsageQuery, calendar: Calendar) async throws -> [UsageRow] {
        if isEnabled() {
            await reconcileKnown()
        }
        await awaitPendingClose()
        guard let store = try storeIfWarranted() else { return [] }
        return try await storeCall { try await store.report(query, calendar: calendar) }
    }

    /// Deletes everything stored, whatever the setting.
    ///
    /// From its first statement until it returns or throws
    /// (`isDeleting`), no ingest starts: a `note` or `reconcileKnown`
    /// arriving meanwhile is dropped, a flight that has not begun is
    /// skipped and a requested re-run is not run. It waits for the flights
    /// already running, so no ingest can write into the store after the
    /// delete, and the block covers its own `publish(_, nil)` calls, so
    /// no ingest can publish a fresh row that one of those calls would
    /// then erase.
    ///
    /// When it returns OR throws, no transcript counts as ingested, so
    /// the next event of any kind reads its transcript again. After a
    /// delete that is the point; after a failed one it is what makes up
    /// for every trigger dropped while it ran, whichever way it was
    /// dropped, and costs little because the checkpoints are still
    /// there. Only a delete that succeeded publishes: every session that
    /// was published is published again with nil. The store's
    /// checkpoints are deleted with the records, so a session that is
    /// still running is read again from the start of its transcript at
    /// its next event.
    ///
    /// While tracking is off and no database exists, nothing is opened
    /// or created.
    func deleteAll() async throws {
        deletionsInProgress += 1
        defer {
            // No flight can have marked a transcript since the wait
            // below ended, so this leaves the set empty on every path.
            ingested.removeAll()
            deletionsInProgress -= 1
        }
        while !flights.isEmpty {
            await waitForChange()
        }
        await awaitPendingClose()
        if let store = try storeIfWarranted() {
            try await storeCall { try await store.deleteAll() }
        }
        let sessionIDs = published.sorted()
        published.removeAll()
        for sessionID in sessionIDs {
            await publish(sessionID, nil)
        }
    }

    /// True from `deleteAll`'s first statement until it returns or
    /// throws.
    var isDeleting: Bool {
        deletionsInProgress > 0
    }

    // MARK: - Lifetime

    /// Returns when no ingest is running or pending.
    func waitUntilIdle() async {
        while !flights.isEmpty {
            await waitForChange()
        }
    }

    /// Waits until nothing uses the store, then closes it, and returns
    /// only once the database is closed, also when another `close()` is
    /// the one closing it. The ledger stays usable: the next need opens
    /// the store again.
    func close() async {
        while !flights.isEmpty || storeCallsInProgress > 0 {
            await waitForChange()
        }
        // Taken out of `store` before the suspension below, so whatever
        // arrives during it opens a store of its own (after this one has
        // closed) instead of being handed a store that is closing.
        if let closing = store {
            store = nil
            closingStore = closing
        }
        await awaitPendingClose()
    }

    // MARK: - Store

    /// Returns once no store taken out by `close()` is still closing.
    /// `UsageStore.close()` is idempotent and the store is an actor, so
    /// calling it again simply returns after the first close has run.
    /// When this returns, the caller runs on without a suspension, so an
    /// open that follows directly cannot overlap a close.
    private func awaitPendingClose() async {
        while let closing = closingStore {
            await closing.close()
            if closingStore === closing {
                closingStore = nil
            }
        }
    }

    /// The store, opened (and created) if it is not open. Synchronous, so
    /// a caller that has just checked the setting opens under that
    /// answer.
    private func openedStore() throws -> UsageStore {
        if let store { return store }
        let opened = try UsageStore(directory: storeDirectory)
        store = opened
        return opened
    }

    /// The store for a read or a delete: the open one, else a newly
    /// opened one when tracking is on or the database already exists,
    /// else nil. While tracking is off the ledger creates nothing, so a
    /// database that is not there is simply "no data".
    private func storeIfWarranted() throws -> UsageStore? {
        if let store { return store }
        let databasePath = storeDirectory.appendingPathComponent(UsageStore.databaseFileName).path
        guard isEnabled() || FileManager.default.fileExists(atPath: databasePath) else { return nil }
        return try openedStore()
    }

    /// Runs a store call outside a flight, counted so `close()` waits
    /// for it.
    private func storeCall<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        storeCallsInProgress += 1
        defer {
            storeCallsInProgress -= 1
            signalChange()
        }
        return try await body()
    }

    // MARK: - Single flight

    /// Asks for one ingest of `location` and returns the id of the
    /// flight that will run it: the transcript's running flight, now
    /// asked for a re-run, or a new one.
    ///
    /// A new flight always runs in a task of the ledger's own, never in
    /// the caller's: whoever asked only waits (or does not), so no
    /// caller's cancellation reaches an ingest.
    private func requestIngest(of location: ClaudeTranscriptLocation) -> UInt64 {
        if let running = flights[location.mainPath] {
            flights[location.mainPath]?.rerunRequested = true
            return running.id
        }
        lastFlightID += 1
        flights[location.mainPath] = Flight(id: lastFlightID)
        Task { await self.runFlight(location) }
        return lastFlightID
    }

    /// Runs the registered flight of `location`: one ingest, then one
    /// more for as long as a trigger arrived during the last one.
    ///
    /// The flight is registered before this runs and removed in the same
    /// synchronous stretch that finds no re-run requested. A trigger
    /// therefore either finds the flight and sets the flag before that
    /// check, or finds no flight and starts a new one; it cannot fall
    /// between the two. Any number of triggers during one run set the
    /// same flag, so they cost one more run.
    private func runFlight(_ location: ClaudeTranscriptLocation) async {
        let key = location.mainPath
        repeat {
            flights[key]?.rerunRequested = false
            await ingestOnce(location)
        } while !isDeleting && flights[key]?.rerunRequested == true
        flights[key] = nil
        signalChange()
    }

    /// One ingest and what follows from its result.
    ///
    /// It succeeded when the seam did not throw and the main transcript's
    /// status is `.read`. Only then is the transcript marked ingested and
    /// the session's stored total published; the partial failures inside
    /// a successful ingest (subagent files, project root) are reported
    /// and change neither. Everything else leaves the transcript
    /// unmarked, so its next event of any kind tries again; nothing here
    /// retries on its own.
    private func ingestOnce(_ location: ClaudeTranscriptLocation) async {
        await awaitPendingClose()
        // Checked here, in the same synchronous stretch as the open, and
        // not only when the trigger arrived: a `deleteAll` may have begun
        // or tracking been turned off since, and the open creates the
        // database.
        guard isEnabled(), !isDeleting else { return }
        let store: UsageStore
        do {
            store = try openedStore()
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return
        }

        let sessionID = location.sessionID
        let row: UsageRow?
        do {
            let result = try await ingest(location, store)
            // No entry at all is not a success either: there is no main
            // status to rely on.
            guard let main = result.files.first else { return }
            switch main.status {
            case .read:
                break
            case .missing:
                // Normal right after SessionStart: the file is not
                // written yet.
                return
            case .notARegularFile, .redirected:
                onDiagnostic(.mainTranscriptUnusable(sessionID: sessionID, status: main.status))
                return
            case .failed(let code):
                // An I/O failure of the main transcript, which the
                // ingestor throws; the same failure handed back as a
                // status is the same failure.
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            for file in result.files.dropFirst() where file.status != .read {
                onDiagnostic(.subagentFileNotRead(path: file.path, status: file.status))
            }
            if result.projectRootResolutionFailed {
                onDiagnostic(.projectRootResolutionFailed(sessionID: sessionID))
            }
            row = try await store.report(UsageQuery(sessionID: sessionID), calendar: Self.totalRowCalendar).first
        } catch {
            onDiagnostic(.ingestFailed(sessionID: sessionID, error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        // The flight is still registered, so a `deleteAll` that began
        // meanwhile is still waiting: these marks and this publish land
        // before its delete, and its own nil publish comes after.
        ingested.insert(location.mainPath)
        published.insert(sessionID)
        await publish(sessionID, row)
    }

    // MARK: - Waiting

    /// Suspends until the next `signalChange()`. Callers loop on their
    /// own condition, which they re-read after every resumption.
    private func waitForChange() async {
        await withCheckedContinuation { changeWaiters.append($0) }
    }

    private func signalChange() {
        let waiters = changeWaiters
        changeWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - Production composition

extension UsageLedger {
    /// Whether the app's ledger tracks usage: the user's setting, and
    /// only in a launch that may touch the real agent paths. A
    /// `--uitesting` launch without a scoped path root resolves
    /// `~/.claude` and the Application Support directory to the
    /// developer's real ones, so tracking stays off there whatever the
    /// setting says.
    static func isTrackingEnabled(setting: Bool, launchMayTouchAgentPaths: Bool) -> Bool {
        setting && launchMayTouchAgentPaths
    }

    /// The ledger the app runs: the real ingestor and git resolver, the
    /// given setting, roots and summaries. Each session's total is
    /// published into `summaries` on the main actor, and diagnostics go
    /// to the unified log. Touches no file.
    static func makeProduction(
        isEnabled: @escaping @Sendable () -> Bool,
        projectsRoot: @escaping @Sendable () -> String,
        storeDirectory: URL,
        summaries: UsageLiveSummaries
    ) -> UsageLedger {
        UsageLedger(
            isEnabled: isEnabled,
            projectsRoot: projectsRoot,
            storeDirectory: storeDirectory,
            ingest: { location, store in
                try await UsageIngestor(store: store, resolver: GitProjectRootResolver()).ingest(location)
            },
            publish: { sessionID, row in
                await summaries.set(row, forSession: sessionID)
            },
            onDiagnostic: { log($0) }
        )
    }

    /// The app's ledger, over Claude Code's projects directory and the
    /// usage directory in Application Support. Created at its first use,
    /// on whichever thread that is; creating it only computes paths. The
    /// setting and the launch policy are read at every call of
    /// `isEnabled`, so a change of the setting applies to the next event.
    static let shared = makeProduction(
        isEnabled: {
            isTrackingEnabled(
                setting: UsageTrackingSettings.enabled,
                launchMayTouchAgentPaths: LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()
            )
        },
        projectsRoot: { AgentToolPaths.claudeProjectsDirectory },
        storeDirectory: URL(fileURLWithPath: AppSupportDirectory.usagePath, isDirectory: true),
        summaries: .shared
    )

    /// One log line per diagnostic. Session ids, paths and a failure's
    /// description (which may name a path) keep the default private
    /// privacy; a failure's domain and code, errno values and status
    /// names are public, so a log that hides the text still tells a full
    /// disk from a permission error. Nothing here comes from a
    /// transcript's content.
    private static func log(_ diagnostic: UsageLedgerDiagnostic) {
        switch diagnostic {
        case .ingestFailed(let sessionID, let error):
            logger.error("""
                Usage ingest failed for session \(sessionID): \
                \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.description)
                """)
        case .mainTranscriptUnusable(let sessionID, let status):
            logger.warning(
                "Main transcript of session \(sessionID) was not read: \(statusName(status), privacy: .public)")
        case .subagentFileNotRead(let path, let status):
            if case .failed(let code) = status {
                logger.warning("""
                    Subagent transcript \(path) was not read: \
                    \(statusName(status), privacy: .public), errno \(code, privacy: .public)
                    """)
            } else {
                logger.warning("Subagent transcript \(path) was not read: \(statusName(status), privacy: .public)")
            }
        case .projectRootResolutionFailed(let sessionID):
            logger.warning("Project root of session \(sessionID) could not be resolved; its working directory is used")
        case .storeUnavailable(let error):
            logger.error("""
                Usage store is unavailable: \
                \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.description)
                """)
        }
    }

    private static func statusName(_ status: UsageIngestFileResult.Status) -> String {
        switch status {
        case .read: return "read"
        case .missing: return "missing"
        case .notARegularFile: return "notARegularFile"
        case .redirected: return "redirected"
        case .failed: return "failed"
        }
    }
}
