// UsageLabel.swift
// Calyx
//
// The one rule every label arriving from the telemetry wire (model,
// effort, thread, agent, session id) passes before it is stored. Those
// labels are shown in the usage window and returned to agents by an MCP
// tool, so they are restricted to a small ASCII alphabet that cannot
// carry markup, quoting, whitespace or look-alike characters.

import Foundation

enum UsageLabel {
    static let maxScalars = 128

    /// Stored in place of a model label that is missing or invalid, so the
    /// tokens still count under a name of their own.
    static let unknownModel = "unknown"

    /// 1...maxScalars Unicode scalars, every one an ASCII letter, an ASCII
    /// digit, or one of  - _ . : @ / [ ]
    /// Counted in scalars rather than Characters so a combining mark can
    /// never hide inside a grapheme that looks like an allowed letter.
    static func isValid(_ string: String) -> Bool {
        var count = 0
        for scalar in string.unicodeScalars {
            count += 1
            guard count <= maxScalars, isAllowed(scalar) else { return false }
        }
        return count > 0
    }

    /// `string` when valid, otherwise nil (also for nil).
    static func validated(_ string: String?) -> String? {
        guard let string, isValid(string) else { return nil }
        return string
    }

    static func model(_ string: String?) -> String {
        validated(string) ?? unknownModel
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".", ":", "@", "/", "[", "]":
            return true
        default:
            return false
        }
    }
}
