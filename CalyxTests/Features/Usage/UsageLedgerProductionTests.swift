//
//  UsageLedgerProductionTests.swift
//  CalyxTests
//
//  Pins the composition the app runs, `UsageLedger.makeProduction`, and
//  the rule that decides whether the app's ledger is on.
//
//  The composition is exercised over a synthetic projects root and a
//  store directory in a per-test temporary directory, publishing into a
//  UsageLiveSummaries the test owns: an export handed to `ingestExport`
//  becomes the session's summary (its totals), a later export replaces
//  it, a delete removes it; with tracking off nothing is created; an
//  export or a catch-up that changed nothing does not notify the
//  summaries' observers; and the real git resolver is in it (the settle
//  that follows an export reads the transcript, and a repository made
//  with `git init` becomes the session's project root).
//
//  `UsageLedger.shared` is never touched: what it adds to the
//  composition is the enabling rule and the choice of store directory,
//  both pure functions here. The store directory is tested with literal
//  paths only; nothing is created in the real Application Support or
//  temporary directories.
//  Nothing waits by polling or sleeping: `ingestExport` requests its
//  settle and its publish before it returns, and `waitUntilIdle()` ends
//  after both (settles and pending publishes).
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

    /// Hands one export of `sessionID` with `input` tokens to the ledger
    /// and waits until its settle and publish are done.
    @discardableResult
    private func exportAndSettle(
        _ ledger: UsageLedger, input: Double, seconds: Int64 = 10, sessionID: String = UsageWiringFixture.sessionA
    ) async throws -> UsageIngestOutcome {
        let outcome = await ledger.ingestExport(
            try Fixture.exportBody(sessionID, input: input, seconds: seconds),
            receivedAtNs: Fixture.exportTimeNs(seconds: seconds))
        await ledger.waitUntilIdle()
        return outcome
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

    // MARK: - The store directory

    /// A literal stand-in for `AppSupportDirectory.usagePath`; nothing
    /// exists or is created there.
    private let literalUsagePath = "/Users/nobody/Library/Application Support/Calyx/usage"

    func test_productionStoreDirectory_whenTheLaunchMayTouchAgentPaths_isUsagePathAsADirectory() {
        let url = UsageLedger.productionStoreDirectory(launchMayTouchAgentPaths: true, usagePath: literalUsagePath)

        XCTAssertEqual(url, URL(fileURLWithPath: literalUsagePath, isDirectory: true))
        XCTAssertTrue(url.hasDirectoryPath)
    }

    /// A UI-test launch without a scoped path root keeps tracking off,
    /// but the Usage window still reads and can delete through the
    /// ledger: its store must not be the developer's real one.
    func test_productionStoreDirectory_whenTheLaunchMayNotTouchAgentPaths_isANonexistentTemporaryDirectory()
        throws
    {
        let url = UsageLedger.productionStoreDirectory(launchMayTouchAgentPaths: false, usagePath: literalUsagePath)
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertFalse(path.hasPrefix(literalUsagePath), "\(path) is the real usage directory or inside it")
        XCTAssertTrue(path.hasPrefix(temporary + "/"), "\(path) is not under \(temporary)")
        XCTAssertNotEqual(path, temporary, "a directory of its own, not the temporary directory itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing creates it")
        XCTAssertEqual(
            UsageLedger.productionStoreDirectory(launchMayTouchAgentPaths: false, usagePath: literalUsagePath), url,
            "one directory per process")
    }

    // MARK: - Export and publish

    func test_makeProduction_anExport_becomesTheSessionsSummary() async throws {
        let ledger = makeProductionLedger()

        let outcome = try await exportAndSettle(ledger, input: 10)

        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(10)])
    }

    func test_makeProduction_aLaterExport_replacesTheSummaryWithTheGrownTotals() async throws {
        let ledger = makeProductionLedger()
        try await exportAndSettle(ledger, input: 10)
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(10)])

        try await exportAndSettle(ledger, input: 25, seconds: 15)

        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(25)])
    }

    func test_makeProduction_anExportOrACatchUpThatChangedNothing_doesNotNotifyTheSummariesObservers()
        async throws
    {
        let ledger = makeProductionLedger()
        try await exportAndSettle(ledger, input: 10)
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = summaries.bySession
        } onChange: {
            notified.withLock { $0 = true }
        }

        try await exportAndSettle(ledger, input: 10, seconds: 15)
        await ledger.catchUp()
        await ledger.waitUntilIdle()

        XCTAssertFalse(notified.withLock { $0 }, "unchanged totals were published as a change")
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(10)])

        // The same observer does hear about totals that changed.
        try await exportAndSettle(ledger, input: 30, seconds: 20)

        XCTAssertTrue(notified.withLock { $0 })
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(30)])
    }

    func test_makeProduction_deleteAll_removesThePublishedSummaries() async throws {
        let ledger = makeProductionLedger()
        try await exportAndSettle(ledger, input: 10)
        try await exportAndSettle(ledger, input: 7, sessionID: Fixture.sessionB)
        XCTAssertEqual(summaries.bySession.count, 2, "Fixture error")

        try await ledger.deleteAll()
        await ledger.waitUntilIdle()

        XCTAssertEqual(summaries.bySession, [:])
    }

    // MARK: - Off

    func test_makeProduction_disabled_storesNothingAndCreatesNoFile() async throws {
        try fixture.write([Fixture.transcriptLine()], to: fixture.mainPath(sessionA))
        let before = fixture.everyPath()
        let ledger = makeProductionLedger(isEnabled: { false })

        let outcome = try await exportAndSettle(ledger, input: 10)
        await ledger.catchUp()
        await ledger.waitUntilIdle()

        XCTAssertEqual(outcome, .dropped)
        XCTAssertEqual(summaries.bySession, [:])
        XCTAssertEqual(fixture.everyPath(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.basePath + "/store"))
    }

    func test_makeProduction_readsTheSettingOnEveryExport_notOnceAtCreation() async throws {
        let enabled = OSAllocatedUnfairLock(initialState: false)
        let ledger = makeProductionLedger(isEnabled: { enabled.withLock { $0 } })
        let dropped = try await exportAndSettle(ledger, input: 10)
        XCTAssertEqual(dropped, .dropped)
        XCTAssertEqual(summaries.bySession, [:])

        enabled.withLock { $0 = true }
        let stored = try await exportAndSettle(ledger, input: 10, seconds: 15)

        XCTAssertEqual(stored, .stored)
        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(10)])
    }

    // MARK: - The git resolver is in the composition

    func test_makeProduction_aGitRepositoryContainingTheSessionsCwd_becomesItsProjectRoot() async throws {
        let repository = fixture.basePath + "/repo"
        try GitScratch.run(
            ["init", "-q", "-b", "main", repository], in: URL(fileURLWithPath: fixture.basePath, isDirectory: true))
        let cwd = repository + "/Sources/Deep"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        try fixture.write([Fixture.transcriptLine(cwd: cwd)], to: fixture.mainPath(sessionA))
        let ledger = makeProductionLedger()

        // The export's settle reads the transcript with the production
        // reader, whose resolver asks git.
        try await exportAndSettle(ledger, input: 10)

        XCTAssertEqual(summaries.bySession, [sessionA: Fixture.inputTotals(10)])
        await ledger.close()
        let stored = try await fixture.readStore { try await $0.session(Fixture.sessionA) }
        // Without a resolver that asks git, the root would be the cwd.
        XCTAssertEqual(stored?.projectRoot, repository)
    }
}
