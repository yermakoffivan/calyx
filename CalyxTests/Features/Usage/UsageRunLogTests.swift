//
//  UsageRunLogTests.swift
//  CalyxTests
//
//  Pins UsageRunLog.apply(_:), the pure state machine that turns a
//  transcript's events (in file order) into closed runs: activity opens a
//  run at its FIRST line in file order and keeps the LATEST time as its
//  end; a cost-state closes the open run, or replaces the last closed
//  run's totals when no run is open (the second cost-state of one exit),
//  or opens-and-closes a run without times when nothing came before.
//  Then every fixture skeleton through ClaudeCostStateReader, against the
//  shared table in UsageRunLogFixtureSupport.swift.
//

import XCTest
@testable import Calyx

final class UsageRunLogTests: XCTestCase {

    private let totalsA = ["m": UsageTokenTotals(input: 1, output: 2, cacheRead: 3, cacheCreation: 4)]
    private let totalsB = ["m": UsageTokenTotals(input: 10, output: 20, cacheRead: 30, cacheCreation: 40)]
    private let totalsC = ["n": UsageTokenTotals(input: 7)]

    private func log(_ events: [ClaudeTranscriptRunEvent]) -> UsageRunLog {
        var log = UsageRunLog()
        for event in events {
            log.apply(event)
        }
        return log
    }

    private func activity(_ timeNs: Int64, _ cwd: String? = nil) -> ClaudeTranscriptRunEvent {
        .activity(timeNs: timeNs, cwd: cwd)
    }

    // MARK: - apply: activity

    func test_empty_hasNoRunsNoOpenRunAndNoCWD() {
        XCTAssertEqual(UsageRunLog(), UsageRunLog(runs: [], openBeginNs: nil, openEndNs: nil, cwd: nil))
    }

    func test_activity_withNoRunOpen_opensARunAtItsTime() {
        XCTAssertEqual(log([activity(100)]), UsageRunLog(runs: [], openBeginNs: 100, openEndNs: 100, cwd: nil))
    }

    func test_activity_laterTime_movesTheOpenEndOnly() {
        XCTAssertEqual(log([activity(100), activity(300)]),
                       UsageRunLog(runs: [], openBeginNs: 100, openEndNs: 300, cwd: nil))
    }

    func test_activity_olderLineAfterTheFirst_keepsTheBeginInFileOrder() {
        // Timestamps are not monotonic: the begin is the FIRST line, not
        // the smallest time.
        XCTAssertEqual(log([activity(200), activity(100)]),
                       UsageRunLog(runs: [], openBeginNs: 200, openEndNs: 200, cwd: nil))
    }

    func test_activity_endIsTheLatestTime_notTheLastLine() {
        XCTAssertEqual(log([activity(100), activity(300), activity(200)]),
                       UsageRunLog(runs: [], openBeginNs: 100, openEndNs: 300, cwd: nil))
    }

    func test_activity_firstNonNilCWDIsKept() {
        let result = log([activity(1, nil), activity(2, "/a"), activity(3, "/b"), activity(4, nil)])

        XCTAssertEqual(result.cwd, "/a")
    }

    func test_activity_cwdIsKeptAcrossRuns() {
        let result = log([activity(1, "/a"), .costState(totals: totalsA), activity(2, "/b")])

        XCTAssertEqual(result.cwd, "/a")
    }

    // MARK: - apply: cost-state

    func test_costState_withARunOpen_closesItAsRunOne_andClearsTheOpenRun() {
        XCTAssertEqual(log([activity(100, "/a"), activity(300), activity(200), .costState(totals: totalsA)]),
                       UsageRunLog(
                           runs: [UsageRun(sequence: 1, beginNs: 100, endNs: 300, totals: totalsA)],
                           openBeginNs: nil, openEndNs: nil, cwd: "/a"))
    }

    func test_secondCostState_withNoRunOpen_replacesTheLastRunsTotals_keepingItsTimes() {
        XCTAssertEqual(log([activity(100), activity(200), .costState(totals: totalsA), .costState(totals: totalsB)]),
                       UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: 100, endNs: 200, totals: totalsB)]))
    }

    func test_thirdCostState_replacesAgain() {
        let result = log([activity(100), .costState(totals: totalsA), .costState(totals: totalsB), .costState(totals: totalsC)])

        XCTAssertEqual(result.runs, [UsageRun(sequence: 1, beginNs: 100, endNs: 100, totals: totalsC)])
    }

    func test_costState_beforeAnyActivity_isARunWithoutTimes() {
        XCTAssertEqual(log([.costState(totals: totalsA)]),
                       UsageRunLog(runs: [UsageRun(sequence: 1, beginNs: nil, endNs: nil, totals: totalsA)]))
    }

    func test_costState_beforeAnyActivity_thenActivityAndCostState_isRunTwo() {
        let result = log([.costState(totals: totalsA), activity(500), activity(400), .costState(totals: totalsB)])

        XCTAssertEqual(result.runs, [
            UsageRun(sequence: 1, beginNs: nil, endNs: nil, totals: totalsA),
            UsageRun(sequence: 2, beginNs: 500, endNs: 500, totals: totalsB),
        ])
    }

    func test_costState_twiceBeforeAnyActivity_replacesTheTimelessRun() {
        XCTAssertEqual(log([.costState(totals: totalsA), .costState(totals: totalsB)]).runs,
                       [UsageRun(sequence: 1, beginNs: nil, endNs: nil, totals: totalsB)])
    }

    func test_threeRuns_areNumberedInFileOrder_eachWithItsOwnTimes() {
        let result = log([
            activity(10), activity(20), .costState(totals: totalsA),
            activity(5), activity(30), .costState(totals: totalsB),
            activity(40), activity(35), .costState(totals: totalsC),
        ])

        XCTAssertEqual(result.runs, [
            UsageRun(sequence: 1, beginNs: 10, endNs: 20, totals: totalsA),
            UsageRun(sequence: 2, beginNs: 5, endNs: 30, totals: totalsB),
            UsageRun(sequence: 3, beginNs: 40, endNs: 40, totals: totalsC),
        ])
    }

    func test_activityAfterAClosedRun_opensANewRun_notReopensTheOldOne() {
        let result = log([activity(10), .costState(totals: totalsA), activity(50)])

        XCTAssertEqual(result, UsageRunLog(
            runs: [UsageRun(sequence: 1, beginNs: 10, endNs: 10, totals: totalsA)],
            openBeginNs: 50, openEndNs: 50, cwd: nil))
    }

    func test_costStateWithNoModels_closesARunWithEmptyTotals() {
        XCTAssertEqual(log([activity(10), .costState(totals: [:])]).runs,
                       [UsageRun(sequence: 1, beginNs: 10, endNs: 10, totals: [:])])
    }

    func test_reapplyingTheSameEvents_toAFreshLog_givesAnEqualLog() {
        let events: [ClaudeTranscriptRunEvent] = [
            .costState(totals: totalsA), activity(10, "/a"), activity(5), .costState(totals: totalsB),
            .costState(totals: totalsC), activity(70, "/b"),
        ]

        XCTAssertEqual(log(events), log(events))
    }

    // MARK: - Fixtures

    private func assertFixtureLog(
        _ skeleton: UsageRunLogSkeleton, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(try UsageRunLogFixtures.log(skeleton), try UsageRunLogFixtures.expectedLog(skeleton),
                       "\(skeleton)", file: file, line: line)
    }

    func test_fixture_run1_oneRun() throws {
        try assertFixtureLog(UsageRunLogFixtures.run1)
    }

    func test_fixture_run2_oneRun_fromTwoCostStateLines() throws {
        let skeleton = UsageRunLogFixtures.run2
        let costStates = try UsageRunLogFixtures.events(skeleton).filter {
            if case .costState = $0 { return true } else { return false }
        }
        XCTAssertEqual(costStates.count, 2, "Fixture error: run2 ends with two cost-state lines")

        try assertFixtureLog(skeleton)
    }

    func test_fixture_run3_twoRuns() throws {
        try assertFixtureLog(UsageRunLogFixtures.run3)
    }

    func test_fixture_run3_secondRunMinusFirst_equalsRun3sOwnMetricUsage() throws {
        let runs = try UsageRunLogFixtures.log(UsageRunLogFixtures.run3).runs
        guard runs.count == 2, let first = runs.first, let second = runs.last else {
            return XCTFail("Expected two runs, got \(runs)")
        }
        // run3's metric: the last value of every series across its two
        // exports, summed by the telemetry tests' independent reader.
        let metric = UsageTelemetryFixtures.lastValueTotals(
            of: try UsageTelemetryFixtures.exports(run: "run3").map { try UsageTelemetryFixtures.rawTokenPoints(in: $0) })
        let metricTotals = try UsageRunLogFixtures.totals(fromModels: metric, source: "run3 metric")

        let difference = UsageRunLogFixtures.difference(second.totals, minus: first.totals)

        XCTAssertEqual(difference, metricTotals)
        // Pinned by hand: run3/expected-cost-state.json minus
        // run2/expected-cost-state.json for claude-sonnet-5-5 (the other
        // two models did not change).
        XCTAssertEqual(difference, [
            "claude-sonnet-5-5": UsageTokenTotals(input: 4, output: 204, cacheRead: 99_145, cacheCreation: 2_235),
        ])
    }

    func test_fixture_run4_oneRun_withTheBracketedModel() throws {
        try assertFixtureLog(UsageRunLogFixtures.run4)
        let runs = try UsageRunLogFixtures.log(UsageRunLogFixtures.run4).runs
        XCTAssertEqual(runs.first.map { Array($0.totals.keys) }, ["claude-opus-5-5[1m]"])
    }

    func test_fixture_run5Skeleton1_oneRun() throws {
        try assertFixtureLog(UsageRunLogFixtures.run5a)
    }

    func test_fixture_run5Skeleton2_oneRun_fromTwoCostStatesWithLastPromptBetween() throws {
        let objects = try UsageRunLogFixtures.objects(UsageRunLogFixtures.run5b)
        let tail = objects.suffix(3).map { $0["type"] as? String }
        XCTAssertEqual(tail, ["cost-state", "last-prompt", "cost-state"], "Fixture error")

        try assertFixtureLog(UsageRunLogFixtures.run5b)
    }

    func test_fixture_run5Skeleton2_beginIsTheFirstLine_althoughTheNextLineIsOlder() throws {
        let events = try UsageRunLogFixtures.events(UsageRunLogFixtures.run5b)
        let times = events.compactMap { event -> Int64? in
            if case .activity(let time, _) = event { return time } else { return nil }
        }
        guard times.count >= 2, let first = times.first else { return XCTFail("Fixture error: \(times)") }
        XCTAssertLessThan(times[1], first, "Fixture error: line 4 is older than line 3")

        let begin = try UsageRunLogFixtures.log(UsageRunLogFixtures.run5b).runs.first?.beginNs

        XCTAssertEqual(begin, first)
        XCTAssertEqual(begin, 1_791_184_138_489_000_000)
    }

    func test_fixture_run6_oneRun_beginIsTheFirstQueueOperation_althoughLaterLinesAreOlder() throws {
        let skeleton = UsageRunLogFixtures.run6
        let events = try UsageRunLogFixtures.events(skeleton)
        let smallest = events.compactMap { event -> Int64? in
            if case .activity(let time, _) = event { return time } else { return nil }
        }.min()
        let run = try XCTUnwrap(UsageRunLogFixtures.log(skeleton).runs.first)
        // Fixture: the copied parent history (06:59:47.404 at the oldest)
        // is older than the fork's first line (07:11:37.711).
        XCTAssertEqual(smallest, 1_791_183_587_404_000_000, "Fixture error")

        XCTAssertEqual(run.beginNs, 1_791_184_297_711_000_000)
        try assertFixtureLog(skeleton)
    }

    func test_fixture_run7Skeleton1_oneRun() throws {
        try assertFixtureLog(UsageRunLogFixtures.run7a)
    }

    func test_fixture_run7Skeleton2_beginIsTheFirstLineWithoutForkedFrom_andTotalsEqualTheBranchsMetric() throws {
        let skeleton = UsageRunLogFixtures.run7b
        let run = try XCTUnwrap(UsageRunLogFixtures.log(skeleton).runs.first)

        // Line 24 (system, 08:01:56.658), not line 1's copied 08:01:37.585.
        XCTAssertEqual(run.beginNs, 1_791_187_316_658_000_000)
        XCTAssertEqual(run.totals, try UsageRunLogFixtures.expectedMetricSums(run: "run7", sessionID: skeleton.sessionID))
        try assertFixtureLog(skeleton)
    }

    func test_fixture_run8Skeleton1_oneRun() throws {
        try assertFixtureLog(UsageRunLogFixtures.run8a)
    }

    func test_fixture_run8Skeleton2_twoRuns_fromThreeCostStateLines() throws {
        let costStates = try UsageRunLogFixtures.events(UsageRunLogFixtures.run8b).filter {
            if case .costState = $0 { return true } else { return false }
        }
        XCTAssertEqual(costStates.count, 3, "Fixture error")

        try assertFixtureLog(UsageRunLogFixtures.run8b)
    }

    func test_fixture_run8Skeleton2_secondRunMinusFirst_equalsTheResumedSessionsMetricSums() throws {
        let skeleton = UsageRunLogFixtures.run8b
        let runs = try UsageRunLogFixtures.log(skeleton).runs
        guard runs.count == 2, let first = runs.first, let second = runs.last else {
            return XCTFail("Expected two runs, got \(runs)")
        }

        let difference = UsageRunLogFixtures.difference(second.totals, minus: first.totals)

        XCTAssertEqual(difference, try UsageRunLogFixtures.expectedMetricSums(run: "run8", sessionID: skeleton.sessionID))
        // Pinned by hand: run8/expected-cost-state-2.json minus
        // run7/expected-cost-state-1.json for claude-sonnet-5-5.
        XCTAssertEqual(difference, [
            "claude-sonnet-5-5": UsageTokenTotals(input: 2, output: 4, cacheRead: 27_340, cacheCreation: 17_320),
        ])
    }

    func test_fixture_run9_eachSkeleton_oneRun() throws {
        for skeleton in [UsageRunLogFixtures.run9a, UsageRunLogFixtures.run9b, UsageRunLogFixtures.run9c] {
            try assertFixtureLog(skeleton)
        }
    }

    func test_fixture_run9Skeleton3_beginsAfterItsTwentySevenCopiedLines() throws {
        let skeleton = UsageRunLogFixtures.run9c
        let objects = try UsageRunLogFixtures.objects(skeleton)
        let copied = objects.prefix { $0["forkedFrom"] != nil }
        XCTAssertEqual(copied.count, 27, "Fixture error")

        let run = try XCTUnwrap(UsageRunLogFixtures.log(skeleton).runs.first)

        // Line 33 (system, 08:27:37.643).
        XCTAssertEqual(run.beginNs, 1_791_188_857_643_000_000)
    }

    func test_fixture_everySkeleton_eachRunsTotalsEqualTheMetricSumsWhereTheSessionStartedFromZero() throws {
        // Sessions born fresh, by /clear or by /branch start from zero, so
        // their single run's totals equal their own metric sums.
        let cases: [(UsageRunLogSkeleton, String)] = [
            (UsageRunLogFixtures.run5a, "run5"), (UsageRunLogFixtures.run5b, "run5"),
            (UsageRunLogFixtures.run7a, "run7"), (UsageRunLogFixtures.run8a, "run8"),
            (UsageRunLogFixtures.run9a, "run9"), (UsageRunLogFixtures.run9b, "run9"), (UsageRunLogFixtures.run9c, "run9"),
        ]
        for (skeleton, run) in cases {
            let runs = try UsageRunLogFixtures.log(skeleton).runs

            XCTAssertEqual(runs.map(\.totals), [try UsageRunLogFixtures.expectedMetricSums(run: run, sessionID: skeleton.sessionID)],
                           "\(skeleton)")
        }
    }

    func test_fixture_reapplyingAFilesEvents_toAFreshLog_givesAnEqualLog() throws {
        for skeleton in UsageRunLogFixtures.all {
            XCTAssertEqual(try UsageRunLogFixtures.log(skeleton), try UsageRunLogFixtures.log(skeleton), "\(skeleton)")
        }
    }
}
