// HerdrIntegrationCoordinator.swift
// Calyx
//
// @MainActor lifecycle owner for the herdr connection: takes a
// `session.snapshot` on its own one-shot connection, subscribes on a
// SEPARATE, long-lived event-stream connection, keeps
// `HerdrAgentMirror` in sync with pushed events, and rebuilds or
// reconnects as the pane set or transport health changes. Every
// dependency is injected (discovery, a transport factory, the mirror)
// so this file's own tests never open a real socket -- see
// HerdrIntegrationCoordinatorTests.swift.
//
// LIFECYCLE: the connection is a FUNCTION of herdr's own presence.
// `HerdrSessionPresence` owns the question "is a herdr session there
// right now?" and reports every transition through
// `herdrSessionPresenceDidChange(_:)` (see the extension at the bottom
// of this file for the per-change contract); nothing else starts,
// stops, or re-aims a connection. There is no polling timer anywhere in
// this type and no detection of its own -- nothing here loops or
// retries on its own initiative except the bounded reconnect described
// below, itself only ever triggered BY a connection to a session
// presence says is live failing (its stream ending, or the very first
// attempt for that session not completing), never by a clock.
//
// `discovery` survives that split for ONE remaining purpose: gating
// each bounded reconnect attempt on `isAlive(socketPath:)`, the probe
// that tells a server which merely dropped one connection from one
// which is gone. Which sockets exist, and which of them are live, is
// presence's question alone.
//
// CONNECT SEQUENCE (`attemptConnect(socketPath:)`, pinned by test) --
// MEASURED against a real herdr 0.8.0 server: a request/response
// connection serves EXACTLY ONE request (the server closes it right
// after), and `events.subscribe` is the ONLY thing that keeps a
// connection open -- see HerdrConnection.swift's own header for the full
// measured contract this follows directly from:
//   1. `HerdrTransportFactory.makeTransport()` + `HerdrOneShotRequest
//      .send(method: "session.snapshot", ...)`, on its OWN transport --
//      this is the ONLY way to learn the CURRENT pane set and agent
//      statuses (subscribing never replays agent-status events, only
//      structural ones, and a replayed pane_created record carries no
//      agent identity at all -- see HerdrConnection.swift's own header,
//      fact 4).
//   2. `mirror.applySnapshot(_:socketPath:)` -- applied on EVERY
//      successful snapshot, including one about to be superseded by a
//      REBUILD TRIGGER below; the snapshot data itself is always
//      accurate.
//   3. `knownPaneIDs` is (re)populated from the snapshot's own
//      `panes[].paneID` -- REPLACING whatever this instance held before,
//      never merged with it. This is what the per-pane subscription list
//      below is built from, so it is always exactly what THIS attempt's
//      own snapshot just revealed. Deliberately NOT `agents[]` -- a
//      pane with no detected agent is still a pane whose status changes
//      we want to hear about, and seeding from `agents[]` alone also
//      guaranteed a mismatch against the very first event any replay
//      burst ever delivers -- see REPLAY BURST RECONCILIATION below for
//      the MEASURED DEFECT this caused and its fix. Separately,
//      `recognizedPaneIDs` (UNION, never replaced -- see REPLAY BURST
//      RECONCILIATION) also absorbs every one of these pane ids on
//      every `attemptConnect`.
//   4. `HerdrTransportFactory.makeTransport()` + `HerdrEventStream
//      .subscribe(_:socketPath:)`, on its OWN, SEPARATE transport,
//      carrying the six structure events herdr documents as type-only
//      ("pane.created", "pane.closed", "pane.exited",
//      "pane.agent_detected", "layout.updated", "workspace.closed")
//      PLUS one `.agentStatusChanged(paneID:)` per pane step 3 just revealed --
//      per pane step 3 revealed ONLY, never per a `recognizedPaneIDs`-
//      only (replay-only) pane id -- see REPLAY BURST RECONCILIATION
//      below, "WHY THE SUBSCRIBE LIST STAYS `knownPaneIDs`-ONLY": MEASURED
//      against a real herdr 0.8.0 server, subscribing
//      `pane.agent_status_changed` for a pane id herdr does not
//      currently consider current -- whether it once genuinely existed
//      or never did -- is REJECTED outright
//      ({"error":{"code":"pane_not_found","message":"pane ... not
//      found"}}), and the WHOLE `events.subscribe` request fails,
//      closing the connection.
//   5. Only on a successful subscribe does this instance begin consuming
//      the returned stream, for as long as that connection lives -- see
//      "ONGOING EVENT HANDLING" below.
//
// Because the snapshot ALWAYS runs before the subscribe that depends on
// it, the subscribe's own per-pane list is always exactly what THAT
// snapshot revealed. The one remaining, deliberately accepted race -- a
// pane created in the tiny window between the snapshot response and the
// subscribe ack -- is still caught without any retry: subscribing
// replays every EXISTING pane as a `pane.created` event on the new
// connection (HerdrConnection.swift's own header, fact 4), which
// `consumeEvents` below still reacts to like any other newly-observed
// pane, via REPLAY BURST RECONCILIATION below.
//
// REPLAY BURST RECONCILIATION -- MEASURED DEFECT and fix. Against a
// real herdr 0.8.0 server, `session.snapshot` deterministically returned
// a strict SUBSET of what a FRESH `events.subscribe`'s own replay burst
// reported (2 panes vs. 5 -- the extra 3 belonged to workspaces closed
// BEFORE either probe ever connected; confirmed byte-for-byte identical
// across two independent probes). A design that treats "a replayed pane
// id I do not already know about" as an IMMEDIATE rebuild trigger
// therefore rebuilds forever: the very FIRST replayed event triggers a
// rebuild, whose own fresh subscribe replays the identical burst,
// triggering another rebuild, with NO delay and NO bound, against a
// server whose actual current state never changes. That was this file's
// own prior bug. The fix tracks two SEPARATE sets for two SEPARATE
// purposes:
//   - `knownPaneIDs` (REPLACED wholesale by every `attemptConnect`'s own
//     fresh `panes[]`) is exactly, and ONLY EVER, what this connection's
//     subscribe legitimately lists per-pane -- CONNECT SEQUENCE step 4
//     above is why a replay-only id must never end up in this set.
//   - `recognizedPaneIDs` (UNION -- grows across every
//     attemptConnect/reconcile for as long as `isActive`; cleared only
//     by `resetToIdle()`) is every pane id this instance has EVER been
//     told about, by snapshot OR by replay. This -- not `knownPaneIDs`
//     -- is what "is this `pane.created` event genuinely new" is judged
//     against in steady state (below): once a replay-only ghost id has
//     been recognized once, it never again looks new. This is the one
//     place this file's behavior deliberately departs from a literal
//     "compare the union against the panes actually subscribed" --
//     CONNECT SEQUENCE step 4 rules out ever WIDENING the subscribed set
//     itself to include a replay-only id, so the comparison and the
//     convergence below are against `recognizedPaneIDs` instead.
//
// Right after every successful subscribe, this instance spends up to
// `replayBurstSettleWindow` in an ACCUMULATING phase
// (`isAccumulatingReplayBurst`): every `pane.created` event is added to
// `pendingBurstPaneIDs` and applied to the mirror as usual, but is NOT
// individually treated as a rebuild trigger -- unlike
// `pane.closed`/`pane.exited`, which stay UNCONDITIONAL rebuild triggers
// at ALL times, accumulating or not (HerdrConnection.swift's own header,
// fact 4: only `pane_created` is ever replayed, so acting on these two
// immediately carries no storm risk). A background task
// (`burstSettleTask`) sleeps `replayBurstSettleWindow` (the SAME injected
// `sleep` primitive DISCONNECT HANDLING's own backoff below uses) and
// then settles the burst EXACTLY once:
// `pendingBurstPaneIDs.subtracting(recognizedPaneIDs)` is what the burst
// revealed that this instance did not already recognize. Empty -- the
// common, converged steady state -- ends the accumulating phase with NO
// rebuild at all, and resets the CONSECUTIVE-REBUILD CAP below (a clean
// settle is itself proof this cycle is not pathological). Non-empty --
// e.g. the very first subscribe against a server carrying replay-only
// ghosts -- merges the difference into `recognizedPaneIDs` (so it can
// never look "new" again) and rebuilds EXACTLY ONCE via
// `triggerRebuild`, below. Because the burst is deterministic, that
// rebuild's own fresh subscribe replays the identical burst again, but
// this time every replayed id is already in `recognizedPaneIDs` -- the
// second settle finds nothing new, and the cycle terminates.
//
// WHY A FIXED, NON-RESETTING WINDOW rather than "the first
// non-`pane.created` event": measured against the same real server, a
// replay burst is NOT a contiguous run of `pane.created` events followed
// by ordinary traffic -- it deterministically INTERLEAVES
// `pane.agent_detected` and `layout.updated` events between
// `pane.created` ones (confirmed byte-for-byte identical across
// independent probes). "Settle on the first non-`pane.created` event"
// would therefore conclude the burst had ended after the SECOND event of
// a 13-event burst, compute an incomplete union, and converge only after
// several more rebuilds (bounded by the cap below regardless, but
// needlessly). A FIXED window sidesteps this entirely: it does not
// inspect event TYPE at all, only that the window has elapsed.
//
// CANNOT HANG: `replayBurstSettleWindow` is a single `sleep` call,
// started once per successful subscribe and NEVER reset/extended by
// subsequent traffic (contrast a resetting debounce, which a
// continuously-active connection could in principle defer forever) -- it
// fires unconditionally after a bounded duration, full stop, regardless
// of how much or how little traffic arrives during it. The consume loop
// itself makes progress the entire time regardless (every event,
// replayed or not, is still applied to the mirror as it arrives) --
// nothing here blocks waiting on this window; it only gates whether a
// `pane.created` id is accumulated or immediately actionable.
//
// REBUILD TRIGGERS (steady state, i.e. once a connection's own
// accumulating phase has settled): a "pane.created" event is a trigger
// only when its pane id is not already in `recognizedPaneIDs` (a
// genuinely new pane -- e.g. one created long after this connection
// settled). A `.paneClosed`/`.paneExited` event is ALWAYS a trigger,
// unconditionally, at ANY time (accumulating or steady state) -- see
// REPLAY BURST RECONCILIATION above for why these two carry no storm
// risk. Every trigger funnels through `triggerRebuild(socketPath:generation:)`,
// shared with the settle task's own burst-driven rebuild -- see
// CONSECUTIVE-REBUILD CAP below for what it checks before tearing
// anything down.
//
// CONSECUTIVE-REBUILD CAP -- independent of, and never touching,
// `totalReconnectAttempts` (LIFETIME RECONNECT BUDGET below bounds a
// DIFFERENT failure mode -- a connection that will not stay up at all;
// this cap instead bounds a connection that stays up fine but keeps
// getting rebuilt, e.g. a pathologically misbehaving server whose own
// replay burst never converges on any subscribe).
// `consecutiveRebuildsWithoutProgress` counts rebuilds since the last one
// that either (a) discovered a genuinely new, CURRENT pane -- a pane id
// present in a fresh `session.snapshot` that was NOT in the immediately
// PRECEDING `knownPaneIDs`, a purely mechanical, post-hoc definition of
// "this rebuild was fruitful," computed inside `attemptConnect` itself
// so it applies uniformly no matter what triggered the rebuild -- or (b)
// settled a burst with nothing new to reconcile (proof this cycle
// understands the current state, not proof of "new" progress, but
// equally proof it is not a pathological loop). Once
// `maxConsecutiveRebuildsWithoutProgress` is reached, `triggerRebuild`
// stops rebuilding ENTIRELY -- checked BEFORE any teardown, so the
// CURRENT, still-live, still-subscribed connection is left completely
// untouched: a subscription that misses a status push for a stale/
// never-current pane id is strictly better than an infinite reconnect
// loop against a server that will never converge. Consecutive rebuilds
// also back off (`rebuildBackoffDelays`, indexed by the pre-increment
// counter and clamped to the schedule's own last entry), sleeping BEFORE
// tearing down the current connection -- the existing connection stays
// live and keeps consuming events for the full backoff duration, not
// just until the new one happens to be ready.
//
// SINGLE OWNER, NOT A RACE: `triggerRebuild` and the "stream ended" tail
// of `consumeEvents` (DISCONNECT HANDLING below) are the only two places
// that ever call `attemptConnect` again after the first, and they are
// mutually exclusive via a CLAIM (`claimRebuildOrReconnect()`), taken
// and released SYNCHRONOUSLY (before any `await`, so there is no
// window for two callers to both see it free): whichever of "the
// burst-settle task decided to reconcile-rebuild" or "this connection's
// own stream genuinely ended" reaches its own outer entry point FIRST
// proceeds; the other backs off rather than independently opening a
// SECOND, redundant connection out from under the first.
// `connectionGeneration` (bumped on every successful `attemptConnect`,
// regardless of caller) additionally lets the burst-settle task recognize
// on its own eventual wakeup that the connection it was accumulating for
// has ALREADY been superseded by an unrelated trigger (e.g. an
// unconditional paneClosed/paneExited rebuild firing before the window
// even elapses) -- checked alongside `Task.isCancelled` (the settle task
// is also explicitly cancelled at the same shared teardown point every
// superseding path already uses -- EXPLICIT TRANSPORT TEARDOWN below)
// and `isAccumulatingReplayBurst` itself (flipped by whichever path acts
// first). One narrow, deliberately accepted gap remains, mirroring this
// file's own existing handshake race (CONNECT SEQUENCE above): a genuinely
// external transport EOF/failure landing in the vanishingly small
// scheduling window after a same-generation settle task has already
// passed both its cancellation and generation checks, but before this
// connection's own natural-disconnect path has itself taken the claim,
// could in principle see it already held and back off from handling
// that disconnect directly --
// accepted because the in-flight rebuild already holding the mutex will
// itself reach `attemptConnect`/`handleDisconnect` and correctly resolve
// the connection's fate either way; nothing is silently dropped, only
// handled by whichever side won.
//
// A PRESENCE TRANSITION OUTRANKS BOTH, and deliberately does not queue
// behind `isRebuildOrReconnectInFlight`: presence is reporting that the
// session those two are working on is not the session behind that path
// any more, so waiting for them would mean waiting on work that is
// already pointless. `discardCurrentConnection` therefore bumps
// `connectionGeneration` (BEFORE closing the transport, so the
// `consumeEvents` tail that unblocks on the close cannot see its own
// generation still current), and every step a rebuild or a reconnect
// takes AFTER an `await` re-checks the generation it started with:
// `attemptConnect` twice (once the moment its snapshot answers, before
// that snapshot reaches the mirror at all, and again before adopting a
// connection -- a superseded attempt closes its own subscribe transport
// rather than orphaning the one presence has since established),
// `triggerRebuild` before it touches any state at all, again after its
// backoff, and again after a failed attempt, `reconnectLoop` at every
// iteration and after its own backoff. A
// superseded path always returns silently -- never through
// `giveUpOnBoundSession()`/`handleDisconnect`, which would clear
// `isActive` and the mirror rows belonging to the connection that
// replaced it.
//
// `discardCurrentConnection` also BREAKS the single-owner claim in that
// same synchronous frame, since the holder is by definition working on
// the connection just discarded: without that, a rebuild sleeping
// through its backoff would still hold the claim when the replacement
// connection is established, and the first structure event on that new
// connection would find no owner available and silently skip its
// resync. The broken claim is not released twice: a holder releases
// only the claim it still holds. One accepted gap of the same class as
// the one above: promotion (DISCONNECT HANDLING below) begins while the
// giving-up path's own claim is still held for a few synchronous
// frames, so a rebuild trigger arriving in that window backs off --
// harmless, since the connection it would rebuild is the one just given
// up on.
//
// HANDSHAKE DEADLINE -- now PER STEP, not one combined window:
// each of the two steps above (the snapshot request, the subscribe ack)
// independently races `handshakeTimeout` via `runWithDeadline(transport:
// operation:)`, mirroring `SessionDaemonClient.bounded()`'s own
// two-unstructured-Tasks-race-a-shared-continuation shape (`withTaskGroup`
// cannot be used here: a stalled step -- the server accepted the
// connection but never answers -- never observes cancellation, so a
// `TaskGroup`'s implicit "await every child before returning" would hang
// exactly as long as the deadline exists to bound). `sleep` -- the same
// injected delay primitive DISCONNECT HANDLING's own backoff uses below
// -- is the timeout arm's wait primitive, so tests drive both
// deterministically. Expiry is handled EXACTLY like the step throwing:
// `attemptConnect` returns `false`, identical to an ordinary connect
// failure -- every existing caller already handles that outcome.
//
// On timeout, `runWithDeadline` closes the STUCK step's own transport
// DIRECTLY -- unlike `HerdrSocketSession` (the type this coordinator used
// to depend on), whose stuck requests needed an `abandon()` indirection
// through the session actor itself, a one-shot/event-stream connection's
// transport is created by, and already held directly by, THIS caller (see
// `attemptConnect(socketPath:)`), so there is no intermediary to ask.
// Closing it unsticks whichever suspension the stuck step is inside,
// exactly as an ordinary transport EOF would, letting that step's own
// `Task` unwind and release its captures instead of leaking them forever.
//
// ONGOING EVENT HANDLING: every event read off the stream is forwarded
// to `mirror.apply(event:socketPath:)`, then separately inspected for a
// REBUILD TRIGGER (above) -- during the accumulating phase, a
// `pane.created` event is instead added to `pendingBurstPaneIDs` (see
// REPLAY BURST RECONCILIATION above). The FIRST event any given
// connection ever delivers also earns back DISCONNECT HANDLING's own
// lifetime reconnect budget -- see LIFETIME RECONNECT BUDGET below. A
// trigger that actually proceeds (see CONSECUTIVE-REBUILD CAP above for
// when it does not) closes and drops this instance's reference to the
// current event-stream transport (see EXPLICIT TRANSPORT TEARDOWN
// below), then re-runs `attemptConnect` against the SAME socket path --
// no explicit cancellation of the event-reading task is needed, or even
// possible: `consumeEvents` IS that task's own body, already running,
// and this instance never retains a `Task` handle for it at all (there
// is nothing here it would be used for); it simply `return`s right
// after this call and the task self-terminates.
//
// STRUCTURE EVENT OBSERVER (`HerdrStructureEventObserver`, set via
// `setStructureEventObserver`): a `pane.closed` event notifies
// `herdrPaneClosed(paneID:socketPath:)` BEFORE the pre-existing
// unconditional rebuild above runs -- both happen, the observer call is
// simply ordered first since a successful rebuild `return`s this Task.
// `pane.exited` deliberately does NOT notify the observer: the herdr
// pane itself still exists after its own child process exits, so closing
// a Calyx bridge surface for it would be wrong. A `layout.updated` event
// (decoded generically as `.unknown(eventType: "layout_updated")`)
// notifies `herdrLayoutUpdated(socketPath:)` ONLY in steady state --
// never while still accumulating a fresh subscribe's own replay burst,
// for the identical storm-avoidance reason REPLAY BURST RECONCILIATION
// above already applies to `pane.created`. A `workspace_closed` event
// notifies `herdrWorkspaceClosed(workspaceID:socketPath:)`
// UNCONDITIONALLY -- accumulating or steady state alike, unlike
// `layout.updated`'s own gate above -- and touches NEITHER
// `knownPaneIDs`/`recognizedPaneIDs` NOR `triggerRebuild`: closing a
// whole workspace never removes a SINGLE already-known pane id from this
// coordinator's own bookkeeping the way an individual `pane.closed`
// does, and a `workspaceID` this instance never opened a tab for is a
// no-op downstream (`HerdrTabCoordinator.handleWorkspaceKilled`'s own
// contract), sending herdr nothing either way -- there is no storm risk
// here to guard against with a REPLAY BURST RECONCILIATION-style dedup.
//
// EXPLICIT TRANSPORT TEARDOWN: unlike the type this coordinator used to
// depend on (`HerdrSocketSession`, whose `BSDHerdrTransport` cleans
// itself up via `deinit` once ARC drops the session's own last strong
// reference), `HerdrEventStream.subscribe(_:socketPath:)`'s own relay
// task (which forwards transport lines onto the returned event stream)
// captures ONLY the stream, never the transport or this coordinator --
// so ARC alone dropping `currentEventStreamTransport` is NOT enough to
// guarantee prompt teardown, particularly for the `InMemoryHerdrTransport`
// test double, which (per HerdrTransport.swift's own contract) has no
// `deinit` safety net of its own. Every path that supersedes or gives up
// on the current event-stream connection
// -- REBUILD TRIGGERS above, and DISCONNECT HANDLING below -- therefore
// closes `currentEventStreamTransport` EXPLICITLY before dropping it,
// rather than relying on ARC, and ALSO explicitly cancels
// `burstSettleTask` at the same point (see SINGLE OWNER, NOT A RACE
// above) -- a harmless no-op once that task has already fired or was
// never accumulating in the first place.
//
// DISCONNECT HANDLING: the event stream ending -- normally (a clean
// EOF) or by throwing (a transport failure) -- is handled identically:
// call `mirror.connectionLost()`, close and drop the event-stream
// transport (see EXPLICIT TRANSPORT TEARDOWN above), then attempt a
// bounded reconnect, each attempt gated by `discovery.isAlive(socketPath:)`
// (checked before AND after its backoff delay -- the delay itself is
// exactly the window in which the socket could disappear): as soon as
// the socket no longer probes alive, stop entirely, no further retry.
// `reconnectDelays` bounds EACH CYCLE's own attempt count (its own
// `count`) and supplies each attempt's backoff duration; `sleep` is the
// injected delay primitive (defaults to real `Task.sleep`, overridden
// in tests to drive it deterministically).
//
// GIVING UP, AND PROMOTION: running out of budget or of
// `reconnectDelays`, or the socket no longer probing alive, is terminal
// FOR THAT SESSION only (`giveUpOnBoundSession()`): the identity is
// marked abandoned, and any OTHER session presence has reported live is
// bound and connected to instead. A session given up on is never
// retried, and never promoted to, until presence reports the path
// carrying a different one -- which is what stops two failing sessions
// from promoting each other forever.
//
// LIFETIME RECONNECT BUDGET: `reconnectDelays` alone bounds only
// ONE disconnect-to-give-up cycle -- a server that repeatedly accepts a
// connection and then immediately drops it again starts a FRESH cycle
// every time, so bounding each cycle in isolation still allows
// unbounded reconnect churn (and visible sidebar flapping: rows cleared
// and repopulated every cycle) across many cycles.
// `totalReconnectAttempts` instead counts every `reconnectLoop`-driven
// attempt across every cycle, capped by `maxLifetimeReconnectAttempts`;
// once reached, `reconnectLoop` gives up permanently (`resetToIdle()`)
// without even trying the remaining attempt, same as running out of
// `reconnectDelays` entries.
//
// The budget belongs to `boundIdentity` -- the ONE herdr session this
// coordinator is currently bound to -- not to this process. What it
// bounds is reconnect churn against a single server, so its verdict
// reaches exactly as far as that server does: `boundIdentity` changing
// (presence reporting the socket REPLACED, or a different live session
// taken up after the bound one DISAPPEARED) discards the spent budget
// along with everything else that was true of the old server. Without
// that, one flapping session would permanently deafen Calyx to every
// later one. Deliberately NOT reset by `resetToIdle()`'s own full
// give-up: giving up on a server says nothing about that server having
// changed. The ONLY other way to earn the budget back to zero is a
// connection proving itself
// HEALTHY, defined here as: it delivered at least one event AFTER its
// own subscribe ack completed (the first iteration of `consumeEvents`'s
// own read loop for that connection actually running). A successful
// subscribe ALONE is deliberately NOT enough -- a server that accepts,
// completes the snapshot and subscribe, and drops again before ever
// pushing anything would otherwise reset the budget every single cycle,
// reproducing the exact indefinite churn this budget exists to prevent.
// Known, accepted limitation: `subscribe(_:)`'s own replay burst counts
// as "at least one event" for a connection with 1+ existing panes, so a
// flapper that happens to survive just long enough to deliver that burst
// before dropping again would still earn the reset -- narrower than a
// wall-clock "stayed up N seconds" bar would be, but avoids a second
// timer/clock dependency for a bar this coordinator does not currently
// need to be that precise about.
//

import Foundation

// MARK: - HerdrStructureEventObserver

/// Notified of herdr-side structural events relevant to a native tab
/// already bridged via `HerdrTabCoordinator` -- see that file's own
/// header. `setStructureEventObserver` stores its argument WEAKLY: this
/// coordinator never owns an observer's own lifecycle.
@MainActor
protocol HerdrStructureEventObserver: AnyObject {
    /// A `layout.updated` event was pushed for `socketPath`, in steady
    /// state only -- never during a fresh subscribe's own replay burst;
    /// see this file's header "REPLAY BURST RECONCILIATION".
    func herdrLayoutUpdated(socketPath: String)
    /// A `pane.closed` event was pushed for `paneID` on `socketPath`.
    func herdrPaneClosed(paneID: String, socketPath: String)
    /// A `workspace.closed` event was pushed for `workspaceID` on
    /// `socketPath` -- herdr closed the WHOLE workspace server-side
    /// (its own TUI, the CLI, or another client), which does NOT also
    /// push `pane.closed` for that workspace's own panes (measured
    /// against a real herdr 0.8.0 server). Notified unconditionally,
    /// at ANY time -- see this file's header "STRUCTURE EVENT OBSERVER".
    func herdrWorkspaceClosed(workspaceID: String, socketPath: String)
}

// MARK: - HerdrIntegrationCoordinator

@MainActor
final class HerdrIntegrationCoordinator {

    /// The six herdr structure events subscribed type-only on every
    /// (re)subscribe -- see this file's header, CONNECT SEQUENCE step 4.
    static let structureEventSubscriptionTypes = [
        "pane.created", "pane.closed", "pane.exited", "pane.agent_detected", "layout.updated", "workspace.closed",
    ]

    /// Default bounded backoff schedule for DISCONNECT HANDLING's
    /// reconnect attempts -- its `count` is the max attempt count PER
    /// CYCLE; see `maxLifetimeReconnectAttempts` for the cross-cycle
    /// bound.
    static let defaultReconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Default HANDSHAKE DEADLINE -- applied independently to EACH
    /// of the snapshot step and the subscribe step (see this file's
    /// header). Generous enough that a merely slow (not hung) real herdr
    /// server is never mistaken for a stalled one, while still bounding
    /// the otherwise-unbounded wait a connection-accepted-then-silent
    /// server would impose.
    static let defaultHandshakeTimeout: Duration = .seconds(10)

    /// Default LIFETIME RECONNECT BUDGET -- see this file's header.
    /// Deliberately larger than any single cycle's own `reconnectDelays
    /// .count` so ordinary transient blips (which settle and prove
    /// HEALTHY well before this total is reached) are never affected.
    static let defaultMaxLifetimeReconnectAttempts = 10

    /// Default REPLAY BURST RECONCILIATION window (see this file's
    /// header) -- pragmatic, unmeasured (mirrors
    /// `BSDHerdrTransport.writePollTimeoutMilliseconds`'s own precedent
    /// for a bounded-but-not-precisely-tuned duration): generous enough
    /// that a real replay burst (measured: well under 100ms for 13
    /// events over a local Unix socket) has long finished arriving,
    /// short enough that a genuinely new pane created while a fresh
    /// connection is still accumulating is not noticeably delayed.
    static let defaultReplayBurstSettleWindow: Duration = .milliseconds(500)

    /// Default CONSECUTIVE-REBUILD CAP (see this file's header) -- small
    /// on purpose: this bounds a pathological server whose replay burst
    /// never converges, not ordinary operation (which converges in at
    /// most one rebuild against every server measured so far).
    static let defaultMaxConsecutiveRebuildsWithoutProgress = 3

    /// Default backoff between consecutive rebuilds (see this file's
    /// header "CONSECUTIVE-REBUILD CAP") -- independent of, and
    /// deliberately shorter than, `defaultReconnectDelays`: a rebuild
    /// keeps the CURRENT connection alive throughout, unlike a
    /// reconnect, so there is less need for a long wait between
    /// attempts.
    static let defaultRebuildBackoffDelays: [Duration] = [.milliseconds(200), .seconds(1), .seconds(2)]

    private let discovery: any HerdrSessionDiscoveryProtocol
    private let transportFactory: any HerdrTransportFactory
    private let mirror: HerdrAgentMirror
    private let reconnectDelays: [Duration]
    private let handshakeTimeout: Duration
    private let maxLifetimeReconnectAttempts: Int
    private let replayBurstSettleWindow: Duration
    private let maxConsecutiveRebuildsWithoutProgress: Int
    private let rebuildBackoffDelays: [Duration]
    private let sleep: @Sendable (Duration) async -> Void

    /// See `HerdrStructureEventObserver`'s own doc comment -- stored
    /// WEAKLY, set via `setStructureEventObserver`, never through `init`.
    private weak var structureEventObserver: any HerdrStructureEventObserver?

    /// The transport behind the CURRENT, subscribed event-stream
    /// connection, once `attemptConnect(socketPath:)` has succeeded --
    /// `nil` before the first successful connect, and while idle/
    /// reconnecting. See this file's header "EXPLICIT TRANSPORT
    /// TEARDOWN" for why every path that supersedes or gives up on it
    /// closes it explicitly rather than relying on ARC.
    private var currentEventStreamTransport: any HerdrTransport?

    /// REPLACE semantics -- see this file's header, CONNECT SEQUENCE
    /// step 3 and REPLAY BURST RECONCILIATION. ONLY EVER exactly this
    /// connection's own fresh `panes[]`; never a replay-only id.
    private var knownPaneIDs: Set<String> = []

    /// UNION semantics -- see this file's header, REPLAY BURST
    /// RECONCILIATION. Grows across every `attemptConnect`/settle for as
    /// long as `isActive`; cleared only by `resetToIdle()`.
    private var recognizedPaneIDs: Set<String> = []

    /// REPLAY BURST RECONCILIATION state (see this file's header) --
    /// ALL reset at the top of every successful `attemptConnect`.
    private var isAccumulatingReplayBurst = false
    private var pendingBurstPaneIDs: Set<String> = []
    private var burstSettleTask: Task<Void, Never>?

    /// Bumped on every successful `attemptConnect`, regardless of
    /// caller -- see this file's header "SINGLE OWNER, NOT A RACE".
    private var connectionGeneration = 0

    /// SINGLE OWNER, NOT A RACE (see this file's header): claimed
    /// synchronously by `triggerRebuild` and by the natural-disconnect
    /// tail of `consumeEvents` before either does anything else, so only
    /// one of the two may ever be establishing/tearing down a
    /// connection at a time. The claim belongs to the CONNECTION it was
    /// taken for: `discardCurrentConnection` breaks it outright, and the
    /// holder's own release is conditional on still holding the SAME
    /// claim, so a claim broken while its holder sleeps can never be
    /// released a second time out from under whoever claimed next.
    private var currentRebuildOrReconnectClaim: Int?
    private var lastRebuildOrReconnectClaimID = 0

    /// CONSECUTIVE-REBUILD CAP (see this file's header) -- counts
    /// rebuilds since the last one that made mechanical progress (see
    /// `attemptConnect`) or settled a burst with nothing new to
    /// reconcile. Independent of, and never touched by,
    /// `totalReconnectAttempts` below.
    private var consecutiveRebuildsWithoutProgress = 0

    /// LIFETIME RECONNECT BUDGET -- see this file's header. Counts
    /// every `reconnectLoop`-driven attempt against `boundIdentity`,
    /// across every disconnect cycle; deliberately NOT touched by
    /// `resetToIdle()`. Reset to zero by `boundIdentity` changing (the
    /// budget belongs to a session, not to this process) or by a
    /// connection earning itself HEALTHY (see `consumeEvents`).
    private var totalReconnectAttempts = 0

    /// The one herdr session this coordinator is bound to, as presence
    /// last reported it -- `nil` only before the first `.appeared` and
    /// after the bound session `.disappeared`. Survives `resetToIdle()`:
    /// giving up on a server does not make it a different server, and a
    /// later `.replaced` for THIS identity is what says it finally is.
    private var boundIdentity: HerdrSocketIdentity?

    /// Every live herdr session presence has reported and not since
    /// withdrawn, keyed by socket path -- what a `.disappeared` for the
    /// bound session is answered from. At most one of these is ever
    /// connected to.
    private var liveIdentities: [String: HerdrSocketIdentity] = [:]

    /// Sessions whose LIFETIME RECONNECT BUDGET is spent -- see
    /// `giveUpOnBoundSession()`. Never connected to again, and never
    /// promoted to. A mark lives exactly as long as the fact that
    /// produced it: any presence transition naming an identity as
    /// newly live (`.appeared`, either side of a `.replaced`, or a
    /// `.disappeared` withdrawing it) clears that identity's mark, so
    /// this holds nothing presence is not currently asserting.
    private var abandonedIdentities: Set<HerdrSocketIdentity> = []

    /// Presence transitions are applied ONE AT A TIME, in arrival order:
    /// `herdrSessionPresenceDidChange(_:)` is synchronous while acting
    /// on a transition is not (a teardown closes a transport, a connect
    /// runs the whole CONNECT SEQUENCE), so a second transition arriving
    /// mid-flight queues here instead of racing the one already being
    /// applied. A queued transition therefore waits at most one whole
    /// connect-and-give-up cycle for the transition ahead of it: a
    /// connect sequence (bounded by the PER-STEP HANDSHAKE DEADLINE),
    /// plus, if it fails, the bounded reconnect that follows. Nothing
    /// there is unbounded, and while it runs `connectionGeneration`
    /// cannot change, so the cycle always resolves against the session
    /// it was started for.
    private var pendingPresenceChanges: [HerdrSessionPresenceChange] = []
    private var isApplyingPresenceChanges = false

    /// `true` from the moment a presence transition begins a real
    /// connection attempt (set SYNCHRONOUSLY, before that path's first
    /// `await`) through until this instance is fully idle again --
    /// covers the in-flight CONNECT SEQUENCE, the established
    /// connection, and every bounded-reconnect attempt. This is what
    /// keeps a second live session appearing while one is already being
    /// connected to from opening a second connection for it.
    private var isActive = false

    init(
        discovery: any HerdrSessionDiscoveryProtocol,
        transportFactory: any HerdrTransportFactory,
        mirror: HerdrAgentMirror,
        reconnectDelays: [Duration] = HerdrIntegrationCoordinator.defaultReconnectDelays,
        handshakeTimeout: Duration = HerdrIntegrationCoordinator.defaultHandshakeTimeout,
        maxLifetimeReconnectAttempts: Int = HerdrIntegrationCoordinator.defaultMaxLifetimeReconnectAttempts,
        replayBurstSettleWindow: Duration = HerdrIntegrationCoordinator.defaultReplayBurstSettleWindow,
        maxConsecutiveRebuildsWithoutProgress: Int = HerdrIntegrationCoordinator.defaultMaxConsecutiveRebuildsWithoutProgress,
        rebuildBackoffDelays: [Duration] = HerdrIntegrationCoordinator.defaultRebuildBackoffDelays,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.discovery = discovery
        self.transportFactory = transportFactory
        self.mirror = mirror
        self.reconnectDelays = reconnectDelays
        self.handshakeTimeout = handshakeTimeout
        self.maxLifetimeReconnectAttempts = maxLifetimeReconnectAttempts
        self.replayBurstSettleWindow = replayBurstSettleWindow
        self.maxConsecutiveRebuildsWithoutProgress = maxConsecutiveRebuildsWithoutProgress
        self.rebuildBackoffDelays = rebuildBackoffDelays
        self.sleep = sleep
    }

    // MARK: - Structure event observer

    /// Registers `observer` to be notified of herdr-side structural
    /// events -- see `HerdrStructureEventObserver`'s own doc comment.
    /// Stored WEAKLY: pass `nil` to clear; a deallocated observer simply
    /// stops being notified rather than being kept alive by this
    /// coordinator.
    func setStructureEventObserver(_ observer: any HerdrStructureEventObserver?) {
        structureEventObserver = observer
    }

    // MARK: - TEST ONLY instrumentation

    /// TEST ONLY: whether this instance is currently in REPLAY BURST
    /// RECONCILIATION's accumulating phase (see this file's header) --
    /// mirrors `BSDHerdrTransport.testOnlyConnectedFileDescriptor()`'s
    /// own precedent (HerdrTransport.swift) for exposing otherwise-
    /// private state ONLY for deterministic test synchronization.
    /// `HerdrIntegrationCoordinatorTests` polls this to know exactly
    /// when it is safe to simulate a steady-state event without it
    /// being silently accumulated instead.
    internal var testOnlyIsAccumulatingReplayBurst: Bool { isAccumulatingReplayBurst }

    /// TEST ONLY: `connectionGeneration` -- same precedent as
    /// `testOnlyIsAccumulatingReplayBurst` above. A test answering a
    /// connect sequence by hand polls this to know the CONNECTION
    /// ITSELF has been adopted (rather than only that its last request
    /// was answered), the point at which injecting an event onto it is
    /// meaningful.
    internal var testOnlyConnectionGeneration: Int { connectionGeneration }

    // MARK: - Connecting (CONNECT SEQUENCE)

    /// Begins a connection to `identity` unless one is already in
    /// flight or established. `isActive` is claimed SYNCHRONOUSLY,
    /// before the first `await`, so two transitions can never both open
    /// a connection for the same session.
    ///
    /// A failed attempt is DISCONNECT HANDLING, exactly as an
    /// established connection's stream ending is: presence says a
    /// session is live behind that path, so one attempt failing (a
    /// handshake that timed out under launch load, a subscribe the
    /// server rejected) says nothing about the session being gone. It
    /// therefore gets the same bounded reconnect, gated on the same
    /// `discovery.isAlive(socketPath:)` probe and bounded by the same
    /// per-identity budget. Nothing else would ever retry it: presence
    /// reports a live session ONCE, so a coordinator that gave up here
    /// would stay blind to that session for the rest of the process.
    ///
    /// `handleDisconnect` also unwinds what a half-finished attempt left
    /// behind: `attemptConnect`'s own snapshot step may have succeeded
    /// (upserting rows into the mirror, and populating `knownPaneIDs`/
    /// `recognizedPaneIDs`) before its OWN subsequent subscribe step
    /// failed.
    private func connect(to identity: HerdrSocketIdentity) async {
        guard !isActive else { return }
        isActive = true
        let generation = connectionGeneration
        if await attemptConnect(socketPath: identity.socketPath) { return }
        await handleDisconnect(socketPath: identity.socketPath, generation: generation)
    }

    /// Runs the CONNECT SEQUENCE described in this file's header: a
    /// one-shot `session.snapshot`, applied to the mirror and used to
    /// (re)populate `knownPaneIDs`, THEN a fresh `events.subscribe`
    /// connection carrying the six structure events plus one
    /// `.agentStatusChanged(paneID:)` per pane the snapshot just
    /// revealed. Each of the two steps is independently bounded by
    /// `runWithDeadline(transport:operation:)`. Returns `true` once
    /// `currentEventStreamTransport` is live and the event-consuming task
    /// (`consumeEvents`) has been started, `false` if either step fails
    /// or times out (nothing left half-set in that case -- the caller
    /// decides what "this attempt failed" means).
    private func attemptConnect(socketPath: String) async -> Bool {
        // A presence transition landing while this attempt is suspended
        // has already re-aimed the coordinator -- see this file's header
        // "SINGLE OWNER, NOT A RACE". Nothing else can bump
        // `connectionGeneration` between here and this attempt's own
        // bump below: every OTHER caller is serialized behind
        // `isRebuildOrReconnectInFlight` or behind the presence queue.
        let startedGeneration = connectionGeneration

        let snapshotTransport = await transportFactory.makeTransport()
        guard let snapshotResult: HerdrSnapshotRPCResult = await runWithDeadline(transport: snapshotTransport, operation: {
            let request = HerdrOneShotRequest(transport: snapshotTransport)
            return try await request.send(method: "session.snapshot", socketPath: socketPath)
        }) else {
            return false
        }
        let snapshot = snapshotResult.snapshot
        // Superseded while the snapshot was in flight: this is a
        // snapshot of a server that is not the one behind that path any
        // more, and everything below it feeds state the connection which
        // replaced this attempt now owns.
        guard startedGeneration == connectionGeneration else { return false }

        mirror.applySnapshot(snapshot, socketPath: socketPath)
        // CONNECT SEQUENCE step 3: REPLACES `knownPaneIDs`, never merges
        // -- see this file's header. Seeded from `panes[]`, NOT
        // `agents[]` -- see this file's header, REPLAY BURST
        // RECONCILIATION.
        let previousKnownPaneIDs = knownPaneIDs
        let freshPaneIDs = Set(snapshot.panes.map(\.paneID))
        knownPaneIDs = freshPaneIDs
        // UNION semantics -- see this file's header, REPLAY BURST
        // RECONCILIATION.
        recognizedPaneIDs.formUnion(freshPaneIDs)
        // CONSECUTIVE-REBUILD CAP: a pane id this fresh snapshot reveals
        // that the PRECEDING `knownPaneIDs` did not -- mechanical,
        // post-hoc "this attempt found genuine progress" (see this
        // file's header). Applies uniformly regardless of what caused
        // this `attemptConnect` call (first connect, ordinary reconnect,
        // or a rebuild); harmless (no-op reset of an already-zero
        // counter) for the first two.
        if !freshPaneIDs.subtracting(previousKnownPaneIDs).isEmpty {
            consecutiveRebuildsWithoutProgress = 0
        }

        let subscribeTransport = await transportFactory.makeTransport()
        let subscriptions = Self.structureEventSubscriptionTypes.map(HerdrSubscription.typeOnly)
            + knownPaneIDs.sorted().map { HerdrSubscription.agentStatusChanged(paneID: $0) }
        guard let stream = await runWithDeadline(transport: subscribeTransport, operation: {
            let eventStream = HerdrEventStream(transport: subscribeTransport)
            return try await eventStream.subscribe(subscriptions, socketPath: socketPath)
        }) else {
            return false
        }
        // Superseded while this attempt was in flight: adopting it now
        // would orphan the connection that replaced it, leaving two live
        // event streams feeding the mirror.
        guard startedGeneration == connectionGeneration else {
            await subscribeTransport.close()
            return false
        }

        currentEventStreamTransport = subscribeTransport
        // REPLAY BURST RECONCILIATION -- see this file's header. Reset
        // for every fresh subscribe; `connectionGeneration` bumped
        // regardless of caller so a stale settle task from a PRIOR
        // connection (see this file's header "SINGLE OWNER, NOT A RACE")
        // can recognize it has been superseded.
        isAccumulatingReplayBurst = true
        pendingBurstPaneIDs = []
        connectionGeneration += 1
        let generation = connectionGeneration
        burstSettleTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.replayBurstSettleWindow)
            guard !Task.isCancelled else { return }
            await self.settleReplayBurst(socketPath: socketPath, generation: generation)
        }
        // Deliberately NOT retained anywhere: `consumeEvents` IS this
        // task's own body, already running once this line executes, and
        // it self-terminates (`return`s) on every exit path -- see this
        // file's header "ONGOING EVENT HANDLING". `Task.init` is
        // `@discardableResult`, so nothing here needs a stored handle to
        // cancel or await later.
        Task { [weak self] in
            await self?.consumeEvents(stream, socketPath: socketPath, generation: generation)
        }
        return true
    }

    /// Races ONE async `operation` -- which internally owns exactly one
    /// `transport`, created by the caller just before this is invoked --
    /// against `handshakeTimeout`; see this file's header for why
    /// `withTaskGroup` cannot be used here. `nil` on either a thrown
    /// error or expiry -- callers do not need to distinguish the two.
    ///
    /// On timeout, closes `transport` DIRECTLY -- see this file's header
    /// "HANDSHAKE DEADLINE". Gated on `resume(with:)` actually WINNING
    /// the race: if the OPERATION arm already won (e.g. it completed a
    /// hair before the deadline), closing `transport` here would tear
    /// down a connection `attemptConnect` just decided to keep.
    private func runWithDeadline<T: Sendable>(
        transport: any HerdrTransport, operation: @escaping @Sendable () async throws -> T
    ) async -> T? {
        let bridge = DeadlineRaceBridge<T>()

        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let operationTask = Task {
                do {
                    let result = try await operation()
                    bridge.resume(with: result)
                } catch {
                    bridge.resume(with: nil)
                }
            }
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(self.handshakeTimeout)
                guard !Task.isCancelled else { return }
                if bridge.resume(with: nil) {
                    // Only reached when the OPERATION arm had not already
                    // won -- see this method's own doc comment above.
                    await transport.close()
                }
            }
            bridge.register(continuation: continuation, operationTask: operationTask, timeoutTask: timeoutTask)
        }
    }

    /// Thread-safe, exactly-once bridge between `runWithDeadline(transport:
    /// operation:)`'s two racing arms -- mirrors
    /// `SessionDaemonBoundedRaceBridge` (SessionDaemonClient.swift),
    /// generalized over the raced operation's result type `T` so ONE
    /// bridge type serves both the snapshot step and the subscribe step.
    /// The first arm to call `resume(with:)` wins; cancelling both tasks
    /// afterward is a harmless no-op for whichever one already finished.
    /// `@unchecked Sendable` is sound because every mutable stored
    /// property below is read/written ONLY while holding `lock`.
    private final class DeadlineRaceBridge<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var operationTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var continuation: CheckedContinuation<T?, Never>?

        func register(
            continuation: CheckedContinuation<T?, Never>,
            operationTask: Task<Void, Never>,
            timeoutTask: Task<Void, Never>
        ) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
        }

        @discardableResult
        func resume(with result: T?) -> Bool {
            lock.lock()
            guard !resumed, let continuation else { lock.unlock(); return false }
            resumed = true
            self.continuation = nil
            let oTask = operationTask
            let tTask = timeoutTask
            operationTask = nil
            timeoutTask = nil
            lock.unlock()
            continuation.resume(returning: result)
            oTask?.cancel()
            tTask?.cancel()
            return true
        }
    }

    // MARK: - Ongoing event handling

    /// Consumes `stream` for as long as the connection lives -- every
    /// event is forwarded to `mirror.apply(event:socketPath:)`, then
    /// separately inspected for a REBUILD TRIGGER (see this file's
    /// header) -- during the accumulating phase, `pane.created` is
    /// instead added to `pendingBurstPaneIDs` (REPLAY BURST
    /// RECONCILIATION). The FIRST event this call ever reads also earns
    /// back the LIFETIME RECONNECT BUDGET -- see this file's header
    /// "LIFETIME RECONNECT BUDGET". The stream ending -- normally (a
    /// clean EOF) or by throwing (a transport failure) -- is DISCONNECT
    /// HANDLING, shared with a failed reconnect attempt via
    /// `handleDisconnect(socketPath:generation:)`; `generation` is what lets that
    /// tail recognize a stream ending as a DIRECT CONSEQUENCE of an
    /// external `triggerRebuild` call (the burst-settle task's own
    /// reconciliation) rather than a genuine disconnect -- see this
    /// file's header "SINGLE OWNER, NOT A RACE".
    private func consumeEvents(
        _ stream: AsyncThrowingStream<HerdrEvent, Error>, socketPath: String, generation: Int
    ) async {
        var hasEarnedHealthyReset = false
        do {
            for try await event in stream {
                if !hasEarnedHealthyReset {
                    hasEarnedHealthyReset = true
                    // HEALTHY: this connection has delivered at
                    // least one event after its own subscribe ack
                    // completed -- see this file's header for the known,
                    // accepted limitation this bar has (the subscribe-time
                    // replay burst counts).
                    totalReconnectAttempts = 0
                }
                mirror.apply(event: event, socketPath: socketPath)

                switch event {
                case .paneCreated(let pane) where isAccumulatingReplayBurst:
                    // REPLAY BURST RECONCILIATION -- see this file's
                    // header: accumulated, not immediately treated as a
                    // rebuild trigger; `burstSettleTask` (spawned
                    // alongside this task in `attemptConnect`) evaluates
                    // the accumulated set exactly once.
                    pendingBurstPaneIDs.insert(pane.paneID)
                case .paneCreated(let pane) where !recognizedPaneIDs.contains(pane.paneID):
                    // Steady-state REBUILD TRIGGER -- a genuinely NEW
                    // pane. No manual `knownPaneIDs`/`recognizedPaneIDs`
                    // update needed here: `attemptConnect`'s own fresh
                    // snapshot (inside `triggerRebuild`, below) already
                    // updates both.
                    if await triggerRebuild(socketPath: socketPath, generation: generation) { return }
                case .paneClosed(let paneID):
                    // Forwarded to the observer BEFORE the pre-existing
                    // unconditional rebuild below -- a successful rebuild
                    // `return`s this Task, so forwarding AFTER it would
                    // silently skip the call on that path.
                    structureEventObserver?.herdrPaneClosed(paneID: paneID, socketPath: socketPath)
                    // ALWAYS a rebuild trigger, unconditionally, at ANY
                    // time (accumulating or steady state) -- neither
                    // pane_closed nor pane_exited is ever replayed at
                    // subscribe time, so there is no storm risk to guard
                    // against here.
                    if await triggerRebuild(socketPath: socketPath, generation: generation) { return }
                case .paneExited:
                    // Deliberately NOT forwarded to the observer: the
                    // herdr pane itself still exists after its own child
                    // process exits (only what was running inside it
                    // died) -- closing the Calyx bridge surface for a
                    // pane that is still there would be wrong. The
                    // pre-existing unconditional rebuild is unaffected.
                    if await triggerRebuild(socketPath: socketPath, generation: generation) { return }
                case .workspaceClosed(let workspaceID):
                    // Unconditional, no rebuild -- see this file's header
                    // "STRUCTURE EVENT OBSERVER".
                    structureEventObserver?.herdrWorkspaceClosed(workspaceID: workspaceID, socketPath: socketPath)
                case .unknown(eventType: "layout_updated") where !isAccumulatingReplayBurst:
                    // Steady state only -- a layout_updated event
                    // replayed WHILE still accumulating a fresh
                    // subscribe's own burst is suppressed here (falls to
                    // `default` below): forwarding every replay on every
                    // (re)subscribe would trigger a re-export storm. See
                    // this file's header "REPLAY BURST RECONCILIATION".
                    structureEventObserver?.herdrLayoutUpdated(socketPath: socketPath)
                default:
                    break
                }
            }
        } catch {
            // Falls through to the shared handling below -- a transport
            // failure is handled identically to a clean EOF (the `for
            // try await` loop above simply ending without throwing) --
            // see this file's header "DISCONNECT HANDLING".
        }

        // SINGLE OWNER, NOT A RACE (see this file's header): this stream
        // ending might be a genuine disconnect, OR the direct
        // consequence of `triggerRebuild` (called from the burst-settle
        // task, for this SAME generation) having already closed this
        // transport while establishing a NEWER connection. Claiming the
        // mutex synchronously, before anything else, is what tells the
        // two apart -- a mismatched generation OR an already-claimed
        // mutex both mean "someone else is already resolving this
        // connection's fate," so back off silently rather than handling
        // it a second time.
        guard generation == connectionGeneration, let claim = claimRebuildOrReconnect() else { return }
        defer { releaseRebuildOrReconnect(claim) }
        await handleDisconnect(socketPath: socketPath, generation: generation)
    }

    // MARK: - Rebuild

    /// Claims the single-owner right to establish or tear down a
    /// connection, `nil` when someone else already holds it -- see this
    /// file's header "SINGLE OWNER, NOT A RACE". Synchronous, with no
    /// `await` between the check and the claim, so two callers can never
    /// both see it free.
    private func claimRebuildOrReconnect() -> Int? {
        guard currentRebuildOrReconnectClaim == nil else { return nil }
        lastRebuildOrReconnectClaimID += 1
        currentRebuildOrReconnectClaim = lastRebuildOrReconnectClaimID
        return lastRebuildOrReconnectClaimID
    }

    /// Releases `claim` if it is still the current one. A claim
    /// `discardCurrentConnection` already broke is NOT the current one,
    /// so its holder waking up later releases nothing.
    private func releaseRebuildOrReconnect(_ claim: Int) {
        guard currentRebuildOrReconnectClaim == claim else { return }
        currentRebuildOrReconnectClaim = nil
    }

    /// Shared entry point for every REBUILD TRIGGER (see this file's
    /// header) -- `consumeEvents`' own steady-state triggers AND
    /// `settleReplayBurst`'s burst-driven reconciliation both call this.
    /// Returns `true` if this call actually performed a rebuild (closed
    /// the current connection and attempted a fresh one); callers inside
    /// `consumeEvents` must `return` (ending their own Task body) ONLY
    /// when this returns `true` -- `false` means `generation` was
    /// already superseded when this trigger arrived, the
    /// CONSECUTIVE-REBUILD CAP was already exhausted, a rebuild/reconnect
    /// sequence was already in flight (SINGLE OWNER, NOT A RACE), or
    /// `generation` was superseded while backing off -- in EVERY case,
    /// deliberately
    /// leaving whatever connection is current completely untouched, per
    /// this file's header.
    @discardableResult
    private func triggerRebuild(socketPath: String, generation: Int) async -> Bool {
        // Checked in the SAME synchronous frame as the claim, BEFORE any
        // of the state below is touched: a trigger from a connection
        // already superseded would otherwise clear the REPLAY BURST
        // accumulating flag of the connection that replaced it, and
        // spend that connection's CONSECUTIVE-REBUILD CAP.
        guard generation == connectionGeneration,
              consecutiveRebuildsWithoutProgress < maxConsecutiveRebuildsWithoutProgress,
              let claim = claimRebuildOrReconnect() else {
            return false
        }
        defer { releaseRebuildOrReconnect(claim) }

        isAccumulatingReplayBurst = false // interrupt any in-progress accumulation

        // Backoff BEFORE teardown -- see this file's header
        // "CONSECUTIVE-REBUILD CAP": the current connection stays live
        // and keeps consuming events for the full backoff duration, not
        // just until a new one happens to be ready.
        let delayIndex = consecutiveRebuildsWithoutProgress
        consecutiveRebuildsWithoutProgress += 1 // optimistic; attemptConnect resets to 0 on genuine progress
        if let lastIndex = rebuildBackoffDelays.indices.last {
            await sleep(rebuildBackoffDelays[min(delayIndex, lastIndex)])
        }
        // Checked again: the guard above ruled out a trigger that was
        // ALREADY superseded when it arrived, this one a presence
        // transition landing DURING the backoff. Rebuilding a superseded
        // connection now would open a second one behind it.
        guard generation == connectionGeneration else { return false }

        await closeAndClearEventStreamTransport()
        if await attemptConnect(socketPath: socketPath) {
            return true
        }
        // A failure a presence transition caused is not this rebuild's
        // to resolve: `handleDisconnect` would clear the mirror rows the
        // connection that superseded this one has already populated.
        guard generation == connectionGeneration else { return false }
        await handleDisconnect(socketPath: socketPath, generation: generation)
        return true
    }

    /// REPLAY BURST RECONCILIATION (see this file's header) -- runs
    /// once, `replayBurstSettleWindow` after a successful subscribe,
    /// unless superseded first (`Task.isCancelled`, checked both here
    /// and by the caller right after `sleep` returns). `generation` is
    /// the value `connectionGeneration` held when this connection's own
    /// `burstSettleTask` was spawned; a mismatch -- or
    /// `isAccumulatingReplayBurst` already `false` -- means this
    /// connection has already been superseded by a DIFFERENT trigger
    /// (e.g. an unconditional paneClosed/paneExited rebuild firing
    /// before this window even elapsed) -- see this file's header
    /// "SINGLE OWNER, NOT A RACE".
    private func settleReplayBurst(socketPath: String, generation: Int) async {
        guard !Task.isCancelled, generation == connectionGeneration, isAccumulatingReplayBurst else { return }
        isAccumulatingReplayBurst = false

        let newlyRevealed = pendingBurstPaneIDs.subtracting(recognizedPaneIDs)
        guard !newlyRevealed.isEmpty else {
            // A clean settle -- the burst told us nothing we did not
            // already recognize -- is itself proof this cycle is not
            // pathological; see this file's header "CONSECUTIVE-REBUILD
            // CAP".
            consecutiveRebuildsWithoutProgress = 0
            return
        }

        recognizedPaneIDs.formUnion(newlyRevealed)
        await triggerRebuild(socketPath: socketPath, generation: generation)
    }

    // MARK: - Disconnect handling

    /// Shared tail for "the live connection is gone": a clean EOF, a
    /// transport failure, or a rebuild's own reconnect attempt failing.
    /// Notifies the mirror exactly once, closes and drops the
    /// event-stream transport (see this file's header "EXPLICIT
    /// TRANSPORT TEARDOWN" -- a harmless no-op here if the transport
    /// already ended on its own), then attempts the bounded reconnect --
    /// see this file's header "DISCONNECT HANDLING".
    private func handleDisconnect(socketPath: String, generation: Int) async {
        mirror.connectionLost()
        await closeAndClearEventStreamTransport()
        await reconnectLoop(socketPath: socketPath, generation: generation)
    }

    /// Closes `currentEventStreamTransport`, if any, and clears the
    /// reference -- shared by `triggerRebuild(socketPath:generation:)` and
    /// `handleDisconnect(socketPath:generation:)`; see this file's header "EXPLICIT
    /// TRANSPORT TEARDOWN". `HerdrTransport.close()` is documented
    /// idempotent, so this is safe to call even when the transport
    /// already ended (EOF/failure) on its own. Also cancels and clears
    /// `burstSettleTask` -- a harmless no-op once it has already fired
    /// or was never accumulating in the first place -- see this file's
    /// header "SINGLE OWNER, NOT A RACE".
    private func closeAndClearEventStreamTransport() async {
        if let transport = currentEventStreamTransport {
            await transport.close()
        }
        currentEventStreamTransport = nil
        burstSettleTask?.cancel()
        burstSettleTask = nil
    }

    /// Bounded reconnect: each attempt is gated by
    /// `discovery.isAlive(socketPath:)`, checked before AND after its
    /// own backoff delay -- the delay itself is exactly the window in
    /// which the socket could disappear -- AND by the LIFETIME RECONNECT
    /// BUDGET (`totalReconnectAttempts` vs
    /// `maxLifetimeReconnectAttempts`) -- see this file's header for
    /// both. Stops (no further retry, no state left "active") the
    /// moment the socket no longer probes alive, once `reconnectDelays`
    /// is exhausted, or once the lifetime budget is exhausted --
    /// whichever comes first.
    ///
    /// A presence transition landing during a backoff delay has already
    /// torn this connection down and re-aimed the coordinator (see this
    /// file's header LIFECYCLE), which `generation` no longer matching
    /// `connectionGeneration` is what reveals. That abandons this loop
    /// silently -- never via `resetToIdle()`, which would flip
    /// `isActive` out from under the connection presence has since put
    /// in this one's place.
    private func reconnectLoop(socketPath: String, generation: Int) async {
        for delay in reconnectDelays {
            guard generation == connectionGeneration else { return }
            guard totalReconnectAttempts < maxLifetimeReconnectAttempts else {
                await giveUpOnBoundSession()
                return
            }
            guard discovery.isAlive(socketPath: socketPath) else {
                await giveUpOnBoundSession()
                return
            }
            await sleep(delay)
            guard generation == connectionGeneration else { return }
            guard discovery.isAlive(socketPath: socketPath) else {
                await giveUpOnBoundSession()
                return
            }
            totalReconnectAttempts += 1
            if await attemptConnect(socketPath: socketPath) {
                return
            }
        }
        guard generation == connectionGeneration else { return }
        await giveUpOnBoundSession()
    }

    /// The terminal state of the bound session's LIFETIME RECONNECT
    /// BUDGET (see this file's header): nothing more is attempted for
    /// that identity until presence reports the path carrying a
    /// DIFFERENT session. Marking it is what stops two failing sessions
    /// from promoting each other back and forth forever, each `bind`
    /// handing the other a fresh budget.
    ///
    /// Giving up on one session says nothing about any OTHER session
    /// presence has reported live, so one is taken up here if there is
    /// one -- the same promotion `.disappeared` performs, for the same
    /// reason. The recursion this can form (promote, fail, give up,
    /// promote again) is bounded by the number of live sessions: each is
    /// marked here before the next is tried.
    private func giveUpOnBoundSession() async {
        if let bound = boundIdentity {
            abandonedIdentities.insert(bound)
        }
        resetToIdle()
        await promoteAnotherLiveSession()
    }

    /// Binds and connects to a live session that is neither the one
    /// currently bound nor one already given up on. A no-op when there
    /// is none, or when a connection already exists.
    private func promoteAnotherLiveSession() async {
        guard !isActive else { return }
        let candidate = liveIdentities
            .sorted { $0.key < $1.key }
            .first { $0.value != boundIdentity && !abandonedIdentities.contains($0.value) }?
            .value
        guard let candidate else { return }
        bind(to: candidate)
        await connect(to: candidate)
    }

    /// Full give-up: resets every piece of per-connection state so a
    /// LATER connection behaves exactly like this instance's very first
    /// one -- EXCEPT `boundIdentity` and its `totalReconnectAttempts`
    /// (the LIFETIME RECONNECT BUDGET), deliberately left untouched:
    /// see this file's header for why giving up on a server leaves that
    /// server's own spent budget spent.
    /// `knownPaneIDs`/`recognizedPaneIDs` in particular must not survive
    /// a full give-up -- a later-discovered herdr session may reuse
    /// pane ids the old one had, and resubscribing (or silently treating
    /// a genuinely new pane as already-recognized) against it with stale
    /// per-pane ids is unmeasured server behavior. `burstSettleTask` is
    /// already cancelled/cleared by `closeAndClearEventStreamTransport`
    /// on every path that reaches `resetToIdle`; cleared again here
    /// defensively, matching that method's own idempotent contract.
    ///
    /// `mirror.connectionLost()` is called unconditionally too, for the
    /// identical reason: `attemptConnect`'s snapshot step upserts rows
    /// into the mirror BEFORE its own, independently fallible subscribe
    /// step runs -- a give-up reached via `connect(to:)`'s own
    /// attemptConnect-failure branch, or via the last attempt inside
    /// `reconnectLoop` before it gives up here, can therefore leave rows
    /// in the mirror with no live connection behind them. Safe to call
    /// even when this attempt never got that far (e.g. a snapshot step
    /// that failed outright, which never touched the mirror at all, or a
    /// `handleDisconnect` that already called it once):
    /// `HerdrAgentMirror.connectionLost()` iterates `ownedIDsBySocketPath`
    /// and clears it, an inherent no-op when nothing is owned.
    private func resetToIdle() {
        isActive = false
        mirror.connectionLost()
        knownPaneIDs.removeAll()
        recognizedPaneIDs.removeAll()
        pendingBurstPaneIDs.removeAll()
        isAccumulatingReplayBurst = false
        burstSettleTask?.cancel()
        burstSettleTask = nil
        consecutiveRebuildsWithoutProgress = 0
    }
}

// MARK: - HerdrSessionPresenceObserver

/// A herdr connection is a function of herdr's own presence -- see
/// HerdrSessionPresence.swift's own header. This is the ONLY thing that
/// starts, stops, or re-aims a connection.
///
///   - `.appeared` while there is no connection: bind to that identity
///     and run the CONNECT SEQUENCE against its socket path. While
///     there IS one (`isActive`), a second live session is recorded and
///     nothing else: this coordinator mirrors exactly one at a time.
///     The condition is `isActive`, NOT "nothing is bound": a session
///     this coordinator gave up on stays bound, and a DIFFERENT server
///     appearing afterwards has nothing to do with that verdict -- its
///     agents would otherwise never be shown at all. Nor does that
///     re-arm the server the budget was spent on: presence reports the
///     same identity once, so the only way a session at a path already
///     bound comes back is `.replaced`, which by definition carries a
///     different server.
///   - `.replaced` for the BOUND identity: the server behind that path
///     is a different one now, so the current connection is worthless.
///     Tear it down, bind to the new identity (which discards the old
///     one's LIFETIME RECONNECT BUDGET), and connect afresh. For any
///     other identity, replace the record -- and, since a replacement
///     is a server that has never been given up on, take it up if this
///     coordinator has no connection at all. Not doing so would leave a
///     live session unmirrored for the rest of the process: the
///     identity presence would report next for that path is another
///     `.replaced`, which would be dropped for the same reason.
///   - `.disappeared` for the BOUND identity: tear the connection down
///     and make NO attempt of this coordinator's own to get it back --
///     presence says the session is gone, and a socket that still
///     happens to answer a probe does not outrank that. Another
///     recorded live session, if there is one, is bound and connected to
///     instead. For any other identity, drop the record and nothing
///     else.
extension HerdrIntegrationCoordinator: HerdrSessionPresenceObserver {

    func herdrSessionPresenceDidChange(_ change: HerdrSessionPresenceChange) {
        pendingPresenceChanges.append(change)
        guard !isApplyingPresenceChanges else { return }
        isApplyingPresenceChanges = true
        Task { [weak self] in
            await self?.applyPendingPresenceChanges()
        }
    }

    /// Drains `pendingPresenceChanges` in arrival order -- see that
    /// property's own doc comment for why transitions are applied one at
    /// a time rather than concurrently.
    private func applyPendingPresenceChanges() async {
        defer { isApplyingPresenceChanges = false }
        while !pendingPresenceChanges.isEmpty {
            await apply(pendingPresenceChanges.removeFirst())
        }
    }

    private func apply(_ change: HerdrSessionPresenceChange) async {
        switch change {
        case .appeared(let identity):
            liveIdentities[identity.socketPath] = identity
            abandonedIdentities.remove(identity)
            guard !isActive else { return }
            bind(to: identity)
            await connect(to: identity)

        case .replaced(let previous, let current):
            liveIdentities[current.socketPath] = current
            abandonedIdentities.remove(previous)
            abandonedIdentities.remove(current)
            guard boundIdentity == previous else {
                // A different server took a path this coordinator is not
                // bound to. Presence is reporting a live session, and
                // clearing the abandoned mark above is what makes it
                // connectable again -- so if there is no connection, take
                // it up exactly as `.appeared` would. Harmless while
                // there is one: promotion refuses to start a second.
                await promoteAnotherLiveSession()
                return
            }
            await discardCurrentConnection()
            bind(to: current)
            await connect(to: current)

        case .disappeared(let identity):
            liveIdentities[identity.socketPath] = nil
            abandonedIdentities.remove(identity)
            guard boundIdentity == identity else { return }
            await discardCurrentConnection()
            boundIdentity = nil
            await promoteAnotherLiveSession()
        }
    }

    /// Binds this coordinator to `identity`, discarding everything that
    /// was true of the previously bound session -- its LIFETIME
    /// RECONNECT BUDGET above all (see this file's header: the budget
    /// belongs to a session, not to this process). Binding to the
    /// identity ALREADY bound changes nothing, budget included: it is
    /// the same server, whatever led back here.
    private func bind(to identity: HerdrSocketIdentity) {
        guard boundIdentity != identity else { return }
        boundIdentity = identity
        totalReconnectAttempts = 0
    }

    /// Tears the current connection down for a session presence says is
    /// no longer the one behind that path. `connectionGeneration` is
    /// bumped BEFORE the transport is closed, never after: closing it
    /// ends the event stream, and the `consumeEvents` tail that unblocks
    /// runs on this same actor -- it would otherwise see its own
    /// generation still current across the `close()` suspension and
    /// treat a deliberate teardown as a disconnect to reconnect from.
    private func discardCurrentConnection() async {
        connectionGeneration += 1
        // Broken in the SAME synchronous frame as the generation bump,
        // before the suspension below: a rebuild or reconnect sleeping
        // through a backoff holds this claim, and the connection about
        // to replace theirs must be free to rebuild.
        currentRebuildOrReconnectClaim = nil
        await closeAndClearEventStreamTransport()
        resetToIdle()
    }
}
