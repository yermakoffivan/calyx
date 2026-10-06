// MCPUsageBridge.swift
// Calyx
//
// Bridges the MCP tool surface onto the usage ledger's Gold query:
// exposes `usage_report`, which aggregates the token usage Claude Code
// counted itself and Calyx received over its telemetry. Same shape as
// MCPCommandLogBridge (thrown LocalizedError, plain switch dispatch,
// JSON text result); the ledger is reached through closures, so the
// bridge holds no store and reads nothing on its own.

import Foundation

// MARK: - MCPUsageBridgeError

/// Failures raised by `MCPUsageBridge` before returning a result.
/// `LocalizedError`, so `CalyxMCPServer.handleUsageToolCall` builds the
/// tool-error text from `error.localizedDescription`.
enum MCPUsageBridgeError: Error, LocalizedError, Equatable {
    /// `handleToolCall` received a `name` not present in `tools`.
    case unknownTool(String)
    /// Usage tracking is off, so there is nothing current to report.
    case trackingDisabled
    /// An argument was present but not of the accepted shape or value.
    case invalidArgument(name: String, reason: String)
    /// `session_id: "current"` with no calling pane, or a pane whose
    /// agent row has no session id.
    case noCurrentSession

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .trackingDisabled:
            // Naming only the setting is accurate although tracking also
            // depends on the launch policy: the same predicate
            // (`LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()`)
            // keeps the MCP server from starting in a launch where the
            // policy turns tracking off, so no agent can receive this there.
            return "Usage tracking is off. Turn on Settings > Agents > Usage Tracking."
        case .invalidArgument(let name, let reason):
            return "Invalid argument \(name): \(reason)"
        case .noCurrentSession:
            return "No agent session is known for the calling pane."
        }
    }
}

// MARK: - MCPUsageBridge

@MainActor
final class MCPUsageBridge {

    private let isEnabled: () -> Bool
    private let reports: ([UsageTokenQuery], Calendar) async throws -> [[UsageTokenRow]]
    private let currentSessionID: (UUID) -> String?
    private let now: () -> Date
    private let calendar: () -> Calendar

    /// - `isEnabled`: whether tracking is on, read at every call.
    /// - `reports`: the ledger's several-queries Gold read; called once
    ///   per tool call.
    /// - `currentSessionID`: the agent session running in a pane, read
    ///   at every call that asks for `current`.
    /// - `now`, `calendar`: resolve `days` and name the result's time
    ///   zone; read once per call. Of `calendar` only the time zone is
    ///   used (`UsagePeriod.localDayCalendar`).
    init(
        isEnabled: @escaping () -> Bool,
        reports: @escaping ([UsageTokenQuery], Calendar) async throws -> [[UsageTokenRow]],
        currentSessionID: @escaping (UUID) -> String?,
        now: @escaping () -> Date,
        calendar: @escaping () -> Calendar
    ) {
        self.isEnabled = isEnabled
        self.reports = reports
        self.currentSessionID = currentSessionID
        self.now = now
        self.calendar = calendar
    }

    // MARK: - Tool catalogue

    /// Wire name of each `group_by` dimension. An exhaustive switch
    /// rather than the raw value, so the Swift case names (such as
    /// `agentType`) are not accepted on the wire.
    nonisolated private static func wireName(_ dimension: UsageTokenQuery.Dimension) -> String {
        switch dimension {
        case .model: return "model"
        case .effort: return "effort"
        case .thread: return "thread"
        case .agentType: return "agent_type"
        case .day: return "day"
        case .project: return "project"
        case .session: return "session"
        }
    }

    /// Every dimension by its wire name, in the order the schema lists them.
    nonisolated private static let dimensions: [(wire: String, dimension: UsageTokenQuery.Dimension)] =
        UsageTokenQuery.Dimension.allCases.map { (wireName($0), $0) }

    private static let defaultGroupBy: [UsageTokenQuery.Dimension] = [.model, .effort]
    private static let defaultLimit = 200
    private static let limitRange = 1...1_000
    /// The `session_id` value that means the calling pane's session.
    private static let currentSessionKeyword = "current"

    /// The one tool this bridge publishes. `nonisolated`, matching the
    /// other bridges, so `MCPRouter` and tests can enumerate it without
    /// hopping onto the main actor.
    nonisolated static let tools: [MCPTool] = [
        MCPTool(
            name: "usage_report",
            description: "Report Claude Code token usage as counted by Claude Code itself and received by Calyx, "
                + "aggregated by the group_by dimensions (default model and effort). Each row carries input, "
                + "cache read, cache creation and output token sums and the last timestamp; rows with unreported "
                + "true are tokens Calyx knows were used but did not receive in detail. totals covers every "
                + "matching row, also when limit cut the rows. Requires Settings > Agents > Usage Tracking.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "group_by": AnyCodable([
                        "type": AnyCodable("array"),
                        "items": AnyCodable([
                            "type": AnyCodable("string"),
                            "enum": AnyCodable(dimensions.map { AnyCodable($0.wire) }),
                        ] as [String: AnyCodable]),
                        "description": AnyCodable(
                            "Dimensions to group by, in key order: model, effort, thread, agent_type, day, "
                                + "project, session. Default [\"model\", \"effort\"]; [] gives the totals as at most two rows "
                                + "(recorded, unreported)"),
                    ] as [String: AnyCodable]),
                    "days": MCPRouter.prop(
                        "integer", "Only the last N local calendar days, today included (1 = today), "
                            + "from 1 to \(UsagePeriod.maxLastDays). Not with since/until"),
                    "since": MCPRouter.prop("string", "Inclusive lower bound, YYYY-MM-DDTHH:MM:SS[.fff]Z (UTC)"),
                    "until": MCPRouter.prop("string", "Exclusive upper bound, YYYY-MM-DDTHH:MM:SS[.fff]Z (UTC)"),
                    "session_id": MCPRouter.prop(
                        "string", "Only this Claude Code session; \"current\" is the session running in the calling pane"),
                    "project": MCPRouter.prop("string", "Only sessions whose project root is exactly this path"),
                    "thread": MCPRouter.prop("string", "Only this thread: main, subagent or auxiliary"),
                    "limit": MCPRouter.prop("integer", "Maximum rows returned, 1 to 1000 (default 200)"),
                ]
            )
        ),
    ]

    /// Fixed notes attached to every result: what the numbers cover.
    private static let notes = [
        "Token counts are Claude Code's own, received over its telemetry while Calyx was running. "
            + "Thinking tokens are part of output_tokens.",
        "Rows with unreported true are tokens Claude Code counted in a tracked session that Calyx did not "
            + "receive (for example because Calyx was not running). Their model is known; effort, thread and "
            + "agent are not, so they are missing from results filtered by thread.",
        "A session is counted only if it was started while usage tracking was on.",
    ]

    // MARK: - Dispatch

    /// Route an MCP `tools/call` to the `usage_report` handler. Every
    /// failure is thrown: `MCPUsageBridgeError` for the tool's own rules,
    /// the store's error unchanged for a failed read.
    func handleToolCall(name: String, arguments: [String: Any], surfaceID: UUID?) async throws -> String {
        switch name {
        case "usage_report":
            return try await handleReport(arguments: arguments, surfaceID: surfaceID)
        default:
            throw MCPUsageBridgeError.unknownTool(name)
        }
    }

    // MARK: - usage_report

    private func handleReport(arguments: [String: Any], surfaceID: UUID?) async throws -> String {
        // Before any argument: with tracking off the answer is the same
        // whatever was asked, and nothing is resolved or read.
        guard isEnabled() else { throw MCPUsageBridgeError.trackingDisabled }

        let groupBy = try decodeGroupBy(arguments)
        let days = try optionalInt(arguments, "days")
        let since = try optionalTimestamp(arguments, "since")
        let until = try optionalTimestamp(arguments, "until")
        let sessionID = try optionalString(arguments, "session_id")
        let project = try optionalString(arguments, "project")
        let thread = try decodeThread(arguments)
        let limit = try optionalInt(arguments, "limit") ?? Self.defaultLimit
        guard Self.limitRange.contains(limit) else {
            throw MCPUsageBridgeError.invalidArgument(
                name: "limit", reason: "expected an integer from \(Self.limitRange.lowerBound) to \(Self.limitRange.upperBound)")
        }

        let calendar = calendar()
        var sinceMs = since
        if let days {
            guard since == nil, until == nil else {
                throw MCPUsageBridgeError.invalidArgument(name: "days", reason: "cannot be combined with since or until")
            }
            guard (1...UsagePeriod.maxLastDays).contains(days) else {
                throw MCPUsageBridgeError.invalidArgument(
                    name: "days", reason: "expected an integer from 1 to \(UsagePeriod.maxLastDays)")
            }
            guard let startMs = UsagePeriod.startMs(lastDays: days, now: now(), calendar: calendar) else {
                throw MCPUsageBridgeError.invalidArgument(name: "days", reason: "no such day in the calendar")
            }
            sinceMs = startMs
        }

        var resolvedSessionID = sessionID
        if sessionID == Self.currentSessionKeyword {
            guard let surfaceID, let current = currentSessionID(surfaceID) else {
                throw MCPUsageBridgeError.noCurrentSession
            }
            resolvedSessionID = current
        }

        let rowsQuery = UsageTokenQuery(
            groupBy: groupBy, sinceMs: sinceMs, untilMs: until, sessionID: resolvedSessionID,
            project: project.map { .root($0) }, thread: thread)
        var totalsQuery = rowsQuery
        totalsQuery.groupBy = []

        // One read for rows and totals, so both describe the same stored
        // state and the totals are not affected by `limit`.
        let results = try await reports([rowsQuery, totalsQuery], calendar)
        // `reports` returns one result per query; read without subscripts
        // so a short answer cannot trap.
        let rows = results.first ?? []
        let totals = results.dropFirst().first ?? []

        let wireNames = groupBy.map(Self.wireName)
        let result: [String: Any] = [
            "group_by": wireNames,
            "since": sinceMs.map(Self.timestamp) ?? NSNull(),
            "until": until.map(Self.timestamp) ?? NSNull(),
            "time_zone": calendar.timeZone.identifier,
            "rows": rows.prefix(limit).map { Self.rowDict($0, wireNames: wireNames) },
            "row_count": rows.count,
            "truncated": rows.count > limit,
            "totals": Self.totalsDict(totals),
            "notes": Self.notes,
        ]
        return try Self.jsonString(result)
    }

    // MARK: - Argument decoding

    private func decodeGroupBy(_ arguments: [String: Any]) throws -> [UsageTokenQuery.Dimension] {
        guard let value = arguments["group_by"] else { return Self.defaultGroupBy }
        guard let names = value as? [String] else {
            throw MCPUsageBridgeError.invalidArgument(name: "group_by", reason: "expected an array of strings")
        }
        var dimensions: [UsageTokenQuery.Dimension] = []
        for name in names {
            guard let dimension = Self.dimensions.first(where: { $0.wire == name })?.dimension else {
                throw MCPUsageBridgeError.invalidArgument(name: "group_by", reason: "unknown dimension \(name)")
            }
            guard !dimensions.contains(dimension) else {
                throw MCPUsageBridgeError.invalidArgument(name: "group_by", reason: "repeated dimension \(name)")
            }
            dimensions.append(dimension)
        }
        return dimensions
    }

    /// The thread labels a `thread` filter accepts.
    private static let threads: Set<String> = ["main", "subagent", "auxiliary"]

    private func decodeThread(_ arguments: [String: Any]) throws -> String? {
        guard let raw = try optionalString(arguments, "thread") else { return nil }
        guard Self.threads.contains(raw) else {
            throw MCPUsageBridgeError.invalidArgument(name: "thread", reason: "expected main, subagent or auxiliary")
        }
        return raw
    }

    /// Optional timestamp argument, parsed to epoch milliseconds by
    /// `TranscriptTimestamp`.
    private func optionalTimestamp(_ arguments: [String: Any], _ key: String) throws -> Int64? {
        guard let text = try optionalString(arguments, key) else { return nil }
        guard let ms = TranscriptTimestamp.epochMilliseconds(fromISO8601: text) else {
            throw MCPUsageBridgeError.invalidArgument(name: key, reason: "expected YYYY-MM-DDTHH:MM:SS[.fff]Z")
        }
        return ms
    }

    /// Optional string argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a `String`.
    private func optionalString(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw MCPUsageBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return string
    }

    /// Optional integer argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a whole number `decodeInt`
    /// can represent exactly.
    private func optionalInt(_ arguments: [String: Any], _ key: String) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let intValue = decodeInt(value) else {
            throw MCPUsageBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return intValue
    }

    /// Same rule as `MCPCommandLogBridge.decodeInt`: a JSON boolean is
    /// not a number (`is Bool` catches the `CFBoolean`-backed NSNumber
    /// before any numeric cast), and `Int(exactly:)` rejects fractional,
    /// non-finite and out-of-range values without trapping.
    private func decodeInt(_ value: Any) -> Int? {
        guard !(value is Bool) else { return nil }
        if let intValue = value as? Int { return intValue }
        guard let doubleValue = value as? Double else { return nil }
        return Int(exactly: doubleValue)
    }

    // MARK: - Result serialization

    /// One row: its key as an object keyed by the `group_by` wire names
    /// (a nil group is JSON null), its source and its token fields.
    private static func rowDict(_ row: UsageTokenRow, wireNames: [String]) -> [String: Any] {
        var key: [String: Any] = [:]
        for (name, value) in zip(wireNames, row.key) {
            key[name] = value ?? NSNull()
        }
        return [
            "key": key,
            "unreported": row.isUnreported,
            "input_tokens": row.inputTokens,
            "cache_read_tokens": row.cacheReadTokens,
            "cache_creation_tokens": row.cacheCreationTokens,
            "output_tokens": row.outputTokens,
            "last_timestamp": timestamp(row.lastTimestampMs),
        ]
    }

    /// Saturating token sums. Counts stay `Int64`, which
    /// `JSONSerialization` writes exactly.
    private struct TokenSums {
        var input: Int64 = 0
        var cacheRead: Int64 = 0
        var cacheCreation: Int64 = 0
        var output: Int64 = 0

        mutating func add(_ row: UsageTokenRow) {
            input = Self.saturatingAdd(input, row.inputTokens)
            cacheRead = Self.saturatingAdd(cacheRead, row.cacheReadTokens)
            cacheCreation = Self.saturatingAdd(cacheCreation, row.cacheCreationTokens)
            output = Self.saturatingAdd(output, row.outputTokens)
        }

        var dict: [String: Any] {
            [
                "input_tokens": input,
                "cache_read_tokens": cacheRead,
                "cache_creation_tokens": cacheCreation,
                "output_tokens": output,
            ]
        }

        private static func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard overflow else { return sum }
            return b > 0 ? Int64.max : Int64.min
        }
    }

    /// Every row of the totals query summed (recorded and unreported), the
    /// latest timestamp among them (null when nothing matched), and the
    /// unreported part on its own.
    private static func totalsDict(_ totals: [UsageTokenRow]) -> [String: Any] {
        var all = TokenSums()
        var unreported = TokenSums()
        var last: Int64?
        for row in totals {
            all.add(row)
            if row.isUnreported { unreported.add(row) }
            last = max(last ?? row.lastTimestampMs, row.lastTimestampMs)
        }
        var dict = all.dict
        dict["unreported"] = unreported.dict
        dict["last_timestamp"] = last.map(timestamp) ?? NSNull()
        return dict
    }

    /// `YYYY-MM-DDTHH:MM:SS.fffZ` in UTC, in integer arithmetic only, so
    /// the text is millisecond exact (no Double fraction to round). The
    /// civil date comes from the day count since the epoch by Howard
    /// Hinnant's `civil_from_days`, valid over the whole proleptic
    /// Gregorian calendar.
    private static func timestamp(_ ms: Int64) -> String {
        let millisPerDay: Int64 = 86_400_000
        var days = ms / millisPerDay
        var msOfDay = ms % millisPerDay
        if msOfDay < 0 {
            days -= 1
            msOfDay += millisPerDay
        }

        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        return String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ",
            year, month, day,
            msOfDay / 3_600_000, msOfDay / 60_000 % 60, msOfDay / 1_000 % 60, msOfDay % 1_000)
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        // JSONSerialization always produces UTF-8.
        return String(decoding: data, as: UTF8.self)
    }
}
