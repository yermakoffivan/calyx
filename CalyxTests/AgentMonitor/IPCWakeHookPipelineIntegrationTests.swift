//
//  IPCWakeHookPipelineIntegrationTests.swift
//  CalyxTests
//
//  Mock-less, end-to-end coverage for the calyx-ipc-wake-hook pipeline:
//  the real INSTALLED script, run as a real child `/bin/sh` process, whose
//  real `curl` long-polls `POST /ipc-wake` on a real `CalyxMCPServer`
//  bound to a real loopback port, with the child's exit code, stdout and
//  stderr asserted directly. Same harness as
//  ApprovalHookPipelineIntegrationTests (temp HOME, random preferred
//  port, isolated agentEndpointDirectory, isolated settings suite).
//
//  Each layer has its own coverage elsewhere: IPCWakeHookScriptTests pins
//  the script's text and drives it against a fake curl,
//  CalyxMCPServerIPCWakeTests drives the route through `route(request:)`
//  with no listener. This file exists for what neither can see: whether
//  the headers the real curl sends are the ones the server reads, whether
//  the body the server answers is the one the script recognises, and
//  whether a script or curl that dies mid-poll releases the server's
//  waiter over a real connection.
//
//  Nothing on the script's PATH is replaced: curl, sh, mktemp and every
//  other command are the system's own. The script creates its temp file
//  with `mktemp "${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX"`, so the child's
//  TMPDIR is set to a directory this test owns, fresh and empty per test
//  (its path contains a space, as a real TMPDIR may), which is how these
//  tests see that the script's temp file exists while it polls and is
//  gone once it has exited.
//
//  Coverage:
//  - a message already waiting: exit 2, stderr equal to the note, stdout
//    empty, no temp file left
//  - a message sent by a `send_message` tools/call while the script is
//    polling: exit 2 with the note
//  - a message put straight into the started server's store while the
//    script is polling: exit 2 with the note
//  - the same message never wakes twice: after the wake it is nudged, and
//    a second run exits 0 silently
//  - setting off: exit 0 at once, no waiter, the message stays un-nudged;
//    turning the setting on then wakes for that same message
//  - setting turned off and every waiter released while the script is
//    polling: exit 0 within 5 s, silent, no temp file left, no waiter; a
//    message delivered afterwards does not wake a second run and stays
//    un-nudged
//  - a stale agent-endpoint.json pointing at a closed port: exit 0, silent
//  - SIGTERM, SIGHUP, SIGINT to the script mid-poll: its curl is gone, the
//    server's waiter is released, the script exits 0 with nothing on
//    stdout or stderr, and the one temp file it held while polling is
//    gone. The signal is sent after the script's stdin was closed, and
//    the child does not start with SIGINT ignored (both through
//    `HookScriptProcessTree.startHookScript`)
//  - SIGKILL to the script's curl mid-poll: the waiter is released, the
//    script exits 0 with nothing on stdout, and the one temp file it held
//    while polling is gone
//
//  Synchronisation: a poll that must stay open gets a 30 s server timeout,
//  and "released" is asserted within 5 s, so a release caused by the event
//  under test cannot be confused with the timeout. Conditions are awaited
//  by polling with a deadline.
//

import XCTest
import Darwin
@testable import Calyx

/// What the script is handed on stdin. File-scope for the same reason as
/// ApprovalHookPipelineIntegrationTests' own stdin constant: a detached
/// Task can read it without this file's `@MainActor` test case.
private let wakeHookStdin = #"{"hook_event_name":"Stop","session_id":"claude-1"}"#

@MainActor
final class IPCWakeHookPipelineIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var tempHome: String!
    private var appSupportDir: String!
    private var scriptPath: String!
    /// The script's TMPDIR, where it creates its temp file. Empty at the
    /// start of every test.
    private var scriptTempDir: String!
    private let testToken = "ipc-wake-hook-pipeline-test-token"
    private let settingsSuiteName = "com.calyx.tests.IPCWakeHookPipelineIntegrationTests"

    /// Timeout of every poll that is ended by an event other than its
    /// timeout.
    private let longTimeoutMs = 30_000
    /// Upper bound for "ended because of the event, not the 30 s timeout".
    private let promptBound: TimeInterval = 5.0

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
        IPCWakeSettings.enabled = true

        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        appSupportDir = tempHome + "/Library/Application Support/Calyx"
        try FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        server = CalyxMCPServer(agentEndpointDirectory: appSupportDir)
        registry = AgentRegistry()
        server.agentRegistry = registry
        // Same isolation from the shared singletons as
        // CalyxMCPServerIPCWakeTests.setUp.
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server.ipcWakeTimeoutMs = longTimeoutMs
        // Randomized preferred port, same rationale as
        // ApprovalHookPipelineIntegrationTests.setUp.
        try await server.start(token: testToken, preferredPort: Int.random(in: 49_152...65_000))

        scriptPath = try IPCWakeHookScript.install(toDirectory: appSupportDir + "/bin")

        scriptTempDir = tempHome + "/script tmp"
        try FileManager.default.createDirectory(atPath: scriptTempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // stop() releases every waiter and closes every connection, so a
        // script still polling after a failed assertion ends here.
        server.stop()
        server = nil
        registry = nil
        if let tempHome {
            try? FileManager.default.removeItem(atPath: tempHome)
        }
        tempHome = nil
        scriptTempDir = nil
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Running the script

    private typealias ScriptResult = HookScriptProcessTree.ScriptResult

    /// Starts the installed script as a real child process
    /// (`/bin/sh <script>`, no kind argument, as Claude Code's own hook
    /// entry invokes it) through the shared
    /// `HookScriptProcessTree.startHookScript`, with exactly HOME, the
    /// inherited PATH, TMPDIR and CALYX_SURFACE_ID in its environment.
    private nonisolated static func startWakeScript(
        scriptPath: String, home: String, tmpDir: String, surfaceID: UUID
    ) throws -> HookScriptProcessTree.RunningScript {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        return try HookScriptProcessTree.startHookScript(
            scriptPath: scriptPath,
            environment: [
                "HOME": home, "PATH": inheritedPath, "TMPDIR": tmpDir,
                "CALYX_SURFACE_ID": surfaceID.uuidString,
            ],
            stdin: wakeHookStdin
        )
    }

    /// Starts the script for `surfaceID` against this test's server.
    private func startScript(for surfaceID: UUID) throws -> HookScriptProcessTree.RunningScript {
        try Self.startWakeScript(
            scriptPath: scriptPath, home: tempHome, tmpDir: scriptTempDir, surfaceID: surfaceID
        )
    }

    /// Runs the script for `surfaceID` to completion.
    private func runScript(for surfaceID: UUID) async throws -> ScriptResult {
        let running = try startScript(for: surfaceID)
        return await running.result.value
    }

    /// The entries of the script's TMPDIR.
    private func scriptTempEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scriptTempDir)
    }

    // MARK: - Store and waiting helpers

    /// A recipient peer bound to a fresh surface, and a sender peer, both
    /// registered straight in the store.
    private func makeBoundRecipientAndSender() async -> (surface: UUID, recipient: UUID, sender: UUID) {
        let sender = await server.store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await server.store.registerPeer(name: "recipient", role: "terminal").id
        let surface = UUID()
        registry.bindSurface(surface, toPeer: recipient)
        return (surface, recipient, sender)
    }

    /// Delivers one message straight through the store. The server was
    /// started, so the store's inbox sink requests a check for it.
    private func deliverInStore(from sender: UUID, to recipient: UUID) async throws {
        _ = try await server.store.sendMessage(from: sender, to: recipient, content: "hello")
    }

    /// The note for one new message from one peer, the only message in
    /// the inbox.
    private func noteForOneNewMessage(to recipient: UUID) -> String {
        IPCWakeResponse(
            peerID: recipient, ticket: IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)
        ).note
    }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Whether the server registered a waiter for `surfaceID` within 5 s:
    /// the script's real request has arrived and is being held open.
    private func waitForWaitingPoll(_ surfaceID: UUID) async -> Bool {
        await waitUntil(timeout: 5.0) { self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID) }
    }

    /// Whether the waiter for `surfaceID` is gone within `promptBound`.
    private func waitForPollReleased(_ surfaceID: UUID) async -> Bool {
        await waitUntil(timeout: promptBound) {
            !self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID)
        }
    }

    // MARK: - A message is already waiting

    func test_messageAlreadyWaiting_exitsTwo_printsTheExactNoteOnStderr() async throws {
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()
        try await deliverInStore(from: sender, to: recipient)

        let result = try await runScript(for: surface)

        XCTAssertEqual(result.exitCode, 2, "a pane whose peer has an unannounced message must be woken")
        XCTAssertEqual(result.stderr, noteForOneNewMessage(to: recipient),
                       "stderr must be the server's note byte for byte: 1 new message from 1 peer")
        XCTAssertEqual(result.stdout, "", "nothing is ever printed on stdout")
        XCTAssertEqual(try scriptTempEntries(), [String](),
                       "the script's temp file must be gone once it has exited with 2")
    }

    // MARK: - A message arrives mid-poll

    func test_messageSentByToolCallWhileScriptIsPolling_exitsTwo_printsTheExactNote() async throws {
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()

        let running = try startScript(for: surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "the script's real request must be held open by the server as a waiter")

        // A real tools/call through route(request:): the message it
        // delivers must wake the waiting poll.
        let rpc: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "send_message",
                "arguments": ["from": sender.uuidString, "to": recipient.uuidString, "content": "hi"],
            ] as [String: Any],
        ]
        let response = await server.route(request: HTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["Authorization": "Bearer \(testToken)"],
            body: try JSONSerialization.data(withJSONObject: rpc)
        ))
        XCTAssertEqual(response.statusCode, 200, "precondition: the send_message tools/call was accepted")
        let responseJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(response.body)) as? [String: Any]
        )
        let rpcResult = try XCTUnwrap(responseJSON["result"] as? [String: Any],
                                      "precondition: send_message returned a result, got \(responseJSON)")
        XCTAssertFalse(rpcResult["isError"] as? Bool ?? false,
                       "precondition: send_message succeeded, got \(rpcResult)")

        let result = await running.result.value

        XCTAssertEqual(result.exitCode, 2, "a message that arrives during the poll must wake the pane")
        XCTAssertEqual(result.stderr, noteForOneNewMessage(to: recipient))
        XCTAssertEqual(result.stdout, "")
    }

    /// The trigger follows the store, not the transport: a message put
    /// straight into the store of the started server (no tools/call at
    /// all) wakes the polling script. The poll timeout is short so that a
    /// missing trigger fails as an exit 0 after 3 s, not a 30 s hang.
    func test_messageDeliveredStraightIntoTheStoreWhileScriptIsPolling_exitsTwo() async throws {
        server.ipcWakeTimeoutMs = 3_000
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()

        let running = try startScript(for: surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "the script's real request must be held open by the server as a waiter")

        try await deliverInStore(from: sender, to: recipient)
        let result = await running.result.value

        XCTAssertEqual(result.exitCode, 2,
                       "a message that reaches the store by any path must wake the polling pane: the store " +
                       "itself reports the inbox growth")
        XCTAssertEqual(result.stderr, noteForOneNewMessage(to: recipient))
        XCTAssertEqual(result.stdout, "")
    }

    // MARK: - Each message wakes once

    func test_afterAWake_messageIsNudged_andASecondRunExitsZeroSilently() async throws {
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()
        try await deliverInStore(from: sender, to: recipient)

        let first = try await runScript(for: surface)
        XCTAssertEqual(first.exitCode, 2, "the first run is woken for the message")
        XCTAssertEqual(first.stderr, noteForOneNewMessage(to: recipient))

        let flagsAfterWake = await server.store._testNudgedFlags(for: recipient)
        XCTAssertEqual(flagsAfterWake, [true], "the message the pane was woken for is marked as announced")

        // Nothing new arrives, so the second poll can only end by its
        // own timeout: keep that short.
        server.ipcWakeTimeoutMs = 1_000
        let second = try await runScript(for: surface)

        XCTAssertEqual(second.exitCode, 0, "the same message must never wake the pane twice")
        XCTAssertEqual(second.stderr, "", "a run that is not woken prints nothing")
        XCTAssertEqual(second.stdout, "")
    }

    // MARK: - Setting off, then on

    func test_settingOff_exitsZeroAtOnce_thenSettingOnWakesForTheSameMessage() async throws {
        IPCWakeSettings.enabled = false
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()
        try await deliverInStore(from: sender, to: recipient)

        let clock = ContinuousClock()
        let started = clock.now
        let whileOff = try await runScript(for: surface)
        let elapsed = clock.now - started

        XCTAssertEqual(whileOff.exitCode, 0, "with the setting off the pane is never woken")
        XCTAssertEqual(whileOff.stderr, "")
        XCTAssertEqual(whileOff.stdout, "")
        XCTAssertLessThan(elapsed, .seconds(10),
                          "with the setting off the server answers at once, far below the 30 s poll timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [],
                       "with the setting off no waiter is registered")
        let flagsWhileOff = await server.store._testNudgedFlags(for: recipient)
        XCTAssertEqual(flagsWhileOff, [false], "the message was not announced while the setting was off")

        IPCWakeSettings.enabled = true
        let whileOn = try await runScript(for: surface)

        XCTAssertEqual(whileOn.exitCode, 2,
                       "a message that arrived while the setting was off wakes the pane once it is on")
        XCTAssertEqual(whileOn.stderr, noteForOneNewMessage(to: recipient))
        XCTAssertEqual(whileOn.stdout, "")
    }

    // MARK: - Setting turned off while a script is polling

    func test_settingTurnedOffWhileScriptIsPolling_releasesIt_andALaterRunIsNotWoken() async throws {
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()

        let running = try startScript(for: surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "the script's real request must be held open by the server as a waiter")
        XCTAssertEqual(try scriptTempEntries().map { $0.hasPrefix("calyx-ipc-wake.") }, [true],
                       "while it polls the script holds exactly one temp file, so an empty directory " +
                       "afterwards means it was removed")

        // What turning the Settings switch off does, in that order.
        IPCWakeSettings.enabled = false
        server.ipcWakeCoordinator.releaseAllWaiters()

        // The script's result, or nil when it has not exited within
        // `promptBound`.
        let outcome = await withTaskGroup(of: ScriptResult?.self) { group -> ScriptResult? in
            group.addTask { await running.result.value }
            group.addTask { [promptBound] in
                try? await Task.sleep(for: .seconds(promptBound))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let released = try XCTUnwrap(
            outcome,
            "a script whose poll was released must exit within 5 s, well under the 30 s poll timeout")

        XCTAssertEqual(released.exitCode, 0, "a released poll is answered without a note: the script exits 0")
        XCTAssertEqual(released.stdout, "", "nothing is ever printed on stdout")
        XCTAssertEqual(released.stderr, "", "a run that is not woken prints nothing")
        XCTAssertEqual(try scriptTempEntries(), [String](),
                       "the script's temp file must be gone once it has exited after its poll was released")
        XCTAssertFalse(server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface),
                       "the released surface must no longer be waiting")

        // A message arrives while the setting is still off.
        try await deliverInStore(from: sender, to: recipient)

        let clock = ContinuousClock()
        let started = clock.now
        let whileOff = try await runScript(for: surface)
        let elapsed = clock.now - started

        XCTAssertEqual(whileOff.exitCode, 0, "with the setting off the pane is never woken")
        XCTAssertEqual(whileOff.stderr, "", "with the setting off no note is printed")
        XCTAssertEqual(whileOff.stdout, "")
        XCTAssertLessThan(elapsed, .seconds(10),
                          "with the setting off the server answers at once, far below the 30 s poll timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [],
                       "with the setting off no waiter is registered")
        let flagsWhileOff = await server.store._testNudgedFlags(for: recipient)
        XCTAssertEqual(flagsWhileOff, [false], "the message was not announced while the setting was off")
    }

    // MARK: - Server not running (stale endpoint file)

    func test_serverNotRunning_staleEndpointFile_exitsZeroSilently() async throws {
        let (surface, recipient, sender) = await makeBoundRecipientAndSender()
        try await deliverInStore(from: sender, to: recipient)
        // stop() removes agent-endpoint.json; a crash would leave it
        // behind pointing at a dead port, which is rebuilt here by hand
        // (as in ApprovalHookPipelineIntegrationTests).
        let stalePort = server.port
        server.stop()
        try AgentEndpointFile.write(port: stalePort, token: testToken, directory: appSupportDir)

        let result = try await runScript(for: surface)

        XCTAssertEqual(result.exitCode, 0, "a dead port must exit 0: the hook chain is never broken")
        XCTAssertEqual(result.stderr, "", "curl's connection-refused failure is silent")
        XCTAssertEqual(result.stdout, "")
    }

    // MARK: - The script is signalled mid-poll

    /// Starts the script with no message anywhere, waits until the server
    /// holds its poll, sends `signal` to the SCRIPT's own `/bin/sh`
    /// process and asserts that nothing is left behind: its curl is gone,
    /// the server's waiter is released well before the 30 s timeout, the
    /// script exits 0, and the one temp file it held while polling is
    /// gone.
    private func assertSignalToScriptEndsThePoll(
        _ signal: Int32, named signalName: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let surface = UUID()
        let running = try startScript(for: surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "[\(signalName)] the script's real request must be held open by the server",
                      file: file, line: line)
        XCTAssertEqual(try scriptTempEntries().map { $0.hasPrefix("calyx-ipc-wake.") }, [true],
                       "[\(signalName)] while it polls the script holds exactly one temp file, so an " +
                       "empty directory afterwards means it was removed",
                       file: file, line: line)

        let curlPID = await HookScriptProcessTree.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let observedCurlPID = try XCTUnwrap(
            curlPID, "[\(signalName)] must locate the script's own curl before signalling the script",
            file: file, line: line
        )

        XCTAssertEqual(kill(running.pid, signal), 0,
                       "[\(signalName)] must be able to signal the script's own /bin/sh process",
                       file: file, line: line)

        let curlGone = await HookScriptProcessTree.waitUntilProcessGone(pid: observedCurlPID, timeout: 3.0)
        XCTAssertTrue(curlGone,
                      "[\(signalName)] the script's curl must not survive the script as an orphan holding " +
                      "the long-poll open",
                      file: file, line: line)

        let released = await waitForPollReleased(surface)
        XCTAssertTrue(released,
                      "[\(signalName)] the server must release the waiter within 5 s of the connection " +
                      "dropping, well under the 30 s poll timeout",
                      file: file, line: line)

        let result = await running.result.value
        XCTAssertEqual(result.exitCode, 0, "[\(signalName)] a signalled script exits 0", file: file, line: line)
        XCTAssertEqual(result.stdout, "", "[\(signalName)] a signalled script prints nothing on stdout",
                       file: file, line: line)
        XCTAssertEqual(result.stderr, "", "[\(signalName)] a signalled script prints nothing on stderr",
                       file: file, line: line)
        XCTAssertEqual(try scriptTempEntries(), [String](),
                       "[\(signalName)] a signalled script must not leave its temp file behind",
                       file: file, line: line)
    }

    func test_sigtermToScriptMidPoll_killsCurl_releasesWaiter_exitsZero() async throws {
        try await assertSignalToScriptEndsThePoll(SIGTERM, named: "SIGTERM")
    }

    func test_sighupToScriptMidPoll_killsCurl_releasesWaiter_exitsZero() async throws {
        try await assertSignalToScriptEndsThePoll(SIGHUP, named: "SIGHUP")
    }

    func test_sigintToScriptMidPoll_killsCurl_releasesWaiter_exitsZero() async throws {
        let ignored = await HookScriptProcessTree.spawnedChildIgnoresSIGINT()
        XCTAssertEqual(ignored, false,
                       "precondition: a child started by startHookScript must not start with SIGINT ignored, " +
                       "or the script could not trap it and this test would test nothing")
        try await assertSignalToScriptEndsThePoll(SIGINT, named: "SIGINT")
    }

    // MARK: - curl is killed mid-poll

    func test_curlKilledMidPoll_releasesWaiterPromptly_scriptExitsZero() async throws {
        let surface = UUID()
        let running = try startScript(for: surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "the script's real request must be held open by the server")
        XCTAssertEqual(try scriptTempEntries().map { $0.hasPrefix("calyx-ipc-wake.") }, [true],
                       "while it polls the script holds exactly one temp file, so an empty directory " +
                       "afterwards means it was removed")

        let curlPID = await HookScriptProcessTree.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let killPID = try XCTUnwrap(curlPID, "must locate the script's own curl to kill it")

        XCTAssertEqual(kill(killPID, SIGKILL), 0, "must be able to SIGKILL the located curl")

        let released = await waitForPollReleased(surface)
        XCTAssertTrue(released,
                      "killing the script's curl mid-poll must release the server's waiter within 5 s, " +
                      "well under the 30 s poll timeout, instead of leaving it until that timeout")

        let result = await running.result.value
        XCTAssertEqual(result.exitCode, 0, "a killed curl is never a wake: the script exits 0")
        XCTAssertEqual(result.stdout, "")
        // stderr is not asserted here: /bin/sh itself reports the killed
        // background job ("Killed: 9 curl ...") on the script's stderr.
        // Silencing that is the job of slice A-5's leading
        // `exec 3>&2 2>/dev/null`, and is pinned with that slice.
        XCTAssertEqual(try scriptTempEntries(), [String](),
                       "the script's temp file must be gone once it has exited after its curl was killed")
    }
}
