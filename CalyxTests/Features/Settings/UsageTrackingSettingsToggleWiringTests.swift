//
//  UsageTrackingSettingsToggleWiringTests.swift
//  CalyxTests
//
//  Covers the Usage Tracking row of the Settings window's Agents pane,
//  in the three parts of AgentHookApprovalSettingsToggleWiringTests:
//
//  (A) the row: where it sits, its heading and label, and the switch
//      with its target and action, found by accessibility identifier in
//      the real SettingsWindowController.shared view tree;
//  (B) the switch's initial state reads UsageTrackingSettings.enabled
//      live;
//  (C) the real action writes the setting both ways; beyond that a flip
//      only requests the activation reconcile of (E). The setting lives in a test
//      suite; UserDefaults.standard is checked to be untouched.
//
//  R4b: (D) the row's status label (identifier, hidden while its text is
//  empty, the resolver's text otherwise, refreshed when the switch and
//  the IPC state change) and (E) every flip of the switch requests a
//  reconcile of the telemetry activation. The controller's
//  `_usageTelemetryActivationForTesting` seam is pointed at a per-test
//  activation over fakes in setUp (so no flip in this class can reach
//  `UsageTelemetryActivation.shared` or a settings file) and reset in
//  tearDown. The IPC setting lives in a test suite as well.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class UsageTrackingSettingsToggleWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.UsageTrackingSettingsToggleWiringTests"
    private let ipcSuiteName = "com.calyx.tests.UsageTrackingSettingsToggleWiringTests.ipc"

    private var standardDefaultsTripwire: StandardDefaultsTripwire!
    private var activationInputs: UsageTelemetryFakeInputs!
    private var activationEffects: UsageTelemetryFakeEffects!
    private var activationRuns: UsageTelemetryStatusChangeCounter!
    private var activation: UsageTelemetryActivation?

    override func setUp() async throws {
        try await super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: UsageTrackingSettings.enabledKey)
        UsageTrackingSettings._testUseSuite(named: settingsSuiteName)
        IPCSettings._testUseSuite(named: ipcSuiteName)
        activationInputs = UsageTelemetryFakeInputs()
        activationEffects = UsageTelemetryFakeEffects()
        activationRuns = UsageTelemetryStatusChangeCounter()
        let activation = UsageTelemetryActivation(
            inputs: activationInputs.inputs, effects: activationEffects.effects,
            onStatusChange: activationRuns.onStatusChange)
        self.activation = activation
        SettingsWindowController.shared._usageTelemetryActivationForTesting = activation
    }

    override func tearDown() async throws {
        SettingsWindowController.shared._usageTelemetryActivationForTesting = nil
        SettingsWindowController.shared._usageIngestMonitorForTesting = nil
        SettingsWindowController.shared._usageServerRunningForTesting = nil
        // Every reconcile a flip requested has returned once one more
        // run has (single flight), so none outlives this test.
        if let activation { await activation.reconcile() }
        activation = nil
        activationInputs = nil
        activationEffects = nil
        activationRuns = nil
        // The shared controller's AI Agent IPC row read the suite's
        // setting; leave it showing the setting off again.
        IPCSettings.enabled = false
        NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
        IPCSettings._testTeardownSuite(named: ipcSuiteName)
        UsageTrackingSettings._testTeardownSuite(named: settingsSuiteName)
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

    private func usageTrackingSwitches() throws -> [NSSwitch] {
        descendants(of: try agentsPaneView(), as: NSSwitch.self).filter {
            $0.accessibilityIdentifier() == AccessibilityID.Settings.usageTrackingSwitch
        }
    }

    private func usageTrackingSwitch() throws -> NSSwitch {
        try XCTUnwrap(try usageTrackingSwitches().first, "the Agents pane has no usage tracking switch")
    }

    private func flip(_ toggleSwitch: NSSwitch, to state: NSControl.StateValue) {
        toggleSwitch.state = state
        _ = SettingsWindowController.shared.perform(NSSelectorFromString("usageTrackingDidChange:"), with: toggleSwitch)
    }

    // MARK: - (A) The row

    func test_usageTrackingRow_isTheLastRowOfTheAgentsPane_afterAgentHookApproval() {
        XCTAssertEqual(SettingsRow.usageTracking.pane, .agents)
        XCTAssertEqual(
            SettingsRow.allCases.filter { $0.pane == .agents },
            [.agentIPC, .agentResume, .agentResumeAutoExecute, .cockpitAutoApprove, .commandTracking,
             .agentHookApproval, .usageTracking])
    }

    func test_accessibilityIdentifier_isTheExactLiteral() {
        XCTAssertEqual(AccessibilityID.Settings.usageTrackingSwitch, "calyx.settings.agents.usageTrackingSwitch")
    }

    func test_sectionHeading_saysWhatIsStoredAndWhatItNeeds() throws {
        let heading = try XCTUnwrap(SettingsWindowController.sectionHeading(for: .usageTracking))

        XCTAssertEqual(heading.title, "Usage Tracking")
        XCTAssertEqual(
            heading.subtitle,
            "Records Claude Code token usage per model and effort, as counted by Claude Code itself. While this is "
                + "on, Calyx adds telemetry settings to ~/.claude/settings.json so that Claude Code on this Mac sends "
                + "its token counts to Calyx. Only numbers and labels are stored, never conversation text. Needs AI "
                + "Agent IPC.")
    }

    func test_usageTrackingSwitch_existsOnceWithTargetAndActionWired() throws {
        let switches = try usageTrackingSwitches()

        XCTAssertEqual(switches.count, 1)
        let toggleSwitch = try XCTUnwrap(switches.first)
        XCTAssertTrue(toggleSwitch.target === SettingsWindowController.shared)
        XCTAssertEqual(toggleSwitch.action, NSSelectorFromString("usageTrackingDidChange:"))
    }

    func test_usageTrackingRow_isLabelled() throws {
        let labels = descendants(of: try agentsPaneView(), as: NSTextField.self).map(\.stringValue)

        XCTAssertEqual(labels.filter { $0 == "Track Claude Code usage" }.count, 1)
        XCTAssertEqual(labels.filter { $0 == "Usage Tracking" }.count, 1)
    }

    // MARK: - (B) Initial state

    func test_sessionToggleInitialState_usageTracking_readsTheSettingLive() {
        UsageTrackingSettings.enabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .usageTracking))

        UsageTrackingSettings.enabled = true
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .usageTracking),
            "the state must be read from the setting at the time of the call, not remembered")

        UsageTrackingSettings.enabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .usageTracking))
    }

    // MARK: - (C) The action

    func test_usageTrackingDidChange_writesTheSetting_onAndOff() async throws {
        let toggleSwitch = try usageTrackingSwitch()

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(UsageTrackingSettings.enabled)

        flip(toggleSwitch, to: .off)
        XCTAssertFalse(UsageTrackingSettings.enabled)

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(UsageTrackingSettings.enabled)
        flip(toggleSwitch, to: .off)
    }

    // MARK: - (D) The status label (R4b)

    private let waitSeconds: TimeInterval = 30

    /// Every view below `view`, including a stack view's arranged views
    /// that are detached while hidden (`detachesHiddenViews`).
    private func allViews(below view: NSView) -> [NSView] {
        var children = view.subviews
        if let stack = view as? NSStackView {
            children += stack.arrangedSubviews.filter { arranged in !children.contains { $0 === arranged } }
        }
        return children.flatMap { [$0] + allViews(below: $0) }
    }

    private func statusLabels() throws -> [NSTextField] {
        allViews(below: try agentsPaneView()).compactMap { $0 as? NSTextField }.filter {
            $0.accessibilityIdentifier() == AccessibilityID.Settings.usageTrackingStatusLabel
        }
    }

    private func statusLabel() throws -> NSTextField {
        try XCTUnwrap(try statusLabels().first, "the Agents pane has no usage tracking status label")
    }

    func test_statusLabel_accessibilityIdentifier_isTheExactLiteral() {
        XCTAssertEqual(
            AccessibilityID.Settings.usageTrackingStatusLabel, "calyx.settings.agents.usageTrackingStatusLabel")
    }

    func test_statusLabel_existsOnce() throws {
        XCTAssertEqual(try statusLabels().count, 1)
    }

    // Tracking off: the text is empty and the label hidden.
    func test_statusLabel_trackingOff_isHidden() throws {
        let toggleSwitch = try usageTrackingSwitch()

        flip(toggleSwitch, to: .off)

        let label = try statusLabel()
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(label.stringValue, "")
    }

    // Tracking on with the IPC setting off: the resolver's line, shown.
    func test_statusLabel_trackingOnAndIPCOff_showsWhyNothingIsReceived() throws {
        IPCSettings.enabled = false
        let toggleSwitch = try usageTrackingSwitch()

        flip(toggleSwitch, to: .on)

        let label = try statusLabel()
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.stringValue, "Not receiving: AI Agent IPC is off.")
        flip(toggleSwitch, to: .off)
        XCTAssertTrue(try statusLabel().isHidden)
    }

    // The label follows the IPC state: the setting turned on (the test
    // host's shared server is never started) and the change posted.
    func test_statusLabel_isRefreshedWhenTheIPCStateChanges() throws {
        IPCSettings.enabled = false
        let toggleSwitch = try usageTrackingSwitch()
        flip(toggleSwitch, to: .on)
        XCTAssertEqual(try statusLabel().stringValue, "Not receiving: AI Agent IPC is off.", "Fixture error")

        IPCSettings.enabled = true
        NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)

        XCTAssertEqual(try statusLabel().stringValue, "Not receiving: The IPC server is not running.")
        XCTAssertFalse(try statusLabel().isHidden)
        IPCSettings.enabled = false
        flip(toggleSwitch, to: .off)
    }

    // MARK: - (E) The switch requests a reconcile (R4b)

    func test_flip_requestsAReconcile_onAndOff() async throws {
        activationInputs.trackingOn = true
        activationInputs.ipcEnabled = false
        let toggleSwitch = try usageTrackingSwitch()

        let first = expectation(description: "turning tracking on requested a reconcile")
        activationRuns.expect(1, fulfilling: first)
        flip(toggleSwitch, to: .on)
        await fulfillment(of: [first], timeout: waitSeconds)
        XCTAssertTrue(UsageTrackingSettings.enabled, "the setting is written before the reconcile is requested")

        let second = expectation(description: "turning tracking off requested a reconcile")
        activationRuns.expect(2, fulfilling: second)
        flip(toggleSwitch, to: .off)
        await fulfillment(of: [second], timeout: waitSeconds)

        XCTAssertEqual(
            activationEffects.calls,
            [.remove, .syncTracking, .loadCredential(create: false),
             .remove, .syncTracking, .loadCredential(create: false)])
    }

    // MARK: - (D) Refresh channels (R4b)

    /// Tracking on, IPC on, the server taken as running: from here on
    /// only the activation's status and the monitor decide the line.
    private func everythingOn() throws -> UsageTelemetryActivation {
        UsageTrackingSettings.enabled = true
        IPCSettings.enabled = true
        SettingsWindowController.shared._usageServerRunningForTesting = true
        SettingsWindowController.shared._usageIngestMonitorForTesting = UsageIngestMonitor()
        return try XCTUnwrap(activation, "Fixture error: no activation")
    }

    private let waitingText =
        "Waiting for Claude Code. Sessions that were already running when tracking was turned on report after "
        + "they are restarted."

    // The settings were written directly (no switch, so no request of the
    // controller's own): only the notification can refresh the label.
    func test_statusLabel_isRefreshedOnTheTelemetryStatusNotification() async throws {
        let activation = try everythingOn()
        NotificationCenter.default.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
        XCTAssertEqual(try statusLabel().stringValue, "Setting up\u{2026}", "Fixture error")

        activationInputs.trackingOn = true
        activationInputs.ipcEnabled = true
        activationInputs.serverPort = 41830
        await activation.reconcile()
        XCTAssertEqual(activation.status, .installed(port: 41830), "Fixture error")
        XCTAssertEqual(try statusLabel().stringValue, "Setting up\u{2026}", "Fixture error: refreshed without a post")

        NotificationCenter.default.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)

        XCTAssertEqual(try statusLabel().stringValue, waitingText)
        XCTAssertFalse(try statusLabel().isHidden)
        UsageTrackingSettings.enabled = false
    }

    /// Waits until the label's text satisfies `condition` (bound:
    /// `waitSeconds`, reached only on failure). The monitor's change is
    /// delivered by observation, after the change returns.
    private func waitForLabel(_ description: String, _ condition: @escaping @MainActor (String) -> Bool) async throws {
        let label = try statusLabel()
        let changed = expectation(
            for: NSPredicate { _, _ in MainActor.assumeIsolated { condition(label.stringValue) } },
            evaluatedWith: nil)
        changed.expectationDescription = description
        await fulfillment(of: [changed], timeout: waitSeconds)
    }

    // Two changes in a row: the observation is armed again after the first.
    func test_statusLabel_followsTheMonitor_acrossSuccessiveChanges() async throws {
        let activation = try everythingOn()
        activationInputs.serverPort = 41830
        await activation.reconcile()
        NotificationCenter.default.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
        XCTAssertEqual(try statusLabel().stringValue, waitingText, "Fixture error")
        let monitor = try XCTUnwrap(SettingsWindowController.shared._usageIngestMonitorForTesting)

        monitor.note(nil, at: Date(timeIntervalSince1970: 1_000_000))
        try await waitForLabel("an accepted export shows") { $0.hasPrefix("Receiving. Last export at ") }

        monitor.note(.unauthorized, at: Date(timeIntervalSince1970: 1_000_060))
        try await waitForLabel("a later refusal shows") {
            $0.hasPrefix("The last export (")
                && $0.hasSuffix(
                    ") was refused: its token was not accepted. Restart that Claude Code session if this continues.")
        }
        UsageTrackingSettings.enabled = false
    }

    // The label's time is the resolver's one time format, for the
    // monitor's own date (no locale-specific literal).
    func test_statusLabel_receiving_showsTheMonitorsDate_inTheDefaultTimeFormat() async throws {
        let activation = try everythingOn()
        activationInputs.serverPort = 41830
        await activation.reconcile()
        NotificationCenter.default.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
        let monitor = try XCTUnwrap(SettingsWindowController.shared._usageIngestMonitorForTesting)
        let accepted = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = "Receiving. Last export at \(UsageTelemetryStatusResolver.defaultTime(accepted))."

        monitor.note(nil, at: accepted)
        try await waitForLabel("the accepted export shows") { $0 == expected }

        XCTAssertEqual(try statusLabel().stringValue, expected)
        UsageTrackingSettings.enabled = false
    }
}
