// ClaudeUsageTelemetryConfig.swift
// Calyx
//
// The telemetry block Calyx keeps in Claude Code's settings file while
// Usage Tracking is on: nine `env` members and the top-level
// `otelHeadersHelper`. The file belongs to the user (often a symbolic
// link into a dotfiles repository), so every edit is a byte splice through
// `JSONConfigDocumentEditor`, and telemetry settings the user wrote
// themselves are never overwritten or removed.

import Foundation

/// The pure part: what a settings document says about telemetry, and the edits Calyx makes to it.
enum ClaudeUsageTelemetryConfig {

    static let endpointKey = "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"
    static let enableKey = "CLAUDE_CODE_ENABLE_TELEMETRY"
    static let helperKey = "otelHeadersHelper"

    /// The nine env keys Calyx writes, in the order they are inserted.
    static let envKeys: [String] = [
        enableKey,
        "OTEL_METRICS_EXPORTER",
        "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL",
        endpointKey,
        "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE",
        "OTEL_EXPORTER_OTLP_METRICS_COMPRESSION",
        "OTEL_METRIC_EXPORT_INTERVAL",
        "OTEL_METRICS_INCLUDE_SESSION_ID",
        "OTEL_METRICS_INCLUDE_ACCOUNT_UUID",
    ]

    private static let envKeyName = "env"
    private static let otelPrefix = "OTEL_"

    // MARK: - Values

    private static let endpointPrefix = "http://127.0.0.1:"
    private static let endpointSuffix = "/usage/v1/metrics"

    static func endpoint(port: Int) -> String {
        endpointPrefix + String(port) + endpointSuffix
    }

    /// The env members of the block, in `envKeys` order, with their values.
    private static func envValues(port: Int) -> [(key: String, value: String)] {
        [
            (enableKey, "1"),
            ("OTEL_METRICS_EXPORTER", "otlp"),
            ("OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "http/json"),
            (endpointKey, endpoint(port: port)),
            ("OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE", "cumulative"),
            ("OTEL_EXPORTER_OTLP_METRICS_COMPRESSION", "none"),
            ("OTEL_METRIC_EXPORT_INTERVAL", "5000"),
            ("OTEL_METRICS_INCLUDE_SESSION_ID", "true"),
            ("OTEL_METRICS_INCLUDE_ACCOUNT_UUID", "false"),
        ]
    }

    private static let helperPrefix = "cat '"
    /// The fallback makes the command succeed when the headers file is
    /// missing: a failing helper makes Claude Code send nothing at all.
    private static let helperSuffix = "' 2>/dev/null || printf '{}'"
    /// How a `'` inside the single-quoted path is written for the shell.
    private static let escapedQuote = "'\\''"

    /// The command Claude Code runs for its headers. `headersFilePath`
    /// must be absolute (Calyx's credential file always is): a path
    /// starting with `-` would be read by `cat` as an option.
    static func helperCommand(headersFilePath: String) -> String {
        helperPrefix + headersFilePath.replacingOccurrences(of: "'", with: escapedQuote) + helperSuffix
    }

    /// The port of a string that is exactly a Calyx endpoint (`http://127.0.0.1:<1...65535, no leading zero>/usage/v1/metrics`), else nil.
    static func port(ofEndpoint value: String) -> Int? {
        let bytes = Array(value.utf8)
        let prefix = Array(endpointPrefix.utf8)
        let suffix = Array(endpointSuffix.utf8)
        guard bytes.count > prefix.count + suffix.count,
              bytes.starts(with: prefix),
              Array(bytes.suffix(suffix.count)) == suffix
        else { return nil }
        let digits = bytes[prefix.count..<(bytes.count - suffix.count)]
        guard digits.count <= 5,
              digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              digits.first != UInt8(ascii: "0"),
              let port = Int(String(decoding: digits, as: UTF8.self)),
              (1...65535).contains(port)
        else { return nil }
        return port
    }

    /// Whether a string is exactly a helper command Calyx writes (for any
    /// non-empty headers file path): the quoted path may hold a `'` only
    /// in its escaped form, so nothing can follow the closing quote.
    static func isHelperCommand(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array(helperPrefix.utf8)
        let suffix = Array(helperSuffix.utf8)
        guard bytes.count > prefix.count + suffix.count,
              bytes.starts(with: prefix),
              Array(bytes.suffix(suffix.count)) == suffix
        else { return false }
        let path = Array(bytes[prefix.count..<(bytes.count - suffix.count)])
        let escape = Array(escapedQuote.utf8)
        var i = 0
        while i < path.count {
            if path[i] == UInt8(ascii: "'") {
                guard i + escape.count <= path.count, Array(path[i..<(i + escape.count)]) == escape else { return false }
                i += escape.count
            } else {
                i += 1
            }
        }
        return true
    }

    // MARK: - State

    enum State: Equatable {
        /// Nothing about telemetry is in the document.
        case absent
        /// Calyx's block is there (its endpoint names this port). Other members may have drifted from section A.
        case installed(port: Int)
        /// Telemetry settings that are not Calyx's; the keys (env keys, or `otelHeadersHelper`), sorted.
        case foreign(keys: [String])
    }

    /// Reads the state of a settings document. Throws `ConfigFileError.invalidJSON`
    /// for a document that is not a JSON object, and
    /// `JSONConfigDocumentEditor.EditorError.typeConflict("env")` when `env`
    /// holds anything other than an object.
    ///
    /// A key that occurs twice in one object resolves to its first
    /// occurrence, the one the editor reads and edits. Claude Code's own
    /// JSON parser takes the last occurrence, so in such a document the
    /// state Calyx reads can differ from the settings Claude Code applies.
    static func state(of document: Data?) throws -> State {
        guard let document, !document.isEmpty else { return .absent }
        let envKeysPresent = try envMemberKeys(in: document)

        var foreign: Set<String> = []
        let endpointPresent = envKeysPresent.contains(endpointKey)
        var installedPort: Int?
        if endpointPresent {
            let value = try JSONConfigDocumentEditor.decodedValue(at: [.key(envKeyName), .key(endpointKey)], in: document)
            if let string = value as? String, let port = port(ofEndpoint: string) {
                installedPort = port
            } else {
                foreign.insert(endpointKey)
            }
        } else {
            // No endpoint: anything telemetry-related in env was written by the user.
            for key in envKeysPresent where envKeys.contains(key) || key.hasPrefix(otelPrefix) {
                foreign.insert(key)
            }
        }
        if JSONConfigDocumentEditor.containsValue(at: [helperKey], in: document),
           !isCalyxHelper(in: document) {
            foreign.insert(helperKey)
        }

        if !foreign.isEmpty { return .foreign(keys: foreign.sorted()) }
        if let installedPort { return .installed(port: installedPort) }
        return .absent
    }

    /// The keys of the root's `env` object (empty when there is none).
    /// Throws `EditorError.typeConflict("env")` when `env` holds anything
    /// other than an object, and `ConfigFileError.invalidJSON` for a
    /// document whose root is not a JSON object.
    private static func envMemberKeys(in document: Data) throws -> Set<String> {
        let env = try JSONConfigDocumentEditor.decodedValue(at: [.key(envKeyName)], in: document)
        guard JSONConfigDocumentEditor.containsValue(at: [envKeyName], in: document) else { return [] }
        guard let object = env as? [String: Any] else {
            throw JSONConfigDocumentEditor.EditorError.typeConflict(envKeyName)
        }
        return Set(object.keys)
    }

    private static func isCalyxHelper(in document: Data?) -> Bool {
        let value = try? JSONConfigDocumentEditor.decodedValue(at: [.key(helperKey)], in: document)
        guard let string = value as? String else { return false }
        return isHelperCommand(string)
    }

    // MARK: - Installing

    enum InstallResult: Equatable { case written, unchanged, blocked(keys: [String]) }

    /// The document with Calyx's block in it, or the reason nothing was changed.
    /// A member that already holds exactly its value is not touched, so a
    /// repeated install returns the same bytes.
    static func installing(port: Int, headersFilePath: String, into document: Data?) throws -> (document: Data?, result: InstallResult) {
        if case .foreign(let keys) = try state(of: document) {
            return (document, .blocked(keys: keys))
        }
        var bytes = document
        for member in envValues(port: port) {
            bytes = try settingString(member.value, at: [envKeyName, member.key], in: bytes)
        }
        bytes = try settingString(helperCommand(headersFilePath: headersFilePath), at: [helperKey], in: bytes)
        return (bytes, bytes == document ? .unchanged : .written)
    }

    private static func settingString(_ value: String, at keyPath: [String], in document: Data?) throws -> Data? {
        let current = try JSONConfigDocumentEditor.decodedValue(at: keyPath.map { .key($0) }, in: document)
        if let current = current as? String, current == value { return document }
        return try JSONConfigDocumentEditor.setValue(Data(jsonString(value).utf8), at: keyPath, in: document)
    }

    /// A JSON string literal that leaves `/` unescaped, so the user's git
    /// diff shows the same text Claude Code reads.
    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Removing

    enum RemoveResult: Equatable { case removed, nothingToRemove }

    /// Removes Calyx's block when the document holds it. Ownership is by
    /// key: while the endpoint is a Calyx endpoint, the nine `envKeys` and
    /// a Calyx helper command are Calyx's whatever values they hold, so a
    /// removal never leaves a member of Calyx's own that would block the
    /// next install. Every other key (the user's own, in `env` or
    /// elsewhere, and a helper that is not Calyx's) stays. A lone Calyx
    /// helper command is removed too; a foreign or otherwise absent
    /// document comes back unchanged.
    static func removing(from document: Data?) throws -> (document: Data?, result: RemoveResult) {
        switch try state(of: document) {
        case .foreign:
            return (document, .nothingToRemove)
        case .absent:
            guard isCalyxHelper(in: document) else { return (document, .nothingToRemove) }
            return (try JSONConfigDocumentEditor.removeValue(at: [helperKey], in: document), .removed)
        case .installed:
            var bytes = document
            for key in envKeys {
                bytes = try JSONConfigDocumentEditor.removeValue(at: [envKeyName, key], in: bytes)
            }
            if isCalyxHelper(in: bytes) {
                bytes = try JSONConfigDocumentEditor.removeValue(at: [helperKey], in: bytes)
            }
            return (bytes, .removed)
        }
    }
}

// MARK: - File

/// The file part: applies `ClaudeUsageTelemetryConfig`'s edits to Claude
/// Code's settings file under `ConfigFileUtils.withExclusiveConfig` (lock,
/// symbolic links followed, atomic replace, mode preserved, unchanged
/// document not written).
struct ClaudeUsageTelemetryConfigManager: Sendable {

    enum Outcome: Equatable {
        /// The block is in the file now (written or already there).
        case installed(port: Int)
        /// Calyx's block is not in the file now (removed or was not there).
        case removed
        case blocked(keys: [String])
        /// The directory of the settings file does not exist.
        case claudeNotFound
    }

    static func install(port: Int, headersFilePath: String, settingsPath: String? = nil) throws -> Outcome {
        let path = settingsPath ?? AgentToolPaths.claudeSettingsPath
        guard directoryExists(for: path) else { return .claudeNotFound }

        var result: ClaudeUsageTelemetryConfig.InstallResult = .unchanged
        // mode: nil keeps the user's mode; the block carries no secret.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: nil) { current in
            let edit = try ClaudeUsageTelemetryConfig.installing(port: port, headersFilePath: headersFilePath, into: current)
            result = edit.result
            return edit.document
        }
        switch result {
        case .written, .unchanged: return .installed(port: port)
        case .blocked(let keys): return .blocked(keys: keys)
        }
    }

    static func remove(settingsPath: String? = nil) throws -> Outcome {
        let path = settingsPath ?? AgentToolPaths.claudeSettingsPath
        guard directoryExists(for: path) else { return .claudeNotFound }

        try ConfigFileUtils.withExclusiveConfig(path: path, mode: nil) { current in
            try ClaudeUsageTelemetryConfig.removing(from: current).document
        }
        return .removed
    }

    static func state(settingsPath: String? = nil) throws -> ClaudeUsageTelemetryConfig.State {
        let resolved = try ConfigFileUtils.resolveConfigPath(settingsPath ?? AgentToolPaths.claudeSettingsPath)
        guard FileManager.default.fileExists(atPath: resolved) else { return .absent }
        return try ClaudeUsageTelemetryConfig.state(of: Data(contentsOf: URL(fileURLWithPath: resolved)))
    }

    /// Claude Code creates its configuration directory itself; when it is
    /// missing Claude Code is not set up for this user and nothing is created.
    private static func directoryExists(for path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let directory = (path as NSString).deletingLastPathComponent
        return FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
