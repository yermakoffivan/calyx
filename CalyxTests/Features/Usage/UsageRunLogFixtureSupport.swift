//
//  UsageRunLogFixtureSupport.swift
//  CalyxTests
//
//  What the run-log tests share: the sanitized transcript skeletons of
//  runs 1-9 in `CalyxTests/Fixtures/UsageTelemetry/` (loaded from the
//  source tree via `#filePath`, never bundled), their `expected-*.json`
//  files read with plain JSONSerialization (so expected totals never come
//  from the code under test), and ONE table of the runs each skeleton must
//  produce, used by both `UsageRunLogTests` and `UsageRunLogReaderTests`.
//
//  How the pinned times were derived (by hand from the skeletons, not by
//  running any Calyx code): each skeleton's lines were listed with their
//  type, timestamp and `forkedFrom` presence; a run's begin is the
//  timestamp of its FIRST timestamped line in file order that has no
//  `forkedFrom`, its end the LATEST timestamp among those lines, and the
//  ISO 8601 strings were converted to epoch milliseconds with Python's
//  `datetime` (UTC), then multiplied by 1_000_000. Totals are read from
//  the fixture's own expected files; see `expectedRuns`.
//
//  Nothing here reads ~/.claude, Application Support or UserDefaults.
//

import XCTest
@testable import Calyx

enum UsageRunLogFixtureError: Error {
    case missing(String)
    case unexpectedShape(String)
}

/// One transcript skeleton: where it is and whose it is.
struct UsageRunLogSkeleton: CustomStringConvertible {
    let run: String
    /// `nil` for the unsuffixed `transcript-skeleton.jsonl`.
    let number: Int?
    let sessionID: String

    var description: String { number.map { "\(run) skeleton-\($0)" } ?? "\(run) skeleton" }

    var fileName: String { number.map { "transcript-skeleton-\($0).jsonl" } ?? "transcript-skeleton.jsonl" }
}

enum UsageRunLogFixtures {
    /// The cwd every skeleton line carries (a fake path).
    static let cwd = "/fixture/project"

    static let run1 = UsageRunLogSkeleton(run: "run1", number: nil, sessionID: "11111111-1111-4111-8111-111111111111")
    static let run2 = UsageRunLogSkeleton(run: "run2", number: nil, sessionID: "22222222-2222-4222-8222-222222222222")
    static let run3 = UsageRunLogSkeleton(run: "run3", number: nil, sessionID: "22222222-2222-4222-8222-222222222222")
    static let run4 = UsageRunLogSkeleton(run: "run4", number: nil, sessionID: "44444444-4444-4444-8444-444444444444")
    static let run5a = UsageRunLogSkeleton(run: "run5", number: 1, sessionID: "55555555-5555-4555-8555-555555555551")
    static let run5b = UsageRunLogSkeleton(run: "run5", number: 2, sessionID: "55555555-5555-4555-8555-555555555552")
    static let run6 = UsageRunLogSkeleton(run: "run6", number: nil, sessionID: "66666666-6666-4666-8666-666666666661")
    static let run7a = UsageRunLogSkeleton(run: "run7", number: 1, sessionID: "77777777-7777-4777-8777-777777777771")
    static let run7b = UsageRunLogSkeleton(run: "run7", number: 2, sessionID: "77777777-7777-4777-8777-777777777772")
    static let run8a = UsageRunLogSkeleton(run: "run8", number: 1, sessionID: "88888888-8888-4888-8888-888888888881")
    /// The same session as `run7a` (run8 resumed run7's parent).
    static let run8b = UsageRunLogSkeleton(run: "run8", number: 2, sessionID: "77777777-7777-4777-8777-777777777771")
    static let run9a = UsageRunLogSkeleton(run: "run9", number: 1, sessionID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
    static let run9b = UsageRunLogSkeleton(run: "run9", number: 2, sessionID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")
    static let run9c = UsageRunLogSkeleton(run: "run9", number: 3, sessionID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")

    static let all = [run1, run2, run3, run4, run5a, run5b, run6, run7a, run7b, run8a, run8b, run9a, run9b, run9c]

    /// `CalyxTests/Fixtures/UsageTelemetry`, found from this file's path.
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Usage/
            .deletingLastPathComponent() // Features/
            .deletingLastPathComponent() // CalyxTests/
            .appendingPathComponent("Fixtures/UsageTelemetry", isDirectory: true)
    }

    private static func url(run: String, name: String) throws -> URL {
        let url = directory.appendingPathComponent(run, isDirectory: true).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageRunLogFixtureError.missing(url.path)
        }
        return url
    }

    /// The skeleton's bytes, exactly as captured.
    static func data(_ skeleton: UsageRunLogSkeleton) throws -> Data {
        try Data(contentsOf: try url(run: skeleton.run, name: skeleton.fileName))
    }

    /// The skeleton's lines without their "\n", in file order. Every
    /// skeleton ends with a newline, so there is no partial last line.
    static func lines(_ skeleton: UsageRunLogSkeleton) throws -> [Data] {
        let bytes = try data(skeleton)
        guard bytes.last == UInt8(ascii: "\n") else {
            throw UsageRunLogFixtureError.unexpectedShape("\(skeleton) does not end with a newline")
        }
        return bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    }

    /// The skeleton's lines as JSON objects, read by the test itself.
    static func objects(_ skeleton: UsageRunLogSkeleton) throws -> [[String: Any]] {
        try lines(skeleton).map { line in
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageRunLogFixtureError.unexpectedShape("\(skeleton): a line is not an object")
            }
            return object
        }
    }

    /// The events of the skeleton's lines, through the reader under test.
    static func events(_ skeleton: UsageRunLogSkeleton) throws -> [ClaudeTranscriptRunEvent] {
        try lines(skeleton).compactMap { ClaudeCostStateReader.event(fromLine: $0, sessionID: skeleton.sessionID) }
    }

    /// A fresh log with every event of the skeleton applied in order.
    static func log(_ skeleton: UsageRunLogSkeleton) throws -> UsageRunLog {
        var log = UsageRunLog()
        for event in try events(skeleton) {
            log.apply(event)
        }
        return log
    }

    // MARK: Expected files

    /// `{model: {input, output, cacheRead, cacheCreation, ...}}` as
    /// totals per model; other keys (`thinking`) are ignored.
    static func totals(fromModels object: Any, source: String) throws -> [String: UsageTokenTotals] {
        guard let models = object as? [String: Any] else {
            throw UsageRunLogFixtureError.unexpectedShape(source)
        }
        var result: [String: UsageTokenTotals] = [:]
        for (model, entry) in models {
            guard let kinds = entry as? [String: Any] else {
                throw UsageRunLogFixtureError.unexpectedShape("\(source): \(model)")
            }
            func value(_ name: String) throws -> Int64 {
                guard let number = kinds[name] as? NSNumber else {
                    throw UsageRunLogFixtureError.unexpectedShape("\(source): \(model).\(name)")
                }
                return number.int64Value
            }
            result[model] = UsageTokenTotals(
                input: try value("input"), output: try value("output"),
                cacheRead: try value("cacheRead"), cacheCreation: try value("cacheCreation"))
        }
        return result
    }

    /// `expected-cost-state.json` (number nil) or `expected-cost-state-N.json`
    /// of a run: the totals of the matching skeleton's LAST cost-state line.
    static func expectedCostState(run: String, number: Int? = nil) throws -> [String: UsageTokenTotals] {
        let name = number.map { "expected-cost-state-\($0).json" } ?? "expected-cost-state.json"
        let url = try url(run: run, name: name)
        return try totals(fromModels: try JSONSerialization.jsonObject(with: try Data(contentsOf: url)), source: url.path)
    }

    static func expectedCostState(_ skeleton: UsageRunLogSkeleton) throws -> [String: UsageTokenTotals] {
        try expectedCostState(run: skeleton.run, number: skeleton.number)
    }

    /// One session's entry of a run's `expected-metric-sums.json`.
    static func expectedMetricSums(run: String, sessionID: String) throws -> [String: UsageTokenTotals] {
        let url = try url(run: run, name: "expected-metric-sums.json")
        guard let sessions = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any],
              let models = sessions[sessionID] else {
            throw UsageRunLogFixtureError.unexpectedShape("\(url.path): \(sessionID)")
        }
        return try totals(fromModels: models, source: url.path)
    }

    /// `later - earlier` per model and kind, models whose four differences
    /// are all 0 dropped (the metric reports no series for a model that was
    /// not used in that stretch). Computed by the test, saturating so it
    /// never traps.
    static func difference(
        _ later: [String: UsageTokenTotals], minus earlier: [String: UsageTokenTotals]
    ) -> [String: UsageTokenTotals] {
        var result: [String: UsageTokenTotals] = [:]
        for (model, totals) in later {
            let base = earlier[model] ?? UsageTokenTotals()
            func minus(_ lhs: Int64, _ rhs: Int64) -> Int64 {
                let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
                return overflow ? Int64.min : value
            }
            let delta = UsageTokenTotals(
                input: minus(totals.input, base.input), output: minus(totals.output, base.output),
                cacheRead: minus(totals.cacheRead, base.cacheRead),
                cacheCreation: minus(totals.cacheCreation, base.cacheCreation))
            if delta != UsageTokenTotals() {
                result[model] = delta
            }
        }
        return result
    }

    // MARK: The expected runs

    /// Epoch nanoseconds of a skeleton timestamp, written out by hand.
    private static func ns(_ milliseconds: Int64) -> Int64 { milliseconds * 1_000_000 }

    /// The runs each skeleton must produce. Times: see the file header
    /// (line numbers are 1-based lines of the skeleton). Totals: the
    /// skeleton's last cost-state is its own expected file; an EARLIER run
    /// of a skeleton takes the expected file of the capture that ended it:
    /// run3's first run is run2's exit (`run2/expected-cost-state.json`,
    /// run3's skeleton repeats run2's 64 lines), run8 skeleton-2's first
    /// run is run7's parent exit (`run7/expected-cost-state-1.json`, its
    /// first 34 lines are byte-identical to run7 skeleton-1).
    static func expectedRuns(_ skeleton: UsageRunLogSkeleton) throws -> [UsageRun] {
        func run(_ sequence: Int, _ begin: Int64, _ end: Int64, _ totals: [String: UsageTokenTotals]) -> UsageRun {
            UsageRun(sequence: sequence, beginNs: ns(begin), endNs: ns(end), totals: totals)
        }
        let own = try expectedCostState(skeleton)
        switch (skeleton.run, skeleton.number) {
        case ("run1", nil):
            // line 1 queue-operation 06:56:45.437; line 43 system 06:57:18.061
            return [run(1, 1_791_183_405_437, 1_791_183_438_061, own)]
        case ("run2", nil):
            // line 6 user 06:59:47.405 (line 7 is .404, older); line 60 user 07:00:22.229
            return [run(1, 1_791_183_587_405, 1_791_183_622_229, own)]
        case ("run3", nil):
            // run 2: line 65 queue-operation 07:01:21.753; line 79 system 07:01:26.877
            return [
                run(1, 1_791_183_587_405, 1_791_183_622_229, try expectedCostState(run: "run2")),
                run(2, 1_791_183_681_753, 1_791_183_686_877, own),
            ]
        case ("run4", nil):
            // line 1 07:01:50.620; line 25 system 07:01:52.377
            return [run(1, 1_791_183_710_620, 1_791_183_712_377, own)]
        case ("run5", 1):
            // line 6 user 07:08:39.448 (line 7 is .446, older); line 33 system 07:08:41.203
            return [run(1, 1_791_184_119_448, 1_791_184_121_203, own)]
        case ("run5", 2):
            // line 3 user 07:08:58.489 (line 4 is .357, older); line 34 system 07:09:17.290
            return [run(1, 1_791_184_138_489, 1_791_184_157_290, own)]
        case ("run6", nil):
            // line 5 queue-operation 07:11:37.711 (lines 7-56 are 06:59-07:01);
            // line 66 system 07:11:40.369
            return [run(1, 1_791_184_297_711, 1_791_184_300_369, own)]
        case ("run7", 1):
            // line 6 user 08:01:37.585; line 33 system 08:01:40.263
            return [run(1, 1_791_187_297_585, 1_791_187_300_263, own)]
        case ("run7", 2):
            // lines 1-18 carry forkedFrom; line 24 system 08:01:56.658; line 34 system 08:02:15.082
            return [run(1, 1_791_187_316_658, 1_791_187_335_082, own)]
        case ("run8", 1):
            // line 6 user 08:05:37.267; line 33 system 08:05:38.785
            return [run(1, 1_791_187_537_267, 1_791_187_538_785, own)]
        case ("run8", 2):
            // run 2: line 37 user 08:06:12.356; line 43 system 08:06:14.703
            return [
                run(1, 1_791_187_297_585, 1_791_187_300_263, try expectedCostState(run: "run7", number: 1)),
                run(2, 1_791_187_572_356, 1_791_187_574_703, own),
            ]
        case ("run9", 1):
            // line 6 user 08:26:23.280; line 33 system 08:26:24.885
            return [run(1, 1_791_188_783_280, 1_791_188_784_885, own)]
        case ("run9", 2):
            // line 3 user 08:26:42.256 (line 4 is .135, older); line 40 system 08:27:18.505
            return [run(1, 1_791_188_802_256, 1_791_188_838_505, own)]
        case ("run9", 3):
            // lines 1-27 carry forkedFrom; line 33 system 08:27:37.643; line 47 system 08:28:14.259
            return [run(1, 1_791_188_857_643, 1_791_188_894_259, own)]
        default:
            throw UsageRunLogFixtureError.missing("no expected runs for \(skeleton)")
        }
    }

    /// The whole log a finished skeleton must give: its runs, no open run,
    /// the fixture cwd.
    static func expectedLog(_ skeleton: UsageRunLogSkeleton) throws -> UsageRunLog {
        UsageRunLog(runs: try expectedRuns(skeleton), openBeginNs: nil, openEndNs: nil, cwd: cwd)
    }
}
