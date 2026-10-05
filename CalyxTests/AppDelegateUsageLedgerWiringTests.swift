//
//  AppDelegateUsageLedgerWiringTests.swift
//  CalyxTests
//
//  Pins AppDelegate.startUsageLedger(server:ledger:), the one place the
//  usage ledger is connected to the app: it installs the usage sink on
//  the server it was GIVEN, forwarding to the ledger it was GIVEN, and
//  starts one reconcile of the sessions that ledger already knows, at a
//  priority no higher than utility. It also installs the server's usage
//  bridge, so a `usage_report` call through /mcp reads that ledger,
//  answers "tracking is off" exactly while the ledger's own switch is
//  off, and resolves `session_id: "current"` through the registry the
//  server holds at call time.
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
//  R3b: it also installs the usage route's endpoint on that server
//  (`server.usageIngest`), forwarding exports to `ledger.ingestExport`,
//  accepting the credential held by the holder it is given, and noting
//  every verdict in the monitor it is given; it loads that credential
//  from the directory it is given (a per-test directory here, never
//  Application Support), syncs the tracking flag, and starts a catch-up.
//
//  R4b: `startUsageLedger` no longer loads the credential or syncs the
//  tracking flag itself: its startup task awaits ONE reconcile of the
//  telemetry activation it is given (which does both), then catches up.
//  It also requests a reconcile on every `.calyxIPCStateDidChange`.
//  Every test here gives it a per-test activation (never `.shared`):
//  inputs "tracking as the ledger says, IPC on, server not running", so
//  the target is `.untouched` (sync, load creating) with tracking on and
//  `.removed` (fake remove, sync, load without creating) with tracking
//  off, which is what the startup did before R4b; its effects reach this
//  test's ledger and holder and never a settings file.
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
    private var holderStorage: UsageIngestCredentialHolder?
    private var monitorStorage: UsageIngestMonitor?
    /// The startup work of every `start`, awaited before the directories
    /// are removed, so none of it can run after the teardown.
    private var startups: [Task<Void, Never>] = []
    /// Kept alive for the whole test: the app delegate holds its
    /// notification observer, which holds the activation weakly.
    private var appDelegates: [AppDelegate] = []
    private var activations: [UsageTelemetryActivation] = []

    override func setUp() async throws {
        try await super.setUp()
        UsageTrackingSettings._testUseSuite(named: settingsSuiteName)
        fixture = try UsageWiringFixture.make(label: "AppDelegateUsageLedgerWiringTests")
        server = CalyxMCPServer(agentEndpointDirectory: fixture.basePath + "/agent-endpoint")
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        recorder = UsagePublishRecorder()
        holderStorage = UsageIngestCredentialHolder()
        monitorStorage = UsageIngestMonitor()
    }

    override func tearDown() async throws {
        server?.usageSink = nil
        server?.usageIngest = nil
        await awaitStartups()
        startups = []
        appDelegates = []
        activations = []
        server?.stop()
        server = nil
        await fixture?.shutDown(ledgers)
        ledgers = []
        fixture = nil
        recorder = nil
        holderStorage = nil
        monitorStorage = nil
        UsageTrackingSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeLedger() -> UsageLedger {
        let ledger = fixture.makeLedger(recorder: recorder)
        ledgers.append(ledger)
        return ledger
    }

    /// The directory the credential is loaded from: under the fixture,
    /// never Application Support.
    private var credentialDirectory: String { fixture.basePath + "/credential" }

    /// The activation `start` gives the launch: tracking as the ledger
    /// says, IPC on, server not running; effects over this test's ledger,
    /// holder and credential directory, and a remove that touches no file.
    private func makeActivation(_ ledger: UsageLedger, holder: UsageIngestCredentialHolder) -> UsageTelemetryActivation {
        let credentialDirectory = self.credentialDirectory
        let activation = UsageTelemetryActivation(
            inputs: UsageTelemetryActivation.Inputs(
                trackingOn: { ledger.isTracking },
                ipcEnabled: { true },
                serverPort: { nil },
                mayTouchAgentFiles: { true }),
            effects: UsageTelemetryActivation.Effects(
                syncTracking: { await ledger.syncTracking() },
                loadCredential: { create in try await holder.load(create: create, directory: credentialDirectory) },
                install: { port, _ in
                    XCTFail("the server never runs in these tests: nothing may be installed")
                    return .installed(port: port)
                },
                remove: { .removed }),
            onStatusChange: {})
        activations.append(activation)
        return activation
    }

    /// Wires `ledger` to this test's server through a new app delegate,
    /// as the launch does with the shared pair, with this test's holder,
    /// monitor and activation (by default `makeActivation`, whose loader
    /// owns this test's credential directory).
    ///
    /// The startup task it returns is never discarded: it is kept in
    /// `startups`, and `awaitStartups()` (called by `settle` and by
    /// tearDown) waits for it. Since R4b it runs `activation.reconcile()`
    /// before its ledger work, so its ledger tasks may not exist yet when
    /// `start` returns.
    private func start(_ ledger: UsageLedger, activation: UsageTelemetryActivation? = nil) {
        guard let holder = holderStorage, let monitor = monitorStorage else {
            XCTFail("Fixture error: no holder or monitor")
            return
        }
        let appDelegate = AppDelegate()
        appDelegates.append(appDelegate)
        let startup = appDelegate.startUsageLedger(
            server: server, ledger: ledger, credentialHolder: holder, ingestMonitor: monitor,
            activation: activation ?? makeActivation(ledger, holder: holder))
        startups.append(startup)
    }

    /// Waits for the startup work of every `start` so far.
    private func awaitStartups() async {
        for startup in startups {
            await startup.value
        }
    }

    /// A Claude-shaped hook event naming `sessionID`'s synthetic transcript.
    /// `surfaceID` names the pane the event comes from; a new one each
    /// time when nil.
    private func eventRequest(
        _ event: String, _ sessionID: String, kind: String? = nil, surfaceID: UUID? = nil
    ) throws -> HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event,
            "cwd": "/work/repo/sub",
            "session_id": sessionID,
            "transcript_path": fixture.mainPath(sessionID),
        ])
        var headers = [
            "Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": (surfaceID ?? UUID()).uuidString,
        ]
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

    /// Waits for every startup task first (only then has each queued its
    /// ledger work), then closes the ledger behind everything started.
    private func settle(_ ledger: UsageLedger) async {
        await awaitStartups()
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

    // MARK: - The usage_report tool

    /// Calls `usage_report` through the server's /mcp route from `surfaceID`.
    private func usageReport(
        _ arguments: [String: Any], from surfaceID: UUID? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "usage_report", "arguments": arguments],
        ] as [String: Any])
        var headers = ["Authorization": "Bearer \(testToken)", "Content-Type": "application/json"]
        if let surfaceID { headers["X-Calyx-Surface-ID"] = surfaceID.uuidString }
        let response = await server.route(
            request: HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body))
        XCTAssertEqual(response.statusCode, 200, file: file, line: line)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(response.body, file: file, line: line))
                as? [String: Any], file: file, line: line)
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)", file: file, line: line)
        let text = try XCTUnwrap(
            (result["content"] as? [[String: Any]])?.first?["text"] as? String, file: file, line: line)
        return (text, try XCTUnwrap(result["isError"] as? Bool, file: file, line: line))
    }

    private func object(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text, file: file, line: line)
    }

    private func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    // Tracking is off, so nothing is read whatever the schedule.
    func test_startUsageLedger_installsAUsageBridgeOnTheGivenServer() {
        XCTAssertNil(server.usageBridge, "Fixture error: a new server has no usage bridge")
        fixture.tracking.set(false)

        start(makeLedger())

        XCTAssertNotNil(server.usageBridge)
    }

    // Two panes, each running its own session. Both events are read and
    // `settle` closes the ledger behind every read they started, so the
    // store holds both sessions before the tool is called; the tool's own
    // reconcile then re-reads fixed transcripts and changes nothing.
    //
    // The registry is replaced AFTER `startUsageLedger`: `current` must be
    // looked up in whatever registry the server holds at call time. The
    // usage setting in the test suite is never written (so it reads off):
    // only the ledger's own switch decides.
    func test_usageReport_trackingOn_reportsTheStoredRows_andCurrentIsTheCallingPanesSession() async throws {
        try fixture.write(
            [Fixture.assistantLine("msg_a1"), Fixture.assistantLine("msg_a2")], to: fixture.mainPath(sessionA))
        try fixture.write([Fixture.assistantLine("msg_b1", sessionID: sessionB)], to: fixture.mainPath(sessionB))
        let ledger = makeLedger()
        start(ledger)
        server.agentRegistry = AgentRegistry()
        let paneA = UUID()
        let paneB = UUID()

        let eventA = await server.route(request: try eventRequest("Stop", sessionA, surfaceID: paneA))
        let eventB = await server.route(request: try eventRequest("Stop", sessionB, surfaceID: paneB))
        XCTAssertEqual(eventA.statusCode, 204)
        XCTAssertEqual(eventB.statusCode, 204)
        await settle(ledger)
        XCTAssertEqual(publishedRows, rows(entry(sessionA, 2), entry(sessionB, 1)), "Fixture error")
        XCTAssertFalse(UsageTrackingSettings.enabled, "Fixture error: the suite's setting is off")

        let bySession = try await usageReport(["group_by": ["session"]])
        let fromPaneA = try await usageReport(["session_id": "current", "group_by": ["model"]], from: paneA)
        let fromPaneB = try await usageReport(["session_id": "current", "group_by": [String]()], from: paneB)

        XCTAssertFalse(bySession.isError, bySession.text)
        let all = try object(bySession.text)
        let allRows = try XCTUnwrap(all["rows"] as? [[String: Any]])
        XCTAssertEqual(allRows.map { ($0["key"] as? [String: Any])?["session"] as? String }, [sessionA, sessionB])
        XCTAssertEqual(allRows.map { number($0["responses"]) }, [2, 1])
        XCTAssertEqual(number((all["totals"] as? [String: Any])?["responses"]), 3)
        XCTAssertEqual(all["time_zone"] as? String, Calendar.current.timeZone.identifier)

        XCTAssertFalse(fromPaneA.isError, fromPaneA.text)
        let a = try object(fromPaneA.text)
        let aRows = try XCTUnwrap(a["rows"] as? [[String: Any]])
        XCTAssertEqual(aRows.count, 1)
        XCTAssertEqual((aRows.first?["key"] as? [String: Any])?["model"] as? String, "claude-opus-5-5")
        // By hand: two final responses of input 3, output 420, thinking
        // 150, cache read 90,000, cache creation 1,200 (1,000 of it 1h).
        let row = try XCTUnwrap(aRows.first)
        XCTAssertEqual(number(row["responses"]), 2)
        XCTAssertEqual(number(row["final_responses"]), 2)
        XCTAssertEqual(number(row["input_tokens"]), 6)
        XCTAssertEqual(number(row["cache_read_tokens"]), 180_000)
        XCTAssertEqual(number(row["cache_creation_tokens"]), 2_400)
        XCTAssertEqual(number(row["cache_creation_1h_tokens"]), 2_000)
        XCTAssertEqual(number(row["output_tokens_final"]), 840)
        XCTAssertEqual(number(row["thinking_tokens_final"]), 300)
        XCTAssertEqual(row["last_timestamp"] as? String, "2026-10-02T10:27:29.765Z")

        XCTAssertFalse(fromPaneB.isError, fromPaneB.text)
        let b = try object(fromPaneB.text)
        XCTAssertEqual((b["rows"] as? [[String: Any]])?.map { number($0["responses"]) }, [1])
        XCTAssertEqual(number((b["totals"] as? [String: Any])?["output_tokens_final"]), 420)
    }

    // The pane's agent row knows no session: `current` cannot be resolved.
    func test_usageReport_currentFromAPaneWithoutASession_isAToolError() async throws {
        let ledger = makeLedger()
        start(ledger)

        let result = try await usageReport(["session_id": "current"], from: UUID())

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "No agent session is known for the calling pane.")
    }

    // The ledger's switch is off while the app's setting (in the test
    // suite) is on: the bridge answers from the ledger, never from the
    // setting. Tracking is off throughout, so nothing is read or created.
    func test_usageReport_trackingOff_isTheTrackingOffToolError_whateverTheSettingSays() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        fixture.tracking.set(false)
        UsageTrackingSettings.enabled = true
        let ledger = makeLedger()
        let before = fixture.everyPath()
        start(ledger)

        let result = try await usageReport(["group_by": ["model"]])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
        await settle(ledger)
        XCTAssertEqual(fixture.everyPath(), before)
    }

    // Wired once at launch; the tool follows the ledger's switch at each
    // call. No session is stored, so whichever schedule the reconcile
    // takes, a successful call reports no rows.
    func test_usageReport_followsTheLedgersTrackingAtEachCall() async throws {
        fixture.tracking.set(false)
        let ledger = makeLedger()
        start(ledger)

        let off = try await usageReport([:])
        fixture.tracking.set(true)
        let on = try await usageReport([:])
        fixture.tracking.set(false)
        let offAgain = try await usageReport([:])

        XCTAssertTrue(off.isError)
        XCTAssertFalse(on.isError, on.text)
        XCTAssertEqual(number(try object(on.text)["row_count"]), 0)
        XCTAssertTrue(offAgain.isError)
        XCTAssertEqual(offAgain.text, "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
    }

    // MARK: - The usage route (R3b)

    private func theHolder() throws -> UsageIngestCredentialHolder {
        try XCTUnwrap(holderStorage, "Fixture error: no holder")
    }

    private func theMonitor() throws -> UsageIngestMonitor {
        try XCTUnwrap(monitorStorage, "Fixture error: no monitor")
    }

    /// A usage token written by hand (64 lowercase hex characters).
    private let usageToken = String(repeating: "0123456789abcdef", count: 4)

    /// Writes the credential file the launch will find.
    private func writeCredential() throws -> UsageIngestCredential {
        let token = usageToken
        return try UsageIngestCredentialStore.loadOrCreate(directory: credentialDirectory, makeToken: { token })
    }

    private func usageRequest(_ body: Data, token: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: HTTPParser.usageMetricsPath,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: body)
    }

    // Tracking is off: nothing is read or created whatever the schedule.
    func test_startUsageLedger_installsTheUsageEndpointOnTheGivenServer() {
        XCTAssertNil(server.usageIngest, "Fixture error: a new server has no usage endpoint")
        fixture.tracking.set(false)

        start(makeLedger())

        XCTAssertNotNil(server.usageIngest)
    }

    // The database is created first with tracking from the epoch, so the
    // export (received at the endpoint's real clock) counts in full. The
    // test loads the credential itself after `start`, which sets the same
    // holder deterministically whichever load runs first. The session has
    // no transcript, so its settles and the catch-up only find it missing.
    func test_fixtureExportPostedToTheRoute_endsUpInTheLedgersTokenReports() async throws {
        let holder = try theHolder()
        let monitor = try theMonitor()
        let seeded = try UsageStore(directory: fixture.storeURL, now: UsageTestClock(Date(timeIntervalSince1970: 0)).now)
        await seeded.close()
        let credential = try writeCredential()
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let ledger = makeLedger()
        start(ledger)
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(loaded, credential, "Fixture error")
        XCTAssertEqual(holder.credential, credential)

        let before = Date()
        let response = await server.route(request: usageRequest(body, token: credential.token))
        let after = Date()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        let accepted = try XCTUnwrap(monitor.lastAcceptedAt, "the monitor records the accepted time")
        XCTAssertGreaterThanOrEqual(accepted, before)
        XCTAssertLessThanOrEqual(accepted, after)
        XCTAssertNil(monitor.lastRejection)

        let results = try await ledger.tokenReports([UsageTokenQuery(groupBy: [.model])], calendar: Fixture.utc)
        let rows = try XCTUnwrap(results.first)
        XCTAssertEqual(rows.filter(\.isUnreported), [])
        let totals = UsageTelemetryFixtures.sumByModel(rows.flatMap { row -> [(String, String, Int64)] in
            let model = row.key.first.flatMap { $0 } ?? ""
            return [(model, "input", row.inputTokens), (model, "output", row.outputTokens),
                    (model, "cacheRead", row.cacheReadTokens), (model, "cacheCreation", row.cacheCreationTokens)]
        })
        XCTAssertEqual(totals, try UsageTelemetryFixtures.expectedTotals(run: "run1"))
        await settle(ledger)
    }

    // Tracking is off, so the launch loads without creating: there is no
    // credential, and the route refuses every token.
    func test_withoutACredential_theSameRequestIsUnauthorized_andNothingIsCreated() async throws {
        let holder = try theHolder()
        let monitor = try theMonitor()
        fixture.tracking.set(false)
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let ledger = makeLedger()
        let before = fixture.everyPath()
        start(ledger)
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertNil(loaded)
        XCTAssertNil(holder.credential)

        let response = await server.route(request: usageRequest(body, token: usageToken))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(monitor.lastRejection?.reason, .unauthorized)
        XCTAssertNil(monitor.lastAcceptedAt)
        await settle(ledger)
        XCTAssertEqual(fixture.everyPath(), before, "with tracking off nothing is created")
    }

    // MARK: - UsageIngestCredentialHolder

    func test_holder_loadWithCreate_writesTheCredential_andHoldsIt() async throws {
        let holder = try theHolder()
        let loaded = try await holder.load(create: true, directory: credentialDirectory)

        let credential = try XCTUnwrap(loaded)
        XCTAssertEqual(holder.credential, credential)
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: credentialDirectory), credential)
        XCTAssertEqual(credential.token.count, 64)
    }

    func test_holder_loadWithoutCreate_readsAnExistingCredential() async throws {
        let holder = try theHolder()
        let credential = try writeCredential()

        let loaded = try await holder.load(create: false, directory: credentialDirectory)

        XCTAssertEqual(loaded, credential)
        XCTAssertEqual(holder.credential, credential)
    }

    func test_holder_loadWithoutCreate_withoutAFile_holdsNothing_andCreatesNothing() async throws {
        let holder = try theHolder()
        holder.set(UsageIngestCredential(token: usageToken, headersFilePath: "/nonexistent/x"))

        let loaded = try await holder.load(create: false, directory: credentialDirectory)

        XCTAssertNil(loaded)
        XCTAssertNil(holder.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory))
    }

    // A load that throws (the headers path is occupied by a directory)
    // leaves the held credential as it was and rethrows.
    func test_holder_loadThatThrows_keepsTheCredential_andRethrows() async throws {
        let holder = try theHolder()
        let credential = try writeCredential()
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(loaded, credential, "Fixture error")
        let path = UsageIngestCredentialStore.headersFilePath(directory: credentialDirectory)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)

        do {
            _ = try await holder.load(create: true, directory: credentialDirectory)
            XCTFail("a load whose headers path is a directory must throw")
        } catch {
            XCTAssertEqual(holder.credential, credential)
        }
    }

    func test_holder_set_replacesTheCredential() throws {
        let holder = try theHolder()
        let credential = UsageIngestCredential(token: usageToken, headersFilePath: "/nonexistent/x")
        XCTAssertNil(holder.credential)
        holder.set(credential)
        XCTAssertEqual(holder.credential, credential)
        holder.set(nil)
        XCTAssertNil(holder.credential)
    }

    // MARK: - UsageIngestMonitor

    func test_monitor_acceptedRequest_recordsItsTime() throws {
        let monitor = try theMonitor()
        let date = Date(timeIntervalSince1970: 1_000)
        monitor.note(nil, at: date)
        XCTAssertEqual(monitor.lastAcceptedAt, date)
        XCTAssertNil(monitor.lastRejection)
    }

    func test_monitor_keepsTheRefusalsAnExporterCanCause() throws {
        let monitor = try theMonitor()
        let reasons: [UsageIngestRejection] = [.unauthorized, .tooLarge, .undecodable, .unavailable]
        for (offset, reason) in reasons.enumerated() {
            let date = Date(timeIntervalSince1970: 2_000 + Double(offset))
            monitor.note(reason, at: date)
            let stored = try XCTUnwrap(UsageIngestMonitor.ExporterRejection(reason), "\(reason)")
            XCTAssertEqual(monitor.lastRejection, UsageIngestMonitor.Rejection(reason: stored, at: date), "\(reason)")
        }
        XCTAssertNil(monitor.lastAcceptedAt)
    }

    func test_monitor_ignoresAForeignOriginAndAMissingBody() throws {
        let monitor = try theMonitor()
        let accepted = Date(timeIntervalSince1970: 1_000)
        let refused = Date(timeIntervalSince1970: 1_001)
        monitor.note(nil, at: accepted)
        monitor.note(.unauthorized, at: refused)

        monitor.note(.foreignOrigin, at: Date(timeIntervalSince1970: 1_002))
        monitor.note(.noBody, at: Date(timeIntervalSince1970: 1_003))

        XCTAssertEqual(monitor.lastAcceptedAt, accepted)
        XCTAssertEqual(monitor.lastRejection, UsageIngestMonitor.Rejection(reason: .unauthorized, at: refused))
    }

    // MARK: - The telemetry activation (R4b)

    private let waitSeconds: TimeInterval = 30

    /// A per-test activation over fakes, kept alive for the test.
    private func fakeActivation(
        _ inputs: UsageTelemetryFakeInputs, _ effects: UsageTelemetryFakeEffects,
        _ counter: UsageTelemetryStatusChangeCounter
    ) -> UsageTelemetryActivation {
        let activation = UsageTelemetryActivation(
            inputs: inputs.inputs, effects: effects.effects, onStatusChange: counter.onStatusChange)
        activations.append(activation)
        return activation
    }

    // The startup task returns only after exactly one reconcile ran.
    func test_startUsageLedger_awaitsExactlyOneReconcile() async throws {
        fixture.tracking.set(false)
        let inputs = UsageTelemetryFakeInputs()
        inputs.trackingOn = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)

        start(makeLedger(), activation: activation)
        await awaitStartups()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(effects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .removed)
    }

    // The startup no longer loads the credential or syncs tracking on
    // its own: with an activation that may not touch agent files, nothing
    // is loaded or created, even with tracking on.
    func test_startUsageLedger_loadsNoCredentialItself_onlyThroughTheActivation() async throws {
        let holder = try theHolder()
        let inputs = UsageTelemetryFakeInputs()
        inputs.mayTouchAgentFiles = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)
        let ledger = makeLedger()

        start(ledger, activation: activation)
        await awaitStartups()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(effects.calls, [])
        XCTAssertNil(holder.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory))
        await settle(ledger)
    }

    // A posted `.calyxIPCStateDidChange` requests another reconcile,
    // which reads the inputs afresh.
    func test_ipcStateDidChange_requestsAnotherReconcile() async throws {
        fixture.tracking.set(false)
        let inputs = UsageTelemetryFakeInputs()
        inputs.trackingOn = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)
        start(makeLedger(), activation: activation)
        await awaitStartups()
        XCTAssertEqual(counter.count, 1, "Fixture error")

        inputs.trackingOn = true
        inputs.serverPort = 41830
        let second = expectation(description: "a second reconcile ran")
        counter.expect(2, fulfilling: second)
        NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
        await fulfillment(of: [second], timeout: waitSeconds)

        XCTAssertEqual(
            effects.calls,
            [.remove, .syncTracking, .loadCredential(create: false),
             .syncTracking, .loadCredential(create: true),
             .install(port: 41830, headersFilePath: UsageTelemetryFakeEffects.headersFilePath)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    // MARK: - UsageIngestMonitor.ExporterRejection (R4b)

    func test_exporterRejection_mapsTheFourRefusalsAnExporterCanCause() {
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.unauthorized), .unauthorized)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.tooLarge), .tooLarge)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.undecodable), .undecodable)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.unavailable), .unavailable)
    }

    func test_exporterRejection_isNilForWhatNoExporterCauses() {
        XCTAssertNil(UsageIngestMonitor.ExporterRejection(.foreignOrigin))
        XCTAssertNil(UsageIngestMonitor.ExporterRejection(.noBody))
    }

    // The stored reason has the narrowed type (a compile-time pin).
    func test_rejectionReason_isAnExporterRejection() throws {
        let monitor = try theMonitor()
        monitor.note(.tooLarge, at: Date(timeIntervalSince1970: 3_000))
        let reason: UsageIngestMonitor.ExporterRejection? = monitor.lastRejection?.reason
        XCTAssertEqual(reason, .tooLarge)
    }
}
