//
//  UsageLedgerProductionTests.swift
//  CalyxTests
//
//  Pins the composition the app runs, `UsageLedger.makeProduction`, and
//  the rule that decides whether the app's ledger is on.
//
//  The composition is exercised over a synthetic projects root and a
//  store directory in a per-test temporary directory, publishing into a
//  UsageLiveSummaries the test owns: one note ingests a main and a
//  subagent transcript and the session's summary equals the stored
//  total; with tracking off nothing is created; a re-read that found
//  nothing new does not notify the summaries' observers; and the real
//  git resolver is in it (a repository made with `git init` becomes the
//  session's project root).
//
//  `UsageLedger.shared` is never touched: what it adds to the
//  composition is the enabling rule, which is a pure function here.
//  Nothing waits by polling or sleeping: `note` registers the read before
//  it returns, so `waitUntilIdle()` ends after that read was published.
//

import Observation
import os
import XCTest
@testable import Calyx

@MainActor
final class UsageLedgerProductionTests: XCTestCase {

    private typealias Fixture = UsageWiringFixture

    private let sessionA = UsageWiringFixture.sessionA
    private var fixture: UsageWiringFixture!
    private var summaries: UsageLiveSummaries!
    private var ledgers: [UsageLedger] = []

    override func setUp() async throws {
        try await super.setUp()
        // Under Caches, not the temporary directory: git reports resolved
        // paths, and this location has a single spelling.
        fixture = try UsageWiringFixture(directory: try GitScratch.makeDirectory("usage-ledger-production"))
        summaries = UsageLiveSummaries()
    }

    override func tearDown() async throws {
        for ledger in ledgers {
            await ledger.close()
        }
        ledgers = []
        fixture?.remove()
        fixture = nil
        summaries = nil
        try await super.tearDown()
    }

    private func makeProductionLedger(isEnabled: @escaping @Sendable () -> Bool = { true }) -> UsageLedger {
        let root = fixture.root
        let ledger = UsageLedger.makeProduction(
            isEnabled: isEnabled, projectsRoot: { root }, storeDirectory: fixture.storeURL, summaries: summaries)
        ledgers.append(ledger)
        return ledger
    }

    private func noteAndSettle(_ ledger: UsageLedger, _ event: String) async {
        await ledger.note(fixture.activity(event))
        await ledger.waitUntilIdle()
    }

    // MARK: - The enabling rule

    func test_isTrackingEnabled_isOnOnlyWhenTheSettingIsOnAndTheLaunchMayTouchTheAgentPaths() {
        XCTAssertTrue(UsageLedger.isTrackingEnabled(setting: true, launchMayTouchAgentPaths: true))
        XCTAssertFalse(
            UsageLedger.isTrackingEnabled(setting: true, launchMayTouchAgentPaths: false),
            "a launch that must not touch the real agent paths keeps tracking off whatever the setting says")
        XCTAssertFalse(UsageLedger.isTrackingEnabled(setting: false, launchMayTouchAgentPaths: true))
        XCTAssertFalse(UsageLedger.isTrackingEnabled(setting: false, launchMayTouchAgentPaths: false))
    }

    // MARK: - Ingest and publish

    func test_makeProduction_oneNote_ingestsMainAndSubagentTranscript_andTheSummaryEqualsTheStoredTotal()
        async throws
    {
        try fixture.write(
            [Fixture.userLine, Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        try fixture.write(
            [Fixture.assistantLine("msg_s1", agentID: "a1")], to: fixture.subagentPath(sessionA, "a1"))
        let ledger = makeProductionLedger()

        await noteAndSettle(ledger, "Stop")

        // One main and one subagent response.
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(2)])
        await ledger.close()
        let (total, byThread) = try await fixture.readStore { store in
            (
                try await store.report(UsageQuery(sessionID: Fixture.sessionA), calendar: Fixture.utc),
                try await store.report(
                    UsageQuery(groupBy: [.thread], sessionID: Fixture.sessionA), calendar: Fixture.utc)
            )
        }
        XCTAssertEqual(total, [Fixture.totalRow(2)])
        XCTAssertEqual(byThread, [Fixture.totalRow(1, key: ["main"]), Fixture.totalRow(1, key: ["subagent"])])
    }

    func test_makeProduction_aLaterTrigger_replacesTheSummaryWithTheGrownTotal() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let ledger = makeProductionLedger()
        await noteAndSettle(ledger, "Stop")
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(1)])

        try fixture.append([Fixture.assistantLine("msg_m2")], to: fixture.mainPath(sessionA))
        await noteAndSettle(ledger, "Stop")

        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(2)])
    }

    func test_makeProduction_aReReadThatFoundNothingNew_doesNotNotifyTheSummariesObservers() async throws {
        // Every reconcile publishes each session's row again; an observer
        // must only hear about the ones that changed.
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let ledger = makeProductionLedger()
        await noteAndSettle(ledger, "Stop")
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = summaries.bySession
        } onChange: {
            notified.withLock { $0 = true }
        }

        await ledger.reconcileKnown()

        XCTAssertFalse(notified.withLock { $0 }, "an unchanged row was published as a change")
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(1)])

        // The same observer does hear about a row that changed.
        try fixture.append([Fixture.assistantLine("msg_m2")], to: fixture.mainPath(sessionA))
        await ledger.reconcileKnown()

        XCTAssertTrue(notified.withLock { $0 })
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(2)])
    }

    // MARK: - Off

    func test_makeProduction_disabled_readsNothingAndCreatesNoFile() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let before = fixture.everyPath()
        let ledger = makeProductionLedger(isEnabled: { false })

        await noteAndSettle(ledger, "Stop")
        await ledger.reconcileKnown()
        await ledger.waitUntilIdle()

        XCTAssertEqual(summaries.bySession, [:])
        XCTAssertEqual(fixture.everyPath(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.basePath + "/store"))
    }

    func test_makeProduction_readsTheSettingOnEveryEvent_notOnceAtCreation() async throws {
        try fixture.write([Fixture.assistantLine("msg_m1")], to: fixture.mainPath(sessionA))
        let enabled = OSAllocatedUnfairLock(initialState: false)
        let ledger = makeProductionLedger(isEnabled: { enabled.withLock { $0 } })
        await noteAndSettle(ledger, "Stop")
        XCTAssertEqual(summaries.bySession, [:])

        enabled.withLock { $0 = true }
        await noteAndSettle(ledger, "Stop")

        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(1)])
    }

    // MARK: - The git resolver is in the composition

    func test_makeProduction_aGitRepositoryContainingTheSessionsCwd_becomesItsProjectRoot() async throws {
        let repository = fixture.basePath + "/repo"
        try GitScratch.run(
            ["init", "-q", "-b", "main", repository], in: URL(fileURLWithPath: fixture.basePath, isDirectory: true))
        let cwd = repository + "/Sources/Deep"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try fixture.write([Fixture.assistantLine("msg_m1", cwd: cwd)], to: fixture.mainPath(sessionA))
        let ledger = makeProductionLedger()

        await noteAndSettle(ledger, "Stop")

        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.totalRow(1)])
        await ledger.close()
        let stored = try await fixture.readStore { try await $0.session(Fixture.sessionA) }
        // Without a resolver that asks git, the root would be the cwd.
        XCTAssertEqual(stored?.projectRoot, repository)
    }
}
