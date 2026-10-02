//
//  AppDelegateUsageLedgerWiringTests.swift
//  CalyxTests
//
//  Pins AppDelegate.startUsageLedger(server:ledger:), the one place the
//  usage ledger is connected to the app: it installs the usage sink on
//  the server it was GIVEN, forwarding to the ledger it was GIVEN, and
//  starts one reconcile of the sessions that ledger already knows, at a
//  priority no higher than utility.
//
//  The whole path is driven for real: an authenticated POST /agent-event
//  is routed by a test server, and the transcript it names is read into
//  a store in a per-test temporary directory by a test ledger running
//  the real ingestor. The shared server, the shared ledger, ~/.claude
//  and Application Support are never involved, and the usage setting is
//  pointed at a test suite so that a wiring mistake reaching the shared
//  ledger would find tracking off.
//
//  SCHEDULES. Neither the forwarded event nor the reconcile is waited
//  for by the code under test, and they run at different priorities, so
//  with tracking on the reconcile may list the store before or after an
//  event's read stored its session. In the second case it reads that
//  session once more and publishes its row again. Every test therefore
//  either has a single source of reads, or asserts only what holds in
//  both orders: WHICH rows were published (as a set), never how often.
//  Each test says which of the two it is.
//
//  WAITING. A test waits for a publish that must happen through an
//  expectation (bound: UsageWiringFixture.waitSeconds, reached only on
//  failure). Before asserting what was or was not published it calls
//  `settle`, which closes the ledger behind every task started so far.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateUsageLedgerWiringTests: XCTestCase {

    private typealias Fixture = UsageWiringFixture
    private typealias Entry = UsagePublishRecorder.Entry

    private let sessionA = UsageWiringFixture.sessionA
    private let sessionB = UsageWiringFixture.sessionB
    private let testToken = "test-token-usage-wiring"
    private let settingsSuiteName = "com.calyx.tests.AppDelegateUsageLedgerWiringTests"

    private var fixture: UsageWiringFixture!
    private var server: CalyxMCPServer!
    private var recorder: UsagePublishRecorder!
    private var ledgers: [UsageLedger] = []

    override func setUp() async throws {
        try await super.setUp()
        UsageTrackingSettings._testUseSuite(named: settingsSuiteName)
        fixture = try UsageWiringFixture.make(label: "AppDelegateUsageLedgerWiringTests")
        server = CalyxMCPServer(agentEndpointDirectory: fixture.basePath + "/agent-endpoint")
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        recorder = UsagePublishRecorder()
    }

    override func tearDown() async throws {
        server?.usageSink = nil
        server?.stop()
        server = nil
        await fixture?.shutDown(ledgers)
        ledgers = []
        fixture = nil
        recorder = nil
        UsageTrackingSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeLedger() -> UsageLedger {
        let ledger = fixture.makeLedger(recorder: recorder)
        ledgers.append(ledger)
        return ledger
    }

    /// Wires `ledger` to this test's server through a new app delegate,
    /// as the launch does with the shared pair.
    private func start(_ ledger: UsageLedger) {
        let appDelegate = AppDelegate()
        appDelegate.startUsageLedger(server: server, ledger: ledger)
    }

    /// A Claude-shaped hook event naming `sessionID`'s synthetic transcript.
    private func eventRequest(_ event: String, _ sessionID: String, kind: String? = nil) throws -> HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event,
            "cwd": "/work/repo/sub",
            "session_id": sessionID,
            "transcript_path": fixture.mainPath(sessionID),
        ])
        var headers = ["Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": UUID().uuidString]
        if let kind { headers["X-Calyx-Agent-Kind"] = kind }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    /// Waits until the ledger has published at least `count` times; fails
    /// the test after UsageWiringFixture.waitSeconds.
    private func waitForPublishes(_ count: Int) async {
        let published = expectation(description: "the ledger published \(count) time(s)")
        recorder.expect(count: count, fulfilling: published)
        await fulfillment(of: [published], timeout: Fixture.waitSeconds)
    }

    private func settle(_ ledger: UsageLedger) async {
        await fixture.closeBehindEverythingStarted(ledger, in: self)
    }

    private func entry(_ sessionID: String, _ responses: Int64) -> Entry {
        Entry(sessionID: sessionID, row: Fixture.totalRow(responses))
    }

    /// The distinct rows that were published, however often each was.
    private var publishedRows: Set<String> {
        Set(recorder.entries.map { "\($0.sessionID): \(String(describing: $0.row))" })
    }

    private func rows(_ entries: Entry...) -> Set<String> {
        Set(entries.map { "\($0.sessionID): \(String(describing: $0.row))" })
    }

    private func storedTotal(_ sessionID: String) async throws -> [UsageRow] {
        try await fixture.readStore { try await $0.report(UsageQuery(sessionID: sessionID), calendar: Fixture.utc) }
    }

    // MARK: - The sink

    // No read can happen: tracking is off, so the reconcile and any
    // event are dropped by the ledger whenever they arrive.
    func test_startUsageLedger_installsTheSinkOnTheGivenServer() {
        XCTAssertNil(server.usageSink, "Fixture error: a new server has no sink")
        fixture.tracking.set(false)

        start(makeLedger())

        XCTAssertNotNil(server.usageSink)
    }

    // Both files exist before anything starts and nothing changes them,
    // so every read of the session, by the event or by the reconcile, in
    // any order and any number of times, publishes the same row.
    func test_claudeCodeEvent_isReadIntoTheGivenLedgersStore() async throws {
        try fixture.write(
            [Fixture.userLine, Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        try fixture.write(
            [Fixture.assistantLine("msg_s1", agentID: "a1")], to: fixture.subagentPath(sessionA, "a1"))
        let ledger = makeLedger()
        start(ledger)

        let response = await server.route(request: try eventRequest("Stop", sessionA))

        XCTAssertEqual(response.statusCode, 204)
        await waitForPublishes(1)
        await settle(ledger)
        XCTAssertEqual(publishedRows, rows(entry(sessionA, 2)))
        let stored = try await storedTotal(sessionA)
        XCTAssertEqual(stored, [Fixture.totalRow(2)])
    }

    // The sink stays installed and forwards each event, not only the
    // first. The second event names another session: the reconcile can
    // only read a session that is stored, and a session is stored only by
    // its own event, so that session's row proves the second event
    // arrived. Each transcript is fixed, so repeated reads change nothing.
    func test_everyEventReachesTheLedger_notOnlyTheFirst() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        try fixture.write(
            [Fixture.assistantLine("msg_b1", sessionID: sessionB), Fixture.assistantLine("msg_b2", sessionID: sessionB)],
            to: fixture.mainPath(sessionB))
        let ledger = makeLedger()
        start(ledger)

        let first = await server.route(request: try eventRequest("SessionStart", sessionA))
        let second = await server.route(request: try eventRequest("Stop", sessionB))

        XCTAssertEqual(first.statusCode, 204)
        XCTAssertEqual(second.statusCode, 204)
        await waitForPublishes(2)
        await settle(ledger)
        XCTAssertEqual(publishedRows, rows(entry(sessionA, 1), entry(sessionB, 2)))
    }

    // Session A is named only by an event of another agent kind, so no
    // correct schedule stores or reads it; session B's event and the
    // reconcile may read B any number of times.
    func test_eventOfAnotherAgentKind_isNotRead() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        try fixture.write(
            [Fixture.assistantLine("msg_b1", sessionID: sessionB)], to: fixture.mainPath(sessionB))
        let ledger = makeLedger()
        start(ledger)

        let other = await server.route(request: try eventRequest("Stop", sessionA, kind: "codex"))
        let claude = await server.route(request: try eventRequest("Stop", sessionB))

        XCTAssertEqual(other.statusCode, 204)
        XCTAssertEqual(claude.statusCode, 204)
        await waitForPublishes(1)
        await settle(ledger)
        XCTAssertEqual(publishedRows, rows(entry(sessionB, 1)))
        let sessions = try await fixture.readStore { try await $0.sessions().map(\.sessionID) }
        XCTAssertEqual(sessions, [sessionB])
    }

    // MARK: - The reconcile at start

    /// An earlier run of the app has read `sessionA`'s first line and
    /// closed its ledger; two lines were appended since.
    private func storeSessionAThenAppendTwoLines() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let earlier = makeLedger()
        await earlier.note(fixture.activity("Stop"))
        await earlier.waitUntilIdle()
        await earlier.close()
        XCTAssertEqual(recorder.entries, [entry(sessionA, 1)], "Fixture error")
        try fixture.append(
            [Fixture.assistantLine("msg_m2"), Fixture.assistantLine("msg_m3")], to: fixture.mainPath(sessionA))
    }

    // No event is sent, so the reconcile is the only source of reads: it
    // reads the one stored session exactly once.
    func test_startUsageLedger_readsAStoredSessionsAppendedLines_withoutAnyEvent() async throws {
        try await storeSessionAThenAppendTwoLines()
        let ledger = makeLedger()

        start(ledger)

        await waitForPublishes(2)
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [entry(sessionA, 1), entry(sessionA, 3)])
        let stored = try await storedTotal(sessionA)
        XCTAssertEqual(stored, [Fixture.totalRow(3)])
    }

    // Catching up on stored sessions is background work: it must not run
    // at the priority of the main thread that starts it. The reconcile is
    // the only source of reads here, and nothing awaits its task (the
    // test waits for the publish through an expectation), so nothing can
    // raise the priority its ingest observes.
    func test_startUsageLedger_reconcileReadsAtUtilityPriorityOrLower() async throws {
        try await storeSessionAThenAppendTwoLines()
        XCTAssertGreaterThan(
            Task.currentPriority, .utility,
            "Fixture error: the caller must run above utility, or an inherited priority would pass")
        let seedIngests = recorder.ingestPriorities.count
        let ledger = makeLedger()

        start(ledger)

        await waitForPublishes(2)
        let priorities = Array(recorder.ingestPriorities.dropFirst(seedIngests))
        XCTAssertEqual(priorities.count, 1)
        for priority in priorities {
            XCTAssertLessThanOrEqual(priority, .utility)
        }
    }

    // MARK: - Tracking off

    // Tracking is off throughout: the ledger drops the reconcile and the
    // event whenever they arrive.
    func test_trackingOff_startAndAnEvent_readNothingAndCreateNothing() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        fixture.tracking.set(false)
        let ledger = makeLedger()
        let before = fixture.everyPath()
        start(ledger)

        let response = await server.route(request: try eventRequest("Stop", sessionA))

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNotNil(server.usageSink, "the sink is installed whatever the setting says")
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [])
        XCTAssertEqual(fixture.everyPath(), before)
    }

    // Wiring happens once at launch, with tracking possibly off; the sink
    // must already be there when the user turns it on. The reconcile may
    // run before tracking is turned on (it does nothing) or after (it
    // finds no session, or re-reads the one the event stored): the fixed
    // transcript gives the same row either way.
    func test_trackingTurnedOnAfterStart_theNextEventIsRead() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        fixture.tracking.set(false)
        let ledger = makeLedger()
        start(ledger)

        fixture.tracking.set(true)
        let response = await server.route(request: try eventRequest("Stop", sessionA))

        XCTAssertEqual(response.statusCode, 204)
        await waitForPublishes(1)
        await settle(ledger)
        XCTAssertEqual(publishedRows, rows(entry(sessionA, 1)))
    }
}
