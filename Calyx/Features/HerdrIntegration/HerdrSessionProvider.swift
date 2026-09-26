// HerdrSessionProvider.swift
// Calyx
//
// Abstraction over listing herdr sessions and focusing/closing a herdr
// workspace,
// so `SessionBrowserModel` can be tested with a fake instead of touching
// real PATH/socket state -- mirrors `SessionDaemonClientProtocol`'s own
// injectable-dependency shape. The production conformer below,
// `HerdrCLISessionProvider`, composes `HerdrSessionDiscovery`'s socket
// enumeration + non-blocking connect probe (that type's own file, called
// here through its frozen protocol, never reimplemented) for identity
// and liveness, then one `session.snapshot` request per alive socket
// (`HerdrConnection.swift`'s one-shot request path) for workspace/pane/
// agent counts AND the per-workspace rows those counts are derived from
// (`HerdrSessionInfo.workspaces`). herdr also exposes a JSON
// session-list subcommand (`herdr session list --json`, verified against
// real herdr 0.8.0); this provider still never shells out to it.
// `closeWorkspace(workspaceID:socketPath:)` sends `workspace.close` for
// the session browser's Kill action on a single workspace row;
// `focusWorkspace(workspaceID:socketPath:)` sends `workspace.focus` so a
// herdr TUI client switches to that workspace before the session
// browser's "Show" focuses the pane it runs in.
// `listSessions()` also attaches the herdr TUI clients found running in
// Calyx panes (`HerdrTUIClientScanner.swift`) to the session whose socket
// they are attached to (`HerdrSessionInfo.tuiClients`).

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "HerdrCLISessionProvider")

protocol HerdrSessionProviderProtocol: Sendable {
    func listSessions() async -> [HerdrSessionInfo]

    /// Closes one herdr workspace via `workspace.close` -- the session
    /// browser's Kill action for a herdr workspace row
    /// (`SessionBrowserModel.killHerdrWorkspace(_:)`). Fire-and-forget,
    /// unlike `SessionDaemonClientProtocol.kill(id:)` (which reports a
    /// `SessionKillOutcome`): nothing to return, any failure swallowed -- see
    /// `HerdrCLISessionProvider.closeWorkspace(workspaceID:socketPath:)`'s
    /// own doc comment for why.
    func closeWorkspace(workspaceID: String, socketPath: String) async

    /// Makes one herdr workspace the one herdr's TUI clients display, via
    /// `workspace.focus` -- sent by `SessionBrowserModel
    /// .attachHerdrWorkspace(_:)` for a `.tuiPane` row before the pane
    /// running that TUI client is focused, so the pane reveals the row's
    /// own workspace rather than whichever one the TUI was already
    /// showing. Same fire-and-forget shape as `closeWorkspace(workspaceID:
    /// socketPath:)` above -- see `HerdrCLISessionProvider.focusWorkspace(
    /// workspaceID:socketPath:)`'s own doc comment.
    func focusWorkspace(workspaceID: String, socketPath: String) async
}

/// One herdr session as `SessionBrowserModel` needs it. `id` is the
/// session's Unix domain socket path -- herdr assigns no separate
/// session ID of its own to key rows on, so the socket path itself IS
/// the identity (mirrors `SessionInfo.id` being the calyx-session ULID,
/// just a different kind of stable string). `name` is optional because
/// the `HERDR_SOCKET_PATH` env-override candidate carries none of its
/// own (see `HerdrSessionDiscovery`'s own doc comment).
///
/// `workspaceCount`/`paneCount`/`agentCount`/`workspaces` all come from
/// one `session.snapshot` request per socket
/// (`HerdrCLISessionProvider.fetchCounts(socketPath:)`) -- `agentCount`
/// aside, `workspaceCount`/`paneCount` are themselves DERIVED from
/// `workspaces` (its own count, and the sum of each entry's own
/// `paneCount`), so the aggregate and the list can never disagree. All
/// four are left at their empty/`nil` default together when that request
/// fails or never answers -- a socket `discovery.isAlive(socketPath:)`
/// already confirmed alive still produces a row in that case, just with
/// unknown counts and no workspace rows: a degraded row is always a
/// valid `HerdrSessionInfo`, never an error.
struct HerdrSessionInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String?
    let workspaceCount: Int?
    let paneCount: Int?
    let agentCount: Int?
    /// Per-workspace rows for the session browser's herdr section
    /// (`HerdrSessionRow.workspaces`, SessionBrowserModel.swift), in the
    /// order `session.snapshot` reports them -- never sorted or
    /// filtered. `[]` both when the snapshot fails (mirroring the `nil`
    /// counts above) and when it legitimately reports zero workspaces --
    /// either way the session browser renders zero workspace rows under
    /// this session's own server row.
    let workspaces: [HerdrWorkspaceInfo]
    /// herdr TUI clients (`HerdrTUIClientScanner`) attached to this
    /// session's own socket (`id`) and running inside a Calyx pane, in
    /// scan order. `[]` when none were found -- herdr's own API reports
    /// nothing about clients, so this is the only source of "this
    /// session is already displayed in a pane".
    let tuiClients: [HerdrTUIClient]

    init(
        id: String,
        name: String?,
        workspaceCount: Int?,
        paneCount: Int?,
        agentCount: Int?,
        workspaces: [HerdrWorkspaceInfo],
        tuiClients: [HerdrTUIClient] = []
    ) {
        self.id = id
        self.name = name
        self.workspaceCount = workspaceCount
        self.paneCount = paneCount
        self.agentCount = agentCount
        self.workspaces = workspaces
        self.tuiClients = tuiClients
    }
}

/// One socket's workspace/pane/agent counts and per-workspace rows,
/// derived from a single `session.snapshot` -- see
/// `HerdrCLISessionProvider.fetchCounts(socketPath:)`.
private struct HerdrSessionCounts: Equatable {
    let workspaceCount: Int
    let paneCount: Int
    let agentCount: Int
    let workspaces: [HerdrWorkspaceInfo]
}

/// Production `HerdrSessionProviderProtocol`.
///
/// `listSessions()` runs in two phases.
///
/// Phase 1: `discovery.discover()`'s candidates, kept only when
/// `discovery.isAlive(socketPath:)`, plus one `tuiClientScanner.scan()`
/// (a blocking process-table walk, run on the same background queue for
/// the same reason). Neither throws, so "a degraded row
/// beats an error" (`HerdrSessionInfo`'s own doc comment) holds
/// structurally: a config directory that doesn't exist yields `[]` from
/// `discover()`, and a stale/crashed socket file yields `false` from
/// `isAlive(socketPath:)`, each flowing straight through to an empty or
/// shorter candidate list -- never a thrown error to swallow. Both are
/// blocking calls, run on `DispatchQueue.global()` behind a
/// `withCheckedContinuation`, mirroring `SystemCommandRunner.locate(_:)`'s
/// identical shape, so the caller's Task never parks a Swift Concurrency
/// cooperative-pool thread inside `discover()`'s `FileManager` scan or
/// `isAlive(socketPath:)`'s blocking `connect()`/`poll()` (up to 50ms per
/// candidate). Once this phase is running on that background queue there
/// is no ambient `Task`, so `discover()`'s and `isAlive(socketPath:)`'s
/// own internal `Task.isCancelled` checks (see `HerdrSessionDiscovery.swift`)
/// are inert on this path -- a caller cancelled mid-sweep no longer stops
/// the sweep early, it just discards the result once it arrives. That is
/// acceptable here: candidate counts are realistically 0-3, and each
/// probe is hard-capped at `HerdrSessionDiscovery`'s own
/// `probeTimeoutMilliseconds` (50ms). The explicit `Task.isCancelled`
/// guards in `listSessions()` below (before ever dispatching to the
/// background queue, and again once phase 1 returns) keep the cheap part
/// of the contract -- an ALREADY cancelled caller does zero work --
/// without needing to reach into that inert internal check.
///
/// Phase 2: one `session.snapshot` request per candidate phase 1 kept
/// (`fetchCounts(socketPath:)`), sequentially. Unlike phase 1, this needs
/// no manual `DispatchQueue` hop -- `HerdrOneShotRequest`/
/// `BSDHerdrTransport` are already non-blocking Swift Concurrency
/// (`BSDHerdrTransport`'s own doc comment). Sequential, not concurrent:
/// simpler, and fine at these candidate counts -- even three stalled
/// sockets, each eating `fetchCounts(socketPath:)`'s own `oneShotRequestTimeout`
/// bound in full, still land under the 5s `daemonQueryBoundTimeoutSeconds`
/// that `SessionBrowserModel.boundedHerdrListSessions()` races this whole
/// call against. A candidate whose snapshot fails or times out still
/// becomes a row -- see `HerdrSessionInfo`'s own doc comment -- only its
/// counts stay `nil`.
///
/// Each resulting `HerdrSessionInfo` carries the scanned TUI clients
/// whose `socketPath` equals that candidate's own socket path
/// (`HerdrSessionInfo.tuiClients`).
///
/// `discovery`/`transportFactory`/`tuiClientScanner` are injectable
/// (production defaults: `HerdrSessionDiscovery()` /
/// `LiveHerdrTransportFactory()` / `HerdrTUIClientScanner()`), so tests
/// can drive both phases with fakes -- see `HerdrSessionProviderTests.swift`.
final class HerdrCLISessionProvider: HerdrSessionProviderProtocol, Sendable {
    private let discovery: any HerdrSessionDiscoveryProtocol
    private let transportFactory: any HerdrTransportFactory
    private let tuiClientScanner: any HerdrTUIClientScanning

    init(
        discovery: any HerdrSessionDiscoveryProtocol = HerdrSessionDiscovery(),
        transportFactory: any HerdrTransportFactory = LiveHerdrTransportFactory(),
        tuiClientScanner: any HerdrTUIClientScanning = HerdrTUIClientScanner()
    ) {
        self.discovery = discovery
        self.transportFactory = transportFactory
        self.tuiClientScanner = tuiClientScanner
    }

    func listSessions() async -> [HerdrSessionInfo] {
        guard !Task.isCancelled else { return [] }
        let discovery = self.discovery
        let tuiClientScanner = self.tuiClientScanner
        let (candidates, tuiClients) = await withCheckedContinuation {
            (continuation: CheckedContinuation<([HerdrSessionCandidate], [HerdrTUIClient]), Never>) in
            DispatchQueue.global().async {
                let alive = discovery.discover().filter { discovery.isAlive(socketPath: $0.socketPath) }
                let clients = tuiClientScanner.scan()
                continuation.resume(returning: (alive, clients))
            }
        }
        guard !Task.isCancelled else { return [] }

        var sessions: [HerdrSessionInfo] = []
        sessions.reserveCapacity(candidates.count)
        for candidate in candidates {
            let counts = await fetchCounts(socketPath: candidate.socketPath)
            sessions.append(
                HerdrSessionInfo(
                    id: candidate.socketPath,
                    name: candidate.name,
                    workspaceCount: counts?.workspaceCount,
                    paneCount: counts?.paneCount,
                    agentCount: counts?.agentCount,
                    workspaces: counts?.workspaces ?? [],
                    tuiClients: tuiClients.filter { $0.socketPath == candidate.socketPath }
                )
            )
        }
        return sessions
    }

    /// Sends `workspace.close` for `workspaceID` on `socketPath` -- see
    /// `HerdrSessionProviderProtocol.closeWorkspace(workspaceID:
    /// socketPath:)`'s own doc comment. Params are exactly
    /// `WorkspaceTarget`'s own schema shape (`herdr api schema --json`),
    /// shared with `workspace.get` via `HerdrWorkspaceTargetParams`
    /// (HerdrTabCoordinator.swift): `{"workspace_id":...}`. Bounded by the
    /// same `oneShotRequestTimeout`/`watchdog` pattern as
    /// `fetchCounts(socketPath:)` below, for the identical reason:
    /// `HerdrOneShotRequest.send` has no timeout of its own, and a server
    /// that accepts the connection and never answers must not hang this
    /// call, and therefore the caller's own unconditional refresh,
    /// forever. Any failure -- an RPC error, a transport EOF/failure, or
    /// `oneShotRequestTimeout` expiry -- is logged at `.error` and
    /// otherwise swallowed: there is no result
    /// to report beyond an `.error` log line (unlike `SessionDaemonClient.kill(id:)`, whose
    /// `SessionKillOutcome` the calyx-session Kill button surfaces).
    /// `SessionBrowserModel.killHerdrWorkspace(_:)` refreshes
    /// unconditionally right after calling this, succeeded or not.
    func closeWorkspace(workspaceID: String, socketPath: String) async {
        let transport = await transportFactory.makeTransport()
        let watchdog = Task {
            try? await Task.sleep(for: Self.oneShotRequestTimeout)
            guard !Task.isCancelled else { return }
            await transport.close()
        }
        defer { watchdog.cancel() }

        do {
            let request = HerdrOneShotRequest(transport: transport)
            let params = HerdrWorkspaceTargetParams(workspaceID: workspaceID)
            let _: HerdrWorkspaceCloseRPCResult = try await request.send(
                method: "workspace.close", params: params, socketPath: socketPath
            )
        } catch {
            // See this method's own doc comment: best-effort, the caller
            // refreshes regardless. Logged so a failed close is diagnosable.
            logger.error("workspace.close failed for workspace \(workspaceID, privacy: .public) on socket \(socketPath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends `workspace.focus` for `workspaceID` on `socketPath` -- see
    /// `HerdrSessionProviderProtocol.focusWorkspace(workspaceID:
    /// socketPath:)`'s own doc comment. Params are `WorkspaceTarget`'s
    /// schema shape (`herdr api schema --json`), the same
    /// `HerdrWorkspaceTargetParams` `closeWorkspace(workspaceID:
    /// socketPath:)` above sends, bounded by the same
    /// `oneShotRequestTimeout`/`watchdog` pattern for the same reason: a
    /// server that accepts the connection and never answers must not hang
    /// the session browser's "Show" forever. Any failure -- an RPC error,
    /// a transport EOF/failure, or `oneShotRequestTimeout` expiry -- is
    /// logged and swallowed, exactly like `closeWorkspace`: there is no result to
    /// report, and the caller focuses the TUI pane regardless.
    func focusWorkspace(workspaceID: String, socketPath: String) async {
        let transport = await transportFactory.makeTransport()
        let watchdog = Task {
            try? await Task.sleep(for: Self.oneShotRequestTimeout)
            guard !Task.isCancelled else { return }
            await transport.close()
        }
        defer { watchdog.cancel() }

        do {
            let request = HerdrOneShotRequest(transport: transport)
            let params = HerdrWorkspaceTargetParams(workspaceID: workspaceID)
            let _: HerdrWorkspaceFocusRPCResult = try await request.send(
                method: "workspace.focus", params: params, socketPath: socketPath
            )
        } catch {
            // See this method's own doc comment: best-effort, the caller
            // focuses the pane regardless. Logged so a failed focus is
            // diagnosable.
            logger.error("workspace.focus failed for workspace \(workspaceID, privacy: .public) on socket \(socketPath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// One socket's counts and per-workspace rows, or `nil` on any
    /// failure -- an RPC error or a transport EOF/failure, both via the
    /// `do`/`catch` below (the same shape `closeWorkspace(workspaceID:
    /// socketPath:)` above uses for its own one-shot request), or
    /// `oneShotRequestTimeout` expiry.
    ///
    /// `HerdrOneShotRequest.send` itself has no timeout (see
    /// HerdrConnection.swift): a server that accepts the connection and
    /// then never answers would hang this call forever without
    /// `watchdog`. Closing `transport` on expiry unblocks whichever read
    /// `send` is suspended in -- a clean `.eof`, landing in the same
    /// `catch` as any other failure -- exactly like
    /// `HerdrIntegrationCoordinator`'s own per-step handshake deadline
    /// (`runWithDeadline(transport:operation:)`). `close()` is idempotent
    /// and `send` already closes the transport on every exit path, so
    /// `watchdog` firing after `send` already finished (the common case
    /// -- cancelled by `defer` below before that can happen) is
    /// harmless.
    ///
    /// `workspaceCount`/`paneCount` are derived FROM `workspaces` (its
    /// own count, and the sum of each entry's own `paneCount`), never
    /// from `snapshot.panes` independently -- see `HerdrSessionInfo`'s
    /// own doc comment for why that keeps the aggregate and the list
    /// structurally consistent.
    private func fetchCounts(socketPath: String) async -> HerdrSessionCounts? {
        let transport = await transportFactory.makeTransport()
        let watchdog = Task {
            try? await Task.sleep(for: Self.oneShotRequestTimeout)
            guard !Task.isCancelled else { return }
            await transport.close()
        }
        defer { watchdog.cancel() }

        let snapshotResult: HerdrSnapshotRPCResult
        do {
            let request = HerdrOneShotRequest(transport: transport)
            snapshotResult = try await request.send(method: "session.snapshot", socketPath: socketPath)
        } catch {
            return nil
        }

        let workspaces = snapshotResult.snapshot.workspaces
        return HerdrSessionCounts(
            workspaceCount: workspaces.count,
            paneCount: workspaces.map(\.paneCount).reduce(0, +),
            agentCount: snapshotResult.snapshot.agents.count,
            workspaces: workspaces
        )
    }

    /// Per-socket bound for `fetchCounts(socketPath:)` and
    /// `closeWorkspace(workspaceID:socketPath:)` above -- see either
    /// method's own doc comment. 1s: a local Unix-socket request measures
    /// well under 100ms against a healthy server (comparable to
    /// `HerdrIntegrationCoordinator`'s own measured replay-burst timing),
    /// so this only ever matters against a genuinely stalled server, and
    /// stays well inside `fetchCounts`'s own sequential sweep budget
    /// described above.
    private static let oneShotRequestTimeout: Duration = .seconds(1)
}

/// `workspace.close`'s own result -- decoded only far enough to confirm
/// "result" is present and is a JSON object (a synthesized `init(from:)`
/// for a zero-property struct still opens a KEYED container, which fails
/// to decode a non-object value), mirroring `HerdrConnection.swift`'s own
/// `HerdrSubscribeAckResult`. The schema has no method-to-result-variant
/// mapping to pin a specific "type" discriminator against, and
/// `closeWorkspace(workspaceID:socketPath:)` never reads this value --
/// only that the request did not throw.
private struct HerdrWorkspaceCloseRPCResult: Decodable {}

/// `workspace.focus`'s own result -- decoded only far enough to confirm
/// "result" is a JSON object, for the identical reason as
/// `HerdrWorkspaceCloseRPCResult` above.
/// `focusWorkspace(workspaceID:socketPath:)` never reads this value --
/// only that the request did not throw.
private struct HerdrWorkspaceFocusRPCResult: Decodable {}
