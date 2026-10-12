//
//  IPCWakeSettingsToggleWiringTests.swift
//  CalyxTests
//
//  Covers the IPC wake row of the Settings window's Agents pane: the
//  switch for IPCWakeSettings.enabled, which gates waking an idle Claude
//  Code pane when its bound peer has messages it has not been told about.
//  Same parts as UsageTrackingSettingsToggleWiringTests:
//
//  (A) the row: SettingsRow.ipcWake sits directly after agentIPC on the
//      Agents pane and has no section heading of its own (it continues
//      the "AI Agent IPC" group), its accessibility identifier, its
//      label, and the switch with its target and action, found by
//      identifier in the real SettingsWindowController.shared view tree;
//  (B) sessionToggleInitialState(for: .ipcWake) reads
//      IPCWakeSettings.enabled live;
//  (C) the real action writes the setting both ways;
//  (D) turning the switch off releases every waiting /ipc-wake long-poll,
//      after the setting was written, and turning it on releases nothing.
//      Pinned twice: through the controller's `_ipcWakeReleaseForTesting`
//      seam (call count and order), and with no seam set against
//      `CalyxMCPServer.shared.ipcWakeCoordinator`, the coordinator the
//      app's own /ipc-wake route waits on.
//
//  The setting lives in a test suite; UserDefaults.standard is checked to
//  be untouched. tearDown resets the seam, sets the shared switch back to
//  off and releases every waiter of the shared coordinator, so nothing of
//  this class outlives it.
//
//  Every test that invokes the handler first obtains the real switch by
//  its accessibility identifier with XCTUnwrap: while the row has no
//  switch the test fails there, and the handler's selector is never sent
//  to a controller that might not respond to it.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class IPCWakeSettingsToggleWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.IPCWakeSettingsToggleWiringTests"
    private let rowLabel = "Wake Claude Code on IPC messages"
    private let handlerSelectorName = "ipcWakeDidChange:"

    private var standardDefaultsTripwire: StandardDefaultsTripwire!

    override func setUp() async throws {
        try await super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: IPCWakeSettings.enabledKey)
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() async throws {
        SettingsWindowController.shared._ipcWakeReleaseForTesting = nil
        // The switch belongs to the shared controller and outlives this
        // class: a test that failed between turning it on and off would
        // leave it on. Only the control's state is reset; the handler is
        // not sent.
        if let toggleSwitch = try? ipcWakeSwitches().first {
            toggleSwitch.state = .off
        }
        // A waiter a test of this class registered returns nil here at
        // the latest, whatever that test's outcome was.
        CalyxMCPServer.shared.ipcWakeCoordinator.releaseAllWaiters()
        IPCWakeSettings.enabled = false
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        standardDefaultsTripwire.assertUnchanged()
        standardDefaultsTripwire = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func agentsPaneView() throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let agentsIndex = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: .agents))
        let tabItem = tabViewController.tabViewItems[agentsIndex]
        return try XCTUnwrap(tabItem.viewController?.view, "The Agents tab item must host a real view controller")
    }

    /// Every view of type `Kind` below `view`, depth first.
    private func descendants<Kind: NSView>(of view: NSView, as kind: Kind.Type) -> [Kind] {
        view.subviews.flatMap { subview in
            ((subview as? Kind).map { [$0] } ?? []) + descendants(of: subview, as: kind)
        }
    }

    private func ipcWakeSwitches() throws -> [NSSwitch] {
        descendants(of: try agentsPaneView(), as: NSSwitch.self).filter {
            $0.accessibilityIdentifier() == AccessibilityID.Settings.ipcWakeSwitch
        }
    }

    private func ipcWakeSwitch() throws -> NSSwitch {
        try XCTUnwrap(
            try ipcWakeSwitches().first,
            "the Agents pane has no switch with the ipcWakeSwitch accessibility identifier")
    }

    /// Sets the switch as a click would and sends its handler. Takes the
    /// real switch, so a caller has unwrapped it before the selector is
    /// sent (see the file header).
    private func flip(_ toggleSwitch: NSSwitch, to state: NSControl.StateValue) {
        toggleSwitch.state = state
        _ = SettingsWindowController.shared.perform(NSSelectorFromString(handlerSelectorName), with: toggleSwitch)
    }

    /// What the release seam saw: how often it ran, and the setting's
    /// value each time it did.
    @MainActor
    private final class ReleaseRecorder {
        private(set) var settingAtEachCall: [Bool] = []

        func record() {
            settingAtEachCall.append(IPCWakeSettings.enabled)
        }
    }

    /// Lets the main actor's other work run until `condition` holds.
    /// Returns false when it still does not after `seconds` (reached only
    /// on failure).
    private func waitUntil(seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    // MARK: - (A) The row

    func test_ipcWakeRow_isOnTheAgentsPane_directlyAfterAgentIPC_withNoHeadingOfItsOwn() throws {
        XCTAssertEqual(SettingsRow.ipcWake.pane, .agents, "the IPC wake row belongs to the Agents pane")

        let agentsRows = SettingsRow.allCases.filter { $0.pane == .agents }
        XCTAssertEqual(agentsRows.first, .agentIPC, "Fixture error: agentIPC is the Agents pane's first row")
        XCTAssertEqual(
            agentsRows.firstIndex(of: .ipcWake), 1,
            "ipcWake must be the Agents pane's second row, directly after agentIPC, whose group it continues")

        XCTAssertNil(
            SettingsWindowController.sectionHeading(for: .ipcWake),
            "ipcWake has no heading of its own: a heading would start a new section, with a divider, "
                + "instead of continuing the \"AI Agent IPC\" group")
    }

    func test_accessibilityIdentifier_isTheExactLiteral() {
        XCTAssertEqual(AccessibilityID.Settings.ipcWakeSwitch, "calyx.settings.agents.ipcWakeSwitch")
    }

    func test_ipcWakeSwitch_existsOnceWithTargetAndActionWired() throws {
        let switches = try ipcWakeSwitches()

        XCTAssertEqual(
            switches.count, 1,
            "the Agents pane must hold exactly one switch with the ipcWakeSwitch accessibility identifier")
        let toggleSwitch = try XCTUnwrap(switches.first)
        XCTAssertTrue(
            toggleSwitch.target === SettingsWindowController.shared,
            "the IPC wake switch must have SettingsWindowController.shared as its target, or a click reaches no handler")
        XCTAssertEqual(
            toggleSwitch.action, NSSelectorFromString(handlerSelectorName),
            "the IPC wake switch's action must be ipcWakeDidChange:")
    }

    func test_ipcWakeRow_isLabelled() throws {
        let labels = descendants(of: try agentsPaneView(), as: NSTextField.self).map(\.stringValue)

        XCTAssertEqual(
            labels.filter { $0 == rowLabel }.count, 1,
            "the Agents pane must show the label \"\(rowLabel)\" exactly once")
    }

    // MARK: - (B) Initial state

    func test_sessionToggleInitialState_ipcWake_readsTheSettingLive() {
        IPCWakeSettings.enabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .ipcWake))

        IPCWakeSettings.enabled = true
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .ipcWake),
            "the switch's initial state must be read from IPCWakeSettings.enabled at the time of the call")

        IPCWakeSettings.enabled = false
        XCTAssertFalse(
            SettingsWindowController.sessionToggleInitialState(for: .ipcWake),
            "the state must follow the setting back to off, not remember an earlier read")
    }

    // MARK: - (C) The action writes the setting

    func test_ipcWakeDidChange_writesTheSetting_onAndOff() throws {
        let toggleSwitch = try ipcWakeSwitch()
        // No waiter exists in this test; the seam only keeps the shared
        // coordinator out of it.
        SettingsWindowController.shared._ipcWakeReleaseForTesting = {}
        XCTAssertFalse(IPCWakeSettings.enabled, "Fixture error: a fresh suite has the setting off")

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(IPCWakeSettings.enabled, "turning the switch on must write IPCWakeSettings.enabled = true")

        flip(toggleSwitch, to: .off)
        XCTAssertFalse(IPCWakeSettings.enabled, "turning the switch off must write IPCWakeSettings.enabled = false")
    }

    // MARK: - (D) Turning the switch off releases the waiting polls

    func test_ipcWakeDidChange_releasesThroughTheSeam_onlyWhenTurnedOff_afterWritingTheSetting() throws {
        let toggleSwitch = try ipcWakeSwitch()
        let recorder = ReleaseRecorder()
        SettingsWindowController.shared._ipcWakeReleaseForTesting = { recorder.record() }

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(IPCWakeSettings.enabled, "Fixture error: the handler did not write the setting")
        XCTAssertEqual(
            recorder.settingAtEachCall, [],
            "turning the switch on must release nothing: the polls that are waiting are the ones to wake")

        flip(toggleSwitch, to: .off)
        XCTAssertEqual(
            recorder.settingAtEachCall, [false],
            "turning the switch off must release the waiting polls exactly once, and only after the setting "
                + "was written: a poll released while the setting still reads true could register again")
    }

    // No seam set: the handler's own default must reach the coordinator
    // the app's /ipc-wake route waits on.
    func test_ipcWakeDidChange_withNoSeam_turningOff_releasesTheSharedCoordinatorsWaiters() async throws {
        XCTAssertNil(
            SettingsWindowController.shared._ipcWakeReleaseForTesting, "Fixture error: a release seam is still set")
        let coordinator = CalyxMCPServer.shared.ipcWakeCoordinator
        let surfaceID = UUID()
        let waiter = Task { await coordinator.awaitWake(surfaceID: surfaceID, timeoutMs: 30_000) }
        let registered = await waitUntil(seconds: 5) { coordinator.waitingSurfaceIDs.contains(surfaceID) }
        XCTAssertTrue(registered, "Fixture error: the waiter never registered")
        guard registered else {
            waiter.cancel()
            return
        }
        // Unwrapped only now, so that the fixture above runs whether or
        // not the row has a switch; tearDown releases the waiter if this
        // throws.
        let toggleSwitch = try ipcWakeSwitch()

        flip(toggleSwitch, to: .on)
        // A release hopping through one more main-actor task would have
        // run by the end of these yields.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(
            coordinator.waitingSurfaceIDs.contains(surfaceID),
            "turning the switch on must leave a waiting poll waiting")

        flip(toggleSwitch, to: .off)
        let released = await waitUntil(seconds: 5) { !coordinator.waitingSurfaceIDs.contains(surfaceID) }
        XCTAssertTrue(
            released,
            "turning the switch off must release the shared coordinator's waiters: nothing else ends a poll "
                + "that registered before the setting turned off, short of its own timeout")
        guard released else { return }

        let response = await waiter.value
        XCTAssertNil(response, "a released poll returns nil, which the route answers with 204")
    }
}
