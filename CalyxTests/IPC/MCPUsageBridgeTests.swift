//
//  MCPUsageBridgeTests.swift
//  CalyxTests
//
//  Pins MCPUsageBridge, the `usage_report` MCP tool over the usage
//  ledger's token Gold query (`UsageTokenQuery` / `UsageTokenRow`, R5b),
//  driven through handleToolCall(name:arguments:
//  surfaceID:) with stub closures (no server, no store, no files):
//
//  - Tracking off is reported first, before any argument is looked at,
//    and nothing is read.
//  - Every argument is validated; a bad one is a thrown
//    `.invalidArgument` naming it, and nothing is read. Unknown argument
//    names are ignored.
//  - Each tool call reads through `reports` exactly ONCE, with two
//    queries: the rows query and a totals query with the same filters
//    and no grouping, so the totals describe the same state as the rows
//    and are not affected by `limit`.
//  - `days` becomes the local midnight N - 1 days back in the injected
//    calendar; `since` / `until` go through `TranscriptTimestamp`,
//    millisecond exact; `session_id: "current"` is the calling pane's
//    agent session, resolved at each call.
//  - The result is a JSON object (rows, row_count before `limit`,
//    truncated, totals, three notes, the time zone), timestamps written
//    as `YYYY-MM-DDTHH:MM:SS.fffZ`. A row carries `unreported` and four
//    token sums; `totals` sums EVERY row of the totals query (recorded
//    and unreported, saturating at Int64.max) and adds an `unreported`
//    object with the unreported part alone.
//
//  Expected epoch values were computed independently (Python) and are
//  written out as literals next to the instants they stand for.
//

import os
import XCTest
@testable import Calyx

// MARK: - Stubs

/// The `reports` seam: records every call and answers as configured.
/// Sendable, so the closures built over it fit any isolation the bridge
/// gives them.
private final class ReportsRecorder: Sendable {
    struct Call: Sendable {
        let queries: [UsageTokenQuery]
        let calendar: Calendar
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var answer: (@Sendable ([UsageTokenQuery]) throws -> [[UsageTokenRow]])?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var calls: [Call] { state.withLock { $0.calls } }

    /// Answers every later call; without one, each query answers `[]`.
    func answer(_ body: @escaping @Sendable ([UsageTokenQuery]) throws -> [[UsageTokenRow]]) {
        state.withLock { $0.answer = body }
    }

    /// The rows query answers `rows`, the totals query `totals`.
    func answer(rows: [UsageTokenRow], totals: [UsageTokenRow]) {
        answer { queries in
            queries.map { $0.groupBy.isEmpty ? totals : rows }
        }
    }

    func run(_ queries: [UsageTokenQuery], _ calendar: Calendar) throws -> [[UsageTokenRow]] {
        let answer = state.withLock { state -> (@Sendable ([UsageTokenQuery]) throws -> [[UsageTokenRow]])? in
            state.calls.append(Call(queries: queries, calendar: calendar))
            return state.answer
        }
        return try answer?(queries) ?? queries.map { _ in [] }
    }
}

/// A value a test changes between calls and the bridge reads through a
/// closure.
private final class Setting<Value: Sendable>: Sendable {
    private let state: OSAllocatedUnfairLock<Value>

    init(_ value: Value) { state = OSAllocatedUnfairLock(initialState: value) }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// The `currentSessionID` seam: a table per surface, and every surface
/// it was asked about.
private final class SessionTable: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (table: [UUID: String](), asked: [UUID]()))

    func set(_ sessionID: String?, for surfaceID: UUID) { state.withLock { $0.table[surfaceID] = sessionID } }
    var asked: [UUID] { state.withLock { $0.asked } }

    func lookUp(_ surfaceID: UUID) -> String? {
        state.withLock { state in
            state.asked.append(surfaceID)
            return state.table[surfaceID]
        }
    }
}

// MARK: - Tests

@MainActor
final class MCPUsageBridgeTests: XCTestCase {

    private var recorder = ReportsRecorder()
    private var enabled = Setting(true)
    private var sessions = SessionTable()
    /// 2026-10-02T10:27:29.765Z unless a test moves it.
    private var now = Setting(Date(timeIntervalSince1970: 0))
    private var calendar = Setting(Calendar(identifier: .gregorian))

    private static let nowMs: Int64 = 1_790_936_849_765

    override func setUp() async throws {
        try await super.setUp()
        recorder = ReportsRecorder()
        enabled = Setting(true)
        sessions = SessionTable()
        now = Setting(Self.date(ms: Self.nowMs))
        calendar = Setting(try Self.calendar("UTC"))
    }

    // MARK: - Helpers

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
    }

    private static func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier), "Fixture error: \(identifier)")
        return calendar
    }

    private func makeBridge() -> MCPUsageBridge {
        let recorder = self.recorder
        let enabled = self.enabled
        let sessions = self.sessions
        let now = self.now
        let calendar = self.calendar
        return MCPUsageBridge(
            isEnabled: { enabled.value },
            reports: { queries, calendar in try recorder.run(queries, calendar) },
            currentSessionID: { sessions.lookUp($0) },
            now: { now.value },
            calendar: { calendar.value })
    }

    /// Calls `usage_report` and parses the result as a JSON object.
    private func report(
        _ arguments: [String: Any] = [:], surfaceID: UUID? = nil, bridge: MCPUsageBridge? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String: Any] {
        let text = try await (bridge ?? makeBridge())
            .handleToolCall(name: "usage_report", arguments: arguments, surfaceID: surfaceID)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any], "not a JSON object: \(text)", file: file, line: line)
    }

    /// The text `usage_report` returns, unparsed.
    private func reportText(_ arguments: [String: Any] = [:]) async throws -> String {
        try await makeBridge().handleToolCall(name: "usage_report", arguments: arguments, surfaceID: nil)
    }

    /// The one `reports` call made so far; fails unless there was exactly one.
    private func onlyCall(file: StaticString = #filePath, line: UInt = #line) throws -> ReportsRecorder.Call {
        let calls = recorder.calls
        XCTAssertEqual(calls.count, 1, "exactly one reports call per tool call", file: file, line: line)
        return try XCTUnwrap(calls.first, file: file, line: line)
    }

    /// The rows query of the one `reports` call.
    private func rowsQuery(file: StaticString = #filePath, line: UInt = #line) throws -> UsageTokenQuery {
        try XCTUnwrap(try onlyCall(file: file, line: line).queries.first, file: file, line: line)
    }

    /// Asserts that the call throws exactly `expected` and reads nothing.
    private func assertThrows(
        _ expected: MCPUsageBridgeError, _ arguments: [String: Any], surfaceID: UUID? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await makeBridge().handleToolCall(name: "usage_report", arguments: arguments, surfaceID: surfaceID)
            XCTFail("Expected \(expected) for \(arguments)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MCPUsageBridgeError, expected, "\(arguments)", file: file, line: line)
        }
        XCTAssertEqual(recorder.calls.count, 0, "nothing is read for \(arguments)", file: file, line: line)
    }

    /// Asserts that the call throws `.invalidArgument` naming `name`
    /// (`nil`: any name) and reads nothing. The reason text is free.
    private func assertInvalid(
        _ arguments: [String: Any], name: String?, surfaceID: UUID? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await makeBridge().handleToolCall(name: "usage_report", arguments: arguments, surfaceID: surfaceID)
            XCTFail("Expected invalidArgument for \(arguments)", file: file, line: line)
        } catch MCPUsageBridgeError.invalidArgument(let actualName, _) {
            if let name {
                XCTAssertEqual(actualName, name, "\(arguments)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected invalidArgument for \(arguments), got \(error)", file: file, line: line)
        }
        XCTAssertEqual(recorder.calls.count, 0, "nothing is read for \(arguments)", file: file, line: line)
    }

    /// A row whose four numbers all differ from each other and from any
    /// other row built with another `base`, so a field written under the
    /// wrong name, or taken from the wrong row, shows.
    private func row(
        _ key: [String?], base: Int64, unreported: Bool = false, lastMs: Int64 = 1_790_936_849_765
    ) -> UsageTokenRow {
        UsageTokenRow(
            key: key,
            isUnreported: unreported,
            inputTokens: base + 1,
            cacheReadTokens: base + 2,
            cacheCreationTokens: base + 3,
            outputTokens: base + 4,
            lastTimestampMs: lastMs)
    }

    /// A row with all four numbers equal to `value`.
    private func flatRow(_ value: Int64, unreported: Bool, lastMs: Int64 = 1_790_936_849_765) -> UsageTokenRow {
        UsageTokenRow(
            key: [], isUnreported: unreported, inputTokens: value, cacheReadTokens: value,
            cacheCreationTokens: value, outputTokens: value, lastTimestampMs: lastMs)
    }

    /// A JSON boolean parses as an NSNumber backed by CFBoolean; a JSON
    /// number does not, even when it is 0 or 1.
    private func isJSONBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `value` as a JSON boolean; nil (and a failure) for anything else.
    private func bool(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) -> Bool? {
        guard isJSONBoolean(value), let number = value as? NSNumber else {
            XCTFail("expected a JSON boolean, got \(String(describing: value))", file: file, line: line)
            return nil
        }
        return number.boolValue
    }

    private func int64(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) -> Int64? {
        guard let number = value as? NSNumber, !isJSONBoolean(value) else {
            XCTFail("expected a number, got \(String(describing: value))", file: file, line: line)
            return nil
        }
        return number.int64Value
    }

    /// Asserts an object carries the four token sums, in the order input,
    /// cache read, cache creation, output, under their wire names.
    private func assertSums(
        _ object: Any?, _ expected: [Int64], file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let dict = object as? [String: Any] else {
            return XCTFail("expected an object, got \(String(describing: object))", file: file, line: line)
        }
        XCTAssertEqual(expected.count, Self.sumNames.count, "Fixture error", file: file, line: line)
        for (name, value) in zip(Self.sumNames, expected) {
            XCTAssertEqual(int64(dict[name], file: file, line: line), value, name, file: file, line: line)
        }
    }

    /// Asserts a row object carries `expected`'s four sums, its
    /// `unreported` flag as a JSON boolean, and `lastTimestamp` as text.
    private func assertFields(
        _ object: Any?, _ expected: UsageTokenRow, lastTimestamp: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let dict = object as? [String: Any] else {
            return XCTFail("expected an object, got \(String(describing: object))", file: file, line: line)
        }
        assertSums(
            dict,
            [expected.inputTokens, expected.cacheReadTokens, expected.cacheCreationTokens, expected.outputTokens],
            file: file, line: line)
        XCTAssertEqual(bool(dict["unreported"], file: file, line: line), expected.isUnreported, file: file, line: line)
        XCTAssertEqual(dict["last_timestamp"] as? String, lastTimestamp, file: file, line: line)
    }

    /// Asserts the `totals` object: exactly its six members, the four
    /// sums, the last timestamp (nil: JSON null) and the `unreported`
    /// object with exactly its four sums.
    private func assertTotals(
        _ object: Any?, sums: [Int64], unreported: [Int64], lastTimestamp: String?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let totals = object as? [String: Any] else {
            return XCTFail("expected an object, got \(String(describing: object))", file: file, line: line)
        }
        XCTAssertEqual(Set(totals.keys), Self.totalsMembers, file: file, line: line)
        assertSums(totals, sums, file: file, line: line)
        if let lastTimestamp {
            XCTAssertEqual(totals["last_timestamp"] as? String, lastTimestamp, file: file, line: line)
        } else {
            XCTAssertTrue(
                totals["last_timestamp"] is NSNull, "last_timestamp: \(String(describing: totals["last_timestamp"]))",
                file: file, line: line)
        }
        let part = totals["unreported"] as? [String: Any]
        XCTAssertEqual(part.map { Set($0.keys) }, Set(Self.sumNames), "totals.unreported", file: file, line: line)
        assertSums(part, unreported, file: file, line: line)
    }

    /// The four token sums, in the order `assertSums` takes them.
    private static let sumNames = ["input_tokens", "cache_read_tokens", "cache_creation_tokens", "output_tokens"]
    /// Exactly the members of a row.
    private static let rowMembers: Set<String> = Set(sumNames).union(["key", "unreported", "last_timestamp"])
    /// Exactly the members of `totals`.
    private static let totalsMembers: Set<String> = Set(sumNames).union(["unreported", "last_timestamp"])

    private func schemaProperties(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let tool = try XCTUnwrap(MCPUsageBridge.tools.first, file: file, line: line)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any]
        return try XCTUnwrap(schema?["properties"] as? [String: Any], file: file, line: line)
    }

    // MARK: - Catalogue

    func test_tools_isTheOneUsageReportTool_withItsArguments() throws {
        let tools = MCPUsageBridge.tools

        XCTAssertEqual(tools.map(\.name), ["usage_report"])
        let tool = try XCTUnwrap(tools.first)
        XCTAssertFalse(tool.description.isEmpty)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        let properties = try XCTUnwrap(schema?["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            ["group_by", "days", "since", "until", "session_id", "project", "thread", "limit"])
    }

    func test_tool_description_isExactlyTheContractsText() throws {
        let tool = try XCTUnwrap(MCPUsageBridge.tools.first)

        XCTAssertEqual(
            tool.description,
            "Report Claude Code token usage as counted by Claude Code itself and received by Calyx, aggregated "
                + "by the group_by dimensions (default model and effort). Each row carries input, cache read, "
                + "cache creation and output token sums and the last timestamp; rows with unreported true are "
                + "tokens Calyx knows were used but did not receive in detail. totals covers every matching row, "
                + "also when limit cut the rows. Requires Settings > Agents > Usage Tracking.")
    }

    // The enum is exactly the seven wire names, in schema order; `branch`
    // is gone. The description is the contract's exact text.
    func test_groupBySchema_enumIsTheSevenWireNames_andTheDescriptionNamesThem() throws {
        let groupBy = try XCTUnwrap(try schemaProperties()["group_by"] as? [String: Any])
        let items = try XCTUnwrap(groupBy["items"] as? [String: Any])
        let seven = ["model", "effort", "thread", "agent_type", "day", "project", "session"]

        XCTAssertEqual(items["enum"] as? [String], seven)
        XCTAssertEqual(
            groupBy["description"] as? String,
            "Dimensions to group by, in key order: model, effort, thread, agent_type, day, project, session. "
                + "Default [\"model\", \"effort\"]; [] gives the totals as at most two rows (recorded, unreported)")
    }

    func test_threadSchema_descriptionIsExact() throws {
        let thread = try XCTUnwrap(try schemaProperties()["thread"] as? [String: Any])

        XCTAssertEqual(thread["type"] as? String, "string")
        XCTAssertEqual(thread["description"] as? String, "Only this thread: main, subagent or auxiliary")
    }

    func test_unknownToolName_throwsUnknownTool_andReadsNothing() async throws {
        do {
            _ = try await makeBridge().handleToolCall(name: "usage_other", arguments: [:], surfaceID: nil)
            XCTFail("Expected unknownTool")
        } catch {
            XCTAssertEqual(error as? MCPUsageBridgeError, .unknownTool("usage_other"))
        }
        XCTAssertEqual(recorder.calls.count, 0)
    }

    // MARK: - Tracking off

    func test_trackingOff_throwsTrackingDisabled_withItsText_andReadsNothing() async throws {
        enabled.value = false

        await assertThrows(.trackingDisabled, [:])
        XCTAssertEqual(
            MCPUsageBridgeError.trackingDisabled.localizedDescription,
            "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
    }

    // Tracking off is the answer whatever the arguments: it is checked
    // before any of them is validated or resolved.
    func test_trackingOff_isReportedBeforeAnyArgumentIsValidated() async throws {
        enabled.value = false

        await assertThrows(.trackingDisabled, ["days": 0])
        await assertThrows(.trackingDisabled, ["group_by": "model"])
        await assertThrows(.trackingDisabled, ["limit": 0, "thread": "nope"])
        await assertThrows(.trackingDisabled, ["session_id": "current"])
        XCTAssertEqual(sessions.asked, [], "`current` is not resolved while tracking is off")
    }

    // The setting is read at every call, never captured once.
    func test_isEnabled_isReadAtEveryCall() async throws {
        let bridge = makeBridge()

        enabled.value = false
        do {
            _ = try await bridge.handleToolCall(name: "usage_report", arguments: [:], surfaceID: nil)
            XCTFail("Expected trackingDisabled")
        } catch {
            XCTAssertEqual(error as? MCPUsageBridgeError, .trackingDisabled)
        }
        enabled.value = true
        _ = try await report(bridge: bridge)
        enabled.value = false
        do {
            _ = try await bridge.handleToolCall(name: "usage_report", arguments: [:], surfaceID: nil)
            XCTFail("Expected trackingDisabled")
        } catch {
            XCTAssertEqual(error as? MCPUsageBridgeError, .trackingDisabled)
        }

        XCTAssertEqual(recorder.calls.count, 1)
    }

    // MARK: - One reports call: rows and totals

    func test_everyFilter_reachesBothQueries_inOneReportsCall() async throws {
        _ = try await report([
            "group_by": ["model"],
            "since": "2026-10-01T12:34:56.789Z",
            "until": "2026-10-04T00:00:00Z",
            "session_id": "session-x",
            "project": "/work/repo",
            "thread": "subagent",
        ])

        let call = try onlyCall()
        XCTAssertEqual(call.queries, [
            UsageTokenQuery(
                groupBy: [.model], sinceMs: 1_790_858_096_789, untilMs: 1_791_072_000_000,
                sessionID: "session-x", project: .root("/work/repo"), thread: "subagent"),
            UsageTokenQuery(
                groupBy: [], sinceMs: 1_790_858_096_789, untilMs: 1_791_072_000_000,
                sessionID: "session-x", project: .root("/work/repo"), thread: "subagent"),
        ])
    }

    func test_eachToolCall_makesItsOwnSingleReportsCall() async throws {
        let bridge = makeBridge()

        _ = try await report(["group_by": ["model"]], bridge: bridge)
        _ = try await report(["group_by": ["thread"]], bridge: bridge)

        XCTAssertEqual(recorder.calls.map { $0.queries.map(\.groupBy) }, [[[.model], []], [[.thread], []]])
    }

    func test_aThrownReadError_isRethrown_andNotRetried() async throws {
        recorder.answer { _ in throw UsageStoreError.closed }

        do {
            _ = try await report()
            XCTFail("Expected the store's error")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .closed)
        }
        XCTAssertEqual(recorder.calls.count, 1)
    }

    // MARK: - group_by

    func test_groupBy_absent_defaultsToModelAndEffort() async throws {
        let result = try await report()

        XCTAssertEqual(try rowsQuery().groupBy, [.model, .effort])
        XCTAssertEqual(result["group_by"] as? [String], ["model", "effort"])
    }

    func test_groupBy_eachWireName_mapsToItsDimension_andNamesItsKey() async throws {
        let pairs: [(String, UsageTokenQuery.Dimension)] = [
            ("model", .model), ("effort", .effort), ("thread", .thread), ("agent_type", .agentType),
            ("day", .day), ("project", .project), ("session", .session),
        ]
        recorder.answer(rows: [row(["value"], base: 0)], totals: [row([], base: 0)])

        for (wire, dimension) in pairs {
            let result = try await report(["group_by": [wire]])

            let query = try XCTUnwrap(recorder.calls.last?.queries.first)
            XCTAssertEqual(query.groupBy, [dimension], wire)
            XCTAssertEqual(result["group_by"] as? [String], [wire])
            let rows = try XCTUnwrap(result["rows"] as? [[String: Any]], wire)
            let key = try XCTUnwrap(rows.first?["key"] as? [String: Any], wire)
            XCTAssertEqual(Set(key.keys), [wire])
            XCTAssertEqual(key[wire] as? String, "value", wire)
        }
    }

    func test_groupBy_keepsTheGivenOrder_inTheQueryAndTheKey() async throws {
        recorder.answer(rows: [row(["s1", "2026-10-02", "swift-specialist"], base: 0)], totals: [row([], base: 0)])

        let result = try await report(["group_by": ["session", "day", "agent_type"]])

        XCTAssertEqual(try rowsQuery().groupBy, [.session, .day, .agentType])
        XCTAssertEqual(result["group_by"] as? [String], ["session", "day", "agent_type"])
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        let key = try XCTUnwrap(rows.first?["key"] as? [String: Any])
        XCTAssertEqual(key["session"] as? String, "s1")
        XCTAssertEqual(key["day"] as? String, "2026-10-02")
        XCTAssertEqual(key["agent_type"] as? String, "swift-specialist")
    }

    func test_groupBy_empty_givesOneTotalRowWithAnEmptyKey() async throws {
        recorder.answer(rows: [row([], base: 10)], totals: [row([], base: 10)])

        let result = try await report(["group_by": [String]()])

        XCTAssertEqual(try onlyCall().queries.first?.groupBy, [])
        XCTAssertEqual(result["group_by"] as? [String], [])
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual((rows.first?["key"] as? [String: Any])?.isEmpty, true)
        assertFields(rows.first, row([], base: 10), lastTimestamp: "2026-10-02T10:27:29.765Z")
    }

    func test_groupBy_invalid_isRejected() async throws {
        await assertInvalid(["group_by": ["models"]], name: "group_by")
        await assertInvalid(["group_by": ["agentType"]], name: "group_by")
        await assertInvalid(["group_by": ["Model"]], name: "group_by")
        await assertInvalid(["group_by": ["model", "effort", "model"]], name: "group_by")
        await assertInvalid(["group_by": "model"], name: "group_by")
        await assertInvalid(["group_by": ["model", 1] as [Any]], name: "group_by")
        await assertInvalid(["group_by": ["model": true]], name: "group_by")
    }

    // `branch` is no dimension of the token data: an unknown dimension,
    // alone or among valid ones, and nothing is read.
    func test_groupBy_branch_isAnUnknownDimension() async throws {
        for groupBy in [["branch"], ["model", "branch"]] {
            do {
                _ = try await makeBridge().handleToolCall(
                    name: "usage_report", arguments: ["group_by": groupBy], surfaceID: nil)
                XCTFail("Expected invalidArgument for \(groupBy)")
            } catch {
                XCTAssertEqual(
                    error as? MCPUsageBridgeError,
                    .invalidArgument(name: "group_by", reason: "unknown dimension branch"), "\(groupBy)")
            }
        }
        XCTAssertEqual(recorder.calls.count, 0)
    }

    // MARK: - days

    // 2026-10-02T20:00Z is 2026-10-03 05:00 in Tokyo: `days: 1` starts
    // at Tokyo's midnight, which is 15:00 UTC the day before.
    func test_days_isTheLocalMidnightOfTheInjectedCalendar_eastOfUTC() async throws {
        now.value = Self.date(ms: 1_790_971_200_000)
        calendar.value = try Self.calendar("Asia/Tokyo")

        let result = try await report(["days": 1])

        let call = try onlyCall()
        XCTAssertEqual(call.queries.map(\.sinceMs), [1_790_953_200_000, 1_790_953_200_000])
        XCTAssertEqual(call.queries.map(\.untilMs), [nil, nil])
        XCTAssertEqual(call.calendar.timeZone.identifier, "Asia/Tokyo")
        XCTAssertEqual(result["since"] as? String, "2026-10-02T15:00:00.000Z")
        XCTAssertTrue(result["until"] is NSNull, "until: \(String(describing: result["until"]))")
        XCTAssertEqual(result["time_zone"] as? String, "Asia/Tokyo")
    }

    // New York springs forward on 2026-03-08. Three days back from
    // 2026-03-10 12:00 EDT is 2026-03-08 00:00 EST = 05:00Z, not the
    // 04:00Z that 2 x 86,400 s before 2026-03-10 00:00 EDT would give.
    func test_days_acrossADSTChange_stepsByCalendarDays() async throws {
        now.value = Self.date(ms: 1_773_158_400_000)
        calendar.value = try Self.calendar("America/New_York")

        let result = try await report(["days": 3])

        XCTAssertEqual(try rowsQuery().sinceMs, 1_772_946_000_000)
        XCTAssertEqual(result["since"] as? String, "2026-03-08T05:00:00.000Z")
        XCTAssertEqual(result["time_zone"] as? String, "America/New_York")
    }

    // Sao Paulo's 2018-11-04 began at 01:00 (DST started at midnight):
    // that day is still the answer for `days: 7` on 2018-11-10.
    func test_days_whenThatDayHasNoMidnight_startsAtItsFirstInstant() async throws {
        now.value = Self.date(ms: 1_541_851_200_000) // 2018-11-10T12:00:00Z
        calendar.value = try Self.calendar("America/Sao_Paulo")

        let result = try await report(["days": 7])

        XCTAssertEqual(try rowsQuery().sinceMs, 1_541_300_400_000)
        XCTAssertEqual(result["since"] as? String, "2018-11-04T03:00:00.000Z")
    }

    // The largest valid window is accepted: 99,999 days before
    // 2026-10-02 is 1752-12-18 (Python `date.fromordinal`).
    func test_days_atTheMaximum_isAccepted() async throws {
        let result = try await report(["days": 100_000])

        XCTAssertEqual(try rowsQuery().sinceMs, -6_849_014_400_000)
        XCTAssertEqual(result["since"] as? String, "1752-12-18T00:00:00.000Z")
    }

    // Above the maximum the reason states the allowed range.
    func test_days_aboveTheMaximum_isRejectedWithTheRange_andReadsNothing() async throws {
        do {
            _ = try await makeBridge().handleToolCall(name: "usage_report", arguments: ["days": 100_001], surfaceID: nil)
            XCTFail("Expected invalidArgument")
        } catch MCPUsageBridgeError.invalidArgument(let name, let reason) {
            XCTAssertEqual(name, "days")
            XCTAssertTrue(reason.contains("100000"), reason)
            XCTAssertFalse(reason.contains("no such day"), reason)
        }
        XCTAssertEqual(recorder.calls.count, 0)
    }

    func test_daysDescription_statesTheRange() throws {
        let tool = try XCTUnwrap(MCPUsageBridge.tools.first)
        let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)) as? [String: Any]
        let days = (schema?["properties"] as? [String: Any])?["days"] as? [String: Any]

        XCTAssertTrue((days?["description"] as? String)?.contains("100000") == true, "\(String(describing: days))")
    }

    // A Japanese calendar in Tokyo means the same days as a Gregorian one.
    func test_days_withAJapaneseCalendar_givesTheGregorianSince() async throws {
        now.value = Self.date(ms: 1_790_971_200_000)
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        calendar.value = japanese

        let result = try await report(["days": 7])

        XCTAssertEqual(try rowsQuery().sinceMs, 1_790_434_800_000)
        XCTAssertEqual(result["since"] as? String, "2026-09-26T15:00:00.000Z")
    }

    // `now` and the calendar are read at each call.
    func test_days_readsNowAndTheCalendarAtEachCall() async throws {
        let bridge = makeBridge()

        _ = try await report(["days": 1], bridge: bridge)
        now.value = Self.date(ms: 1_790_971_200_000)
        calendar.value = try Self.calendar("Asia/Tokyo")
        _ = try await report(["days": 1], bridge: bridge)

        XCTAssertEqual(recorder.calls.map { $0.queries.first?.sinceMs }, [1_790_899_200_000, 1_790_953_200_000])
    }

    func test_days_invalid_isRejected() async throws {
        await assertInvalid(["days": 0], name: "days")
        await assertInvalid(["days": -1], name: "days")
        await assertInvalid(["days": 2.5], name: "days")
        await assertInvalid(["days": "3"], name: "days")
        await assertInvalid(["days": true], name: "days")
        await assertInvalid(["days": NSNull()], name: "days")
    }

    // A number of days the calendar cannot step back is an invalid
    // argument, not a report from the calendar's earliest date.
    func test_days_beyondTheCalendar_isRejected_andReadsNothing() async throws {
        await assertInvalid(["days": Int.max], name: "days")
        await assertInvalid(["days": NSNumber(value: Int64.max)], name: "days")
        await assertInvalid(["days": 1_000_000_000], name: "days")
    }

    func test_days_togetherWithSinceOrUntil_isRejected() async throws {
        await assertInvalid(["days": 1, "since": "2026-10-01T00:00:00Z"], name: nil)
        await assertInvalid(["days": 1, "until": "2026-10-04T00:00:00Z"], name: nil)
        await assertInvalid(
            ["days": 1, "since": "2026-10-01T00:00:00Z", "until": "2026-10-04T00:00:00Z"], name: nil)
    }

    // MARK: - since / until

    func test_sinceAndUntil_passThroughMillisecondExact_andAreEchoed() async throws {
        let result = try await report(["since": "2026-10-01T12:34:56.789Z", "until": "2026-10-04T00:00:00Z"])

        let query = try rowsQuery()
        XCTAssertEqual(query.sinceMs, 1_790_858_096_789)
        XCTAssertEqual(query.untilMs, 1_791_072_000_000)
        XCTAssertEqual(result["since"] as? String, "2026-10-01T12:34:56.789Z")
        XCTAssertEqual(result["until"] as? String, "2026-10-04T00:00:00.000Z")
    }

    func test_noTimeBounds_echoesNullForBoth() async throws {
        let result = try await report()

        let query = try rowsQuery()
        XCTAssertNil(query.sinceMs)
        XCTAssertNil(query.untilMs)
        XCTAssertTrue(result["since"] is NSNull, "since: \(String(describing: result["since"]))")
        XCTAssertTrue(result["until"] is NSNull, "until: \(String(describing: result["until"]))")
    }

    // The shapes the transcript parser accepts: no fraction, a short
    // fraction, a fraction longer than milliseconds (truncated, never
    // rounded), a leap day.
    func test_since_acceptsEveryShapeTheTranscriptParserAccepts() async throws {
        let cases: [(String, Int64)] = [
            ("2026-10-01T12:34:56Z", 1_790_858_096_000),
            ("2026-10-01T12:34:56.7Z", 1_790_858_096_700),
            ("2026-10-01T12:34:56.789999Z", 1_790_858_096_789),
            ("2028-02-29T00:00:00Z", 1_835_395_200_000),
        ]
        let bridge = makeBridge()

        for (text, _) in cases {
            _ = try await report(["since": text], bridge: bridge)
            _ = try await report(["until": text], bridge: bridge)
        }

        let calls = recorder.calls
        XCTAssertEqual(calls.count, cases.count * 2)
        guard calls.count == cases.count * 2 else { return }
        for (index, (text, expected)) in cases.enumerated() {
            XCTAssertEqual(calls[2 * index].queries.first?.sinceMs, expected, "since \(text)")
            XCTAssertEqual(calls[2 * index + 1].queries.first?.untilMs, expected, "until \(text)")
        }
    }

    // The shapes the transcript parser rejects, among them some a general
    // ISO 8601 parser would take.
    func test_sinceAndUntil_rejectEveryShapeTheTranscriptParserRejects() async throws {
        let rejected = [
            "2026-10-01T12:34:56+00:00",
            "2026-10-01T12:34:56.000+09:00",
            "2026-10-01T12:34:56.Z",
            "2026-10-01T12:34:56z",
            "2026-10-01 12:34:56Z",
            "2026-10-01",
            "2026-02-30T00:00:00Z",
            "2026-10-01T24:00:00Z",
            "2026-13-01T00:00:00Z",
            "",
        ]
        for text in rejected {
            await assertInvalid(["since": text], name: "since")
            await assertInvalid(["until": text], name: "until")
        }
        await assertInvalid(["since": 1_790_858_096_789], name: "since")
        await assertInvalid(["until": 1_790_858_096_789], name: "until")
    }

    func test_sinceNotBeforeUntil_isNotAnError() async throws {
        let result = try await report(["since": "2026-10-04T00:00:00Z", "until": "2026-10-01T00:00:00Z"])

        let query = try rowsQuery()
        XCTAssertEqual(query.sinceMs, 1_791_072_000_000)
        XCTAssertEqual(query.untilMs, 1_790_812_800_000)
        XCTAssertEqual((result["rows"] as? [Any])?.count, 0)
        XCTAssertEqual(int64(result["row_count"]), 0)
    }

    // MARK: - session_id

    func test_sessionID_givenExplicitly_isTheFilter() async throws {
        _ = try await report(["session_id": "11111111-2222-3333-4444-555555555555"])

        XCTAssertEqual(try rowsQuery().sessionID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(try onlyCall().queries.last?.sessionID, "11111111-2222-3333-4444-555555555555")
    }

    func test_sessionID_current_isTheCallingPanesSession_resolvedAtEachCall() async throws {
        let pane = UUID()
        let otherPane = UUID()
        sessions.set("session-of-pane", for: pane)
        sessions.set("session-of-other-pane", for: otherPane)
        let bridge = makeBridge()

        _ = try await report(["session_id": "current"], surfaceID: pane, bridge: bridge)
        _ = try await report(["session_id": "current"], surfaceID: otherPane, bridge: bridge)
        sessions.set("next-session-of-pane", for: pane)
        _ = try await report(["session_id": "current"], surfaceID: pane, bridge: bridge)

        XCTAssertEqual(
            recorder.calls.map { $0.queries.map(\.sessionID) },
            [
                ["session-of-pane", "session-of-pane"],
                ["session-of-other-pane", "session-of-other-pane"],
                ["next-session-of-pane", "next-session-of-pane"],
            ])
        XCTAssertEqual(sessions.asked, [pane, otherPane, pane])
    }

    func test_sessionID_current_withoutASurface_throwsNoCurrentSession() async throws {
        await assertThrows(.noCurrentSession, ["session_id": "current"], surfaceID: nil)
        XCTAssertEqual(
            MCPUsageBridgeError.noCurrentSession.localizedDescription,
            "No agent session is known for the calling pane.")
    }

    func test_sessionID_current_whenThePaneHasNoSession_throwsNoCurrentSession() async throws {
        let pane = UUID()

        await assertThrows(.noCurrentSession, ["session_id": "current"], surfaceID: pane)
        XCTAssertEqual(sessions.asked, [pane])
    }

    func test_sessionID_nonString_isRejected() async throws {
        await assertInvalid(["session_id": 42], name: "session_id")
        await assertInvalid(["session_id": ["current"]], name: "session_id")
    }

    // MARK: - project / thread

    func test_project_isAnExactRootFilter() async throws {
        _ = try await report(["project": "/Users/someone/repo"])

        XCTAssertEqual(try onlyCall().queries.map(\.project), [.root("/Users/someone/repo"), .root("/Users/someone/repo")])
    }

    func test_project_nonString_isRejected() async throws {
        await assertInvalid(["project": 1], name: "project")
        await assertInvalid(["project": ["/a"]], name: "project")
    }

    func test_thread_eachValue_isTheThreadFilter() async throws {
        let bridge = makeBridge()

        for value in ["main", "subagent", "auxiliary"] {
            _ = try await report(["thread": value], bridge: bridge)
        }

        XCTAssertEqual(
            recorder.calls.map { $0.queries.map(\.thread) },
            [["main", "main"], ["subagent", "subagent"], ["auxiliary", "auxiliary"]])
    }

    func test_thread_invalid_isRejected() async throws {
        await assertInvalid(["thread": "Main"], name: "thread")
        await assertInvalid(["thread": "sidechain"], name: "thread")
        await assertInvalid(["thread": ""], name: "thread")
        await assertInvalid(["thread": 1], name: "thread")
    }

    // `advisor` was a version-1 thread; the token data names it
    // `auxiliary`. Any other string is rejected with the contract's reason.
    func test_thread_unknownLabel_isRejectedWithTheThreeAllowedValues() async throws {
        for value in ["advisor", "Auxiliary", "sidechain"] {
            do {
                _ = try await makeBridge().handleToolCall(
                    name: "usage_report", arguments: ["thread": value], surfaceID: nil)
                XCTFail("Expected invalidArgument for \(value)")
            } catch {
                XCTAssertEqual(
                    error as? MCPUsageBridgeError,
                    .invalidArgument(name: "thread", reason: "expected main, subagent or auxiliary"), value)
            }
        }
        XCTAssertEqual(recorder.calls.count, 0)
    }

    func test_unknownArgumentNames_areIgnored() async throws {
        _ = try await report(["group_by": ["model"], "format": "csv", "verbose": true])

        XCTAssertEqual(try rowsQuery(), UsageTokenQuery(groupBy: [.model]))
    }

    // MARK: - limit, row_count, truncated

    // `row_count` counts the groups before `limit`; `rows` are the first
    // `limit` in the order the store gave; `totals` comes from the totals
    // query (recorded 9,001.. plus unreported 50,001..), so it is neither
    // the sum of the rows kept nor of all three rows.
    func test_limit_truncatesRows_rowCountIsBeforeLimit_totalsComeFromTheTotalsQuery() async throws {
        let rows = [row([nil], base: 100), row(["a"], base: 200), row(["b"], base: 300)]
        recorder.answer(
            rows: rows, totals: [row([], base: 9_000), row([], base: 50_000, unreported: true)])

        let result = try await report(["group_by": ["effort"], "limit": 2])

        let output = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue((output.first?["key"] as? [String: Any])?["effort"] is NSNull)
        XCTAssertEqual((output.last?["key"] as? [String: Any])?["effort"] as? String, "a")
        assertFields(output.first, rows[0], lastTimestamp: "2026-10-02T10:27:29.765Z")
        assertFields(output.last, rows[1], lastTimestamp: "2026-10-02T10:27:29.765Z")
        XCTAssertEqual(int64(result["row_count"]), 3)
        XCTAssertEqual(bool(result["truncated"]), true)
        assertTotals(
            result["totals"], sums: [59_002, 59_004, 59_006, 59_008], unreported: [50_001, 50_002, 50_003, 50_004],
            lastTimestamp: "2026-10-02T10:27:29.765Z")
    }

    func test_limit_default_is200() async throws {
        let many = (0..<201).map { row([String(format: "m%03d", $0)], base: Int64($0) * 10) }
        recorder.answer(rows: many, totals: [row([], base: 1)])

        let result = try await report(["group_by": ["model"]])

        let output = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(output.count, 200)
        XCTAssertEqual((output.last?["key"] as? [String: Any])?["model"] as? String, "m199")
        XCTAssertEqual(int64(result["row_count"]), 201)
        XCTAssertEqual(bool(result["truncated"]), true)
    }

    func test_limit_notReached_isNotTruncated() async throws {
        let rows = [row(["a"], base: 0), row(["b"], base: 10)]
        recorder.answer(rows: rows, totals: [row([], base: 1)])

        let exact = try await report(["group_by": ["model"], "limit": 2])
        let above = try await report(["group_by": ["model"], "limit": 1_000])

        for result in [exact, above] {
            XCTAssertEqual((result["rows"] as? [Any])?.count, 2)
            XCTAssertEqual(int64(result["row_count"]), 2)
            XCTAssertEqual(bool(result["truncated"]), false)
        }
    }

    func test_limit_one_isAccepted() async throws {
        recorder.answer(rows: [row(["a"], base: 0), row(["b"], base: 10)], totals: [row([], base: 1)])

        let result = try await report(["group_by": ["model"], "limit": 1])

        XCTAssertEqual((result["rows"] as? [Any])?.count, 1)
        XCTAssertEqual(bool(result["truncated"]), true)
    }

    func test_limit_invalid_isRejected() async throws {
        await assertInvalid(["limit": 0], name: "limit")
        await assertInvalid(["limit": -5], name: "limit")
        await assertInvalid(["limit": 1_001], name: "limit")
        await assertInvalid(["limit": 1.5], name: "limit")
        await assertInvalid(["limit": "10"], name: "limit")
        await assertInvalid(["limit": true], name: "limit")
    }

    // MARK: - totals

    // Nothing matched: the totals query answers no row. Zeros everywhere,
    // a null timestamp, and an all-zero `unreported` object.
    func test_nothingMatched_totalsAreZeroWithANullTimestamp() async throws {
        let result = try await report()

        XCTAssertEqual((result["rows"] as? [Any])?.count, 0)
        XCTAssertEqual(int64(result["row_count"]), 0)
        XCTAssertEqual(bool(result["truncated"]), false)
        assertTotals(result["totals"], sums: [0, 0, 0, 0], unreported: [0, 0, 0, 0], lastTimestamp: nil)
    }

    // Recorded 101/102/103/104 + unreported 1,001/1,002/1,003/1,004. The
    // later timestamp is taken whichever row carries it: first on the
    // recorded row, then on the unreported one.
    func test_totals_sumRecordedAndUnreported_andTakeTheLaterTimestamp() async throws {
        let later: Int64 = 1_790_936_849_765 // 2026-10-02T10:27:29.765Z
        let earlier: Int64 = 1_790_899_200_000 // 2026-10-02T00:00:00.000Z
        let bridge = makeBridge()

        for (recordedMs, unreportedMs) in [(later, earlier), (earlier, later)] {
            recorder.answer(
                rows: [],
                totals: [
                    row([], base: 100, lastMs: recordedMs),
                    row([], base: 1_000, unreported: true, lastMs: unreportedMs),
                ])

            let result = try await report(["group_by": ["model"]], bridge: bridge)

            assertTotals(
                result["totals"], sums: [1_102, 1_104, 1_106, 1_108], unreported: [1_001, 1_002, 1_003, 1_004],
                lastTimestamp: "2026-10-02T10:27:29.765Z")
        }
    }

    // Every totals row is summed, however many: recorded 11.. + recorded
    // 201.. + unreported 3,001.. The latest of the three timestamps wins.
    func test_totals_sumEveryRowOfTheTotalsQuery_threeRows() async throws {
        recorder.answer(
            rows: [],
            totals: [
                row([], base: 10, lastMs: 1_790_899_200_000),
                row([], base: 200, lastMs: 1_790_936_849_765),
                row([], base: 3_000, unreported: true, lastMs: 1_790_899_200_000),
            ])

        let result = try await report(["group_by": ["model"]])

        assertTotals(
            result["totals"], sums: [3_213, 3_216, 3_219, 3_222], unreported: [3_001, 3_002, 3_003, 3_004],
            lastTimestamp: "2026-10-02T10:27:29.765Z")
    }

    // Only recorded tokens matched: the `unreported` object is zeros.
    func test_totals_withoutAnUnreportedRow_haveAZeroUnreportedPart() async throws {
        recorder.answer(rows: [], totals: [row([], base: 700, lastMs: 1_790_899_200_000)])

        let result = try await report(["group_by": ["model"]])

        assertTotals(
            result["totals"], sums: [701, 702, 703, 704], unreported: [0, 0, 0, 0],
            lastTimestamp: "2026-10-02T00:00:00.000Z")
    }

    // Only unreported tokens matched: the sums and the unreported part
    // are the same numbers.
    func test_totals_withOnlyAnUnreportedRow_areThatRowTwice() async throws {
        recorder.answer(rows: [], totals: [row([], base: 40, unreported: true, lastMs: 1_790_899_200_000)])

        let result = try await report(["group_by": ["model"]])

        assertTotals(
            result["totals"], sums: [41, 42, 43, 44], unreported: [41, 42, 43, 44],
            lastTimestamp: "2026-10-02T00:00:00.000Z")
    }

    // (Int64.max - 1) + 5 and Int64.max + Int64.max are not representable:
    // each sum stops at Int64.max instead of wrapping or trapping.
    func test_totals_saturateAtInt64Max() async throws {
        let bridge = makeBridge()

        recorder.answer(rows: [], totals: [flatRow(Int64.max - 1, unreported: false), flatRow(5, unreported: true)])
        let nearMax = try await report(["group_by": ["model"]], bridge: bridge)
        recorder.answer(
            rows: [], totals: [flatRow(Int64.max, unreported: false), flatRow(Int64.max, unreported: true)])
        let bothMax = try await report(["group_by": ["model"]], bridge: bridge)

        let max = Int64.max
        assertTotals(
            nearMax["totals"], sums: [max, max, max, max], unreported: [5, 5, 5, 5],
            lastTimestamp: "2026-10-02T10:27:29.765Z")
        assertTotals(
            bothMax["totals"], sums: [max, max, max, max], unreported: [max, max, max, max],
            lastTimestamp: "2026-10-02T10:27:29.765Z")
    }

    // MARK: - Result shape

    func test_result_hasExactlyTheDocumentedFields() async throws {
        recorder.answer(
            rows: [row(["claude-opus-5-5", "max", nil], base: 0)], totals: [row([], base: 0)])

        let result = try await report(["group_by": ["model", "effort", "agent_type"]])

        XCTAssertEqual(
            Set(result.keys),
            ["group_by", "since", "until", "time_zone", "rows", "row_count", "truncated", "totals", "notes"])
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(first.keys), Self.rowMembers)
        let key = try XCTUnwrap(first["key"] as? [String: Any])
        XCTAssertEqual(Set(key.keys), ["model", "effort", "agent_type"])
        XCTAssertEqual(key["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(key["effort"] as? String, "max")
        XCTAssertTrue(key["agent_type"] is NSNull, "a nil group is JSON null")
        let totals = try XCTUnwrap(result["totals"] as? [String: Any])
        XCTAssertEqual(Set(totals.keys), Self.totalsMembers)
        XCTAssertEqual((totals["unreported"] as? [String: Any]).map { Set($0.keys) }, Set(Self.sumNames))
    }

    // `unreported` is the row's own `isUnreported`, as a JSON boolean; an
    // unreported row's unknown effort is JSON null.
    func test_result_unreportedFlag_isEachRowsOwn() async throws {
        let rows = [
            row(["claude-opus-5-5", "high"], base: 0),
            row(["claude-opus-5-5", nil], base: 10, unreported: true, lastMs: 1_790_899_200_000),
        ]
        recorder.answer(rows: rows, totals: [row([], base: 0)])

        let result = try await report(["group_by": ["model", "effort"]])

        let output = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(output.count, 2)
        guard output.count == 2 else { return }
        assertFields(output[0], rows[0], lastTimestamp: "2026-10-02T10:27:29.765Z")
        assertFields(output[1], rows[1], lastTimestamp: "2026-10-02T00:00:00.000Z")
        XCTAssertEqual(bool(output[0]["unreported"]), false)
        XCTAssertEqual(bool(output[1]["unreported"]), true)
        XCTAssertEqual((output[1]["key"] as? [String: Any])?["model"] as? String, "claude-opus-5-5")
        XCTAssertTrue((output[1]["key"] as? [String: Any])?["effort"] is NSNull)
    }

    func test_result_rowsKeepTheStoresOrder_andEveryNumberIsExact() async throws {
        // 2^53 + 1 does not survive a trip through Double.
        let big = UsageTokenRow(
            key: ["z"], isUnreported: false, inputTokens: 9_007_199_254_740_993, cacheReadTokens: 2,
            cacheCreationTokens: 3, outputTokens: 9_007_199_254_740_995, lastTimestampMs: 1_790_899_200_000)
        let rows = [big, row([nil], base: 10, unreported: true), row(["a"], base: 20)]
        recorder.answer(rows: rows, totals: [row([], base: 30)])

        let result = try await report(["group_by": ["agent_type"]])

        let output = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(output.count, 3)
        guard output.count == 3 else { return }
        assertFields(output[0], big, lastTimestamp: "2026-10-02T00:00:00.000Z")
        assertFields(output[1], rows[1], lastTimestamp: "2026-10-02T10:27:29.765Z")
        assertFields(output[2], rows[2], lastTimestamp: "2026-10-02T10:27:29.765Z")
        XCTAssertEqual((output[0]["key"] as? [String: Any])?["agent_type"] as? String, "z")
        XCTAssertTrue((output[1]["key"] as? [String: Any])?["agent_type"] is NSNull)
    }

    func test_result_timeZone_isTheInjectedCalendars() async throws {
        calendar.value = try Self.calendar("Asia/Kolkata")

        let result = try await report()

        XCTAssertEqual(result["time_zone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(try onlyCall().calendar.timeZone.identifier, "Asia/Kolkata")
    }

    func test_result_notes_areTheThreeFixedNotes() async throws {
        let first = try await report()
        recorder.answer(rows: [row(["a"], base: 0, unreported: true)], totals: [row([], base: 0, unreported: true)])
        let second = try await report(["group_by": ["model"], "days": 3])

        let expected = [
            "Token counts are Claude Code's own, received over its telemetry while Calyx was running. Thinking "
                + "tokens are part of output_tokens.",
            "Rows with unreported true are tokens Claude Code counted in a tracked session that Calyx did not "
                + "receive (for example because Calyx was not running). Their model is known; effort, thread and "
                + "agent are not, so they are missing from results filtered by thread.",
            "A session is counted only if it was started while usage tracking was on.",
        ]
        XCTAssertEqual(first["notes"] as? [String], expected)
        XCTAssertEqual(second["notes"] as? [String], expected, "the notes do not depend on the query")
    }

    // JSONSerialization with sorted keys: the top-level keys appear in
    // alphabetical order in the text.
    func test_result_text_hasSortedKeys() async throws {
        let text = try await reportText()

        let order = ["group_by", "notes", "row_count", "rows", "since", "time_zone", "totals", "truncated", "until"]
        var positions: [Int] = []
        for name in order {
            let range = try XCTUnwrap(
                text.range(of: "\"\(name)\"\\s*:", options: .regularExpression), "\(name) in \(text)")
            positions.append(text.distance(from: text.startIndex, to: range.lowerBound))
        }
        XCTAssertEqual(positions, positions.sorted(), text)
    }
}
