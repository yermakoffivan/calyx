// UsageTokenGold.swift
// Calyx
//
// The Gold query over the telemetry tables: recorded token points
// (`usage_points`) and the tokens Claude Code counted but Calyx never
// received (`usage_unreported`). Nothing is stored; every report is
// computed on demand. Each result row aggregates ONE source, so the rows
// of a result always add up to the full total while unreported tokens
// stay distinguishable from recorded detail.

import Foundation

struct UsageTokenQuery: Sendable, Equatable {
    enum Dimension: String, Sendable, CaseIterable {
        case model, effort, thread, agentType, day, project, session
    }

    enum ProjectFilter: Sendable, Equatable {
        /// Sessions whose stored project root is exactly this path.
        case root(String)
        /// Sessions with no session row or no project root.
        case unattributed
    }

    /// One key element per dimension, in this order. Empty: totals.
    var groupBy: [Dimension] = []
    /// Inclusive lower bound on the row time.
    var sinceMs: Int64? = nil
    /// Exclusive upper bound on the row time.
    var untilMs: Int64? = nil
    var sessionID: String? = nil
    var project: ProjectFilter? = nil
    /// A thread label, e.g. "main", "subagent", "auxiliary".
    var thread: String? = nil
}

struct UsageTokenRow: Sendable, Equatable {
    /// The group's value per `groupBy` dimension; nil is a group of its own.
    let key: [String?]
    /// false: tokens Calyx received and recorded. true: tokens that are in
    /// Claude Code's own totals but were never received; their model, day,
    /// project and session are known, their effort, thread and agent are not.
    let isUnreported: Bool
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let outputTokens: Int64
    /// The latest time among the rows of the group.
    let lastTimestampMs: Int64
}

enum UsageTokenGold {
    /// Aggregates the recorded points and the unreported rows matching
    /// `query`: one row per group and source, sorted by key (element by
    /// element, nil before any string, strings by their UTF-8 bytes), the
    /// recorded row before the
    /// unreported one for equal keys. No matching source row yields no
    /// row, even with an empty `groupBy`.
    ///
    /// Times: a point is dated at the start of its minute
    /// (`minute * 60_000` ms), an unreported row at `floor(time_ns / 1e6)`
    /// ms. The SQL never computes a time: millisecond bounds are converted
    /// in Swift to the exact equivalent inclusive bounds on the stored
    /// column (`minute` / `time_ns`), so the comparisons can use the
    /// columns' indexes, and the stored maxima are converted back.
    ///
    /// `Dimension.day` is walked per local day: the calendar supplies
    /// each local day's exact interval and the aggregate runs once per
    /// interval and source. Of `calendar` only the time zone is used
    /// (`UsagePeriod.localDayCalendar`).
    ///
    /// SQL is assembled only from fixed fragments; every filter value is
    /// bound. Sums are SQLite integer sums, which fail with an error
    /// (thrown here) instead of wrapping when not representable.
    static func rows(
        for query: UsageTokenQuery, calendar injected: Calendar, connection: SQLiteConnection
    ) throws -> [UsageTokenRow] {
        let calendar = UsagePeriod.localDayCalendar(injected)
        guard Set(query.groupBy).count == query.groupBy.count else {
            throw UsageStoreError.invalidQuery
        }
        if let sinceMs = query.sinceMs, let untilMs = query.untilMs, sinceMs >= untilMs {
            return []
        }

        var rows: [UsageTokenRow] = []
        for source in Source.allCases {
            // The thread of an unreported row is not known: a thread
            // filter can never match one.
            if source == .unreported, query.thread != nil { continue }
            rows += try sourceRows(source, query: query, calendar: calendar, connection: connection)
        }
        return rows.sorted(by: rowPrecedes)
    }

    // MARK: - Sources

    private enum Source: CaseIterable {
        case recorded, unreported

        var table: String {
            switch self {
            case .recorded: "usage_points"
            case .unreported: "usage_unreported"
            }
        }

        /// The stored time column the bounds apply to.
        var timeColumn: String {
            switch self {
            case .recorded: "r.minute"
            case .unreported: "r.time_ns"
            }
        }

        /// The stored time unit per millisecond relation.
        private static let msPerMinute: Int64 = 60_000
        private static let nsPerMs: Int64 = 1_000_000

        /// The smallest stored time whose millisecond time is >= `ms`;
        /// nil when no stored time can be.
        func storedLowerBound(_ ms: Int64) -> Int64? {
            switch self {
            case .recorded:
                return ceilingDivision(ms, Self.msPerMinute)
            case .unreported:
                let (product, overflow) = ms.multipliedReportingOverflow(by: Self.nsPerMs)
                guard overflow else { return product }
                return ms > 0 ? nil : .min
            }
        }

        /// The largest stored time whose millisecond time is < `ms`; nil
        /// when no stored time can be.
        func storedUpperBound(_ ms: Int64) -> Int64? {
            switch self {
            case .recorded:
                // minute * 60_000 < ms  <=>  minute <= ceil(ms / 60_000) - 1;
                // the quotient's magnitude is far below Int64's range.
                return ceilingDivision(ms, Self.msPerMinute) - 1
            case .unreported:
                // floor(ns / 1e6) < ms  <=>  ns <= ms * 1e6 - 1
                let (product, overflow) = ms.multipliedReportingOverflow(by: Self.nsPerMs)
                guard !overflow else { return ms > 0 ? .max : nil }
                let (bound, underflow) = product.subtractingReportingOverflow(1)
                return underflow ? nil : bound
            }
        }

        /// The millisecond time of a stored time (rule 2).
        func milliseconds(ofStored value: Int64) throws -> Int64 {
            switch self {
            case .recorded:
                let (product, overflow) = value.multipliedReportingOverflow(by: Self.msPerMinute)
                guard !overflow else { throw UsageStoreError.malformedRow }
                return product
            case .unreported:
                return floorDivision(value, Self.nsPerMs)
            }
        }

        private func ceilingDivision(_ a: Int64, _ b: Int64) -> Int64 {
            a / b + (a % b > 0 ? 1 : 0)
        }

        private func floorDivision(_ a: Int64, _ b: Int64) -> Int64 {
            a / b - (a % b < 0 ? 1 : 0)
        }
    }

    private static func sourceRows(
        _ source: Source, query: UsageTokenQuery, calendar: Calendar, connection: SQLiteConnection
    ) throws -> [UsageTokenRow] {
        let plan = Plan(query: query, source: source)
        var rows: [UsageTokenRow] = []

        guard let dayPosition = query.groupBy.firstIndex(of: .day) else {
            guard let bounds = plan.storedBounds(sinceMs: query.sinceMs, untilMs: query.untilMs) else {
                return []
            }
            try connection.withTransientStatement(plan.aggregateSQL) { aggregate in
                try plan.bind(to: aggregate, bounds: bounds)
                rows = try readRows(aggregate, plan: plan, splicing: nil)
            }
            return rows
        }

        try connection.withTransientStatement(plan.aggregateSQL) { aggregate in
            try connection.withTransientStatement(plan.nextTimeSQL) { next in
                var cursor = try nextTimeMs(
                    next, plan: plan, atOrAfter: query.sinceMs, untilMs: query.untilMs)
                while let timeMs = cursor {
                    let day = try localDay(containing: timeMs, calendar: calendar)
                    let lowerMs = max(day.startMs, query.sinceMs ?? .min)
                    let upperMs = min(day.endMs, query.untilMs ?? .max)
                    if let bounds = plan.storedBounds(sinceMs: lowerMs, untilMs: upperMs) {
                        aggregate.reset()
                        try plan.bind(to: aggregate, bounds: bounds)
                        rows += try readRows(aggregate, plan: plan, splicing: (dayPosition, day.label))
                    }
                    cursor = try nextTimeMs(next, plan: plan, atOrAfter: day.endMs, untilMs: query.untilMs)
                }
            }
        }
        return rows
    }

    // MARK: - Query plan

    /// The SQL fragments and bound values of one query over one source.
    /// The stored-time bounds are always the LAST two parameters
    /// (inclusive lower, inclusive upper), after the filter values.
    private struct Plan {
        let source: Source
        /// Column expression per non-day dimension, in `groupBy` order.
        let columns: [String]
        let needsSessions: Bool
        let conditions: [String]
        let values: [String]

        init(query: UsageTokenQuery, source: Source) {
            self.source = source
            columns = query.groupBy.compactMap { Self.column(for: $0, source: source) }
            needsSessions = query.groupBy.contains(.project) || query.project != nil

            var conditions: [String] = []
            var values: [String] = []
            if let sessionID = query.sessionID {
                conditions.append("r.session_id = ?")
                values.append(sessionID)
            }
            switch query.project {
            case .root(let root):
                conditions.append("s.project_root = ?")
                values.append(root)
            case .unattributed:
                // True both for a session with no row (the LEFT JOIN
                // yields NULL) and for a row whose root is NULL.
                conditions.append("s.project_root IS NULL")
            case nil:
                break
            }
            if let thread = query.thread, source == .recorded {
                conditions.append("r.thread = ?")
                values.append(thread)
            }
            conditions.append("\(source.timeColumn) >= ?")
            conditions.append("\(source.timeColumn) <= ?")
            self.conditions = conditions
            self.values = values
        }

        /// The only place a dimension becomes SQL text. `day` has no
        /// column: it is constant within one interval query. The labels an
        /// unreported row does not have are a constant NULL.
        private static func column(for dimension: UsageTokenQuery.Dimension, source: Source) -> String? {
            switch (dimension, source) {
            case (.model, _): "r.model"
            case (.effort, .recorded): "r.effort"
            case (.thread, .recorded): "r.thread"
            case (.agentType, .recorded): "r.agent"
            case (.effort, .unreported), (.thread, .unreported), (.agentType, .unreported): "NULL"
            case (.day, _): nil
            case (.project, _): "s.project_root"
            case (.session, _): "r.session_id"
            }
        }

        private var from: String {
            needsSessions
                ? "\(source.table) r LEFT JOIN usage_sessions s ON s.session_id = r.session_id"
                : "\(source.table) r"
        }

        private var whereClause: String {
            " WHERE " + conditions.joined(separator: " AND ")
        }

        var aggregateSQL: String {
            let aggregates = """
                COUNT(*), SUM(r.input_tokens), SUM(r.cache_read_tokens), \
                SUM(r.cache_creation_tokens), SUM(r.output_tokens), MAX(\(source.timeColumn))
                """
            let selected = (columns + [aggregates]).joined(separator: ", ")
            let grouping = columns.isEmpty ? "" : " GROUP BY " + columns.joined(separator: ", ")
            return "SELECT \(selected) FROM \(from)" + whereClause + grouping
        }

        /// The earliest matching stored time within the bounds.
        var nextTimeSQL: String {
            "SELECT MIN(\(source.timeColumn)) FROM \(from)" + whereClause
        }

        /// The inclusive stored-time bounds equivalent to the millisecond
        /// range `[sinceMs, untilMs)`; nil when nothing can match.
        func storedBounds(sinceMs: Int64?, untilMs: Int64?) -> (lower: Int64, upper: Int64)? {
            var lower = Int64.min
            var upper = Int64.max
            if let sinceMs {
                guard let bound = source.storedLowerBound(sinceMs) else { return nil }
                lower = bound
            }
            if let untilMs {
                guard let bound = source.storedUpperBound(untilMs) else { return nil }
                upper = bound
            }
            guard lower <= upper else { return nil }
            return (lower, upper)
        }

        func bind(to statement: SQLiteStatement, bounds: (lower: Int64, upper: Int64)) throws {
            var index: Int32 = 1
            for value in values {
                try statement.bind(value, at: index)
                index += 1
            }
            try statement.bind(bounds.lower, at: index)
            try statement.bind(bounds.upper, at: index + 1)
        }
    }

    // MARK: - Reading

    private static func readRows(
        _ statement: SQLiteStatement, plan: Plan, splicing day: (position: Int, label: String)?
    ) throws -> [UsageTokenRow] {
        var rows: [UsageTokenRow] = []
        let columnCount = Int32(plan.columns.count)
        while try statement.step() {
            // Without GROUP BY an aggregate returns one row even when
            // nothing matched; no match must mean no row.
            guard statement.int64(at: columnCount) > 0 else { continue }
            var key: [String?] = (0..<columnCount).map { statement.text(at: $0) }
            if let day {
                key.insert(day.label, at: day.position)
            }
            rows.append(UsageTokenRow(
                key: key,
                isUnreported: plan.source == .unreported,
                inputTokens: statement.int64(at: columnCount + 1),
                cacheReadTokens: statement.int64(at: columnCount + 2),
                cacheCreationTokens: statement.int64(at: columnCount + 3),
                outputTokens: statement.int64(at: columnCount + 4),
                lastTimestampMs: try plan.source.milliseconds(ofStored: statement.int64(at: columnCount + 5))
            ))
        }
        return rows
    }

    /// The millisecond time of the earliest matching row at or after
    /// `lowerMs` and before `untilMs`; nil when there is none.
    private static func nextTimeMs(
        _ statement: SQLiteStatement, plan: Plan, atOrAfter lowerMs: Int64?, untilMs: Int64?
    ) throws -> Int64? {
        guard let bounds = plan.storedBounds(sinceMs: lowerMs, untilMs: untilMs) else { return nil }
        statement.reset()
        try plan.bind(to: statement, bounds: bounds)
        // MIN over no rows is one row holding NULL.
        guard try statement.step(), !statement.isNull(at: 0) else { return nil }
        return try plan.source.milliseconds(ofStored: statement.int64(at: 0))
    }

    // MARK: - Days

    /// The local day containing `timeMs`: its exact interval in epoch
    /// milliseconds and its "yyyy-MM-dd" label, from the Gregorian
    /// local-day calendar. Throws rather than guessing if the interval
    /// does not contain the time; that check also guarantees the day walk
    /// always moves forward.
    private static func localDay(
        containing timeMs: Int64, calendar: Calendar
    ) throws -> (startMs: Int64, endMs: Int64, label: String) {
        let date = Date(timeIntervalSince1970: Double(timeMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let interval = calendar.dateInterval(of: .day, for: date),
              let startMs = Int64(exactly: (interval.start.timeIntervalSince1970 * 1_000).rounded()),
              let endMs = Int64(exactly: (interval.end.timeIntervalSince1970 * 1_000).rounded()),
              startMs <= timeMs, timeMs < endMs,
              let year = components.year, let month = components.month, let day = components.day else {
            throw UsageStoreError.dayBoundaryUnavailable
        }
        return (startMs, endMs, String(format: "%04d-%02d-%02d", year, month, day))
    }

    // MARK: - Ordering

    /// By key, element by element (nil before any string, strings by their
    /// UTF-8 bytes, a prefix first); for equal keys the recorded row first.
    /// Bytes, not Swift's `<` / `==`: the database groups by bytes, and
    /// Swift treats canonically equivalent strings as equal.
    private static func rowPrecedes(_ a: UsageTokenRow, _ b: UsageTokenRow) -> Bool {
        for (left, right) in zip(a.key, b.key) {
            switch (left, right) {
            case (nil, nil): continue
            case (nil, _?): return true
            case (_?, nil): return false
            case let (left?, right?):
                if !left.utf8.elementsEqual(right.utf8) {
                    return left.utf8.lexicographicallyPrecedes(right.utf8)
                }
            }
        }
        if a.key.count != b.key.count { return a.key.count < b.key.count }
        return !a.isUnreported && b.isUnreported
    }
}
