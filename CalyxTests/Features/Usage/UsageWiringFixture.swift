//
//  UsageWiringFixture.swift
//  CalyxTests
//
//  What the tests of the usage ledger's wiring share: a per-test
//  temporary directory holding a synthetic projects root and a store
//  directory, synthetic exports of the token metric with the totals they
//  add up to (written by hand), a recorder for the ledger's `publish` seam
//  that can fulfil an expectation, and a test ledger whose settles run the
//  REAL run log reader.
//  Nothing here knows ~/.claude, Application Support or UserDefaults.
//
//  The code under test starts tasks it does not wait for (a settle, a
//  catch-up, a publish). Two things keep such a task from outliving its test:
//  `closeBehindEverythingStarted` is the barrier a test uses before it
//  asserts that something did NOT happen, and `shutDown` turns the
//  fixture's tracking switch off before it closes the ledgers and removes
//  the directory, so a task that reaches a ledger even later finds
//  tracking off and creates nothing. Only a killed test process can leave
//  the directory behind.
//

import os
import XCTest
@testable import Calyx

/// "Not a repository": the session's root is its cwd.
struct UsageFixtureNoRepositoryResolver: ProjectRootResolving {
    func projectRoot(forCWD cwd: String) async throws -> String? { nil }
}

/// What a fixture ledger's `isEnabled` answers. On until a test, or
/// `UsageWiringFixture.shutDown`, turns it off.
final class UsageFixtureSwitch: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)

    var isOn: Bool { state.withLock { $0 } }

    func set(_ value: Bool) { state.withLock { $0 = value } }
}

/// Records every `publish` call in order. `expect(count:fulfilling:)`
/// lets a test wait for a publish that must happen instead of sleeping.
final class UsagePublishRecorder: Sendable {
    struct Entry: Equatable, Sendable {
        let sessionID: String
        let totals: UsageTokenTotals?
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var settlePriorities: [TaskPriority] = []
        var waiters: [(count: Int, expectation: XCTestExpectation)] = []
        var settleWaiters: [(count: Int, expectation: XCTestExpectation)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var entries: [Entry] { state.withLock { $0.entries } }

    /// `Task.currentPriority` inside each run log read (one per settle)
    /// of a fixture ledger, in call order.
    var settlePriorities: [TaskPriority] { state.withLock { $0.settlePriorities } }

    func recordSettle(priority: TaskPriority) {
        let ready: [XCTestExpectation] = state.withLock { state in
            state.settlePriorities.append(priority)
            let count = state.settlePriorities.count
            let ready = state.settleWaiters.filter { $0.count <= count }.map(\.expectation)
            state.settleWaiters.removeAll { $0.count <= count }
            return ready
        }
        for expectation in ready { expectation.fulfill() }
    }

    /// Fulfils `expectation` once at least `count` run log reads were
    /// recorded.
    func expectSettles(count: Int, fulfilling expectation: XCTestExpectation) {
        let alreadyThere = state.withLock { state in
            if state.settlePriorities.count >= count { return true }
            state.settleWaiters.append((count, expectation))
            return false
        }
        if alreadyThere { expectation.fulfill() }
    }

    func record(_ sessionID: String, _ totals: UsageTokenTotals?) {
        let ready: [XCTestExpectation] = state.withLock { state in
            state.entries.append(Entry(sessionID: sessionID, totals: totals))
            let count = state.entries.count
            let ready = state.waiters.filter { $0.count <= count }.map(\.expectation)
            state.waiters.removeAll { $0.count <= count }
            return ready
        }
        for expectation in ready { expectation.fulfill() }
    }

    /// Fulfils `expectation` once at least `count` publishes were recorded.
    func expect(count: Int, fulfilling expectation: XCTestExpectation) {
        let alreadyThere = state.withLock { state in
            if state.entries.count >= count { return true }
            state.waiters.append((count, expectation))
            return false
        }
        if alreadyThere { expectation.fulfill() }
    }
}

struct UsageWiringFixture {
    struct FixtureError: Error {}

    static let sessionA = "11111111-2222-3333-4444-555555555555"
    static let sessionB = "99999999-8888-7777-6666-555555555555"

    /// How long a test waits for something that must happen. Reached only
    /// when it does not happen, and the test then fails.
    static let waitSeconds: TimeInterval = 30

    /// realpath(3) of the directory everything lives in: the transcript
    /// locator compares resolved paths.
    let basePath: String

    /// The tracking setting of the ledgers `makeLedger` builds.
    let tracking = UsageFixtureSwitch()

    /// A fresh directory under the temporary directory.
    static func make(label: String) throws -> UsageWiringFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        return try UsageWiringFixture(directory: url)
    }

    /// Uses (and creates) `directory`.
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let resolved = realpath(directory.path, nil) else { throw FixtureError() }
        defer { free(resolved) }
        basePath = String(cString: resolved)
        try FileManager.default.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: basePath)
    }

    /// Ends a test: tracking off first, so a task that was started
    /// without being waited for and reaches a ledger only now does
    /// nothing; then every ledger is closed (which waits for a read that
    /// is running) and the directory is removed.
    func shutDown(_ ledgers: [UsageLedger]) async {
        tracking.set(false)
        for ledger in ledgers {
            await ledger.close()
        }
        remove()
    }

    /// Closes `ledger` from a task of the lowest priority and waits for
    /// it through an expectation (bound: `waitSeconds`). That task goes
    /// through the main actor and then the ledger behind every task the
    /// code under test has started so far on the main actor, whatever
    /// priority those have, and `close()` waits for the reads they
    /// started. Afterwards nothing that was started is still pending, so
    /// a test can assert what did not happen. Never awaited directly:
    /// awaiting a task raises its priority.
    @MainActor
    func closeBehindEverythingStarted(_ ledger: UsageLedger, in testCase: XCTestCase) async {
        let closed = testCase.expectation(description: "the ledger was closed behind everything started")
        Task(priority: .background) {
            await ledger.close()
            closed.fulfill()
        }
        await testCase.fulfillment(of: [closed], timeout: Self.waitSeconds)
    }

    // MARK: Paths

    var root: String { basePath + "/projects" }
    var projectDirectory: String { root + "/-Users-someone-repo" }
    var storePath: String { basePath + "/store/usage" }
    var storeURL: URL { URL(fileURLWithPath: storePath, isDirectory: true) }

    func mainPath(_ sessionID: String) -> String {
        projectDirectory + "/" + sessionID + ".jsonl"
    }

    /// Every path below the base directory, sorted.
    func everyPath() -> [String] {
        (FileManager.default.subpaths(atPath: basePath) ?? []).sorted()
    }

    // MARK: Files

    /// Writes `lines`, each terminated by "\n".
    func write(_ lines: [String], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
    }

    /// Appends `lines`, each terminated by "\n", to an existing file.
    func append(_ lines: [String], to path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else { throw FixtureError() }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    // MARK: Transcript lines

    /// A line of the session's own transcript with a timestamp and a cwd:
    /// what the run log reader takes the session's cwd (and so its project
    /// root) from.
    static func transcriptLine(_ sessionID: String = sessionA, cwd: String = "/work/repo/sub") -> String {
        #"{"type":"user","timestamp":"2026-10-05T07:30:00.000Z","sessionId":""# + sessionID
            + #"","cwd":""# + cwd + #""}"#
    }

    // MARK: Exports

    /// A process start far after any store clock (2096): its exports count
    /// in full whenever the store's tracking started.
    static let exportStartNs: Int64 = 4_000_000_000_000_000_000
    static let secondNs: Int64 = 1_000_000_000

    /// One export of a fresh process of `sessionID` (started at
    /// `exportStartNs`): its process start and one cumulative input series
    /// of `input` tokens, sampled `seconds` after the start. The session's
    /// totals after it are `inputTotals(input)`.
    static func exportBody(_ sessionID: String = sessionA, input: Double, seconds: Int64 = 10) throws -> Data {
        let fixtures = UsageTelemetryFixtures.self
        let timeNs = exportStartNs + seconds * secondNs
        let tokens = fixtures.point(
            attributes: fixtures.attributes([
                "session.id": sessionID, "model": "claude-sonnet-5-5", "query_source": "main", "type": "input",
            ]),
            startNs: exportStartNs, timeNs: timeNs, asDouble: input)
        let start: [String: Any] = [
            "attributes": fixtures.attributes(["session.id": sessionID, "start_type": "fresh"]),
            "startTimeUnixNano": String(exportStartNs), "timeUnixNano": String(timeNs), "asDouble": 1.0,
        ]
        return try fixtures.body(metrics: [
            fixtures.metric(points: [tokens]),
            fixtures.metric(name: "claude_code.session.count", points: [start]),
        ])
    }

    /// When `exportBody(input:seconds:)` is received.
    static func exportTimeNs(seconds: Int64 = 10) -> Int64 {
        exportStartNs + seconds * secondNs
    }

    /// The totals of a session whose only tokens are `input` input tokens.
    static func inputTotals(_ input: Int64) -> UsageTokenTotals {
        UsageTokenTotals(input: input, output: 0, cacheRead: 0, cacheCreation: 0)
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Ledger and store

    /// A ledger over this fixture's roots, enabled while `tracking` is
    /// on, whose settles run the real run log reader (sessions are
    /// attributed to their cwd) and which records what it publishes and at
    /// which priority each settle read its run log.
    func makeLedger(recorder: UsagePublishRecorder) -> UsageLedger {
        let root = self.root
        let tracking = self.tracking
        return UsageLedger(
            isEnabled: { tracking.isOn },
            projectsRoot: { root },
            storeDirectory: storeURL,
            publish: { sessionID, totals in recorder.record(sessionID, totals) },
            onDiagnostic: { _ in },
            readRunLog: { sessionID, store, resolveProjectRoot in
                recorder.recordSettle(priority: Task.currentPriority)
                return try await UsageRunLogReader(
                    store: store, resolver: UsageFixtureNoRepositoryResolver(), projectsRoot: { root }
                ).read(sessionID: sessionID, resolveProjectRoot: resolveProjectRoot)
            })
    }

    /// Reads the store directory with a connection of its own. Call it
    /// only after every ledger using the directory was closed.
    func readStore<Value: Sendable>(
        _ body: @Sendable (UsageStore) async throws -> Value
    ) async throws -> Value {
        let store = try UsageStore(directory: storeURL)
        do {
            let value = try await body(store)
            await store.close()
            return value
        } catch {
            await store.close()
            throw error
        }
    }
}
