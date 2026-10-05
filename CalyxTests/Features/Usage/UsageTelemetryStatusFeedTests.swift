//
//  UsageTelemetryStatusFeedTests.swift
//  CalyxTests
//
//  Pins UsageTelemetryStatusFeed (R5c), the one source of the reception
//  status line shared by the Settings row and the Usage window:
//
//  - `text` is `UsageTelemetryStatusResolver.text` over the inputs as
//    they are when it is read (switches, server, the activation's status,
//    the monitor's values), with the injected time format.
//  - `onChange` is called synchronously for `.calyxUsageTelemetryStatus
//    DidChange` and `.calyxIPCStateDidChange` (the Settings tests read the
//    label on the line after the post), and after each change of the
//    monitor's values; the monitor observation is armed again after each
//    change, and `monitorDidChange()` moves it to the monitor the inputs
//    now name, never keeping two.
//  - Releasing the feed removes its observers: later notifications and
//    monitor changes call nothing.
//
//  Notifications go through a private `NotificationCenter`, so nothing
//  here reaches the shared Settings controller or the app delegate. The
//  activation runs over R4b's fake effects; no file is touched. Monitor
//  changes are delivered by observation after the change returns; they
//  are awaited with bounded expectations, never by sleeping. To show
//  that a monitor change did NOT call a feed, a second feed observing the
//  same monitor serves as the barrier: once its `onChange` ran, the first
//  feed's would have run as well.
//

import Foundation
import XCTest
@testable import Calyx

/// The values the feed reads through its input closures.
@MainActor
private final class FeedInputs {
    var trackingOn = true
    var ipcEnabled = true
    var serverRunning = true
    var activation: UsageTelemetryActivation
    var monitor: UsageIngestMonitor

    init(activation: UsageTelemetryActivation, monitor: UsageIngestMonitor) {
        self.activation = activation
        self.monitor = monitor
    }

    var inputs: UsageTelemetryStatusFeed.Inputs {
        UsageTelemetryStatusFeed.Inputs(
            trackingOn: { self.trackingOn },
            ipcEnabled: { self.ipcEnabled },
            serverRunning: { self.serverRunning },
            activation: { self.activation },
            monitor: { self.monitor })
    }
}

@MainActor
final class UsageTelemetryStatusFeedTests: XCTestCase {

    private let waitSeconds: TimeInterval = 10
    /// A new XCTestCase instance runs each test, so this is fresh per test.
    private let center = NotificationCenter()

    private let waitingText =
        "Waiting for Claude Code. Sessions that were already running when tracking was turned on report after "
        + "they are restarted."

    /// An activation over R4b's fakes: tracking and IPC on, the server on
    /// port 41830, so a `reconcile()` makes its status `.installed(port: 41830)`.
    private func makeActivation() -> UsageTelemetryActivation {
        UsageTelemetryActivation(
            inputs: UsageTelemetryFakeInputs().inputs, effects: UsageTelemetryFakeEffects().effects,
            onStatusChange: {})
    }

    /// Seconds since 1970, so a text shows which date it was given.
    private static func time(_ date: Date) -> String {
        "t=\(Int(date.timeIntervalSince1970))"
    }

    private func makeFeed(_ inputs: FeedInputs, counter: UsageTelemetryStatusChangeCounter) -> UsageTelemetryStatusFeed {
        UsageTelemetryStatusFeed(
            inputs: inputs.inputs, time: Self.time, notificationCenter: center,
            onChange: counter.onStatusChange)
    }

    /// One more main-actor turn: a task enqueued at the back of the main
    /// actor's queue, awaited. Every task the monitor change enqueued
    /// before it (the observations' hops) has run when this returns.
    /// Bounded: it runs nothing but an empty body.
    private func drainMainActor() async {
        await Task { @MainActor in }.value
    }

    private func waitFor(_ counter: UsageTelemetryStatusChangeCounter, toReach count: Int, _ description: String) async {
        let reached = expectation(description: description)
        counter.expect(count, fulfilling: reached)
        await fulfillment(of: [reached], timeout: waitSeconds)
    }

    // MARK: - text

    func test_text_followsTheResolverRulesForTheSwitchesAndTheServer_readLive() {
        let inputs = FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor())
        let feed = makeFeed(inputs, counter: UsageTelemetryStatusChangeCounter())

        inputs.trackingOn = false
        XCTAssertEqual(feed.text, "")

        inputs.trackingOn = true
        inputs.ipcEnabled = false
        XCTAssertEqual(feed.text, "Not receiving: AI Agent IPC is off.")

        inputs.ipcEnabled = true
        inputs.serverRunning = false
        XCTAssertEqual(feed.text, "Not receiving: The IPC server is not running.")

        inputs.serverRunning = true
        XCTAssertEqual(feed.text, "Setting up\u{2026}", "the activation has not run yet (.unknown)")
    }

    func test_text_usesTheActivationsStatus_andTheMonitorsValues_withTheInjectedTime() async {
        let activation = makeActivation()
        let monitor = UsageIngestMonitor()
        let feed = makeFeed(FeedInputs(activation: activation, monitor: monitor), counter: UsageTelemetryStatusChangeCounter())

        await activation.reconcile()
        XCTAssertEqual(activation.status, .installed(port: 41830), "fixture")
        XCTAssertEqual(feed.text, waitingText)

        monitor.note(nil, at: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(feed.text, "Receiving. Last export at t=1000000.")

        monitor.note(.tooLarge, at: Date(timeIntervalSince1970: 1_000_060))
        XCTAssertEqual(
            feed.text,
            "The last export (t=1000060) was refused: it was larger than 16 MB. Restart that Claude Code session.")
    }

    /// Without a `time:`, the feed uses R4b's one time format.
    func test_text_withoutAnInjectedTime_usesTheResolversDefaultTime() async {
        let activation = makeActivation()
        let monitor = UsageIngestMonitor()
        let feed = UsageTelemetryStatusFeed(
            inputs: FeedInputs(activation: activation, monitor: monitor).inputs, notificationCenter: center,
            onChange: {})
        await activation.reconcile()
        let accepted = Date(timeIntervalSince1970: 1_700_000_000)

        monitor.note(nil, at: accepted)

        XCTAssertEqual(feed.text, "Receiving. Last export at \(UsageTelemetryStatusResolver.defaultTime(accepted)).")
    }

    func test_text_readsTheActivationAndTheMonitorTheInputsNameNow() async {
        let inputs = FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor())
        let feed = makeFeed(inputs, counter: UsageTelemetryStatusChangeCounter())
        XCTAssertEqual(feed.text, "Setting up\u{2026}", "fixture")

        let installed = makeActivation()
        await installed.reconcile()
        inputs.activation = installed
        XCTAssertEqual(feed.text, waitingText)

        let receiving = UsageIngestMonitor()
        receiving.note(nil, at: Date(timeIntervalSince1970: 2_000_000))
        inputs.monitor = receiving
        XCTAssertEqual(feed.text, "Receiving. Last export at t=2000000.")
    }

    // MARK: - Triggers

    func test_theTelemetryStatusNotification_callsOnChange_synchronously() {
        let counter = UsageTelemetryStatusChangeCounter()
        let feed = makeFeed(FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor()), counter: counter)

        center.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)

        XCTAssertEqual(counter.count, 1)
        center.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
        XCTAssertEqual(counter.count, 2)
        withExtendedLifetime(feed) {}
    }

    func test_theIPCStateNotification_callsOnChange_synchronously() {
        let counter = UsageTelemetryStatusChangeCounter()
        let feed = makeFeed(FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor()), counter: counter)

        center.post(name: .calyxIPCStateDidChange, object: nil)

        XCTAssertEqual(counter.count, 1)
        withExtendedLifetime(feed) {}
    }

    func test_otherNotifications_andCreatingTheFeed_callNothing() {
        let counter = UsageTelemetryStatusChangeCounter()
        let feed = makeFeed(FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor()), counter: counter)
        XCTAssertEqual(counter.count, 0, "creating the feed calls nothing")

        center.post(name: Notification.Name("com.calyx.tests.unrelated"), object: nil)

        XCTAssertEqual(counter.count, 0)
        withExtendedLifetime(feed) {}
    }

    /// The text `onChange` reads is already the new one.
    func test_onChange_seesTheNewText() {
        let inputs = FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor())
        inputs.ipcEnabled = false
        // onChange reads the text of the feed it belongs to.
        let probe = ProbeBox()
        let feed = UsageTelemetryStatusFeed(
            inputs: inputs.inputs, time: Self.time, notificationCenter: center,
            onChange: { probe.read() })
        probe.read = { [weak feed, unowned probe] in if let feed { probe.seen.append(feed.text) } }
        XCTAssertEqual(feed.text, "Not receiving: AI Agent IPC is off.", "fixture")

        inputs.ipcEnabled = true
        center.post(name: .calyxIPCStateDidChange, object: nil)

        XCTAssertEqual(probe.seen, ["Setting up\u{2026}"])
    }

    func test_aMonitorChange_callsOnChange() async {
        let counter = UsageTelemetryStatusChangeCounter()
        let monitor = UsageIngestMonitor()
        let feed = makeFeed(FeedInputs(activation: makeActivation(), monitor: monitor), counter: counter)

        monitor.note(nil, at: Date(timeIntervalSince1970: 1_000_000))

        await waitFor(counter, toReach: 1, "an accepted export calls onChange")
        withExtendedLifetime(feed) {}
    }

    /// Two changes in a row: the observation is armed again after the
    /// first, and each change calls `onChange` exactly once.
    func test_theMonitorObservation_survivesTwoSuccessiveChanges() async {
        let counter = UsageTelemetryStatusChangeCounter()
        let monitor = UsageIngestMonitor()
        let feed = makeFeed(FeedInputs(activation: makeActivation(), monitor: monitor), counter: counter)

        monitor.note(nil, at: Date(timeIntervalSince1970: 1_000_000))
        await waitFor(counter, toReach: 1, "the first change calls onChange")

        monitor.note(.unauthorized, at: Date(timeIntervalSince1970: 1_000_060))
        await waitFor(counter, toReach: 2, "the second change calls onChange")

        // A synchronous call as the barrier: one call per change, no more.
        center.post(name: .calyxIPCStateDidChange, object: nil)
        XCTAssertEqual(counter.count, 3)
        withExtendedLifetime(feed) {}
    }

    /// The Settings seam swaps the monitor: after `monitorDidChange()` the
    /// feed follows the new one only, and re-arming twice does not make a
    /// change call `onChange` twice.
    func test_monitorDidChange_movesTheObservationToTheNewMonitor_withoutDoubling() async {
        let old = UsageIngestMonitor()
        // The barrier observes the old monitor before the feed under test
        // does, and `drainMainActor()` follows it: neither the order of
        // the two observations nor of their main-actor tasks matters.
        let barrierCounter = UsageTelemetryStatusChangeCounter()
        let barrier = makeFeed(FeedInputs(activation: makeActivation(), monitor: old), counter: barrierCounter)
        let counter = UsageTelemetryStatusChangeCounter()
        let inputs = FeedInputs(activation: makeActivation(), monitor: old)
        let feed = makeFeed(inputs, counter: counter)

        let new = UsageIngestMonitor()
        inputs.monitor = new
        feed.monitorDidChange()
        feed.monitorDidChange()

        // The old monitor changes first: the retired observations act on
        // nothing.
        old.note(nil, at: Date(timeIntervalSince1970: 1_000_000))
        await waitFor(barrierCounter, toReach: 1, "the old monitor's change was delivered")
        await drainMainActor()
        XCTAssertEqual(counter.count, 0, "the feed no longer follows the old monitor")

        new.note(nil, at: Date(timeIntervalSince1970: 1_000_000))
        await waitFor(counter, toReach: 1, "the new monitor's change calls onChange")
        new.note(.undecodable, at: Date(timeIntervalSince1970: 1_000_060))
        await waitFor(counter, toReach: 2, "and so does its next change")

        center.post(name: .calyxIPCStateDidChange, object: nil)
        XCTAssertEqual(counter.count, 3, "one onChange per change")
        withExtendedLifetime((feed, barrier)) {}
    }

    // MARK: - Release

    func test_releasingTheFeed_freesIt_andALaterNotificationCallsNothing() {
        let counter = UsageTelemetryStatusChangeCounter()
        var feed: UsageTelemetryStatusFeed? =
            makeFeed(FeedInputs(activation: makeActivation(), monitor: UsageIngestMonitor()), counter: counter)
        weak let released = feed

        feed = nil

        XCTAssertNil(released, "the feed is not kept alive by its own observers")
        center.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
        center.post(name: .calyxIPCStateDidChange, object: nil)
        XCTAssertEqual(counter.count, 0)
    }

    func test_releasingTheFeed_aLaterMonitorChangeCallsNothing() async {
        let monitor = UsageIngestMonitor()
        // Armed before the feed under test; `drainMainActor()` follows the
        // barrier, so the order of the two tasks does not matter.
        let barrierCounter = UsageTelemetryStatusChangeCounter()
        let barrier = makeFeed(FeedInputs(activation: makeActivation(), monitor: monitor), counter: barrierCounter)
        let counter = UsageTelemetryStatusChangeCounter()
        var feed: UsageTelemetryStatusFeed? =
            makeFeed(FeedInputs(activation: makeActivation(), monitor: monitor), counter: counter)
        weak let released = feed

        feed = nil
        XCTAssertNil(released)
        monitor.note(nil, at: Date(timeIntervalSince1970: 1_000_000))

        await waitFor(barrierCounter, toReach: 1, "the change was delivered")
        await drainMainActor()
        XCTAssertEqual(counter.count, 0)
        withExtendedLifetime(barrier) {}
    }
}

/// Lets an `onChange` closure call code set up after the feed exists.
@MainActor
private final class ProbeBox {
    var read: () -> Void = {}
    var seen: [String] = []
}
