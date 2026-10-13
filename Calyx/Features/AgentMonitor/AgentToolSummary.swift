// AgentToolSummary.swift
// Calyx
//
// The tool-specific human-readable string derived from a hook payload's
// tool-input object, shared by the approval banner
// (AgentHookToolCall.summary) and the Agents sidebar's subagent child
// row (AgentEvent.toolSummary). One derivation, so a banner and a row
// describing the same tool call can never disagree about what it is.
//
// `singleLineSummary` runs `SecretRedactor.redact` on a bounded window of
// the collapsed text before applying the final cap, so a secret that
// straddles the cut is masked whole instead of leaking its prefix. Every
// summary built through it (the Agents sidebar rows, Mission Map rows,
// and the `agent_status` MCP tool) is therefore already redacted when it
// is stored; a consumer that redacts it again gets the same string back,
// because `SecretRedactor.marker` matches none of the redaction rules.

import Foundation

enum AgentToolSummary {

    /// A derived summary's cap, in `Character`s. `derive` itself returns
    /// the full string, so a caller that also needs the untruncated value
    /// (or a different cap) is not forced through this one; the cap is
    /// applied by the caller, by `readableArguments`, which stops
    /// building at it, and by `singleLineSummary`, which redacts secrets
    /// in its bounded window before cutting to this cap.
    static let maxSummaryLength = 500

    /// How many characters `singleLineSummary` reads before redaction,
    /// in `Character`s. Redacting only the first
    /// `maxSummaryLength` characters would miss a secret that straddles
    /// the cut (its prefix alone matches no pattern), so the window must
    /// extend past the cap by at least the longest secret that can cross
    /// it: 500 plus about 161 for a fine-grained `github_pat_` token,
    /// rounded up to 4,096 for generous margin. The window keeps ingest
    /// bounded: a megabyte input is walked once, never redacted in full.
    /// Known residual: a JWT segment may run to about 2,000 characters,
    /// so a JWT that starts near the cut with exceptionally long header
    /// and payload segments can extend past the window, go unmatched, and
    /// leave its first characters in the capped summary.
    static let redactionWindowLength = 4_096

    /// How many characters past the renderer's remaining budget
    /// `readableArguments` redacts in each leaf string value, in
    /// `Character`s. A secret that starts inside the budget and crosses
    /// its end is masked whole only if the redacted prefix contains all
    /// of it, so this must exceed the longest non-JWT secret pattern
    /// (about 161 characters for a fine-grained `github_pat_` token); 512
    /// leaves generous margin. The JWT residual documented on
    /// `redactionWindowLength` applies here as well. Bounding each value
    /// by the remaining budget keeps the total redaction work per event
    /// near `maxSummaryLength` plus this lookahead per rendered value,
    /// instead of a full window per value.
    static let redactionLookahead = 512

    /// `tool_name`s whose summary is the string at `tool_input.file_path`.
    /// `NotebookEdit` is deliberately NOT in this set -- Claude Code's
    /// actual PreToolUse schema for it is `tool_input.notebook_path`, a
    /// distinct key of its own (see `derive`'s own `NotebookEdit` case).
    private static let filePathToolNames: Set<String> = ["Write", "Edit", "Read"]

    /// Tool names whose summary is the string at `tool_input.command`:
    /// Claude Code's and Codex's `Bash`, and Grok's own shell tool
    /// `run_terminal_command`.
    private static let commandToolNames: Set<String> = ["Bash", "run_terminal_command"]

    /// What `readableArguments` writes between two `key: value` pairs.
    private static let pairSeparator = ", "

    /// What `appendCompactJSON` writes between two array elements and
    /// between two object members.
    private static let jsonElementSeparator = ","

    /// The compact JSON of a tool-input object, empty when it holds a
    /// value JSONSerialization cannot encode.
    static func compactJSON(_ toolInput: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: toolInput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The well-known key per tool name (the command for `Bash` and
    /// Grok's `run_terminal_command`, the file path for
    /// `Write`/`Edit`/`Read`, the notebook path for `NotebookEdit` -- its
    /// own distinct `notebook_path` key, never `file_path` -- the URL for
    /// `WebFetch`), falling back to `fallback` when `toolName` isn't one
    /// of these, or the expected key is absent/not a string.
    ///
    /// `fallback` is the caller's own rendering of the whole tool input
    /// (the approval banner's compact JSON, the sidebar row's readable
    /// `key: value` pairs), and an autoclosure so it is only built when it
    /// is actually the answer: a `Write`'s `tool_input.content` runs to
    /// hundreds of kilobytes while its summary is just the file path.
    static func derive(
        toolName: String,
        toolInput: [String: Any],
        fallback: @autoclosure () -> String
    ) -> String {
        switch toolName {
        case _ where commandToolNames.contains(toolName):
            return (toolInput["command"] as? String) ?? fallback()
        case _ where filePathToolNames.contains(toolName):
            return (toolInput["file_path"] as? String) ?? fallback()
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String) ?? fallback()
        case "WebFetch":
            return (toolInput["url"] as? String) ?? fallback()
        default:
            return fallback()
        }
    }

    /// A derived summary rendered as one line, capped at
    /// `maxSummaryLength` characters: every run of whitespace (spaces,
    /// tabs, newlines, carriage returns) becomes a single space, and
    /// leading and trailing whitespace is dropped. The sidebar's child
    /// row draws its tool line as a single `Text` with `.lineLimit(1)`
    /// and joins its help/accessibility fields with newlines, so a hard
    /// line break inside a summary (a heredoc command, routinely) would
    /// cut the row short of the available width and break the
    /// one-field-per-line structure VoiceOver reads. The approval banner
    /// does not go through this: an operator approving a script sees the
    /// command as written.
    ///
    /// The collapsed text is gathered into a window of
    /// `redactionWindowLength` characters, `SecretRedactor.redact` is
    /// applied to that window, and only then is the result cut to
    /// `maxSummaryLength`, so a secret straddling the cap is masked whole
    /// rather than leaking its prefix. The cut never leaves a trailing
    /// space. Collapsing only ever replaces whitespace with a space,
    /// never removes it, so it cannot join two pieces into a secret.
    ///
    /// The window counts characters that survive the collapse, so
    /// whitespace never spends it. That bounds what is gathered and
    /// redacted, not what is read: whitespace is walked in full, so a run
    /// of a million spaces costs its own length.
    static func singleLineSummary(_ text: String) -> String {
        var line = BoundedText(limit: redactionWindowLength)
        var pendingSpace = false
        for character in text {
            guard !character.isWhitespace else {
                pendingSpace = !line.value.isEmpty
                continue
            }
            if pendingSpace {
                // The separating space is only worth its budget when the
                // character it separates still fits after it.
                guard line.remaining > 1 else { break }
                line.append(" ")
                pendingSpace = false
            }
            line.append(String(character))
            if line.isFull { break }
        }
        let redacted = SecretRedactor.redact(line.value)
        guard redacted.count > maxSummaryLength else { return redacted }
        var capped = String(redacted.prefix(maxSummaryLength))
        while capped.last?.isWhitespace == true { capped.removeLast() }
        return capped
    }

    /// A tool input's arguments rendered as `key: value` pairs joined by
    /// `, `, keys sorted so the same call always reads the same way. A
    /// string value is rendered verbatim, a number or a boolean by its
    /// natural spelling, and anything structured (array, object, null) as
    /// the compact JSON of that one value.
    ///
    /// Every leaf string value (a top-level string, and every string
    /// inside a structured value, JSON object keys excluded) is passed
    /// through `SecretRedactor.redact` before it is rendered, so a secret
    /// that straddles the cap is masked whole. Keys are parameter names
    /// and are left as written. Only the first `remaining budget +
    /// redactionLookahead` characters of a value are redacted and
    /// rendered, which keeps the cost bounded for a value of hundreds of
    /// kilobytes and for a tool input with many long values. Redacting per
    /// value loses nothing real: a secret split across two values is not
    /// a secret. `singleLineSummary` still runs its window redaction over
    /// the rendered result afterwards, which is idempotent.
    ///
    /// Built incrementally and stopped the moment it reaches
    /// `maxSummaryLength` characters, so a caller on the main actor never
    /// pays for serializing a tool input whose values run to hundreds of
    /// kilobytes: a value that alone exceeds the remaining budget is cut
    /// at the budget instead of being rendered in full first. The budget
    /// bounds the rendering, not the key count: every key is sorted before
    /// the first pair is written, so a tool input with a great many keys
    /// costs that sort whatever the budget is.
    ///
    /// An empty tool input yields an empty string.
    static func readableArguments(_ toolInput: [String: Any]) -> String {
        var text = BoundedText(limit: maxSummaryLength)
        for (index, key) in toolInput.keys.sorted().enumerated() {
            if index > 0 {
                // The separator is only worth its budget when at least
                // one character of the pair behind it still fits, so a
                // summary never ends on a dangling ", ".
                guard text.remaining > pairSeparator.count else { break }
                text.append(pairSeparator)
            }
            text.append(key)
            text.append(": ")
            appendValue(toolInput[key] ?? NSNull(), to: &text)
        }
        return text.value
    }

    /// One argument value: a string verbatim, a number or boolean by its
    /// natural spelling, anything structured as its own compact JSON.
    private static func appendValue(_ value: Any, to text: inout BoundedText) {
        switch value {
        case let string as String:
            text.append(redactedValue(string, budget: text.remaining))
        case let number as NSNumber where isBoolean(number):
            text.append(number.boolValue ? "true" : "false")
        case let number as NSNumber:
            text.append(number.description)
        default:
            appendCompactJSON(value, to: &text)
        }
    }

    /// The compact JSON of one value, written straight into the bounded
    /// buffer: object keys sorted for a stable rendering, and every append
    /// a no-op once the budget is spent, so an oversized value ends up cut
    /// mid-render rather than serialized in full and trimmed.
    private static func appendCompactJSON(_ value: Any, to text: inout BoundedText) {
        guard !text.isFull else { return }
        switch value {
        case is NSNull:
            text.append("null")
        case let number as NSNumber where isBoolean(number):
            text.append(number.boolValue ? "true" : "false")
        case let number as NSNumber:
            text.append(number.description)
        case let string as String:
            appendJSONString(string, redacting: true, to: &text)
        case let array as NSArray:
            text.append("[")
            for (index, element) in array.enumerated() {
                guard !text.isFull else { break }
                if index > 0 {
                    // The separator is only worth its budget when at
                    // least one character of the element behind it still
                    // fits, so a value never ends on a dangling ",".
                    guard text.remaining > jsonElementSeparator.count else { break }
                    text.append(jsonElementSeparator)
                }
                appendCompactJSON(element, to: &text)
            }
            text.append("]")
        case let object as NSDictionary:
            guard let keys = object.allKeys as? [String] else { break }
            text.append("{")
            for (index, key) in keys.sorted().enumerated() {
                guard !text.isFull else { break }
                if index > 0 {
                    // The separator is only worth its budget when at
                    // least one character of the member behind it still
                    // fits, so a value never ends on a dangling ",".
                    guard text.remaining > jsonElementSeparator.count else { break }
                    text.append(jsonElementSeparator)
                }
                appendJSONString(key, redacting: false, to: &text)
                text.append(":")
                appendCompactJSON(object[key] ?? NSNull(), to: &text)
            }
            text.append("}")
        default:
            break
        }
    }

    /// A JSON string literal, escaped one character at a time so a long
    /// string is never escaped past the budget.
    ///
    /// `redacting` is true for a string value and false for an object
    /// key, which is a name rather than data.
    private static func appendJSONString(
        _ string: String, redacting: Bool, to text: inout BoundedText
    ) {
        text.append("\"")
        for character in redacting ? redactedValue(string, budget: text.remaining) : string {
            guard !text.isFull else { return }
            text.append(escaped(character))
        }
        text.append("\"")
    }

    /// A leaf string value with its secrets masked, limited to the first
    /// `budget + redactionLookahead` characters, where `budget` is the
    /// renderer's remaining capacity. Each source character renders as at
    /// least one character, so nothing past `budget` can be shown, and
    /// the lookahead lets a secret crossing the budget be matched whole.
    private static func redactedValue(_ string: String, budget: Int) -> String {
        SecretRedactor.redact(String(string.prefix(max(budget, 0) + redactionLookahead)))
    }

    /// One character's JSON spelling inside a string literal.
    private static func escaped(_ character: Character) -> String {
        switch character {
        case "\"": return "\\\""
        case "\\": return "\\\\"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default:
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1, scalar.value < 0x20 else {
                return String(character)
            }
            return String(format: "\\u%04x", scalar.value)
        }
    }

    /// Whether a JSON number is really a boolean. `JSONSerialization`
    /// decodes both as `NSNumber`, and an integer one casts to `Bool` just
    /// as happily, so the underlying type is what distinguishes them.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A string that accepts appends until it holds `limit` characters and
    /// ignores every one after that, so a caller can write a rendering out
    /// piece by piece without ever measuring what it skipped.
    private struct BoundedText {
        let limit: Int
        private(set) var value = ""
        private var length = 0

        init(limit: Int) {
            self.limit = limit
        }

        var isFull: Bool { remaining <= 0 }

        /// How many more characters this buffer will accept.
        var remaining: Int { limit - length }

        mutating func append(_ piece: String) {
            for character in piece {
                guard length < limit else { return }
                value.append(character)
                length += 1
            }
        }
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` in half -- backs off to the last whole
    /// character that still fits under `cap`.
    static func truncatedToByteCap(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= cap else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
