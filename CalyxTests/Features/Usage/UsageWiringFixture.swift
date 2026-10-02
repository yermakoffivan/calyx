//
//  UsageWiringFixture.swift
//  CalyxTests
//
//  What the tests of the usage ledger's wiring share: a per-test
//  temporary directory holding a synthetic projects root and a store
//  directory, synthetic transcript lines with the total row they add up
//  to (written by hand), a recorder for the ledger's `publish` seam that
//  can fulfil an expectation, and a test ledger running the REAL ingestor.
//  Nothing here knows ~/.claude, Application Support or UserDefaults.
//
//  The code under test starts tasks it does not wait for (a reconcile, a
//  forwarded event). Two things keep such a task from outliving its test:
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
        let row: UsageRow?
    }

    private struct State: Sendable {
        var entries: [Entry] = []
        var ingestPriorities: [TaskPriority] = []
        var waiters: [(count: Int, expectation: XCTestExpectation)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var entries: [Entry] { state.withLock { $0.entries } }

    /// `Task.currentPriority` inside each ingest of a fixture ledger, in
    /// call order.
    var ingestPriorities: [TaskPriority] { state.withLock { $0.ingestPriorities } }

    func recordIngest(priority: TaskPriority) {
        state.withLock { $0.ingestPriorities.append(priority) }
    }

    func record(_ sessionID: String, _ row: UsageRow?) {
        let ready: [XCTestExpectation] = state.withLock { state in
            state.entries.append(Entry(sessionID: sessionID, row: row))
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

    func subagentPath(_ sessionID: String, _ agentID: String) -> String {
        projectDirectory + "/" + sessionID + "/subagents/agent-" + agentID + ".jsonl"
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

    /// One final assistant line in the transcript's shape. `agentID`
    /// non-nil makes it a subagent (sidechain) line.
    static func assistantLine(
        _ id: String, sessionID: String = sessionA, agentID: String? = nil, cwd: String = "/work/repo/sub"
    ) -> String {
        var text = #"{"type":"assistant","sessionId":""# + sessionID + #"","#
        text += #""timestamp":"2026-10-02T10:27:29.765Z","#
        text += #""cwd":""# + cwd + #"","#
        text += #""gitBranch":"main","effort":"high","#
        if let agentID {
            text += #""isSidechain":true,"agentId":""# + agentID + #"","attributionAgent":"swift-specialist","#
        } else {
            text += #""isSidechain":false,"#
        }
        text += #""message":{"id":""# + id + #"","model":"claude-opus-5-5","stop_reason":"end_turn","#
        text += #""usage":{"input_tokens":3,"output_tokens":420"#
        text += #","cache_read_input_tokens":90000,"cache_creation_input_tokens":1200,"#
        text += #""cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":200},"#
        text += #""output_tokens_details":{"thinking_tokens":150}"#
        text += "}}}"
        return text
    }

    /// A line that is read but yields no record.
    static let userLine =
        #"{"type":"user","sessionId":"11111111-2222-3333-4444-555555555555","message":{"role":"user"}}"#

    /// The total row of a session holding `responses` of those assistant
    /// lines, by hand: each is final with input 3, output 420, thinking
    /// 150, cache read 90,000, cache creation 1,200 (1,000 of it 1h), at
    /// 2026-10-02T10:27:29.765Z = 1_790_936_849_765 ms.
    static func totalRow(_ responses: Int64, key: [String?] = []) -> UsageRow {
        UsageRow(
            key: key,
            responses: responses,
            finalResponses: responses,
            inputTokens: 3 * responses,
            cacheReadTokens: 90_000 * responses,
            cacheCreationTokens: 1_200 * responses,
            cacheCreation1hTokens: 1_000 * responses,
            outputTokensFinal: 420 * responses,
            thinkingTokensFinal: 150 * responses,
            lastTimestampMs: 1_790_936_849_765
        )
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Ledger and store

    func activity(_ event: String, _ sessionID: String = sessionA) -> UsageActivity {
        UsageActivity(sessionID: sessionID, transcriptPath: mainPath(sessionID), hookEventName: event)
    }

    /// A ledger over this fixture's roots, enabled while `tracking` is
    /// on, that runs the real ingestor (sessions are attributed to their
    /// cwd) and records what it publishes and at which priority each
    /// ingest ran.
    func makeLedger(recorder: UsagePublishRecorder) -> UsageLedger {
        let root = self.root
        let tracking = self.tracking
        return UsageLedger(
            isEnabled: { tracking.isOn },
            projectsRoot: { root },
            storeDirectory: storeURL,
            ingest: { location, store in
                recorder.recordIngest(priority: Task.currentPriority)
                return try await UsageIngestor(store: store, resolver: UsageFixtureNoRepositoryResolver()).ingest(location)
            },
            publish: { sessionID, row in recorder.record(sessionID, row) },
            onDiagnostic: { _ in })
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
