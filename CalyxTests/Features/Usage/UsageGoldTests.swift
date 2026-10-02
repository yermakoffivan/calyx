//
//  UsageGoldTests.swift
//  CalyxTests
//
//  Pins UsageStore.report(_:calendar:), the Gold query layer of the usage
//  ledger: aggregation over the stored (deduplicated) records, output and
//  thinking tokens summed over FINAL records only, grouping by up to
//  several dimensions with nil as its own group, deterministic row order,
//  filters, and local-day bucketing in the injected calendar's time zone.
//
//  Expected values are computed by hand. Epoch-millisecond literals were
//  computed outside the code under test. All fixtures are synthetic.
//

import XCTest
@testable import Calyx

final class UsageGoldTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: UsageStore!

    /// 2026-10-02T10:00:00.000Z
    private let baseMs: Int64 = 1_790_935_200_000

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageGoldTests-\(UUID().uuidString)", isDirectory: true)
        store = try UsageStore(directory: tempDirectory.appendingPathComponent("usage", isDirectory: true))
    }

    override func tearDown() async throws {
        if let store {
            await store.close()
        }
        store = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier), "Fixture error: unknown time zone")
        return calendar
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Defaults: a final main-thread record with input 10, output 100,
    /// thinking 5, cache read 1000, cache creation 50 (20 of it 1h).
    private func makeRecord(
        key: String,
        sessionID: String = "s1",
        timestampMs: Int64 = 1_790_935_200_000,
        model: String = "opus",
        effort: String? = "high",
        thread: UsageRecord.Thread = .main,
        agentID: String? = nil,
        agentType: String? = nil,
        gitBranch: String? = "main",
        cwd: String? = "/tmp/project",
        inputTokens: Int64 = 10,
        outputTokens: Int64 = 100,
        thinkingTokens: Int64 = 5,
        cacheReadTokens: Int64 = 1_000,
        cacheCreationTokens: Int64 = 50,
        cacheCreation1hTokens: Int64 = 20,
        isFinal: Bool = true
    ) -> UsageRecord {
        UsageRecord(
            key: key,
            sessionID: sessionID,
            timestampMs: timestampMs,
            model: model,
            effort: effort,
            thread: thread,
            agentID: agentID,
            agentType: agentType,
            gitBranch: gitBranch,
            cwd: cwd,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            thinkingTokens: thinkingTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheCreation1hTokens: cacheCreation1hTokens,
            isFinal: isFinal
        )
    }

    private func seed(_ records: [UsageRecord]) async throws {
        try await store.apply(UsageBatch(records: records, session: nil, fileCheckpoint: nil))
    }

    private func seedSession(_ sessionID: String, root: String?) async throws {
        try await store.apply(UsageBatch(
            records: [],
            session: UsageSessionMeta(sessionID: sessionID, transcriptPath: "/t/\(sessionID).jsonl", projectRoot: root),
            fileCheckpoint: nil
        ))
    }

    /// A row made of `count` default final records (see `makeRecord`), all
    /// at `lastMs`.
    private func defaultRow(_ key: [String?], count: Int64, lastMs: Int64 = 1_790_935_200_000) -> UsageRow {
        UsageRow(
            key: key,
            responses: count,
            finalResponses: count,
            inputTokens: 10 * count,
            cacheReadTokens: 1_000 * count,
            cacheCreationTokens: 50 * count,
            cacheCreation1hTokens: 20 * count,
            outputTokensFinal: 100 * count,
            thinkingTokensFinal: 5 * count,
            lastTimestampMs: lastMs
        )
    }

    private func report(_ query: UsageQuery, calendar: Calendar? = nil) async throws -> [UsageRow] {
        try await store.report(query, calendar: calendar ?? utc)
    }

    // MARK: - Totals

    func test_report_emptyStore_returnsNoRowsEvenWithEmptyGroupBy() async throws {
        let total = try await report(UsageQuery())
        let grouped = try await report(UsageQuery(groupBy: [.model]))

        XCTAssertEqual(total, [])
        XCTAssertEqual(grouped, [])
    }

    func test_report_emptyGroupByWithMatches_returnsOneRowWithEmptyKey() async throws {
        try await seed([makeRecord(key: "m1"), makeRecord(key: "m2"), makeRecord(key: "m3")])

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [defaultRow([], count: 3)])
    }

    func test_report_outputAndThinkingSumFinalOnly_inputSideSumsEveryRecord() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: baseMs),
            // Non-final: its output 999 and thinking 888 must NOT be summed;
            // its input 7, cache read 300, cache creation 4 and 1h 3 must be.
            makeRecord(
                key: "m2", timestampMs: baseMs + 1_000,
                inputTokens: 7, outputTokens: 999, thinkingTokens: 888,
                cacheReadTokens: 300, cacheCreationTokens: 4, cacheCreation1hTokens: 3, isFinal: false),
        ])

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [
            UsageRow(
                key: [],
                responses: 2,
                finalResponses: 1,
                inputTokens: 17,
                cacheReadTokens: 1_300,
                cacheCreationTokens: 54,
                cacheCreation1hTokens: 23,
                outputTokensFinal: 100,
                thinkingTokensFinal: 5,
                lastTimestampMs: 1_790_935_201_000
            ),
        ])
    }

    func test_report_onlyNonFinalRecords_finalSumsAreZero() async throws {
        try await seed([makeRecord(key: "m1", outputTokens: 60, thinkingTokens: 9, isFinal: false)])

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [
            UsageRow(
                key: [], responses: 1, finalResponses: 0, inputTokens: 10, cacheReadTokens: 1_000,
                cacheCreationTokens: 50, cacheCreation1hTokens: 20, outputTokensFinal: 0,
                thinkingTokensFinal: 0, lastTimestampMs: 1_790_935_200_000),
        ])
    }

    func test_report_fiveLinesOfOneIDInSeparateBatches_countOnce() async throws {
        // Four partial lines with growing output, then the final line.
        let outputs: [Int64] = [10, 20, 30, 40]
        for (index, output) in outputs.enumerated() {
            try await seed([makeRecord(
                key: "m1", timestampMs: baseMs + Int64(index) * 1_000,
                outputTokens: output, thinkingTokens: 0, isFinal: false)])
        }
        try await seed([makeRecord(key: "m1", timestampMs: baseMs + 4_000, outputTokens: 420, thinkingTokens: 150)])

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [
            UsageRow(
                key: [], responses: 1, finalResponses: 1, inputTokens: 10, cacheReadTokens: 1_000,
                cacheCreationTokens: 50, cacheCreation1hTokens: 20, outputTokensFinal: 420,
                thinkingTokensFinal: 150, lastTimestampMs: 1_790_935_204_000),
        ])
    }

    func test_report_lastTimestampIsTheMaximumOfTheGroup() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: baseMs + 5_000),
            makeRecord(key: "m2", timestampMs: baseMs + 9_000),
            makeRecord(key: "m3", timestampMs: baseMs + 1_000),
        ])

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [defaultRow([], count: 3, lastMs: 1_790_935_209_000)])
    }

    // MARK: - Single dimensions

    func test_report_groupByModel_oneRowPerModelOrderedByName() async throws {
        try await seed([
            makeRecord(key: "m1", model: "opus"),
            makeRecord(key: "m2", model: "haiku"),
            makeRecord(key: "m3", model: "opus"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.model]))

        XCTAssertEqual(rows, [defaultRow(["haiku"], count: 1), defaultRow(["opus"], count: 2)])
    }

    func test_report_groupByEffort_nilEffortIsItsOwnGroupListedFirst() async throws {
        try await seed([
            makeRecord(key: "m1", effort: "high"),
            makeRecord(key: "m2", effort: nil),
            makeRecord(key: "m3", effort: "low"),
            makeRecord(key: "m4", effort: nil),
        ])

        let rows = try await report(UsageQuery(groupBy: [.effort]))

        XCTAssertEqual(rows, [
            defaultRow([nil], count: 2), defaultRow(["high"], count: 1), defaultRow(["low"], count: 1),
        ])
    }

    func test_report_groupByThread_usesTheRawValue() async throws {
        try await seed([
            makeRecord(key: "m1", thread: .subagent),
            makeRecord(key: "m2", thread: .main),
            makeRecord(key: "m3", thread: .advisor),
            makeRecord(key: "m4", thread: .subagent),
        ])

        let rows = try await report(UsageQuery(groupBy: [.thread]))

        XCTAssertEqual(rows, [
            defaultRow(["advisor"], count: 1), defaultRow(["main"], count: 1), defaultRow(["subagent"], count: 2),
        ])
    }

    func test_report_groupByAgentType_nilGroupIsKept() async throws {
        try await seed([
            makeRecord(key: "m1", thread: .subagent, agentType: "swift-specialist"),
            makeRecord(key: "m2"),
            makeRecord(key: "m3", thread: .subagent, agentType: "code-reviewer"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.agentType]))

        XCTAssertEqual(rows, [
            defaultRow([nil], count: 1),
            defaultRow(["code-reviewer"], count: 1),
            defaultRow(["swift-specialist"], count: 1),
        ])
    }

    func test_report_groupByBranch_usesGitBranchAndKeepsTheNilGroup() async throws {
        try await seed([
            makeRecord(key: "m1", gitBranch: "main"),
            makeRecord(key: "m2", gitBranch: nil),
            makeRecord(key: "m3", gitBranch: "feature/x"),
            makeRecord(key: "m4", gitBranch: "main"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.branch]))

        XCTAssertEqual(rows, [
            defaultRow([nil], count: 1), defaultRow(["feature/x"], count: 1), defaultRow(["main"], count: 2),
        ])
    }

    func test_report_groupBySession_usesTheSessionID() async throws {
        try await seed([
            makeRecord(key: "m1", sessionID: "s2"),
            makeRecord(key: "m2", sessionID: "s1"),
            makeRecord(key: "m3", sessionID: "s2"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.session]))

        XCTAssertEqual(rows, [defaultRow(["s1"], count: 1), defaultRow(["s2"], count: 2)])
    }

    // MARK: - Project dimension and filter

    /// s1 has a row with a root; s2 has no session row at all; s3 has a row
    /// whose root is nil; s4 has a row with another root.
    private func seedProjects() async throws {
        try await seedSession("s1", root: "/r/one")
        try await seedSession("s3", root: nil)
        try await seedSession("s4", root: "/r/two")
        try await seed([
            makeRecord(key: "m1", sessionID: "s1"),
            makeRecord(key: "m2", sessionID: "s1"),
            makeRecord(key: "m3", sessionID: "s2"),
            makeRecord(key: "m4", sessionID: "s3"),
            makeRecord(key: "m5", sessionID: "s4"),
        ])
    }

    func test_report_groupByProject_unattributedSessionsShareTheNilGroup() async throws {
        try await seedProjects()

        let rows = try await report(UsageQuery(groupBy: [.project]))

        XCTAssertEqual(rows, [
            defaultRow([nil], count: 2), defaultRow(["/r/one"], count: 2), defaultRow(["/r/two"], count: 1),
        ])
    }

    func test_report_totals_includeUnattributedRecords() async throws {
        try await seedProjects()

        let rows = try await report(UsageQuery())

        XCTAssertEqual(rows, [defaultRow([], count: 5)])
    }

    func test_report_projectFilterRoot_matchesOnlySessionsWithThatRoot() async throws {
        try await seedProjects()

        let one = try await report(UsageQuery(groupBy: [.session], project: .root("/r/one")))
        let unknown = try await report(UsageQuery(project: .root("/r/none")))

        XCTAssertEqual(one, [defaultRow(["s1"], count: 2)])
        XCTAssertEqual(unknown, [])
    }

    func test_report_projectFilterUnattributed_matchesSessionsWithoutRowOrWithoutRoot() async throws {
        try await seedProjects()

        let rows = try await report(UsageQuery(groupBy: [.session], project: .unattributed))

        XCTAssertEqual(rows, [defaultRow(["s2"], count: 1), defaultRow(["s3"], count: 1)])
    }

    // MARK: - Several dimensions

    private func seedModelThreadMatrix() async throws {
        try await seed([
            makeRecord(key: "m1", model: "opus", thread: .main),
            makeRecord(key: "m2", model: "opus", thread: .subagent),
            makeRecord(key: "m3", model: "haiku", thread: .subagent),
            makeRecord(key: "m4", model: "opus", thread: .subagent),
        ])
    }

    func test_report_groupByModelThenThread_keyFollowsGroupByOrder() async throws {
        try await seedModelThreadMatrix()

        let rows = try await report(UsageQuery(groupBy: [.model, .thread]))

        XCTAssertEqual(rows, [
            defaultRow(["haiku", "subagent"], count: 1),
            defaultRow(["opus", "main"], count: 1),
            defaultRow(["opus", "subagent"], count: 2),
        ])
    }

    func test_report_groupByThreadThenModel_keyAndOrderFollowTheSwappedGroupBy() async throws {
        try await seedModelThreadMatrix()

        let rows = try await report(UsageQuery(groupBy: [.thread, .model]))

        XCTAssertEqual(rows, [
            defaultRow(["main", "opus"], count: 1),
            defaultRow(["subagent", "haiku"], count: 1),
            defaultRow(["subagent", "opus"], count: 2),
        ])
    }

    func test_report_groupByThreeDimensions_keyHasThreeElementsInGroupByOrder() async throws {
        try await seed([
            makeRecord(key: "m1", sessionID: "s1", model: "opus", effort: "high"),
            makeRecord(key: "m2", sessionID: "s1", model: "opus", effort: "high"),
            makeRecord(key: "m3", sessionID: "s1", model: "opus", effort: nil),
            makeRecord(key: "m4", sessionID: "s2", model: "haiku", effort: nil),
            makeRecord(key: "m5", sessionID: "s1", model: "haiku", effort: "low"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.session, .model, .effort]))

        XCTAssertEqual(rows, [
            defaultRow(["s1", "haiku", "low"], count: 1),
            defaultRow(["s1", "opus", nil], count: 1),
            defaultRow(["s1", "opus", "high"], count: 2),
            defaultRow(["s2", "haiku", nil], count: 1),
        ])
    }

    func test_report_rowOrder_nilSortsBeforeAnyStringAtEachKeyPosition() async throws {
        try await seed([
            makeRecord(key: "m1", effort: "high", gitBranch: "main"),
            makeRecord(key: "m2", effort: nil, gitBranch: "main"),
            makeRecord(key: "m3", effort: "high", gitBranch: nil),
            makeRecord(key: "m4", effort: nil, gitBranch: nil),
            makeRecord(key: "m5", effort: "high", gitBranch: "feature/x"),
        ])

        let rows = try await report(UsageQuery(groupBy: [.effort, .branch]))

        XCTAssertEqual(rows.map(\.key), [
            [nil, nil],
            [nil, "main"],
            ["high", nil],
            ["high", "feature/x"],
            ["high", "main"],
        ])
        XCTAssertEqual(rows.map(\.responses), [1, 1, 1, 1, 1])
    }

    func test_report_duplicateDimension_throwsInvalidQuery() async throws {
        try await seed([makeRecord(key: "m1")])

        do {
            _ = try await report(UsageQuery(groupBy: [.model, .thread, .model]))
            XCTFail("A dimension listed twice must throw")
        } catch {
            XCTAssertEqual(error as? UsageStoreError, .invalidQuery)
        }
    }

    // MARK: - Filters

    func test_report_threadFilter_matchesOnlyThatThread() async throws {
        try await seed([
            makeRecord(key: "m1", thread: .main),
            makeRecord(key: "m2", thread: .subagent),
            makeRecord(key: "m3", thread: .subagent),
            makeRecord(key: "m4", thread: .advisor),
        ])

        let subagent = try await report(UsageQuery(thread: .subagent))
        let advisor = try await report(UsageQuery(groupBy: [.thread], thread: .advisor))

        XCTAssertEqual(subagent, [defaultRow([], count: 2)])
        XCTAssertEqual(advisor, [defaultRow(["advisor"], count: 1)])
    }

    func test_report_sessionFilter_matchesOnlyThatSession() async throws {
        try await seed([
            makeRecord(key: "m1", sessionID: "s1"),
            makeRecord(key: "m2", sessionID: "s2"),
            makeRecord(key: "m3", sessionID: "s2"),
        ])

        let s2 = try await report(UsageQuery(sessionID: "s2"))
        let none = try await report(UsageQuery(sessionID: "s9"))

        XCTAssertEqual(s2, [defaultRow([], count: 2)])
        XCTAssertEqual(none, [])
    }

    private func seedThreeInstants() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: baseMs),
            makeRecord(key: "m2", timestampMs: baseMs + 1_000),
            makeRecord(key: "m3", timestampMs: baseMs + 2_000),
        ])
    }

    func test_report_sinceIsInclusive() async throws {
        try await seedThreeInstants()

        let rows = try await report(UsageQuery(groupBy: [.session], sinceMs: baseMs + 1_000))

        XCTAssertEqual(rows, [defaultRow(["s1"], count: 2, lastMs: 1_790_935_202_000)])
    }

    func test_report_untilIsExclusive() async throws {
        try await seedThreeInstants()

        let rows = try await report(UsageQuery(untilMs: baseMs + 2_000))

        XCTAssertEqual(rows, [defaultRow([], count: 2, lastMs: 1_790_935_201_000)])
    }

    func test_report_sinceAndUntilTogether_selectTheHalfOpenRange() async throws {
        try await seedThreeInstants()

        let rows = try await report(UsageQuery(sinceMs: baseMs + 1_000, untilMs: baseMs + 2_000))

        XCTAssertEqual(rows, [defaultRow([], count: 1, lastMs: 1_790_935_201_000)])
    }

    func test_report_sinceEqualToOrAfterUntil_returnsNoRows() async throws {
        try await seedThreeInstants()

        let equal = try await report(UsageQuery(sinceMs: baseMs + 1_000, untilMs: baseMs + 1_000))
        let reversed = try await report(UsageQuery(sinceMs: baseMs + 2_000, untilMs: baseMs))

        XCTAssertEqual(equal, [])
        XCTAssertEqual(reversed, [])
    }

    func test_report_filtersCombine() async throws {
        try await seedSession("s1", root: "/r/one")
        try await seed([
            makeRecord(key: "m1", sessionID: "s1", timestampMs: baseMs, thread: .subagent),
            makeRecord(key: "m2", sessionID: "s1", timestampMs: baseMs + 1_000, thread: .main),
            makeRecord(key: "m3", sessionID: "s1", timestampMs: baseMs + 2_000, thread: .subagent),
            makeRecord(key: "m4", sessionID: "s2", timestampMs: baseMs + 2_000, thread: .subagent),
        ])

        let rows = try await report(UsageQuery(
            sinceMs: baseMs + 1_000, sessionID: "s1", project: .root("/r/one"), thread: .subagent))

        XCTAssertEqual(rows, [defaultRow([], count: 1, lastMs: 1_790_935_202_000)])
    }

    // MARK: - Advisor records

    func test_report_advisorRecords_appearUnderTheirOwnModelAndAdvisorThread() async throws {
        try await seed([
            makeRecord(key: "m1", model: "opus", thread: .main),
            makeRecord(
                key: "m1#adv1", model: "fable", effort: nil, thread: .advisor,
                inputTokens: 125_008, outputTokens: 10_278, thinkingTokens: 0,
                cacheReadTokens: 77, cacheCreationTokens: 55, cacheCreation1hTokens: 0),
        ])

        let rows = try await report(UsageQuery(groupBy: [.model, .thread]))

        XCTAssertEqual(rows, [
            UsageRow(
                key: ["fable", "advisor"], responses: 1, finalResponses: 1, inputTokens: 125_008,
                cacheReadTokens: 77, cacheCreationTokens: 55, cacheCreation1hTokens: 0,
                outputTokensFinal: 10_278, thinkingTokensFinal: 0, lastTimestampMs: 1_790_935_200_000),
            defaultRow(["opus", "main"], count: 1),
        ])
    }

    // MARK: - Day bucketing

    func test_report_groupByDay_2330ZIsADifferentDayInUTCAndTokyo() async throws {
        // 2026-10-02T23:30:00Z is 2026-10-03T08:30 in Asia/Tokyo (UTC+9).
        try await seed([makeRecord(key: "m1", timestampMs: 1_790_983_800_000)])

        let inUTC = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("UTC"))
        let inTokyo = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("Asia/Tokyo"))

        XCTAssertEqual(inUTC, [defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_983_800_000)])
        XCTAssertEqual(inTokyo, [defaultRow(["2026-10-03"], count: 1, lastMs: 1_790_983_800_000)])
    }

    func test_report_groupByDay_kolkataMidnightSplitsAtHalfHourOffset() async throws {
        // Asia/Kolkata is UTC+5:30, so local midnight is 18:30:00.000Z.
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_790_965_799_999),   // 2026-10-02T18:29:59.999Z
            makeRecord(key: "m2", timestampMs: 1_790_965_800_000),   // 2026-10-02T18:30:00.000Z
        ])

        let rows = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("Asia/Kolkata"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_965_799_999),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_790_965_800_000),
        ])
    }

    func test_report_groupByDay_newYorkSpringForward_usesTheLocalMidnightsOfEachDay() async throws {
        // 2026-03-08 in America/New_York starts at 05:00Z (EST, UTC-5) and,
        // after the 02:00 spring-forward, ends at 2026-03-09T04:00Z (EDT, UTC-4).
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_772_945_999_999),   // 03-08T04:59:59.999Z -> local 03-07
            makeRecord(key: "m2", timestampMs: 1_772_946_000_000),   // 03-08T05:00:00.000Z -> local 03-08
            makeRecord(key: "m3", timestampMs: 1_773_028_799_999),   // 03-09T03:59:59.999Z -> local 03-08
            makeRecord(key: "m4", timestampMs: 1_773_028_800_000),   // 03-09T04:00:00.000Z -> local 03-09
        ])

        let rows = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("America/New_York"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-03-07"], count: 1, lastMs: 1_772_945_999_999),
            defaultRow(["2026-03-08"], count: 2, lastMs: 1_773_028_799_999),
            defaultRow(["2026-03-09"], count: 1, lastMs: 1_773_028_800_000),
        ])
    }

    func test_report_groupByDayWithoutSinceOrUntil_coversEveryStoredDayInOrder() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_791_021_600_000),   // 2026-10-03T10:00Z
            makeRecord(key: "m2", timestampMs: 1_709_202_449_765),   // 2024-02-29T10:27:29.765Z
            makeRecord(key: "m3", timestampMs: 1_790_935_200_000),   // 2026-10-02T10:00Z
            makeRecord(key: "m4", timestampMs: 1_790_935_201_000),   // 2026-10-02T10:00:01Z
        ])

        let rows = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("UTC"))

        XCTAssertEqual(rows, [
            defaultRow(["2024-02-29"], count: 1, lastMs: 1_709_202_449_765),
            defaultRow(["2026-10-02"], count: 2, lastMs: 1_790_935_201_000),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_791_021_600_000),
        ])
    }

    func test_report_groupByDayAndModel_dayIsOneKeyElementAmongOthers() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_790_935_200_000, model: "opus"),    // 2026-10-02
            makeRecord(key: "m2", timestampMs: 1_791_021_600_000, model: "haiku"),   // 2026-10-03
            makeRecord(key: "m3", timestampMs: 1_791_021_600_000, model: "opus"),    // 2026-10-03
        ])

        let rows = try await report(UsageQuery(groupBy: [.model, .day]), calendar: calendar("UTC"))

        XCTAssertEqual(rows, [
            defaultRow(["haiku", "2026-10-03"], count: 1, lastMs: 1_791_021_600_000),
            defaultRow(["opus", "2026-10-02"], count: 1, lastMs: 1_790_935_200_000),
            defaultRow(["opus", "2026-10-03"], count: 1, lastMs: 1_791_021_600_000),
        ])
    }

    // MARK: - Pinned decision: fall-back DST day

    func test_report_groupByDay_newYorkFallBack_theLocalDayIs25HoursLong() async throws {
        // 2026-11-01 in America/New_York starts at 04:00Z (EDT, UTC-4) and,
        // after the 02:00 fall-back, ends at 2026-11-02T05:00Z (EST, UTC-5).
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_793_505_599_999),   // 11-01T03:59:59.999Z -> local 10-31
            makeRecord(key: "m2", timestampMs: 1_793_505_600_000),   // 11-01T04:00:00.000Z -> local 11-01
            makeRecord(key: "m3", timestampMs: 1_793_595_599_999),   // 11-02T04:59:59.999Z -> local 11-01
            makeRecord(key: "m4", timestampMs: 1_793_595_600_000),   // 11-02T05:00:00.000Z -> local 11-02
        ])

        let rows = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("America/New_York"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-31"], count: 1, lastMs: 1_793_505_599_999),
            defaultRow(["2026-11-01"], count: 2, lastMs: 1_793_595_599_999),
            defaultRow(["2026-11-02"], count: 1, lastMs: 1_793_595_600_000),
        ])
    }

    // MARK: - Review B2: day grouping with bounds and filters

    /// Five records around three Asia/Tokyo (UTC+9) local days.
    private func seedTokyoDays() async throws {
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_790_884_800_000),   // 10-01T20:00Z -> Tokyo 10-02 05:00
            makeRecord(key: "m2", timestampMs: 1_790_906_400_000),   // 10-02T02:00Z -> Tokyo 10-02 11:00
            makeRecord(key: "m3", timestampMs: 1_791_028_800_000),   // 10-03T12:00Z -> Tokyo 10-03 21:00
            makeRecord(key: "m4", timestampMs: 1_791_079_200_000),   // 10-04T02:00Z -> Tokyo 10-04 11:00
            makeRecord(key: "m5", timestampMs: 1_791_115_200_000),   // 10-04T12:00Z -> Tokyo 10-04 21:00
        ])
    }

    func test_report_groupByDayWithMidDaySinceAndUntil_countsOnlyTheIncludedPartsOfTheEdgeDays() async throws {
        try await seedTokyoDays()

        // since falls between m1 and m2 (mid 10-02), until between m4 and m5 (mid 10-04).
        let rows = try await report(
            UsageQuery(groupBy: [.day], sinceMs: 1_790_900_000_000, untilMs: 1_791_100_000_000),
            calendar: calendar("Asia/Tokyo"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_906_400_000),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_791_028_800_000),
            defaultRow(["2026-10-04"], count: 1, lastMs: 1_791_079_200_000),
        ])
    }

    func test_report_groupByDayWithOnlySince_dropsTheEarlierPartOfTheFirstDay() async throws {
        try await seedTokyoDays()

        let rows = try await report(
            UsageQuery(groupBy: [.day], sinceMs: 1_790_900_000_000), calendar: calendar("Asia/Tokyo"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_906_400_000),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_791_028_800_000),
            defaultRow(["2026-10-04"], count: 2, lastMs: 1_791_115_200_000),
        ])
    }

    func test_report_groupByDayWithOnlyUntil_dropsTheLaterPartOfTheLastDay() async throws {
        try await seedTokyoDays()

        let rows = try await report(
            UsageQuery(groupBy: [.day], untilMs: 1_791_100_000_000), calendar: calendar("Asia/Tokyo"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 2, lastMs: 1_790_906_400_000),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_791_028_800_000),
            defaultRow(["2026-10-04"], count: 1, lastMs: 1_791_079_200_000),
        ])
    }

    /// s1 has root "/r/one"; s2 has no session row.
    private func seedDayThreadProjectMatrix() async throws {
        try await seedSession("s1", root: "/r/one")
        try await seed([
            makeRecord(key: "m1", sessionID: "s1", timestampMs: 1_790_942_400_000, thread: .subagent),   // 10-02T12:00Z
            makeRecord(key: "m2", sessionID: "s1", timestampMs: 1_791_028_800_000, thread: .subagent),   // 10-03T12:00Z
            makeRecord(key: "m3", sessionID: "s1", timestampMs: 1_790_942_400_000, thread: .main),       // 10-02T12:00Z
            makeRecord(key: "m4", sessionID: "s2", timestampMs: 1_790_942_400_000, thread: .subagent),   // 10-02T12:00Z
        ])
    }

    func test_report_groupByDayWithSessionThreadAndProjectFilters_appliesAllOfThem() async throws {
        try await seedDayThreadProjectMatrix()

        let rows = try await report(
            UsageQuery(groupBy: [.day], sessionID: "s1", project: .root("/r/one"), thread: .subagent),
            calendar: calendar("UTC"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_942_400_000),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_791_028_800_000),
        ])
    }

    func test_report_groupByThreadDayProject_dayIsTheMiddleKeyElement() async throws {
        try await seedDayThreadProjectMatrix()

        let rows = try await report(UsageQuery(groupBy: [.thread, .day, .project]), calendar: calendar("UTC"))

        XCTAssertEqual(rows, [
            defaultRow(["main", "2026-10-02", "/r/one"], count: 1, lastMs: 1_790_942_400_000),
            defaultRow(["subagent", "2026-10-02", nil], count: 1, lastMs: 1_790_942_400_000),
            defaultRow(["subagent", "2026-10-02", "/r/one"], count: 1, lastMs: 1_790_942_400_000),
            defaultRow(["subagent", "2026-10-03", "/r/one"], count: 1, lastMs: 1_791_028_800_000),
        ])
    }

    // MARK: - Review B3: 45-minute offset

    func test_report_groupByDay_kathmanduMidnightSplitsAtFortyFiveMinuteOffset() async throws {
        // Asia/Kathmandu is UTC+5:45, so local midnight is 18:15:00.000Z.
        try await seed([
            makeRecord(key: "m1", timestampMs: 1_790_964_899_999),   // 2026-10-02T18:14:59.999Z
            makeRecord(key: "m2", timestampMs: 1_790_964_900_000),   // 2026-10-02T18:15:00.000Z
        ])

        let rows = try await report(UsageQuery(groupBy: [.day]), calendar: calendar("Asia/Kathmandu"))

        XCTAssertEqual(rows, [
            defaultRow(["2026-10-02"], count: 1, lastMs: 1_790_964_899_999),
            defaultRow(["2026-10-03"], count: 1, lastMs: 1_790_964_900_000),
        ])
    }
}
