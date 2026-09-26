//
//  SessionBrowserModelRefreshDedupeTests.swift
//  CalyxTests
//
//  SessionBrowserModel.refresh() has no in-flight guard, so a second
//  refresh() issued while a previous one is still awaiting the daemon
//  round-trip (listAllBounded()) starts a second, fully overlapping
//  daemon call instead of reusing the first's outstanding one. On the
//  session browser's 1s poll timer this stacks an unbounded number of
//  concurrent daemon round-trips behind a slow/hung calyx-session
//  daemon instead of naturally backing off to the bound's own cadence.
//
//  Drives SessionBrowserModel.refresh() directly against a fake
//  SessionDaemonClientProtocol whose listAll() suspends on a
//  continuation this test controls explicitly, letting the assertion
//  observe the in-flight call count deterministically -- no reliance on
//  wall-clock timing. Note listAllBounded() (the method refresh() calls
//  the daemon through) is a SessionDaemonClientProtocol extension
//  default, so it always races the fake's listAll() against its own
//  5s bound rather than being independently overridable per fake; as
//  long as the fake's listAll() resolves well inside 5s (which
//  resumeAllPending() below drives explicitly), the daemon arm wins the
//  race and this test never depends on that bound actually elapsing.
//
//  Coverage:
//  - Two refresh() calls issued back-to-back, the second while the
//    first is still awaiting the daemon, must never have more than ONE
//    daemon round-trip in flight at a time (before the fix each call
//    fired its own overlapping one immediately)
//  - The second call is serialized, not dropped: once the first
//    completes, it runs its own round-trip
//  - A parked call whose Task is cancelled before it wakes never
//    issues a round-trip of its own
//

import XCTest
@testable import Calyx

/// Records every `listAll()` invocation and suspends each one on a
/// continuation the test resumes explicitly via `resumeAllPending()` --
/// a process boundary stand-in, no real `calyx-session` binary
/// involved. Not shared with `SessionBrowserModelTests`' own fake,
/// matching this codebase's established per-file fixture-duplication
/// convention (see `AppDelegateAgentResumeStalenessTests`).
private final class SuspendingCountingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var pendingContinuations: [CheckedContinuation<[SessionInfo], Never>] = []

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async -> SessionKillOutcome { .killed }

    /// `NSLock.lock()`/`unlock()` are unavailable at the top level of an
    /// `async` function body under this toolchain's Swift 6 diagnostics
    /// (async-unsafe scoped locking), so the increment is a plain
    /// synchronous helper `listAll()` calls into instead of locking
    /// inline.
    private func incrementCallCount() {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
    }

    private func addPendingContinuation(_ continuation: CheckedContinuation<[SessionInfo], Never>) {
        lock.lock(); defer { lock.unlock() }
        pendingContinuations.append(continuation)
    }

    func listAll() async -> [SessionInfo] {
        incrementCallCount()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[SessionInfo], Never>) in
            addPendingContinuation(continuation)
        }
    }

    /// Resumes every `listAll()` call currently suspended with an empty
    /// ledger, unblocking any in-flight `refresh()`'s awaited daemon
    /// round-trip so the test can drain both Tasks to completion.
    func resumeAllPending() {
        lock.lock()
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: [])
        }
    }
}

@MainActor
final class SessionBrowserModelRefreshDedupeTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve against a genuinely stuck
    /// condition -- not a wall-clock wait, just an upper bound on how
    /// many scheduler turns we're willing to hand back before giving up
    /// and letting the assertion below fail with the real count.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    /// Primary assertion pinning the fix: before it,
    /// `refresh()` had no in-flight guard, so a second
    /// call issued while the first is still awaiting the daemon starts
    /// its own, fully overlapping `listAll()` round-trip. The second
    /// call now waits for the first to finish and then issues its own
    /// round-trip (see the next test), so the tail below resumes the
    /// first, waits for the second's call to arrive, and resumes that
    /// too before awaiting both Tasks.
    func test_refresh_secondCallWhileFirstInFlight_dedupesToOneDaemonCall() async {
        let client = SuspendingCountingDaemonClient()
        let surfaceMap = SessionSurfaceMap()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: surfaceMap, herdrAvailability: { false })

        let firstRefresh = Task { await model.refresh() }
        // Let the first refresh() actually reach the daemon call before
        // firing the second, so the second call is provably issued
        // while the first is in flight, not merely racing its start.
        await waitUntil { client.callCount >= 1 }

        let secondRefresh = Task { await model.refresh() }
        // Give the second refresh() every opportunity to reach its own
        // daemon call too, so a would-be second round-trip has had a
        // fair chance to fire before we assert.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(
            client.callCount, 1,
            "A second refresh() issued while the first is still awaiting the daemon must not start an " +
            "overlapping round-trip -- refresh() needs an in-flight guard"
        )

        client.resumeAllPending()
        _ = await firstRefresh.value
        await waitUntil { client.callCount >= 2 }
        client.resumeAllPending()
        _ = await secondRefresh.value
    }

    /// TDD Red (Test 2, see task spec): a refresh() requested while another
    /// is already in flight must not be silently DROPPED once the in-flight
    /// one finishes -- it still owes its own caller a fresh daemon
    /// round-trip. Today `refresh()`'s `guard !isRefreshing else { return }`
    /// makes the second call return immediately with nothing queued, so
    /// `secondRefresh.value` resolves without ever driving a second
    /// `listAll()` call and `callCount` never reaches 2.
    ///
    /// The resume/wait/resume/await sequence below is deliberately
    /// design-agnostic between the two fixes an implementer might pick:
    /// (a) queue-and-replay (the second call parks and, once the first
    /// finishes, itself issues a fresh round-trip), or (b) coalesce-and-loop
    /// (the still-running first call notices a second request arrived and
    /// loops to serve it before returning). Resuming BEFORE waiting for
    /// `firstRefresh.value` avoids a false hang under design (b): if the
    /// implementation loops inside the first refresh's own Task, that Task
    /// is what issues the second `listAll()` call, and `firstRefresh.value`
    /// only resolves once that second call also resumes -- so this test's
    /// own `client.resumeAllPending()` must fire again for that call before
    /// awaiting `firstRefresh.value`, not after.
    ///
    /// `herdrAvailability: { false }` (not the default) so this stays a
    /// pure daemon-only round-trip: `SessionBrowserModel`'s default
    /// `herdrAvailability` hops onto a real `HerdrBinaryResolver.resolve()`
    /// PATH scan, and an available default `herdrProvider` would then
    /// perform a real network round-trip against whatever herdr sockets
    /// exist on this machine -- neither belongs in a daemon-call-counting
    /// unit test.
    func test_refresh_secondCallAfterFirstCompletes_issuesItsOwnDaemonRoundTrip() async {
        let client = SuspendingCountingDaemonClient()
        let surfaceMap = SessionSurfaceMap()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: surfaceMap, herdrAvailability: { false })

        let firstRefresh = Task { await model.refresh() }
        await waitUntil { client.callCount >= 1 }

        let secondRefresh = Task { await model.refresh() }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(
            client.callCount, 1,
            "still deduped while the first call is in flight -- the existing invariant this test does " +
            "not change"
        )

        client.resumeAllPending()
        await waitUntil { client.callCount >= 2 }
        client.resumeAllPending()
        _ = await firstRefresh.value
        _ = await secondRefresh.value

        XCTAssertEqual(
            client.callCount, 2,
            "the second refresh() must run its own daemon round-trip once the first completes, instead " +
            "of being a no-op that returns without ever calling listAll() again"
        )
    }

    /// A `refresh()` parked behind an in-flight one whose own Task is
    /// cancelled while parked must return on wake WITHOUT issuing a
    /// `listAll()` round-trip -- its caller has already given up, and
    /// every assignment the round-trip would feed is `Task.isCancelled`-
    /// guarded anyway, so the call would be pure waste. The second
    /// `resumeAllPending()` before awaiting `secondRefresh` keeps a
    /// regression (a waiter that DOES call `listAll()`) from hanging the
    /// test instead of failing the count assertion.
    func test_refresh_waiterCancelledWhileParked_neverIssuesDaemonRoundTrip() async {
        let client = SuspendingCountingDaemonClient()
        let surfaceMap = SessionSurfaceMap()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: surfaceMap, herdrAvailability: { false })

        let firstRefresh = Task { await model.refresh() }
        await waitUntil { client.callCount >= 1 }

        let secondRefresh = Task { await model.refresh() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(client.callCount, 1, "the second refresh() must be parked behind the first")

        secondRefresh.cancel()
        client.resumeAllPending()
        _ = await firstRefresh.value
        for _ in 0..<50 { await Task.yield() }
        client.resumeAllPending()
        _ = await secondRefresh.value

        XCTAssertEqual(
            client.callCount, 1,
            "a refresh() cancelled while parked must return on wake without calling listAll()"
        )
    }
}
