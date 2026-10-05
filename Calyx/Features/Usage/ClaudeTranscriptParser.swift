// ClaudeTranscriptParser.swift
// Calyx
//
// Turns ONE line of Claude Code's transcript JSONL into numeric usage
// records. Only a top-level "assistant" object yields records; an advisor
// iteration inside its usage becomes a record of its own. Mirrors
// AgentEvent's lenient JSONSerialization decode convention (see
// AgentEvent.decode(from:)): unknown keys are tolerated and nothing throws.

import Foundation

enum ClaudeTranscriptParser {
    /// Returns the main record first, then one record per advisor
    /// iteration in iteration order; an empty array for any line that is
    /// not a usable assistant line (other types, `<synthetic>` model,
    /// malformed JSON, a missing or invalid required field).
    static func records(fromLine line: Data) -> [UsageRecord] {
        // Transcript lines can be megabytes (tool results) and most are
        // not assistant lines, so skip the JSON parse when the line cannot
        // be one. The needle is the quoted word alone, not
        // `"type":"assistant"`: a spacing change in a future Claude Code
        // version must not silently drop every line.
        guard line.range(of: assistantNeedle) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let key = label(message["id"], maxLength: identifierMaxLength),
              let model = modelLabel(message["model"]),
              let sessionID = label(object["sessionId"], maxLength: identifierMaxLength),
              let timestampText = object["timestamp"] as? String,
              let timestampMs = epochMilliseconds(fromISO8601: timestampText) else {
            return []
        }

        // Older Claude Code versions leave `effort` null and only set
        // `perTurnEffort`; where both are present they agree.
        let effort = label(object["effort"], maxLength: effortMaxLength)
            ?? label(object["perTurnEffort"], maxLength: effortMaxLength)
        let agentID = label(object["agentId"], maxLength: identifierMaxLength)
        let agentType = label(object["attributionAgent"], maxLength: identifierMaxLength)
        let gitBranch = label(object["gitBranch"], maxLength: gitBranchMaxLength)
        let cwd = cwdLabel(object["cwd"])
        // A null stop_reason marks a line written mid-response, whose
        // output-side numbers are not final yet.
        let isFinal = message["stop_reason"] is String

        func record(key: String, model: String, effort: String?, thread: UsageRecord.Thread,
                    usage: [String: Any]) -> UsageRecord {
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
                inputTokens: tokenCount(usage["input_tokens"]),
                outputTokens: tokenCount(usage["output_tokens"]),
                thinkingTokens: tokenCount(
                    (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]),
                cacheReadTokens: tokenCount(usage["cache_read_input_tokens"]),
                cacheCreationTokens: tokenCount(usage["cache_creation_input_tokens"]),
                cacheCreation1hTokens: tokenCount(
                    (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]),
                isFinal: isFinal
            )
        }

        var records = [
            record(
                key: key, model: model, effort: effort,
                thread: isTrue(object["isSidechain"]) ? .subagent : .main, usage: usage),
        ]

        // Advisor usage is NOT included in the top-level usage numbers; it
        // only appears as an iteration carrying its own model, so it is
        // emitted as a separate record instead of being added to the main
        // one. The index is the position in the whole iterations array, so
        // the key stays stable whatever the other iterations are. The key
        // is derived from an already-validated id and is not length-checked
        // again (a 128-character id must still get its advisor record).
        if let iterations = usage["iterations"] as? [Any] {
            for (index, element) in iterations.enumerated() {
                guard let iteration = element as? [String: Any],
                      iteration["type"] as? String == advisorIterationType,
                      let advisorModel = modelLabel(iteration["model"]) else {
                    continue
                }
                records.append(record(
                    key: "\(key)#adv\(index)", model: advisorModel, effort: nil,
                    thread: .advisor, usage: iteration))
            }
        }
        return records
    }

    // MARK: - Constants

    private static let assistantNeedle = Data(#""assistant""#.utf8)
    private static let syntheticModel = "<synthetic>"
    private static let advisorIterationType = "advisor_message"

    private static let identifierMaxLength = TranscriptLabel.identifierMaxScalars
    private static let effortMaxLength = 64
    private static let gitBranchMaxLength = 255
    private static let cwdMaxLength = TranscriptLabel.cwdMaxScalars

    // MARK: - Labels

    /// `TranscriptLabel.label`, the one label rule (see there).
    private static func label(_ value: Any?, maxLength: Int) -> String? {
        TranscriptLabel.label(value, maxScalars: maxLength)
    }

    /// The label rule for a working directory or project root: `label`
    /// at `cwdMaxLength` scalars.
    private static func cwdLabel(_ value: Any?) -> String? {
        label(value, maxLength: cwdMaxLength)
    }

    /// Forwards to `TranscriptLabel.isCWD`.
    static func isCWDLabel(_ path: String) -> Bool {
        TranscriptLabel.isCWD(path)
    }

    /// Forwards to `TranscriptLabel.isIdentifier`.
    static func isIdentifierLabel(_ identifier: String) -> Bool {
        TranscriptLabel.isIdentifier(identifier)
    }

    /// A model label, for the main record and for an advisor iteration
    /// alike: a valid label that is not `<synthetic>`, so no record ever
    /// carries that model. Compared AFTER validation, against the trimmed
    /// value that would be stored: comparing the raw string would let
    /// " <synthetic> " through as a record whose model is "<synthetic>".
    private static func modelLabel(_ value: Any?) -> String? {
        guard let model = label(value, maxLength: identifierMaxLength), model != syntheticModel else {
            return nil
        }
        return model
    }

    // MARK: - Numbers

    /// A token count is a non-negative integer; an integral double (12.0)
    /// is accepted, and every other shape counts as 0 rather than failing
    /// the line, because one odd field must not lose the other numbers.
    private static func tokenCount(_ value: Any?) -> Int64 {
        guard let number = jsonNumber(value),
              let count = Int64(exactly: number),
              count >= 0 else {
            return 0
        }
        return count
    }

    /// JSONSerialization bridges both JSON numbers and JSON booleans to
    /// NSNumber, and Swift's `as? Int` / `as? Bool` casts cannot tell them
    /// apart (`true as? Int` is 1, `1 as? Bool` is true). The CoreFoundation
    /// type id can: only a JSON boolean is a CFBoolean.
    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, !isJSONBoolean(number) else { return nil }
        return number
    }

    /// True only for a JSON `true`, never for a numeric 1.
    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, isJSONBoolean(number) else { return false }
        return number.boolValue
    }

    // MARK: - Timestamp

    /// Forwards to `TranscriptTimestamp.epochMilliseconds(fromISO8601:)`.
    static func epochMilliseconds(fromISO8601 text: String) -> Int64? {
        TranscriptTimestamp.epochMilliseconds(fromISO8601: text)
    }
}
