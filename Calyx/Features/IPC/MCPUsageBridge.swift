// MCPUsageBridge.swift
// Calyx
//
// Bridges the MCP tool surface onto the usage ledger's Gold query:
// exposes `usage_report`, which aggregates the token usage Calyx has
// recorded from Claude Code transcripts. Same shape as
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
    private let reports: ([UsageQuery], Calendar) async throws -> [[UsageRow]]
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
        reports: @escaping ([UsageQuery], Calendar) async throws -> [[UsageRow]],
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
    nonisolated private static func wireName(_ dimension: UsageQuery.Dimension) -> String {
        switch dimension {
        case .model: return "model"
        case .effort: return "effort"
        case .thread: return "thread"
        case .agentType: return "agent_type"
        case .day: return "day"
        case .project: return "project"
        case .branch: return "branch"
        case .session: return "session"
        }
    }

    /// Every dimension by its wire name, in the order the schema lists them.
    nonisolated private static let dimensions: [(wire: String, dimension: UsageQuery.Dimension)] =
        UsageQuery.Dimension.allCases.map { (wireName($0), $0) }

    private static let defaultGroupBy: [UsageQuery.Dimension] = [.model, .effort]
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
            description: "Report the Claude Code token usage Calyx has recorded from session transcripts, "
                + "aggregated by the group_by dimensions (default model and effort). Each row carries "
                + "responses, final_responses, input, cache read, cache creation (and its 1h part), output "
                + "and thinking token sums, and the last timestamp; totals covers every matching record, "
                + "also when limit cut the rows. Requires Settings > Agents > Usage Tracking. The notes "
                + "field explains which numbers are lower bounds.",
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
                                + "project, branch, session. Default [\"model\", \"effort\"]; [] gives one total row"),
                    ] as [String: AnyCodable]),
                    "days": MCPRouter.prop(
                        "integer", "Only the last N local calendar days, today included (1 = today), "
                            + "from 1 to \(UsagePeriod.maxLastDays). Not with since/until"),
                    "since": MCPRouter.prop("string", "Inclusive lower bound, YYYY-MM-DDTHH:MM:SS[.fff]Z (UTC)"),
                    "until": MCPRouter.prop("string", "Exclusive upper bound, YYYY-MM-DDTHH:MM:SS[.fff]Z (UTC)"),
                    "session_id": MCPRouter.prop(
                        "string", "Only this Claude Code session; \"current\" is the session running in the calling pane"),
                    "project": MCPRouter.prop("string", "Only sessions whose project root is exactly this path"),
                    "thread": MCPRouter.prop("string", "Only this thread: main, subagent or advisor"),
                    "limit": MCPRouter.prop("integer", "Maximum rows returned, 1 to 1000 (default 200)"),
                ]
            )
        ),
    ]

    /// Fixed notes attached to every result: what the numbers cover.
    private static let notes = [
        "output_tokens_final and thinking_tokens_final count only responses whose final transcript line was "
            + "written; compare final_responses with responses to see how much of a group they cover.",
        "Requests Claude Code does not write to its transcript are not counted, so these numbers are lower than "
            + "Claude Code's own session totals (output by roughly 1-3%, cache reads by more).",
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

        let rowsQuery = UsageQuery(
            groupBy: groupBy, sinceMs: sinceMs, untilMs: until, sessionID: resolvedSessionID,
            project: project.map { .root($0) }, thread: thread)
        var totalsQuery = rowsQuery
        totalsQuery.groupBy = []

        // One read for rows and totals, so both describe the same stored
        // state and the totals are not affected by `limit`.
        let results = try await reports([rowsQuery, totalsQuery], calendar)
        // `reports` returns exactly one result per query.
        let rows = results[0]
        let totals = results[1]

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

    private func decodeGroupBy(_ arguments: [String: Any]) throws -> [UsageQuery.Dimension] {
        guard let value = arguments["group_by"] else { return Self.defaultGroupBy }
        guard let names = value as? [String] else {
            throw MCPUsageBridgeError.invalidArgument(name: "group_by", reason: "expected an array of strings")
        }
        var dimensions: [UsageQuery.Dimension] = []
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

    private func decodeThread(_ arguments: [String: Any]) throws -> UsageRecord.Thread? {
        guard let raw = try optionalString(arguments, "thread") else { return nil }
        guard let thread = UsageRecord.Thread(rawValue: raw) else {
            throw MCPUsageBridgeError.invalidArgument(name: "thread", reason: "expected main, subagent or advisor")
        }
        return thread
    }

    /// Optional timestamp argument in the one shape the transcripts use,
    /// parsed by the transcript parser itself: epoch milliseconds.
    private func optionalTimestamp(_ arguments: [String: Any], _ key: String) throws -> Int64? {
        guard let text = try optionalString(arguments, key) else { return nil }
        guard let ms = ClaudeTranscriptParser.epochMilliseconds(fromISO8601: text) else {
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
    /// (a nil group is JSON null) plus the nine fields.
    private static func rowDict(_ row: UsageRow, wireNames: [String]) -> [String: Any] {
        var key: [String: Any] = [:]
        for (name, value) in zip(wireNames, row.key) {
            key[name] = value ?? NSNull()
        }
        var dict = fieldsDict(row)
        dict["key"] = key
        return dict
    }

    /// The totals query's single row; with nothing matched Gold returns
    /// no row, which is zero everywhere and no last timestamp.
    private static func totalsDict(_ totals: [UsageRow]) -> [String: Any] {
        guard let row = totals.first else {
            var dict: [String: Any] = [:]
            for name in numericFieldNames {
                dict[name] = Int64(0)
            }
            dict["last_timestamp"] = NSNull()
            return dict
        }
        return fieldsDict(row)
    }

    private static let numericFieldNames = [
        "responses", "final_responses", "input_tokens", "cache_read_tokens", "cache_creation_tokens",
        "cache_creation_1h_tokens", "output_tokens_final", "thinking_tokens_final",
    ]

    /// The nine fields of a row. Counts stay `Int64`, which
    /// `JSONSerialization` writes exactly.
    private static func fieldsDict(_ row: UsageRow) -> [String: Any] {
        [
            "responses": row.responses,
            "final_responses": row.finalResponses,
            "input_tokens": row.inputTokens,
            "cache_read_tokens": row.cacheReadTokens,
            "cache_creation_tokens": row.cacheCreationTokens,
            "cache_creation_1h_tokens": row.cacheCreation1hTokens,
            "output_tokens_final": row.outputTokensFinal,
            "thinking_tokens_final": row.thinkingTokensFinal,
            "last_timestamp": timestamp(row.lastTimestampMs),
        ]
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
