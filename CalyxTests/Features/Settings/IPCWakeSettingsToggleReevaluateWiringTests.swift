//
//  IPCWakeSettingsToggleReevaluateWiringTests.swift
//  CalyxTests
//
//  Pins P6 at the Settings switch: turning "Wake Claude Code on IPC
//  messages" on re-evaluates every waiting /ipc-wake long-poll, exactly
//  once, after the setting was written, and releases nothing; turning it
//  off releases exactly once and re-evaluates nothing.
//
//  Driven through the controller's two seams, which stand in for the
//  calls on `CalyxMCPServer.shared.ipcWakeCoordinator`:
//  `_ipcWakeReleaseForTesting` (existing) and
//  `_ipcWakeReevaluateForTesting` (the re-evaluation counterpart).
//  The handler is sent to the real switch, found by its accessibility
//  identifier, as in IPCWakeSettingsToggleWiringTests.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class IPCWakeSettingsToggleReevaluateWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.IPCWakeSettingsToggleReevaluateWiringTests"
    private let handlerSelectorName = "ipcWakeDidChange:"

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() async throws {
        SettingsWindowController.shared._ipcWakeReleaseForTesting = nil
        SettingsWindowController.shared._ipcWakeReevaluateForTesting = nil
        if let toggleSwitch = try? ipcWakeSwitch() {
            toggleSwitch.state = .off
        }
        IPCWakeSettings.enabled = false
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func descendants<Kind: NSView>(of view: NSView, as kind: Kind.Type) -> [Kind] {
        view.subviews.flatMap { subview in
            ((subview as? Kind).map { [$0] } ?? []) + descendants(of: subview, as: kind)
        }
    }

    private func ipcWakeSwitch() throws -> NSSwitch {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let agentsIndex = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: .agents))
        let view = try XCTUnwrap(tabViewController.tabViewItems[agentsIndex].viewController?.view)
        return try XCTUnwrap(
            descendants(of: view, as: NSSwitch.self).first {
                $0.accessibilityIdentifier() == AccessibilityID.Settings.ipcWakeSwitch
            },
            "the Agents pane has no switch with the ipcWakeSwitch accessibility identifier"
        )
    }

    private func flip(_ toggleSwitch: NSSwitch, to state: NSControl.StateValue) {
        toggleSwitch.state = state
        _ = SettingsWindowController.shared.perform(NSSelectorFromString(handlerSelectorName), with: toggleSwitch)
    }

    /// The setting's value at each call of each seam, in call order.
    @MainActor
    private final class SeamRecorder {
        private(set) var events: [String] = []

        func release() { events.append("release(enabled=\(IPCWakeSettings.enabled))") }
        func reevaluate() { events.append("reevaluate(enabled=\(IPCWakeSettings.enabled))") }
    }

    // MARK: - Tests

    func test_turningOn_reevaluatesExactlyOnce_afterWritingTheSetting_andReleasesNothing() throws {
        let toggleSwitch = try ipcWakeSwitch()
        let recorder = SeamRecorder()
        SettingsWindowController.shared._ipcWakeReleaseForTesting = { recorder.release() }
        SettingsWindowController.shared._ipcWakeReevaluateForTesting = { recorder.reevaluate() }
        XCTAssertFalse(IPCWakeSettings.enabled, "Fixture error: a fresh suite has the setting off")

        flip(toggleSwitch, to: .on)

        XCTAssertEqual(
            recorder.events, ["reevaluate(enabled=true)"],
            "turning the switch on must re-evaluate the waiting polls exactly once, after the setting was " +
            "written (a check reads the setting when it starts), and must release nothing")
    }

    func test_turningOff_releasesExactlyOnce_andReevaluatesNothing() throws {
        let toggleSwitch = try ipcWakeSwitch()
        let recorder = SeamRecorder()
        // Turn on with both seams set, then start recording from a clean
        // slate for the off transition.
        SettingsWindowController.shared._ipcWakeReleaseForTesting = {}
        SettingsWindowController.shared._ipcWakeReevaluateForTesting = {}
        flip(toggleSwitch, to: .on)
        XCTAssertTrue(IPCWakeSettings.enabled, "Fixture error: the handler did not write the setting")
        SettingsWindowController.shared._ipcWakeReleaseForTesting = { recorder.release() }
        SettingsWindowController.shared._ipcWakeReevaluateForTesting = { recorder.reevaluate() }

        flip(toggleSwitch, to: .off)

        XCTAssertEqual(
            recorder.events, ["release(enabled=false)"],
            "turning the switch off must release the waiting polls exactly once, after the setting was " +
            "written, and must not re-evaluate them")
    }
}
