// UsageGold.swift
// Calyx
//
// The Gold layer of the usage ledger: typed aggregate queries over the
// Silver records in UsageStore. Nothing is stored; every report is
// computed from Silver on demand. The Usage screen, the MCP tool and the
// Mission Map card all read through this one query, so they cannot
// disagree about what a number means.

import Foundation

struct UsageQuery: Sendable, Equatable {
    enum Dimension: String, Sendable, CaseIterable {
        case model, effort, thread, agentType, day, project, branch, session
    }

    enum ProjectFilter: Sendable, Equatable {
        /// Sessions whose stored project root is exactly this path.
        case root(String)
        /// Sessions with no session row or no project root.
        case unattributed
    }

    /// One key element per dimension, in this order. Empty: one total row.
    var groupBy: [Dimension] = []
    /// Inclusive lower bound on the record timestamp.
    var sinceMs: Int64? = nil
    /// Exclusive upper bound on the record timestamp.
    var untilMs: Int64? = nil
    var sessionID: String? = nil
    var project: ProjectFilter? = nil
    var thread: UsageRecord.Thread? = nil
}

struct UsageRow: Sendable, Equatable {
    /// The group's value for each `groupBy` dimension; nil is a group of
    /// its own (no effort, no branch, unattributed project).
    let key: [String?]
    let responses: Int64
    let finalResponses: Int64
    let inputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let cacheCreation1hTokens: Int64
    /// Output and thinking tokens are summed over FINAL responses only: a
    /// non-final record holds a mid-response snapshot, not the response's
    /// real output. `finalResponses / responses` says how much of the
    /// group these two sums cover. Input-side numbers are already correct
    /// on a non-final record, so those sum over every response.
    let outputTokensFinal: Int64
    let thinkingTokensFinal: Int64
    let lastTimestampMs: Int64
}

enum UsageGold {
    /// Aggregates the stored records matching `query`, one row per group,
    /// sorted by key (element by element, nil before any string). No
    /// matching record yields no rows, even with an empty `groupBy`.
    ///
    /// SQL is assembled only from fixed fragments chosen by the
    /// `Dimension` enum and by which filters are present; every filter
    /// VALUE is bound as a parameter, so no caller string reaches the SQL
    /// text.
    ///
    /// `Dimension.day` is not computed in SQL. SQLite can only shift a
    /// timestamp by a fixed offset, which is wrong on the 23- and 25-hour
    /// days around a DST change. Instead the injected calendar supplies
    /// each local day's exact [start, end) interval and the aggregate runs
    /// once per interval, with the day's label spliced into the key.
    /// Empty days cost nothing: after each day the next matching record is
    /// looked up and the walk jumps straight to that record's day.
    static func rows(
        for query: UsageQuery, calendar: Calendar, connection: SQLiteConnection
    ) throws -> [UsageRow] {
        guard Set(query.groupBy).count == query.groupBy.count else {
            throw UsageStoreError.invalidQuery
        }
        if let sinceMs = query.sinceMs, let untilMs = query.untilMs, sinceMs >= untilMs {
            return []
        }

        let plan = Plan(query: query)
        var rows: [UsageRow] = []

        if let dayPosition = query.groupBy.firstIndex(of: .day) {
            let aggregateSQL = plan.aggregateSQL(hasLowerBound: true, hasUpperBound: true)
            let nextSQL = plan.nextTimestampSQL(hasUpperBound: query.untilMs != nil)
            try connection.withTransientStatement(aggregateSQL) { aggregate in
                try connection.withTransientStatement(nextSQL) { next in
                    var cursor = try nextTimestamp(
                        next, plan: plan, atOrAfter: query.sinceMs ?? .min, untilMs: query.untilMs)
                    while let timestampMs = cursor {
                        let day = try localDay(containing: timestampMs, calendar: calendar)
                        aggregate.reset()
                        var index = try plan.bindFilters(to: aggregate)
                        try aggregate.bind(max(day.startMs, query.sinceMs ?? .min), at: index)
                        index += 1
                        try aggregate.bind(min(day.endMs, query.untilMs ?? .max), at: index)
                        rows += try readRows(aggregate, plan: plan, splicing: (dayPosition, day.label))
                        cursor = try nextTimestamp(
                            next, plan: plan, atOrAfter: day.endMs, untilMs: query.untilMs)
                    }
                }
            }
        } else {
            let sql = plan.aggregateSQL(
                hasLowerBound: query.sinceMs != nil, hasUpperBound: query.untilMs != nil)
            try connection.withTransientStatement(sql) { aggregate in
                var index = try plan.bindFilters(to: aggregate)
                if let sinceMs = query.sinceMs {
                    try aggregate.bind(sinceMs, at: index)
                    index += 1
                }
                if let untilMs = query.untilMs {
                    try aggregate.bind(untilMs, at: index)
                }
                rows = try readRows(aggregate, plan: plan, splicing: nil)
            }
        }

        return rows.sorted { keyPrecedes($0.key, $1.key) }
    }

    // MARK: - Query plan

    /// The SQL fragments and bound values a query maps to. Time bounds are
    /// always the LAST parameters, after the filter values.
    private struct Plan {
        /// Column expression per non-day dimension, in `groupBy` order.
        let columns: [String]
        let needsSessions: Bool
        /// Conditions other than the time bounds, and their values.
        let conditions: [String]
        let values: [String]

        init(query: UsageQuery) {
            columns = query.groupBy.compactMap(Self.column)
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
            if let thread = query.thread {
                conditions.append("r.thread = ?")
                values.append(thread.rawValue)
            }
            self.conditions = conditions
            self.values = values
        }

        /// The only place a dimension becomes SQL text. `day` has no
        /// column: it is constant within one interval query.
        private static func column(for dimension: UsageQuery.Dimension) -> String? {
            switch dimension {
            case .model: "r.model"
            case .effort: "r.effort"
            case .thread: "r.thread"
            case .agentType: "r.agent_type"
            case .day: nil
            case .project: "s.project_root"
            case .branch: "r.git_branch"
            case .session: "r.session_id"
            }
        }

        private var source: String {
            needsSessions
                ? "usage_records r LEFT JOIN usage_sessions s ON s.session_id = r.session_id"
                : "usage_records r"
        }

        private func whereClause(hasLowerBound: Bool, hasUpperBound: Bool) -> String {
            var all = conditions
            if hasLowerBound { all.append("r.timestamp_ms >= ?") }
            if hasUpperBound { all.append("r.timestamp_ms < ?") }
            return all.isEmpty ? "" : " WHERE " + all.joined(separator: " AND ")
        }

        func aggregateSQL(hasLowerBound: Bool, hasUpperBound: Bool) -> String {
            let aggregates = """
                COUNT(*), SUM(r.is_final), SUM(r.input_tokens), SUM(r.cache_read_tokens), \
                SUM(r.cache_creation_tokens), SUM(r.cache_creation_1h_tokens), \
                SUM(CASE WHEN r.is_final = 1 THEN r.output_tokens ELSE 0 END), \
                SUM(CASE WHEN r.is_final = 1 THEN r.thinking_tokens ELSE 0 END), \
                MAX(r.timestamp_ms)
                """
            let selected = (columns + [aggregates]).joined(separator: ", ")
            let grouping = columns.isEmpty ? "" : " GROUP BY " + columns.joined(separator: ", ")
            return "SELECT \(selected) FROM \(source)"
                + whereClause(hasLowerBound: hasLowerBound, hasUpperBound: hasUpperBound) + grouping
        }

        /// The earliest matching timestamp at or after a bound.
        func nextTimestampSQL(hasUpperBound: Bool) -> String {
            "SELECT MIN(r.timestamp_ms) FROM \(source)"
                + whereClause(hasLowerBound: true, hasUpperBound: hasUpperBound)
        }

        /// Binds the filter values; returns the index of the next
        /// parameter, where the time bounds go.
        func bindFilters(to statement: SQLiteStatement) throws -> Int32 {
            var index: Int32 = 1
            for value in values {
                try statement.bind(value, at: index)
                index += 1
            }
            return index
        }
    }

    // MARK: - Reading

    private static func readRows(
        _ statement: SQLiteStatement, plan: Plan, splicing day: (position: Int, label: String)?
    ) throws -> [UsageRow] {
        var rows: [UsageRow] = []
        let columnCount = Int32(plan.columns.count)
        while try statement.step() {
            let responses = statement.int64(at: columnCount)
            // Without GROUP BY an aggregate returns one row even when
            // nothing matched; no match must mean no row.
            guard responses > 0 else { continue }
            var key: [String?] = (0..<columnCount).map { statement.text(at: $0) }
            if let day {
                key.insert(day.label, at: day.position)
            }
            rows.append(UsageRow(
                key: key,
                responses: responses,
                finalResponses: statement.int64(at: columnCount + 1),
                inputTokens: statement.int64(at: columnCount + 2),
                cacheReadTokens: statement.int64(at: columnCount + 3),
                cacheCreationTokens: statement.int64(at: columnCount + 4),
                cacheCreation1hTokens: statement.int64(at: columnCount + 5),
                outputTokensFinal: statement.int64(at: columnCount + 6),
                thinkingTokensFinal: statement.int64(at: columnCount + 7),
                lastTimestampMs: statement.int64(at: columnCount + 8)
            ))
        }
        return rows
    }

    private static func nextTimestamp(
        _ statement: SQLiteStatement, plan: Plan, atOrAfter lowerMs: Int64, untilMs: Int64?
    ) throws -> Int64? {
        statement.reset()
        var index = try plan.bindFilters(to: statement)
        try statement.bind(lowerMs, at: index)
        index += 1
        if let untilMs {
            try statement.bind(untilMs, at: index)
        }
        // MIN over no rows is one row holding NULL.
        guard try statement.step(), !statement.isNull(at: 0) else { return nil }
        return statement.int64(at: 0)
    }

    // MARK: - Days

    /// The local day containing `timestampMs`: its exact interval in epoch
    /// milliseconds and its "yyyy-MM-dd" label, both from the injected
    /// calendar (so DST days and 30- / 45-minute offsets come out right).
    /// Throws rather than guessing if the calendar's interval does not
    /// contain the timestamp; that check is also what guarantees the day
    /// walk always moves forward.
    private static func localDay(
        containing timestampMs: Int64, calendar: Calendar
    ) throws -> (startMs: Int64, endMs: Int64, label: String) {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1_000)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let interval = calendar.dateInterval(of: .day, for: date),
              let startMs = Int64(exactly: (interval.start.timeIntervalSince1970 * 1_000).rounded()),
              let endMs = Int64(exactly: (interval.end.timeIntervalSince1970 * 1_000).rounded()),
              startMs <= timestampMs, timestampMs < endMs,
              let year = components.year, let month = components.month, let day = components.day else {
            throw UsageStoreError.dayBoundaryUnavailable
        }
        return (startMs, endMs, String(format: "%04d-%02d-%02d", year, month, day))
    }

    // MARK: - Ordering

    /// Element by element: nil before any string, strings by `<`; a key
    /// that is a prefix of another comes first.
    private static func keyPrecedes(_ a: [String?], _ b: [String?]) -> Bool {
        for (left, right) in zip(a, b) {
            switch (left, right) {
            case (nil, nil): continue
            case (nil, _?): return true
            case (_?, nil): return false
            case let (left?, right?):
                if left != right { return left < right }
            }
        }
        return a.count < b.count
    }
}
