// UsageLedger.swift
// Calyx
//
// Sits between the usage route and the usage store: commits each export,
// settles the sessions it changed, owns the store's lifetime, and
// publishes each session's totals when they change. It is the only place
// that consults the tracking setting: while tracking is off nothing is
// stored and nothing is created on disk.

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

    case projectRootResolutionFailed(sessionID: String)
    /// The store could not be opened or read outside an ingest.
    case storeUnavailable(error: Failure)
    /// An export handed over by the usage route is not a metric export.
    /// Carries nothing of the body.
    case exportUndecodable
    /// Reading a session's run log threw.
    case runLogReadFailed(sessionID: String, error: Failure)
    /// A session's transcript was there but could not be used:
    /// `.notARegularFile` or `.redirected`. Never reported for `.missing`.
    case transcriptNotUsable(sessionID: String, status: UsageRunLogReadResult.Status)
    /// Recomputing a session's unreported rows threw.
    case reconcileFailed(sessionID: String, error: Failure)
}

// MARK: - UsageLedger

actor UsageLedger {
    /// The calendar handed to the store for a session's totals. That
    /// query has no `groupBy`, so no calendar can change its result; a
    /// fixed one keeps the published totals independent of the user's
    /// locale.
    private static let totalRowCalendar = Calendar(identifier: .gregorian)

    private let isEnabled: @Sendable () -> Bool
    private let projectsRoot: @Sendable () -> String
    private let storeDirectory: URL
    private let publish: @Sendable (String, UsageTokenTotals?) async -> Void
    private let onDiagnostic: @Sendable (UsageLedgerDiagnostic) -> Void
    private let readRunLog: @Sendable (String, UsageStore, Bool) async throws -> UsageRunLogReadResult
    private let now: @Sendable () -> Date
    /// Test seam: awaited inside `ingestExport`'s counted store call right
    /// after `store.apply` returned. Production passes nothing.
    private let afterApply: (@Sendable () async -> Void)?

    /// How long `catchUp` does not look again for a session whose
    /// transcript was found missing.
    static let missingTranscriptRetryInterval: TimeInterval = 10 * 60

    /// One session's settle, from the request that started it until its
    /// last re-run has ended.
    private struct Settle {
        /// Tells this settle from a later one for the same session.
        let id: UInt64
        /// A request arrived since the current run started.
        var rerunRequested = false
    }

    /// Running settles, keyed by session id.
    private var settles: [String: Settle] = [:]
    private var lastSettleID: UInt64 = 0
    /// Sessions whose project root could not be resolved in this process
    /// and whose transcript has had no new line read since. Bounded: at
    /// most one entry per session heard in this run of the app; cleared
    /// by `deleteAll()`.
    private var projectRootFailed: Set<String> = []
    /// When a session's transcript was last found missing. Bounded: at
    /// most one entry per session heard in this run of the app; cleared
    /// by `deleteAll()`.
    private var transcriptMissingSince: [String: Date] = [:]
    /// The tracking state last written to the store's durable flag; nil
    /// until the first successful sync.
    private var syncedTracking: Bool?

    /// The open store; nil before the first need and after `close()`.
    private var store: UsageStore?
    /// A store `close()` took out of `store` and whose close may not have
    /// finished. A second connection must not open the database while the
    /// first is still checkpointing it (there is no busy timeout), so
    /// every open waits for this one first (`awaitPendingClose`).
    private var closingStore: UsageStore?
    /// Calls into the store that are not part of a settle (`apply`,
    /// `tokenReports`, `deleteAll`, ...) and are still running. `close()` waits for
    /// them, so none of them finds its store closed underneath it.
    private var storeCallsInProgress = 0

    /// What `publish` was last called with per session, only so an equal
    /// value is not sent again; an absent entry is nil. Bounded: at most
    /// one entry per session published in this run; cleared by a
    /// successful `deleteAll()`.
    private var lastPublished: [String: UsageTokenTotals] = [:]
    /// Publishes requested and not yet handed to `publish`, in call order.
    private var pendingPublishes: [(sessionID: String, totals: UsageTokenTotals?)] = []
    /// True while the one task delivering `pendingPublishes` runs.
    private var isPublishing = false
    /// `deleteAll` calls that have not finished. While non-zero no export
    /// is stored and no settle starts.
    private var deletionsInProgress = 0
    /// Resumed whenever a settle, a store call or the publishing task
    /// ends; each waiter then
    /// re-checks its own condition.
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Touches no file: the store is opened at the first need.
    ///
    /// - `isEnabled`: the tracking setting, read every time it matters.
    /// - `projectsRoot`: Claude Code's projects directory, the root every
    ///   transcript path is validated against.
    /// - `publish`: receives a session's totals whenever they changed
    ///   (an export, a settle), and nil once the data was deleted; calls
    ///   arrive one at a time, in the order they were requested.
    /// - `onDiagnostic`: receives everything that went wrong without
    ///   being thrown to a caller.
    init(
        isEnabled: @escaping @Sendable () -> Bool,
        projectsRoot: @escaping @Sendable () -> String,
        storeDirectory: URL,
        publish: @escaping @Sendable (String, UsageTokenTotals?) async -> Void,
        onDiagnostic: @escaping @Sendable (UsageLedgerDiagnostic) -> Void,
        readRunLog: (@Sendable (String, UsageStore, Bool) async throws -> UsageRunLogReadResult)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        afterApply: (@Sendable () async -> Void)? = nil
    ) {
        self.afterApply = afterApply
        self.isEnabled = isEnabled
        self.projectsRoot = projectsRoot
        self.storeDirectory = storeDirectory
        self.publish = publish
        self.onDiagnostic = onDiagnostic
        self.readRunLog = readRunLog ?? { sessionID, store, resolveProjectRoot in
            try await UsageRunLogReader(store: store, resolver: GitProjectRootResolver(), projectsRoot: projectsRoot)
                .read(sessionID: sessionID, resolveProjectRoot: resolveProjectRoot)
        }
        self.now = now
    }

    // MARK: - Reading and deleting

    /// Whether tracking is on right now: the ledger's own `isEnabled`,
    /// read at each access. Callers outside the ledger that need to say
    /// whether tracking is on read it here, so they agree with what the
    /// ledger does. Nonisolated: it only calls the immutable `@Sendable`
    /// closure.
    nonisolated var isTracking: Bool {
        isEnabled()
    }

    /// Deletes everything stored, whatever the setting.
    ///
    /// From its first statement until it returns or throws
    /// (`isDeleting`), no export is stored and no settle starts: an export
    /// arriving meanwhile is dropped and a requested re-run of a settle is
    /// not run. It waits for the settles and store calls already running,
    /// so nothing can write into the store after the delete.
    ///
    /// Only a delete that succeeded publishes: it first waits until every
    /// publish requested before it was delivered, then every session that
    /// was published in this run is published again with nil, and the
    /// memory of what was published is cleared. Its nils are delivered
    /// before it returns. The store's checkpoints are deleted with the
    /// records, so a session that is still running is read again from
    /// the start of its transcript at its next settle.
    ///
    /// While tracking is off and no database exists, nothing is opened
    /// or created.
    func deleteAll() async throws {
        deletionsInProgress += 1
        defer {
            projectRootFailed.removeAll()
            transcriptMissingSince.removeAll()
            deletionsInProgress -= 1
            // Wakes the reports waiting for the delete to finish.
            signalChange()
        }
        // Waits for everything in flight that started before it, as
        // `close()` does: settles, and store calls (an export's `apply`
        // suspended in the store included). Work that resumes meanwhile
        // sees `isDeleting` and requests nothing new; a requested re-run
        // of a settle is not run. Its own store call starts only after
        // this wait, so it never waits on itself.
        while !settles.isEmpty || storeCallsInProgress > 0 {
            await waitForChange()
        }
        await awaitPendingClose()
        if let store = try storeIfWarranted() {
            try await storeCall { try await store.deleteAll() }
        }
        // What was queued before the delete is delivered first, so none
        // of it can arrive after the nils below and show deleted totals.
        await waitForPublishes()
        let sessionIDs = lastPublished.keys.sorted()
        lastPublished.removeAll()
        for sessionID in sessionIDs {
            enqueuePublish(sessionID, nil)
        }
        await waitForPublishes()
    }

    /// Returns once no `deleteAll` is in progress (several in a row
    /// included). Holds no store call while it waits, so a report waiting
    /// here never keeps a delete from running.
    private func waitWhileDeleting() async {
        while isDeleting {
            await waitForChange()
        }
    }

    /// Returns with no delete in progress and no store closing, in the
    /// same synchronous stretch, so the store call that follows directly
    /// answers from the store as it is after every delete and never
    /// starts while a delete waits.
    private func awaitStoreReadyAfterDeletes() async {
        repeat {
            await waitWhileDeleting()
            await awaitPendingClose()
        } while isDeleting
    }

    /// True from `deleteAll`'s first statement until it returns or
    /// throws.
    var isDeleting: Bool {
        deletionsInProgress > 0
    }

    // MARK: - Lifetime

    /// Returns when no settle is running or pending and every requested
    /// publish was delivered.
    func waitUntilIdle() async {
        while !settles.isEmpty || isPublishing {
            await waitForChange()
        }
    }

    /// Waits until nothing uses the store, then closes it, and returns
    /// only once the database is closed, also when another `close()` is
    /// the one closing it. The ledger stays usable: the next need opens
    /// the store again.
    func close() async {
        while !settles.isEmpty || storeCallsInProgress > 0 || isPublishing {
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

    /// Runs a store call outside a settle, counted so `close()` waits
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

    // MARK: - Exports (version 2)

    /// One export from the usage route. Returns once the export is
    /// committed (or refused); the settles it requests run afterwards in
    /// tasks of the ledger's own and are not waited for.
    ///
    /// - Tracking off or a delete in progress: `.dropped`, nothing opened
    ///   or created (with tracking off the durable flag is brought in line
    ///   first, which opens only an existing database).
    /// - Not a metric export: `.undecodable`, reported once.
    /// - The flag cannot be made active, the store cannot be opened, or
    ///   `apply` throws: `.unavailable`, reported as `storeUnavailable`.
    /// - Otherwise `.stored`, and every session the export changed is
    ///   settled.
    func ingestExport(_ body: Data, receivedAtNs: Int64) async -> UsageIngestOutcome {
        guard !isDeleting else { return .dropped }
        guard isEnabled() else {
            await syncTrackingIfChanged()
            return .dropped
        }
        let batch: OTLPTokenUsageBatch
        do {
            batch = try OTLPTokenUsageDecoder.decode(body)
        } catch {
            onDiagnostic(.exportUndecodable)
            return .undecodable
        }
        // Never applied before the durable flag is active: a switch back
        // on must restart tracking before the first export after it.
        if syncedTracking != true {
            await syncTracking()
        }
        guard isEnabled(), !isDeleting else { return .dropped }
        guard syncedTracking == true else { return .unavailable }
        await awaitPendingClose()
        guard isEnabled(), !isDeleting else { return .dropped }
        let outcome: UsageSeriesApplyOutcome
        let store: UsageStore
        do {
            store = try openedStore()
            let afterApply = self.afterApply
            outcome = try await storeCall {
                let applied = try await store.apply(
                    samples: batch.samples, processStarts: batch.processStarts, receivedAtNs: receivedAtNs)
                await afterApply?()
                return applied
            }
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return .unavailable
        }
        let changed = outcome.changedSessions.sorted()
        // Published before the settles, so the card never waits for a
        // transcript read; the publishes are queued, not awaited.
        await publishTotals(of: changed, from: store)
        if !isDeleting {
            for sessionID in changed {
                _ = requestSettle(of: sessionID)
            }
        }
        return .stored
    }

    /// Settles every session heard from since tracking (re)started, one
    /// after another, and returns when they are done. A session whose
    /// transcript was found missing less than
    /// `missingTranscriptRetryInterval` ago (the injected clock) is
    /// skipped. Does nothing while tracking is off or a delete is in
    /// progress. Never throws; a store failure is `storeUnavailable`.
    func catchUp() async {
        guard isEnabled(), !isDeleting else { return }
        await syncTrackingIfChanged()
        await awaitPendingClose()
        guard isEnabled(), !isDeleting else { return }
        let sessionIDs: [String]
        do {
            let store = try openedStore()
            sessionIDs = try await storeCall { try await store.sessionsWithSeries() }
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        for sessionID in sessionIDs {
            guard isEnabled(), !isDeleting else { return }
            if let missingSince = transcriptMissingSince[sessionID],
               now().timeIntervalSince(missingSince) < Self.missingTranscriptRetryInterval {
                continue
            }
            let settle = requestSettle(of: sessionID)
            // Ends when that settle does, re-run included.
            while settles[sessionID]?.id == settle {
                await waitForChange()
            }
        }
    }

    /// The token aggregate query, one result per query in order. With
    /// tracking on it first catches up; then ONE store call answers every
    /// query. With tracking off and no database every answer is empty and
    /// nothing is created. Errors of the store call are thrown.
    func tokenReports(_ queries: [UsageTokenQuery], calendar: Calendar) async throws -> [[UsageTokenRow]] {
        await waitWhileDeleting()
        if isEnabled() {
            await catchUp()
        } else {
            await syncTrackingIfChanged()
        }
        await awaitStoreReadyAfterDeletes()
        guard let store = try storeIfWarranted() else { return queries.map { _ in [] } }
        return try await storeCall { try await store.tokenReports(queries, calendar: calendar) }
    }

    /// Brings the store's durable tracking flag in line with the setting.
    /// Tracking on: opens (creates) the store and marks it active, which
    /// restarts tracking when it was paused. Tracking off: marks it paused
    /// only when the database exists; nothing is created. A failure is
    /// `storeUnavailable` and is retried at the next call.
    ///
    /// A pause takes effect when the ledger observes it: here, which
    /// R4b's activation reconciler calls on every change of the setting,
    /// and at every entry point that notices the setting differs from
    /// what was last synced. A switch off and on again that no call
    /// observed in between is not a pause.
    func syncTracking() async {
        await awaitPendingClose()
        let enabled = isEnabled()
        do {
            guard let store = try storeIfWarranted() else {
                // Off, and no database: nothing to record.
                syncedTracking = false
                return
            }
            _ = try await storeCall { try await store.setTrackingActive(enabled) }
            syncedTracking = enabled
        } catch {
            syncedTracking = nil
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
        }
    }

    /// `syncTracking()` when the setting differs from what was last
    /// synced; the steady state costs nothing.
    private func syncTrackingIfChanged() async {
        guard syncedTracking != isEnabled() else { return }
        await syncTracking()
    }

    // MARK: - Settles

    /// Asks for one settle of `sessionID` and returns the id of the
    /// settle that will run it: the session's running settle, now asked
    /// for a re-run, or a new one in a task of the ledger's own.
    private func requestSettle(of sessionID: String) -> UInt64 {
        if let running = settles[sessionID] {
            settles[sessionID]?.rerunRequested = true
            return running.id
        }
        lastSettleID += 1
        settles[sessionID] = Settle(id: lastSettleID)
        Task { await self.runSettle(sessionID) }
        return lastSettleID
    }

    /// Runs the registered settle of `sessionID`: one settle, then one
    /// more for as long as a request arrived during the last one. The
    /// entry is removed in the same synchronous stretch that finds no
    /// re-run requested, so a request either sets the flag or starts a
    /// new settle. No re-run starts while a delete is in progress.
    private func runSettle(_ sessionID: String) async {
        repeat {
            settles[sessionID]?.rerunRequested = false
            await settleOnce(sessionID)
        } while !isDeleting && settles[sessionID]?.rerunRequested == true
        settles[sessionID] = nil
        signalChange()
    }

    /// Reads the session's run log, then recomputes its unreported rows.
    /// Never throws; failures become diagnostics.
    private func settleOnce(_ sessionID: String) async {
        await awaitPendingClose()
        guard isEnabled(), !isDeleting else { return }
        let store: UsageStore
        do {
            store = try openedStore()
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        let resolveProjectRoot = !projectRootFailed.contains(sessionID)
        let result: UsageRunLogReadResult
        do {
            result = try await readRunLog(sessionID, store, resolveProjectRoot)
        } catch {
            onDiagnostic(.runLogReadFailed(sessionID: sessionID, error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        switch result.status {
        case .read:
            transcriptMissingSince[sessionID] = nil
        case .missing:
            transcriptMissingSince[sessionID] = now()
        case .notARegularFile, .redirected:
            transcriptMissingSince[sessionID] = nil
            onDiagnostic(.transcriptNotUsable(sessionID: sessionID, status: result.status))
        }
        if result.linesRead > 0 {
            projectRootFailed.remove(sessionID)
        }
        if result.projectRootResolutionFailed {
            projectRootFailed.insert(sessionID)
            onDiagnostic(.projectRootResolutionFailed(sessionID: sessionID))
        }
        do {
            _ = try await store.reconcile(session: sessionID)
        } catch {
            onDiagnostic(.reconcileFailed(sessionID: sessionID, error: UsageLedgerDiagnostic.Failure(error)))
        }
        await publishTotals(of: [sessionID], from: store)
    }

    // MARK: - Publishing

    /// Reads the totals of `sessionIDs` in one counted store call and
    /// queues a publish for each whose totals differ from what was last
    /// published for it. A failed read is `storeUnavailable` and
    /// publishes nothing.
    private func publishTotals(of sessionIDs: [String], from store: UsageStore) async {
        guard !sessionIDs.isEmpty else { return }
        let calendar = Self.totalRowCalendar
        let totals: [UsageTokenTotals?]
        do {
            totals = try await storeCall {
                var read: [UsageTokenTotals?] = []
                for sessionID in sessionIDs {
                    let rows = try await store.tokenReport(UsageTokenQuery(sessionID: sessionID), calendar: calendar)
                    read.append(Self.totals(of: rows))
                }
                return read
            }
        } catch {
            onDiagnostic(.storeUnavailable(error: UsageLedgerDiagnostic.Failure(error)))
            return
        }
        for (sessionID, value) in zip(sessionIDs, totals) where lastPublished[sessionID] != value {
            lastPublished[sessionID] = value
            enqueuePublish(sessionID, value)
        }
    }

    /// A session's totals: its rows (at most one recorded and one
    /// unreported) summed field by field, saturating; nil for no row.
    private static func totals(of rows: [UsageTokenRow]) -> UsageTokenTotals? {
        guard !rows.isEmpty else { return nil }
        return rows.reduce(into: UsageTokenTotals()) { sum, row in
            sum.input = saturatingSum(sum.input, row.inputTokens)
            sum.output = saturatingSum(sum.output, row.outputTokens)
            sum.cacheRead = saturatingSum(sum.cacheRead, row.cacheReadTokens)
            sum.cacheCreation = saturatingSum(sum.cacheCreation, row.cacheCreationTokens)
        }
    }

    /// `a + b`, at `Int64.max` (or `.min`) instead of trapping.
    private static func saturatingSum(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    /// Queues one publish and starts the delivering task if none runs.
    /// One task delivers the queue in order, so publishes arrive in call
    /// order and none is awaited by whoever requested it.
    private func enqueuePublish(_ sessionID: String, _ totals: UsageTokenTotals?) {
        pendingPublishes.append((sessionID: sessionID, totals: totals))
        guard !isPublishing else { return }
        isPublishing = true
        Task { await self.deliverPublishes() }
    }

    private func deliverPublishes() async {
        while let next = pendingPublishes.first {
            pendingPublishes.removeFirst()
            await publish(next.sessionID, next.totals)
        }
        isPublishing = false
        signalChange()
    }

    /// Returns once every queued publish was delivered.
    private func waitForPublishes() async {
        while isPublishing {
            await waitForChange()
        }
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

    /// The ledger the app runs: the real run-log reader and git resolver,
    /// the given setting, roots and summaries. Each session's totals are
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
            publish: { sessionID, totals in
                await summaries.set(totals, forSession: sessionID)
            },
            onDiagnostic: { log($0) }
        )
    }

    /// The app's ledger, over Claude Code's projects directory. Its store
    /// directory (`productionStoreDirectory`) is the usage directory in
    /// Application Support, or a per-process temporary directory in a
    /// launch that may not touch the developer's paths; it is decided
    /// once, when this is created. Created at its first use, on whichever
    /// thread that is; creating it only computes paths. The setting and
    /// the launch policy are read at every call of `isEnabled`, so a
    /// change of the setting applies to the next event.
    static let shared = makeProduction(
        isEnabled: {
            isTrackingEnabled(
                setting: UsageTrackingSettings.enabled,
                launchMayTouchAgentPaths: LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()
            )
        },
        projectsRoot: { AgentToolPaths.claudeProjectsDirectory },
        storeDirectory: productionStoreDirectory(
            launchMayTouchAgentPaths: LaunchEnvironmentPolicy.mayPerformAgentIPCActivation(),
            usagePath: AppSupportDirectory.usagePath
        ),
        summaries: .shared
    )

    /// The directory of the app's usage database: `usagePath` when this
    /// launch may touch the developer's real paths; otherwise a directory
    /// of this process's own under `NSTemporaryDirectory()`, which this
    /// function does not create.
    ///
    /// Reading and deleting open an existing database whatever the
    /// tracking setting, so a launch that may not touch the real paths
    /// (a `--uitesting` launch without a scoped path root) must not point
    /// them at the real one. The temporary directory is safe only because
    /// tracking is off in exactly that launch (`isTrackingEnabled(setting:
    /// launchMayTouchAgentPaths:)` with `launchMayTouchAgentPaths` false),
    /// so nothing creates it or writes there: reads find no database and
    /// a delete removes nothing. Allowing tracking in such a launch would
    /// start writing into the temporary directory, so that rule and this
    /// one must change together.
    static func productionStoreDirectory(launchMayTouchAgentPaths: Bool, usagePath: String) -> URL {
        guard launchMayTouchAgentPaths else {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "Calyx-usage-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return URL(fileURLWithPath: usagePath, isDirectory: true)
    }

    /// One log line per diagnostic. Session ids, paths and a failure's
    /// description (which may name a path) keep the default private
    /// privacy; a failure's domain and code, errno values and status
    /// names are public, so a log that hides the text still tells a full
    /// disk from a permission error. Nothing here comes from a
    /// transcript's content.
    private static func log(_ diagnostic: UsageLedgerDiagnostic) {
        switch diagnostic {
        case .projectRootResolutionFailed(let sessionID):
            logger.warning("Project root of session \(sessionID) could not be resolved; its working directory is used")
        case .storeUnavailable(let error):
            logger.error("""
                Usage store is unavailable: \
                \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.description)
                """)
        case .exportUndecodable:
            logger.warning("A usage export could not be decoded")
        case .runLogReadFailed(let sessionID, let error):
            logger.error("""
                Run log of session \(sessionID) could not be read: \
                \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.description)
                """)
        case .transcriptNotUsable(let sessionID, let status):
            logger.warning(
                "Transcript of session \(sessionID) was not read: \(runLogStatusName(status), privacy: .public)")
        case .reconcileFailed(let sessionID, let error):
            logger.error("""
                Unreported usage of session \(sessionID) could not be recomputed: \
                \(error.domain, privacy: .public) \(error.code, privacy: .public): \(error.description)
                """)
        }
    }

    private static func runLogStatusName(_ status: UsageRunLogReadResult.Status) -> String {
        switch status {
        case .read: return "read"
        case .missing: return "missing"
        case .notARegularFile: return "notARegularFile"
        case .redirected: return "redirected"
        }
    }
}
