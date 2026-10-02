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
//  (C) the real action writes the setting both ways. Turning it ON also
//      reconciles the ledger (a stored session whose transcript gained
//      lines is read without any hook event), at a priority no higher
//      than utility; turning it OFF does not.
//
//  (C) never reaches the app's ledger: the controller's
//  `_usageLedgerForTesting` seam is pointed at a test ledger over a
//  per-test temporary directory, and is reset in tearDown. That ledger
//  is always enabled on purpose, so a handler that reconciled on OFF
//  would be seen instead of being hidden by the ledger's own check of
//  the setting. The setting lives in a test suite; UserDefaults.standard
//  is checked to be untouched.
//
//  The handler starts the reconcile without waiting for it, so the ON
//  half waits for the ledger's publish through an expectation (bound:
//  UsageWiringFixture.waitSeconds, reached only on failure). The OFF
//  half closes the ledger behind every task started so far
//  (UsageWiringFixture.closeBehindEverythingStarted), so a wrongly
//  started reconcile has run before the test asserts that none did. In
//  both halves the handler's reconcile is the only possible source of a
//  read, which is why exact publish lists are asserted.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class UsageTrackingSettingsToggleWiringTests: XCTestCase {

    private typealias Fixture = UsageWiringFixture

    private let settingsSuiteName = "com.calyx.tests.UsageTrackingSettingsToggleWiringTests"
    private let sessionA = UsageWiringFixture.sessionA

    private var standardDefaultsTripwire: StandardDefaultsTripwire!
    private var fixture: UsageWiringFixture!
    private var recorder: UsagePublishRecorder!
    private var ledgers: [UsageLedger] = []

    override func setUp() async throws {
        try await super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: UsageTrackingSettings.enabledKey)
        UsageTrackingSettings._testUseSuite(named: settingsSuiteName)
        fixture = try UsageWiringFixture.make(label: "UsageTrackingSettingsToggleWiringTests")
        recorder = UsagePublishRecorder()
    }

    override func tearDown() async throws {
        SettingsWindowController.shared._usageLedgerForTesting = nil
        await fixture?.shutDown(ledgers)
        ledgers = []
        fixture = nil
        recorder = nil
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

    private func entry(_ responses: Int64) -> UsagePublishRecorder.Entry {
        UsagePublishRecorder.Entry(sessionID: sessionA, row: Fixture.totalRow(responses))
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
            "Records Claude Code token usage per model and effort from its transcripts. Only numbers and labels "
                + "are stored, never conversation text. Needs AI Agent IPC.")
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
        // A ledger with tracking off: the reconcile the handler starts
        // does nothing whenever it runs.
        fixture.tracking.set(false)
        let ledger = fixture.makeLedger(recorder: recorder)
        ledgers.append(ledger)
        SettingsWindowController.shared._usageLedgerForTesting = ledger
        let toggleSwitch = try usageTrackingSwitch()

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(UsageTrackingSettings.enabled)

        flip(toggleSwitch, to: .off)
        XCTAssertFalse(UsageTrackingSettings.enabled)

        flip(toggleSwitch, to: .on)
        XCTAssertTrue(UsageTrackingSettings.enabled)
        flip(toggleSwitch, to: .off)
    }

    /// A ledger behind the controller's seam that has stored `sessionA`,
    /// whose transcript then gained a line that no hook event announced.
    private func ledgerWithAStoredSessionThatGainedALine() async throws -> UsageLedger {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let ledger = fixture.makeLedger(recorder: recorder)
        ledgers.append(ledger)
        await ledger.note(fixture.activity("Stop"))
        await ledger.waitUntilIdle()
        XCTAssertEqual(recorder.entries, [entry(1)], "Fixture error")
        try fixture.append([Fixture.assistantLine("msg_m2")], to: fixture.mainPath(sessionA))
        SettingsWindowController.shared._usageLedgerForTesting = ledger
        return ledger
    }

    func test_usageTrackingDidChange_on_reconcilesAtUtilityPriorityOrLower() async throws {
        // Catching up is background work and must not run at the
        // priority of the main thread handling the click. Nothing awaits
        // the handler's task (the wait is an expectation), so nothing
        // can raise the priority the ingest observes.
        _ = try await ledgerWithAStoredSessionThatGainedALine()
        XCTAssertGreaterThan(
            Task.currentPriority, .utility,
            "Fixture error: the caller must run above utility, or an inherited priority would pass")
        let seedIngests = recorder.ingestPriorities.count
        let toggleSwitch = try usageTrackingSwitch()

        let reconciled = expectation(description: "turning tracking on read the appended line")
        recorder.expect(count: 2, fulfilling: reconciled)
        flip(toggleSwitch, to: .on)
        await fulfillment(of: [reconciled], timeout: Fixture.waitSeconds)

        let priorities = Array(recorder.ingestPriorities.dropFirst(seedIngests))
        XCTAssertEqual(priorities.count, 1)
        for priority in priorities {
            XCTAssertLessThanOrEqual(priority, .utility)
        }
        flip(toggleSwitch, to: .off)
    }

    func test_usageTrackingDidChange_on_reconcilesTheLedger_andOffDoesNot() async throws {
        let ledger = try await ledgerWithAStoredSessionThatGainedALine()
        let toggleSwitch = try usageTrackingSwitch()

        let reconciled = expectation(description: "turning tracking on read the appended line")
        recorder.expect(count: 2, fulfilling: reconciled)
        flip(toggleSwitch, to: .on)

        XCTAssertTrue(UsageTrackingSettings.enabled)
        await fulfillment(of: [reconciled], timeout: Fixture.waitSeconds)
        await ledger.waitUntilIdle()
        XCTAssertEqual(recorder.entries, [entry(1), entry(2)])

        // Turning it off leaves the next appended line unread.
        try fixture.append([Fixture.assistantLine("msg_m3")], to: fixture.mainPath(sessionA))
        flip(toggleSwitch, to: .off)

        XCTAssertFalse(UsageTrackingSettings.enabled)
        await fixture.closeBehindEverythingStarted(ledger, in: self)
        XCTAssertEqual(recorder.entries, [entry(1), entry(2)])
        let stored = try await fixture.readStore {
            try await $0.report(UsageQuery(sessionID: Fixture.sessionA), calendar: Fixture.utc)
        }
        XCTAssertEqual(stored, [Fixture.totalRow(2)], "stored data stays, and nothing was added")
    }
}
