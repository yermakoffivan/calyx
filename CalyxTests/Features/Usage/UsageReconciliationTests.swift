//
//  UsageReconciliationTests.swift
//  CalyxTests
//
//  Pins UsageReconciliation, the pure comparison of what Calyx recorded of
//  a session (heard buckets, dated by receive minute) with Claude Code's
//  own cumulative totals per closed run: which runs are reconciled (rules
//  1-3), the usage of a run (rule 4), what counts as received for a run
//  (rule 5), the shortfall and the rows built from its suffix minima
//  (rules 6-7), and the surplus (rule 8). Every expected value below is
//  computed by hand from the contract's rules on small synthetic inputs.
//
//  Times: minute `m` of these tests is minute `baseMinute + m` since the
//  epoch; `ns(m, s)` is second `s` of it.
//

import XCTest
@testable import Calyx

final class UsageReconciliationTests: XCTestCase {

    // MARK: - Builders

    private static let baseMinute: Int64 = 29_853_100
    private static let sonnet = "claude-sonnet-5-5"
    private static let haiku = "claude-haiku-4-5-20251001"

    /// Second `second` of test minute `minute` in nanoseconds since the epoch.
    private func ns(_ minute: Int64, _ second: Int64 = 0) -> Int64 {
        (Self.baseMinute + minute) * 60_000_000_000 + second * 1_000_000_000
    }

    private func tt(_ input: Int64 = 0, _ output: Int64 = 0, _ cacheRead: Int64 = 0, _ cacheCreation: Int64 = 0)
        -> UsageTokenTotals {
        UsageTokenTotals(input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation)
    }

    private func run(_ sequence: Int, _ beginNs: Int64?, _ endNs: Int64?, _ totals: [String: UsageTokenTotals]) -> UsageRun {
        UsageRun(sequence: sequence, beginNs: beginNs, endNs: endNs, totals: totals)
    }

    /// A bucket received in test minute `minute`.
    private func bucket(_ minute: Int64, _ totals: UsageTokenTotals, model: String = UsageReconciliationTests.sonnet)
        -> UsageHeardBucket {
        UsageHeardBucket(minute: Self.baseMinute + minute, model: model, totals: totals)
    }

    private func start(_ startNs: Int64, _ type: String?) -> UsageProcessStart {
        UsageProcessStart(sessionID: "session-a", startNs: startNs, startType: type)
    }

    private func input(
        _ runs: [UsageRun],
        trackedFromNs: Int64? = nil,
        starts: [UsageProcessStart] = [],
        firstHeardNs: Int64? = nil,
        heard: [UsageHeardBucket] = []
    ) -> UsageReconcileInput {
        UsageReconcileInput(
            runs: runs, trackedFromNs: trackedFromNs ?? ns(-100), processStarts: starts,
            firstHeardNs: firstHeardNs, heard: heard)
    }

    private func row(_ sequence: Int, _ timeNs: Int64, _ totals: UsageTokenTotals,
                     model: String = UsageReconciliationTests.sonnet) -> UsageUnreportedRow {
        UsageUnreportedRow(sequence: sequence, timeNs: timeNs, model: model, totals: totals)
    }

    private var emptyOutcome: UsageReconcileOutcome {
        UsageReconcileOutcome(firstSequence: nil, rows: [], surplus: [:])
    }

    // MARK: - The standard session
    //
    // Run 1: minutes 0-2, cumulative sonnet (100, 200, 3000, 400).
    // Run 2: minutes 10-12, cumulative sonnet (150, 260, 5000, 450).
    // So D1 = (100, 200, 3000, 400) and D2 = (50, 60, 2000, 50).

    private var run1End: Int64 { ns(2, 30) }
    private var run2End: Int64 { ns(12, 30) }

    private var standardRuns: [UsageRun] {
        [
            run(1, ns(0), run1End, [Self.sonnet: tt(100, 200, 3000, 400)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(150, 260, 5000, 450)]),
        ]
    }

    private var freshBeforeRun1: UsageProcessStart { start(ns(-1, 30), "fresh") }

    /// Everything of both runs received, each in its own run's minutes.
    private var everythingHeard: [UsageHeardBucket] {
        [bucket(1, tt(100, 200, 3000, 400)), bucket(11, tt(50, 60, 2000, 50))]
    }

    private var firstRunOnlyStandard: [UsageRun] { Array(standardRuns.prefix(1)) }

    // MARK: - Rule 1: heard at all

    func test_rule1_noProcessStartAndNoFirstHeard_isEmpty_evenWithHeardBuckets() {
        let outcome = UsageReconciliation.reconcile(input(standardRuns, heard: [bucket(1, tt(10))]))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    func test_rule1_aProcessStartAlone_isEnough_andNothingHeardIsAllUnreported() {
        let outcome = UsageReconciliation.reconcile(input(standardRuns, starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome.firstSequence, 1)
        XCTAssertEqual(outcome.rows, [row(1, run1End, tt(100, 200, 3000, 400)), row(2, run2End, tt(50, 60, 2000, 50))])
        XCTAssertEqual(outcome.surplus, [:])
    }

    func test_rule1_firstHeardAlone_isEnough() {
        let outcome = UsageReconciliation.reconcile(
            input(standardRuns, firstHeardNs: ns(1), heard: [bucket(1, tt(100, 200, 3000, 400))]))
        XCTAssertEqual(outcome.firstSequence, 1)
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(50, 60, 2000, 50))])
    }

    // MARK: - Rule 2: which runs

    func test_rule2_trackingBeforeEveryRun_reconcilesFromRun1() {
        let outcome = UsageReconciliation.reconcile(
            input(standardRuns, trackedFromNs: ns(-50), starts: [freshBeforeRun1], heard: everythingHeard))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
    }

    func test_rule2_trackingExactlyAtRun1Begin_includesRun1() {
        let outcome = UsageReconciliation.reconcile(
            input(standardRuns, trackedFromNs: ns(0), starts: [freshBeforeRun1], heard: everythingHeard))
        XCTAssertEqual(outcome.firstSequence, 1)
    }

    func test_rule2_trackingOneNanosecondAfterRun1Begin_excludesRun1() {
        let outcome = UsageReconciliation.reconcile(
            input(standardRuns, trackedFromNs: ns(0) + 1, starts: [freshBeforeRun1], heard: everythingHeard))
        XCTAssertEqual(outcome.firstSequence, 2)
    }

    func test_rule2_trackingInsideRun1_reconcilesFromRun2_withOnlyRun2sShortfall() {
        // Run 1 is out; lower bound = minute 2 (run 1's end). The minute-1
        // bucket is ignored; run 2 needs D2 = (50, 60, 2000, 50) and got
        // (20, 60, 2000, 50): row (30, 0, 0, 0).
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, trackedFromNs: ns(1), starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 3000, 400)), bucket(11, tt(20, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 2, rows: [row(2, run2End, tt(30))], surplus: [:]))
    }

    func test_rule2_trackingInsideRun2OfThree_reconcilesOnlyRun3() {
        let runs = [
            run(1, ns(0), ns(1), [Self.sonnet: tt(10)]),
            run(2, ns(10), ns(11), [Self.sonnet: tt(30)]),
            run(3, ns(20), ns(21), [Self.sonnet: tt(60)]),
        ]
        // Run 2 began before tracking even though it ended after it.
        let outcome = UsageReconciliation.reconcile(input(runs, trackedFromNs: ns(10, 30), starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 3, rows: [row(3, ns(21), tt(30))], surplus: [:]))
    }

    func test_rule2_trackingAfterEveryRunBegan_isEmpty() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, trackedFromNs: ns(10, 1), starts: [start(ns(11), "fresh")], firstHeardNs: ns(11),
            heard: [bucket(11, tt(1))]))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    func test_rule2_aRunWithoutBegin_endsTheSuffix_evenWhenAnEarlierRunBeganAfterTracking() {
        // Run 2 has no activity; the longest suffix is run 3 alone. Run 2 has
        // no end either, so there is no lower bound. D3 = 170 - 150 = 20.
        let runs = [
            run(1, ns(0), ns(1), [Self.sonnet: tt(100)]),
            run(2, nil, nil, [Self.sonnet: tt(150)]),
            run(3, ns(20), ns(21), [Self.sonnet: tt(170)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 3, rows: [row(3, ns(21), tt(20))], surplus: [:]))
    }

    func test_rule2_lastRunWithoutBegin_isEmpty() {
        let runs = [
            run(1, ns(0), ns(1), [Self.sonnet: tt(100)]),
            run(2, nil, nil, [Self.sonnet: tt(150)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1], firstHeardNs: ns(0, 30)))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    func test_rule2_noRuns_isEmpty() {
        let outcome = UsageReconciliation.reconcile(input([], starts: [freshBeforeRun1], heard: [bucket(1, tt(5))]))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    // MARK: - Rule 3: the first run needs proof that it started from zero

    private func firstSequence(starts: [UsageProcessStart], firstHeardNs: Int64? = nil,
                               runs: [UsageRun]? = nil) -> Int? {
        UsageReconciliation.reconcile(
            input(runs ?? standardRuns, starts: starts, firstHeardNs: firstHeardNs, heard: everythingHeard)).firstSequence
    }

    func test_rule3_freshStartBeforeRun1End_keepsRun1() {
        XCTAssertEqual(firstSequence(starts: [freshBeforeRun1]), 1)
    }

    func test_rule3_resumeStartBeforeRun1End_dropsRun1_keepsRun2() {
        XCTAssertEqual(firstSequence(starts: [start(ns(-1, 30), "resume")]), 2)
    }

    func test_rule3_resumeStartBeforeRun1End_withoutRun2_isEmpty() {
        let outcome = UsageReconciliation.reconcile(input(
            firstRunOnlyStandard, starts: [start(ns(-1, 30), "resume")], firstHeardNs: ns(1),
            heard: [bucket(1, tt(1))]))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    func test_rule3_resumeStartAfterRun1End_isTheOrdinaryResume_run1Kept() {
        XCTAssertEqual(firstSequence(starts: [freshBeforeRun1, start(ns(9, 50), "resume")]), 1)
    }

    func test_rule3_resumeStartAfterRun1End_withFirstHeardInsideRun1_run1Kept() {
        XCTAssertEqual(firstSequence(starts: [start(ns(9, 50), "resume")], firstHeardNs: ns(1)), 1)
    }

    func test_rule3_nilStartTypeBeforeRun1End_dropsRun1() {
        XCTAssertEqual(firstSequence(starts: [start(ns(-1, 30), nil)]), 2)
    }

    func test_rule3_continueStartBeforeRun1End_dropsRun1() {
        XCTAssertEqual(firstSequence(starts: [start(ns(-1, 30), "continue")]), 2)
    }

    func test_rule3_resumeStartExactlyAtRun1End_dropsRun1() {
        XCTAssertEqual(firstSequence(starts: [start(run1End, "resume")], firstHeardNs: ns(1)), 2)
    }

    func test_rule3_resumeStartOneNanosecondAfterRun1End_keepsRun1() {
        XCTAssertEqual(firstSequence(starts: [start(run1End + 1, "resume")], firstHeardNs: ns(1)), 1)
    }

    func test_rule3_freshStartExactlyAtRun1End_isEvidence() {
        XCTAssertEqual(firstSequence(starts: [start(run1End, "fresh")]), 1)
    }

    func test_rule3_freshStartAfterRun1End_isNoEvidence() {
        XCTAssertEqual(firstSequence(starts: [start(run1End + 1, "fresh")]), 2)
    }

    func test_rule3_noStart_firstHeardInsideRun1_keepsRun1() {
        // `/clear` and `/branch`: a session born inside a running process.
        XCTAssertEqual(firstSequence(starts: [], firstHeardNs: ns(1)), 1)
    }

    func test_rule3_noStart_firstHeardExactlyAtRun1End_keepsRun1() {
        XCTAssertEqual(firstSequence(starts: [], firstHeardNs: run1End), 1)
    }

    func test_rule3_noStart_firstHeardOneSecondAfterRun1End_dropsRun1() {
        // Strict: no allowance for the seconds an export takes.
        XCTAssertEqual(firstSequence(starts: [], firstHeardNs: run1End + 1_000_000_000), 2)
    }

    func test_rule3_noStart_firstHeardOneNanosecondAfterRun1End_dropsRun1() {
        XCTAssertEqual(firstSequence(starts: [], firstHeardNs: run1End + 1), 2)
    }

    func test_rule3_noStart_firstHeardAfterRun1End_withoutRun2_isEmpty() {
        let outcome = UsageReconciliation.reconcile(input(
            firstRunOnlyStandard, firstHeardNs: run1End + 1_000_000_000, heard: [bucket(3, tt(100, 200, 3000, 400))]))
        XCTAssertEqual(outcome, emptyOutcome)
    }

    func test_rule3_neitherStartNorFirstHeard_isEmpty() {
        XCTAssertNil(firstSequence(starts: []))
    }

    func test_rule3_droppedRun1_itsUsageIsNotReported() {
        // A fork: run 1's totals include the parent's. Run 1 dropped; lower
        // bound minute 2; run 2's D2 fully received: nothing to report.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [start(ns(-1, 30), "resume")], heard: [bucket(11, tt(50, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 2, rows: [], surplus: [:]))
    }

    // MARK: - Rule 4: usage of a run

    func test_rule4_ordinaryDeltas_secondRunsShortfallIsItsDelta() {
        let outcome = UsageReconciliation.reconcile(
            input(standardRuns, starts: [freshBeforeRun1], heard: [bucket(1, tt(100, 200, 3000, 400))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(50, 60, 2000, 50))])
    }

    func test_rule4_aModelAppearingInRun2_countsWhole() {
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(100)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(100), Self.haiku: tt(7, 8)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(100))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(7, 8), model: Self.haiku)])
    }

    func test_rule4_aModelThatShrank_meansARestart_run2CountsWhole() {
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(100, 100, 100, 100)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(50, 200, 200, 200)]),
        ]
        let outcome = UsageReconciliation.reconcile(
            input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(100, 100, 100, 100))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(50, 200, 200, 200))])
    }

    func test_rule4_aVanishedModelWithAPositivePreviousValue_meansARestart() {
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(10, 10, 10, 10), Self.haiku: tt(5)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(20, 20, 20, 20)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(10, 10, 10, 10)), bucket(1, tt(5), model: Self.haiku)]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(20, 20, 20, 20))])
    }

    func test_rule4_aVanishedModelWhosePreviousValueWasZero_isNoRestart() {
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(10, 10, 10, 10), Self.haiku: tt()]),
            run(2, ns(10), run2End, [Self.sonnet: tt(20, 20, 20, 20)]),
        ]
        let outcome = UsageReconciliation.reconcile(
            input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(10, 10, 10, 10))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(10, 10, 10, 10))])
    }

    func test_rule4_aShrinkInOneModel_restartsEveryModel() {
        // Haiku shrank, so sonnet's D2 is its whole run-2 total (30), not 10.
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(20), Self.haiku: tt(9)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(30), Self.haiku: tt(4)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(20)), bucket(1, tt(9), model: Self.haiku)]))
        XCTAssertEqual(outcome.rows, [
            row(2, run2End, tt(4), model: Self.haiku),
            row(2, run2End, tt(30)),
        ])
    }

    // MARK: - Rules 5-7: received, shortfall, rows

    func test_everythingReceived_noRows_noSurplus() {
        let outcome = UsageReconciliation.reconcile(input(standardRuns, starts: [freshBeforeRun1], heard: everythingHeard))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
    }

    func test_tailOfTheLastRunNotReceived_oneRow_exactlyTheDifference() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 3000, 400)), bucket(11, tt(50, 60, 1500, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [row(2, run2End, tt(0, 0, 500))], surplus: [:]))
    }

    func test_gapInRun1Only_rowOnRun1Only() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 2000, 400)), bucket(11, tt(50, 60, 2000, 50))]))
        XCTAssertEqual(outcome.rows, [row(1, run1End, tt(0, 0, 1000))])
    }

    func test_gapsInBothRuns_aRowOnEach() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 2000, 400)), bucket(11, tt(50, 60, 1500, 50))]))
        XCTAssertEqual(outcome.rows, [row(1, run1End, tt(0, 0, 1000)), row(2, run2End, tt(0, 0, 500))])
    }

    func test_suffixMinimum_aLaterSurplusRemovesTheEarlierRow() {
        // U1 = (10, 0, 0, 0); run 2 received 15 input for D2 = 50, so
        // H2 = 155 > E2 = 150: U2 = 0 and the earlier row disappears.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(90, 200, 3000, 400)), bucket(11, tt(65, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [Self.sonnet: tt(5)]))
    }

    func test_suffixMinimum_aLaterPartialMakeUpReducesTheEarlierRow() {
        // U1 = 10, U2 = 150 - 144 = 6: m1 = 6, m2 = 6. Row 1 = 6, row 2 = 0.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(90, 200, 3000, 400)), bucket(11, tt(54, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [row(1, run1End, tt(6))], surplus: [:]))
    }

    func test_rowsAddUpToTheLastShortfall() {
        // U1 = 30, U2 = 30 + 20 = 50 (input): rows 30 and 20.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(70, 200, 3000, 400)), bucket(11, tt(30, 60, 2000, 50))]))
        XCTAssertEqual(outcome.rows, [row(1, run1End, tt(30)), row(2, run2End, tt(20))])
    }

    func test_lowerBound_whenK0IsAbove1_includesTheMinuteOfThePreviousRunsEnd() {
        // Tracking inside run 1: lower bound = minute 2. The minute-2 bucket
        // counts for run 2: (50, 60, 2000, 50) - (20, 60, 2000, 50) = 30.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, trackedFromNs: ns(1), starts: [freshBeforeRun1],
            heard: [bucket(2, tt(20)), bucket(11, tt(0, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 2, rows: [row(2, run2End, tt(30))], surplus: [:]))
    }

    func test_lowerBound_whenK0IsAbove1_excludesEarlierMinutes_alsoFromTheSurplus() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, trackedFromNs: ns(1), starts: [freshBeforeRun1],
            heard: [bucket(1, tt(1000)), bucket(11, tt(0, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 2, rows: [row(2, run2End, tt(50))], surplus: [:]))
    }

    func test_lowerBound_absentWhenThePrecedingRunHasNoEnd() {
        // Run 2 has neither begin nor end: run 3 alone, D3 = 20, and a bucket
        // of minute 1 counts (no lower bound): row 15.
        let runs = [
            run(1, ns(0), ns(1), [Self.sonnet: tt(100)]),
            run(2, nil, nil, [Self.sonnet: tt(150)]),
            run(3, ns(20), ns(21), [Self.sonnet: tt(170)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(5))]))
        XCTAssertEqual(outcome.rows, [row(3, ns(21), tt(15))])
    }

    func test_upperBound_excludesTheMinuteTheNextRunBegins() {
        // Run 1 (D 10) got 6 in minute 1; run 2 begins in minute 5 and its
        // 7 arrive in minute 5. H1 = 6 (minute 5 excluded): U1 = 4; H2 = 13,
        // E2 = 17: U2 = 4. The 4 stay on run 1.
        let runs = [
            run(1, ns(0), ns(2, 30), [Self.sonnet: tt(10)]),
            run(2, ns(5, 10), ns(5, 40), [Self.sonnet: tt(17)]),
        ]
        let outcome = UsageReconciliation.reconcile(
            input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(6)), bucket(5, tt(7))]))
        XCTAssertEqual(outcome.rows, [row(1, ns(2, 30), tt(4))])
    }

    func test_upperBound_includesTheMinuteBeforeTheNextRunBegins() {
        let runs = [
            run(1, ns(0), ns(2, 30), [Self.sonnet: tt(10)]),
            run(2, ns(5, 10), ns(5, 40), [Self.sonnet: tt(17)]),
        ]
        let outcome = UsageReconciliation.reconcile(
            input(runs, starts: [freshBeforeRun1], heard: [bucket(4, tt(10)), bucket(5, tt(7))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
    }

    func test_lastRunHasNoUpperBound_usageOfAnOpenRunReducesTheShortfall() {
        // 500 cacheRead of run 2 missing, then 500 arrive in minute 30
        // (after run 2's end: a run still open).
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 3000, 400)), bucket(11, tt(50, 60, 1500, 50)), bucket(30, tt(0, 0, 500))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
    }

    func test_perKindIndependence_inputShortWhileOutputIsOver() {
        // Run 1: input 10 short, output 10 over (H 210 > 200). Kinds never
        // offset each other.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(90, 210, 3000, 400)), bucket(11, tt(50, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(
            firstSequence: 1, rows: [row(1, run1End, tt(10))], surplus: [Self.sonnet: tt(0, 10)]))
    }

    func test_perKindIndependence_inputShortWhileOutputIsComplete() {
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(100, 200, 3000, 400)), bucket(11, tt(40, 60, 2000, 50))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(10))])
    }

    func test_perModelIndependence_oneModelShortWhileAnotherIsOver() {
        let runs = [run(1, ns(0), run1End, [Self.sonnet: tt(10), Self.haiku: tt(10)])]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(4)), bucket(1, tt(13), model: Self.haiku)]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(
            firstSequence: 1, rows: [row(1, run1End, tt(6))], surplus: [Self.haiku: tt(3)]))
    }

    // MARK: - Rule 8: surplus

    func test_rule8_surplusListsOnlyModelsWithAPositiveNumber() {
        let runs = [run(1, ns(0), run1End, [Self.sonnet: tt(10, 10), Self.haiku: tt(5)])]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(10, 10)), bucket(1, tt(8), model: Self.haiku)]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [Self.haiku: tt(3)]))
    }

    func test_rule8_aHeardModelAbsentFromTheTotals_isSurplus() {
        let runs = [run(1, ns(0), run1End, [Self.sonnet: tt(10)])]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(10)), bucket(1, tt(0, 2), model: "claude-other")]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: ["claude-other": tt(0, 2)]))
    }

    func test_rule8_surplusIsOverAllReconciledRuns_notPerRun() {
        // Run 1 over by 5 input in its own minutes, run 2 short by 5:
        // H_n = E_n, so no surplus; rows: U1 = 0 so m1 = 0, U2 = 0.
        let outcome = UsageReconciliation.reconcile(input(
            standardRuns, starts: [freshBeforeRun1],
            heard: [bucket(1, tt(105, 200, 3000, 400)), bucket(11, tt(45, 60, 2000, 50))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(firstSequence: 1, rows: [], surplus: [:]))
    }

    // MARK: - Saturation, order, zero rows

    func test_saturation_cumulativeUsageStopsAtInt64Max_withoutTrapping() {
        // Run 2 restarts (cacheCreation shrank): D2 = (max, 0, 0, 0), so
        // E2's input saturates at max. U1 = (max, 0, 0, 1), U2 = (max, 0, 0, 1).
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(Int64.max, 0, 0, 1)]),
            run(2, ns(10), run2End, [Self.sonnet: tt(Int64.max, 0, 0, 0)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(
            firstSequence: 1, rows: [row(1, run1End, tt(Int64.max, 0, 0, 1))], surplus: [:]))
    }

    func test_saturation_heardSumStopsAtInt64Max_withoutTrapping() {
        let runs = [run(1, ns(0), run1End, [Self.sonnet: tt(10)])]
        let outcome = UsageReconciliation.reconcile(input(
            runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(Int64.max)), bucket(2, tt(Int64.max))]))
        XCTAssertEqual(outcome, UsageReconcileOutcome(
            firstSequence: 1, rows: [], surplus: [Self.sonnet: tt(Int64.max - 10)]))
    }

    func test_rowsAreOrderedBySequenceThenModel() {
        let zeta = "claude-zeta-1"
        let alpha = "claude-alpha-1"
        let runs = [
            run(1, ns(0), run1End, [zeta: tt(1), alpha: tt(2)]),
            run(2, ns(10), run2End, [zeta: tt(3), alpha: tt(5)]),
        ]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome.rows, [
            row(1, run1End, tt(2), model: alpha),
            row(1, run1End, tt(1), model: zeta),
            row(2, run2End, tt(3), model: alpha),
            row(2, run2End, tt(2), model: zeta),
        ])
    }

    func test_noRowIsEverEmittedWithAllZeros() {
        // Haiku is listed with zeros, sonnet fully received on run 1 and
        // short on run 2 by output only.
        let runs = [
            run(1, ns(0), run1End, [Self.sonnet: tt(10, 10), Self.haiku: tt()]),
            run(2, ns(10), run2End, [Self.sonnet: tt(20, 20), Self.haiku: tt()]),
        ]
        let outcome = UsageReconciliation.reconcile(
            input(runs, starts: [freshBeforeRun1], heard: [bucket(1, tt(10, 10)), bucket(11, tt(10, 5))]))
        XCTAssertEqual(outcome.rows, [row(2, run2End, tt(0, 5))])
        for row in outcome.rows {
            let totals = row.totals
            XCTAssertTrue(totals.input > 0 || totals.output > 0 || totals.cacheRead > 0 || totals.cacheCreation > 0,
                          "an all-zero row: \(row)")
        }
    }

    func test_aRowsTimeIsItsRunsEnd_notItsBegin() {
        let runs = [run(1, ns(0), ns(7, 59), [Self.sonnet: tt(3)])]
        let outcome = UsageReconciliation.reconcile(input(runs, starts: [freshBeforeRun1]))
        XCTAssertEqual(outcome.rows, [row(1, ns(7, 59), tt(3))])
    }
}
