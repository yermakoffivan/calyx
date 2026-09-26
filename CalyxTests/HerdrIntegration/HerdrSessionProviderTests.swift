//
//  HerdrSessionProviderTests.swift
//  CalyxTests
//
//  HerdrCLISessionProvider.listSessions()'s snapshot-driven counts and
//  per-workspace list: phase 2 (HerdrSessionProvider.swift's own doc
//  comment) fetches one session.snapshot per socket phase 1's
//  discovery+liveness sweep kept, and derives HerdrSessionInfo's
//  workspaces (id, label, pane count, straight from the snapshot's own
//  workspaces[] array) plus workspaceCount/paneCount/agentCount from it
//  -- workspaceCount/paneCount are themselves derived FROM workspaces,
//  never counted independently, so the two can never disagree. Also
//  covers closeWorkspace(workspaceID:socketPath:) -- the session
//  browser's Kill action for a herdr workspace row. Every dependency is
//  a fake/spy -- no real socket or herdr binary is ever touched,
//  mirroring HerdrIntegrationCoordinatorTests.swift's own
//  SpyHerdrTransportFactory + InMemoryHerdrTransport style, and its own
//  per-file fake-duplication convention.
//
//  Coverage:
//  - a snapshot naming multiple workspaces (in the SAME, UNSORTED order
//    the snapshot itself carries them) maps each onto a HerdrWorkspaceInfo
//    (id, label, pane count) in HerdrSessionInfo.workspaces, and
//    workspaceCount/paneCount stay consistent with that list
//  - a snapshot that fails (transport EOF before answering) leaves all
//    three counts nil AND workspaces empty, and the row still appears --
//    a live socket whose snapshot failed is still a live herdr
//  - closeWorkspace(workspaceID:socketPath:) sends workspace.close with
//    params EXACTLY {"workspace_id":...} -- WorkspaceTarget's own schema
//    shape, shared with workspace.get (HerdrWorkspaceTargetParams,
//    HerdrTabCoordinator.swift)
//

import XCTest
@testable import Calyx

// MARK: - Fakes

/// Fixed candidate/alive set -- neither test below mutates either
/// mid-run, so this stays an immutable struct (simpler than
/// HerdrIntegrationCoordinatorTests's own lock-guarded
/// FakeHerdrSessionDiscovery, built for that file's own need to flip a
/// socket from alive to dead mid-run).
private struct FakeHerdrSessionDiscovery: HerdrSessionDiscoveryProtocol {
    let candidates: [HerdrSessionCandidate]
    let aliveSocketPaths: Set<String>

    func discover() -> [HerdrSessionCandidate] { candidates }
    func isAlive(socketPath: String) -> Bool { aliveSocketPaths.contains(socketPath) }
}

/// Fixed `HerdrTUIClientScanning` fake -- returns a canned client list
/// regardless of when `scan()` is called, mirroring
/// `FakeHerdrSessionDiscovery`'s own immutable-fixture shape above (no
/// test below needs `scan()` to change mid-run).
private struct FakeHerdrTUIClientScanner: HerdrTUIClientScanning {
    let clients: [HerdrTUIClient]
    func scan() -> [HerdrTUIClient] { clients }
}

/// `HerdrTransportFactory` spy: each `makeTransport()` call hands out a
/// fresh `InMemoryHerdrTransport`, retaining it so tests can drive it --
/// mirrors `HerdrIntegrationCoordinatorTests.SpyHerdrTransportFactory`.
private actor SpyHerdrTransportFactory: HerdrTransportFactory {
    private(set) var transports: [InMemoryHerdrTransport] = []

    func makeTransport() async -> any HerdrTransport {
        let transport = InMemoryHerdrTransport()
        transports.append(transport)
        return transport
    }

    var callCount: Int { transports.count }

    func transport(at index: Int) -> InMemoryHerdrTransport? {
        transports.indices.contains(index) ? transports[index] : nil
    }
}

// File-scope, not an instance property: test_closeWorkspace below passes
// this into Task { ... }'s own initializer closure, and referencing an
// INSTANCE property there implicitly captures self -- which Swift 6's
// region-based isolation checker flags as a 'sending' closure data race
// risk, since XCTestCase itself is not proven Sendable. A file-scope
// constant carries no such capture (mirrors HerdrTabCoordinatorTests.swift's
// own identical pattern for its async let initializer expressions).
private let socketPath = "/fixture/config/herdr/herdr.sock"

// MARK: - HerdrSessionProviderTests

final class HerdrSessionProviderTests: XCTestCase {

    // MARK: - listSessions() maps a snapshot's workspaces[] onto HerdrSessionInfo's workspaces and counts

    /// The fixture below deliberately lists `w2` BEFORE `w1` -- the
    /// snapshot's own, unsorted order -- so this test also pins that
    /// `HerdrSessionInfo.workspaces` preserves it verbatim rather than
    /// sorting by id.
    func test_listSessions_snapshotWithMultipleWorkspaces_populatesPerWorkspaceListAndConsistentCounts() async {
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
            aliveSocketPaths: [socketPath]
        )
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(
            discovery: discovery,
            transportFactory: factory,
            tuiClientScanner: FakeHerdrTUIClientScanner(clients: [])
        )

        let task = Task { await provider.listSessions() }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected listSessions() to request a transport for the one alive candidate")
            return
        }
        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateLine(snapshotResponseLineWithTwoWorkspaces(id: "1"))

        let sessions = await task.value

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1, "one alive candidate must request exactly one transport")
        XCTAssertEqual(sessions.count, 1)
        guard let session = sessions.first else { return }
        XCTAssertEqual(session.id, socketPath)
        XCTAssertEqual(session.name, "default")

        XCTAssertEqual(
            session.workspaces.map(\.workspaceID), ["w2", "w1"],
            "must preserve the snapshot's own order, never sort by id"
        )
        XCTAssertEqual(session.workspaces.map(\.label), ["personal", "work"])
        XCTAssertEqual(session.workspaces.map(\.paneCount), [1, 2])

        XCTAssertEqual(
            session.workspaceCount, session.workspaces.count,
            "workspaceCount must stay consistent with workspaces -- derived from it, not counted independently"
        )
        XCTAssertEqual(
            session.paneCount, session.workspaces.map(\.paneCount).reduce(0, +),
            "paneCount must stay consistent with workspaces -- the sum of each entry's own paneCount"
        )
        XCTAssertEqual(session.workspaceCount, 2)
        XCTAssertEqual(session.paneCount, 3)
        XCTAssertEqual(session.agentCount, 2)
    }

    // MARK: - listSessions() leaves counts nil and workspaces empty, without dropping the row, when a snapshot fails

    func test_listSessions_snapshotFails_leavesCountsNilAndWorkspacesEmpty_stillYieldsTheRow() async {
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
            aliveSocketPaths: [socketPath]
        )
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(
            discovery: discovery,
            transportFactory: factory,
            tuiClientScanner: FakeHerdrTUIClientScanner(clients: [])
        )

        let task = Task { await provider.listSessions() }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected listSessions() to request a transport for the one alive candidate")
            return
        }
        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateEOF()

        let sessions = await task.value

        XCTAssertEqual(
            sessions.count, 1,
            "a live socket whose snapshot failed must still yield a row, just with unknown counts"
        )
        guard let session = sessions.first else { return }
        XCTAssertEqual(session.id, socketPath)
        XCTAssertEqual(session.name, "default")
        XCTAssertNil(session.workspaceCount)
        XCTAssertNil(session.paneCount)
        XCTAssertNil(session.agentCount)
        XCTAssertEqual(session.workspaces, [], "a failed snapshot must yield no workspace rows")
    }

    // MARK: - listSessions() attaches only the scanned TUI clients matching this session's own socket path

    /// TDD Red (herdr TUI-client integration): `HerdrCLISessionProvider`
    /// has no `tuiClientScanner:` initializer parameter yet, and
    /// `HerdrSessionInfo` has no `tuiClients` field yet -- this fails to
    /// COMPILE (unresolved `HerdrTUIClient`/`HerdrTUIClientScanning`,
    /// unexpected `tuiClientScanner:` argument, unknown `tuiClients`
    /// member).
    func test_listSessions_attachesScannedTUIClientsToTheirSession() async {
        let discovery = FakeHerdrSessionDiscovery(
            candidates: [HerdrSessionCandidate(name: "default", socketPath: socketPath)],
            aliveSocketPaths: [socketPath]
        )
        let factory = SpyHerdrTransportFactory()
        let matchingClient = HerdrTUIClient(
            socketPath: socketPath,
            surfaceHint: .surfaceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        )
        let otherClient = HerdrTUIClient(
            socketPath: "/other/herdr.sock",
            surfaceHint: .surfaceID(UUID(uuidString: "99999999-8888-7777-6666-555555555555")!)
        )
        let scanner = FakeHerdrTUIClientScanner(clients: [matchingClient, otherClient])
        let provider = HerdrCLISessionProvider(discovery: discovery, transportFactory: factory, tuiClientScanner: scanner)

        let task = Task { await provider.listSessions() }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected listSessions() to request a transport for the one alive candidate")
            return
        }
        _ = await awaitSentMessages(transport, atLeast: 1)
        await transport.simulateLine(snapshotResponseLineWithTwoWorkspaces(id: "1"))

        let sessions = await task.value

        XCTAssertEqual(sessions.count, 1)
        guard let session = sessions.first else { return }
        XCTAssertEqual(
            session.tuiClients, [matchingClient],
            "listSessions() must attach exactly the scanned TUI clients whose own socketPath equals this " +
            "session's own socket path, never a client scanned for a different socket"
        )
    }

    // MARK: - closeWorkspace(workspaceID:socketPath:) sends workspace.close with exactly the given id

    func test_closeWorkspace_sendsWorkspaceCloseWithExactlyTheGivenWorkspaceID() async {
        let discovery = FakeHerdrSessionDiscovery(candidates: [], aliveSocketPaths: [])
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(
            discovery: discovery,
            transportFactory: factory,
            tuiClientScanner: FakeHerdrTUIClientScanner(clients: [])
        )

        let task = Task { await provider.closeWorkspace(workspaceID: "w1", socketPath: socketPath) }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected closeWorkspace to request a transport")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard sent.count == 1, let requestID = requestID(inLine: sent[0]) else {
            XCTFail("expected exactly one request line; got \(sent)")
            return
        }
        XCTAssertEqual(requestMethod(inLine: sent[0]), "workspace.close")
        let params = jsonObject(inLine: sent[0])?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            params as NSDictionary, ["workspace_id": "w1"] as NSDictionary,
            "workspace.close's params must carry EXACTLY {\"workspace_id\":...} -- WorkspaceTarget's own " +
            "schema shape, shared with workspace.get"
        )

        await transport.simulateLine(okResponseLine(id: requestID))
        await task.value

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1, "closeWorkspace must request exactly one transport")
    }

    // MARK: - focusWorkspace(workspaceID:socketPath:) sends workspace.focus

    /// TDD Red: mirrors `test_closeWorkspace_sendsWorkspaceCloseWithExactlyTheGivenWorkspaceID`
    /// above exactly, for the new `focusWorkspace(workspaceID:socketPath:)`
    /// requirement -- sent by `SessionBrowserModel.attachHerdrWorkspace(_:)`
    /// for a `.tuiPane` row before it asks the window controller to focus
    /// the pane, so the herdr TUI itself switches to the right workspace
    /// instead of merely revealing whichever one it was already on. Fails
    /// to COMPILE today: `HerdrCLISessionProvider` has no `focusWorkspace`
    /// member at all.
    func test_focusWorkspace_sendsWorkspaceFocusWithExactlyTheGivenWorkspaceID() async {
        let discovery = FakeHerdrSessionDiscovery(candidates: [], aliveSocketPaths: [])
        let factory = SpyHerdrTransportFactory()
        let provider = HerdrCLISessionProvider(
            discovery: discovery,
            transportFactory: factory,
            tuiClientScanner: FakeHerdrTUIClientScanner(clients: [])
        )

        let task = Task { await provider.focusWorkspace(workspaceID: "w1", socketPath: socketPath) }
        guard let transport = await awaitTransport(factory, at: 0) else {
            XCTFail("expected focusWorkspace to request a transport")
            return
        }
        let sent = await awaitSentMessages(transport, atLeast: 1)
        guard sent.count == 1, let requestID = requestID(inLine: sent[0]) else {
            XCTFail("expected exactly one request line; got \(sent)")
            return
        }
        XCTAssertEqual(requestMethod(inLine: sent[0]), "workspace.focus")
        let params = jsonObject(inLine: sent[0])?["params"] as? [String: Any] ?? [:]
        XCTAssertEqual(
            params as NSDictionary, ["workspace_id": "w1"] as NSDictionary,
            "workspace.focus's params must carry EXACTLY {\"workspace_id\":...} -- the same " +
            "HerdrWorkspaceTargetParams shape workspace.close/workspace.get already use"
        )

        await transport.simulateLine(okResponseLine(id: requestID))
        await task.value

        let callCount = await factory.callCount
        XCTAssertEqual(callCount, 1, "focusWorkspace must request exactly one transport")
    }

    // MARK: - Fixtures

    /// `session.snapshot` result naming 2 workspaces (`w2` first, then
    /// `w1` -- deliberately NOT sorted by id) and 2 agents --
    /// required-fields-only WorkspaceInfo/AgentInfo records (see
    /// HerdrEvent.swift's own header, HerdrTabCoordinator.swift's own
    /// `HerdrWorkspaceInfo` doc comment), matching
    /// `HerdrConnectionTests.snapshotResponseLineWithOneMinimalPane`'s
    /// own minimal-fixture style. `panes` mirrors the two workspaces'
    /// own `pane_count` (1 for w2, 2 for w1) for fixture realism, though
    /// `HerdrCLISessionProvider` no longer counts through it.
    private func snapshotResponseLineWithTwoWorkspaces(id: String) -> String {
        #"""
        {"id":"\#(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.8.0","protocol":19,"workspaces":[{"workspace_id":"w2","number":2,"label":"personal","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"idle"},{"workspace_id":"w1","number":1,"label":"work","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"idle"}],"tabs":[],"panes":[{"terminal_id":"term-1","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1},{"terminal_id":"term-2","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p2","focused":false,"revision":1},{"terminal_id":"term-3","agent_status":"working","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"revision":1}],"layouts":[],"agents":[{"terminal_id":"term-1","agent_status":"unknown","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1},{"terminal_id":"term-3","agent_status":"working","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"revision":1}]}}}
        """#
    }

    /// A generic, empty-object success result -- `workspace.close`'s own
    /// response shape has no method-to-result mapping in the schema to
    /// pin a specific discriminator against, and
    /// `HerdrCLISessionProvider.closeWorkspace(workspaceID:socketPath:)`
    /// never reads this value, only that the request did not throw.
    private func okResponseLine(id: String) -> String {
        "{\"id\":\"\(id)\",\"result\":{}}"
    }

    // MARK: - Wire-line parsing helpers (mirrors HerdrAttachOrCreateFlowTests.swift's own)

    private func jsonObject(inLine line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func requestMethod(inLine line: String) -> String? {
        jsonObject(inLine: line)?["method"] as? String
    }

    private func requestID(inLine line: String) -> String? {
        jsonObject(inLine: line)?["id"] as? String
    }

    // MARK: - Bounded async polling (mirrors HerdrConnectionTests.swift's own helpers)

    private func waitUntil(maxYields: Int = 10_000, _ condition: () async -> Bool) async {
        var iterations = 0
        while await !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    private func awaitTransport(_ factory: SpyHerdrTransportFactory, at index: Int) async -> InMemoryHerdrTransport? {
        await waitUntil { await factory.callCount > index }
        return await factory.transport(at: index)
    }

    private func awaitSentMessages(_ transport: InMemoryHerdrTransport, atLeast count: Int) async -> [String] {
        await waitUntil { await transport.sentMessages().count >= count }
        return await transport.sentMessages()
    }
}
