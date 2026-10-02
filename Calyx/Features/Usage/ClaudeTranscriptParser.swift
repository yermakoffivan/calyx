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
        let cwd = label(object["cwd"], maxLength: cwdMaxLength)
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

    private static let identifierMaxLength = 128
    private static let effortMaxLength = 64
    private static let gitBranchMaxLength = 255
    private static let cwdMaxLength = 1_024

    // MARK: - Labels

    /// Transcript-derived strings are later handed to agents over MCP, so
    /// each one is limited in length and character class before it is
    /// stored: surrounding whitespace is trimmed, and the trimmed value
    /// must be non-empty, at most `maxLength` Unicode SCALARS, and free of
    /// every scalar `ControlCharacterDisplay.isEscapedCategory` flags.
    /// Returns nil for anything else, including a non-string value; the
    /// caller decides whether nil drops the line (required label) or just
    /// the label (optional one).
    ///
    /// The length is counted in scalars, not `Character`s, for the reason
    /// `ControlCharacterDisplay.render` documents for its `cap`: one
    /// grapheme cluster can carry an unbounded number of combining marks,
    /// so a grapheme-counted limit does not bound the stored size at all.
    ///
    /// The unsafe set is `ControlCharacterDisplay`'s own definition, not a
    /// copy of it, so the approval banner and these labels cannot drift
    /// apart: controls and line breaks (a tab INSIDE the value counts),
    /// plus format scalars (bidi overrides, zero-width characters, the Tag
    /// block used for invisible prompt injection), private-use and
    /// surrogate scalars. The banner escapes such a scalar into a visible
    /// token; a label has no reader to show a token to, so it is rejected
    /// whole. Consequence: a label containing any format scalar is
    /// invalid, including a ZWJ inside an otherwise ordinary emoji
    /// sequence. Combining marks and non-ASCII letters stay valid.
    ///
    /// Trimming is an explicit scalar loop, NOT `trimmingCharacters(in:
    /// .whitespaces)`: Foundation's trimming also strips U+FEFF and U+200B
    /// at the edges although neither is in `.whitespaces`, which would
    /// store "main" for "\u{200B}main" -- a value the transcript never
    /// contained (for `cwd`, a different path) -- and hide a format scalar
    /// from the check below. Only real whitespace is removed (see
    /// `isEdgeWhitespace`); every scalar that remains is classified, so a
    /// format scalar is rejected at any position, first and last included.
    /// U+00A0 and U+3000 are Zs too, so they are trimmed at the edges and
    /// valid inside a label.
    ///
    /// One exception sits below this function and cannot be seen from it:
    /// `JSONSerialization.jsonObject` removes exactly ONE leading U+FEFF
    /// from every string value before the parser sees it, for raw BOM
    /// bytes and the `\ufeff` escape alike (verified; `JSONDecoder` does
    /// not). So a single leading BOM is unobservable here ("\u{FEFF}main"
    /// is stored as "main"), while two leading BOMs leave one behind and
    /// are rejected. That is accepted: the removal cannot inject anything
    /// and no slice needs the stored label to equal the transcript's
    /// bytes. Pinned by
    /// `test_records_singleLeadingBOM_isRemovedByJSONSerializationBeforeTheParserSeesIt`.
    private static func label(_ value: Any?, maxLength: Int) -> String? {
        guard let raw = value as? String else { return nil }
        var scalars = raw.unicodeScalars[...]
        while let first = scalars.first, isEdgeWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isEdgeWhitespace(last) { scalars.removeLast() }
        var scalarCount = 0
        for scalar in scalars {
            scalarCount += 1
            guard scalarCount <= maxLength, !ControlCharacterDisplay.isEscapedCategory(scalar) else {
                return nil
            }
        }
        guard scalarCount > 0 else { return nil }
        return String(scalars)
    }

    /// Whitespace that is trimmed from a label's edges: a space separator
    /// (general category Zs) or a tab. Defined from the Unicode property,
    /// not from `CharacterSet`, so the set is exactly what it says.
    private static func isEdgeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .spaceSeparator || scalar == "\t"
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

    /// Parses the one shape Claude Code writes (JavaScript's
    /// `toISOString()`): `YYYY-MM-DDTHH:MM:SS[.fraction]Z`, UTC only.
    /// Done by hand in integer arithmetic for two reasons: the result is
    /// millisecond-exact (no Double seconds to round), and it needs no
    /// formatter, which would either be allocated per line or shared as
    /// non-Sendable global state.
    private static func epochMilliseconds(fromISO8601 text: String) -> Int64? {
        let bytes = Array(text.utf8)
        // "YYYY-MM-DDTHH:MM:SSZ" is 20 bytes; a fraction adds "." + digits.
        guard bytes.count >= 20, bytes.last == UInt8(ascii: "Z"),
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = decimal(bytes[0..<4]),
              let month = decimal(bytes[5..<7]),
              let day = decimal(bytes[8..<10]),
              let hour = decimal(bytes[11..<13]),
              let minute = decimal(bytes[14..<16]),
              let second = decimal(bytes[17..<19]),
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else {
            return nil
        }

        var milliseconds: Int64 = 0
        if bytes.count > 20 {
            let fraction = bytes[20..<(bytes.count - 1)]
            guard bytes[19] == UInt8(ascii: "."), !fraction.isEmpty,
                  fraction.allSatisfy(isDigit) else {
                return nil
            }
            // Digits beyond the third are below a millisecond: truncated.
            var scale: Int64 = 100
            for byte in fraction.prefix(3) {
                milliseconds += Int64(byte - UInt8(ascii: "0")) * scale
                scale /= 10
            }
        }

        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
        return seconds * 1_000 + milliseconds
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// The value of an all-digit ASCII run; nil if any byte is not a digit.
    private static func decimal(_ bytes: ArraySlice<UInt8>) -> Int64? {
        var value: Int64 = 0
        for byte in bytes {
            guard isDigit(byte) else { return nil }
            value = value * 10 + Int64(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func daysInMonth(_ month: Int64, year: Int64) -> Int64 {
        switch month {
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days from 1970-01-01 to the given proleptic Gregorian date (Howard
    /// Hinnant's `days_from_civil`): the year is shifted to start in March
    /// so the leap day falls at the end of the 400-year era's year.
    private static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
        let shiftedYear = month <= 2 ? year - 1 : year
        // The parsed year is 0...9999, so shiftedYear is -1 at the lowest.
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
