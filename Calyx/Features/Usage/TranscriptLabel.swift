// TranscriptLabel.swift
// Calyx
//
// The one rule every string taken from a Claude Code transcript (or
// derived from one, such as a project root) passes before it is stored.
// Shared by every transcript reader and by the locator, so a session id,
// a cwd and a root mean the same thing wherever they come from.

import Foundation

enum TranscriptLabel {
    /// Longest working directory or project root, in Unicode scalars.
    static let cwdMaxScalars = 1_024
    /// Longest session id, message id, agent id or model, in Unicode scalars.
    static let identifierMaxScalars = 128

    /// Transcript-derived strings are later handed to agents over MCP, so
    /// each one is limited in length and character class before it is
    /// stored: surrounding whitespace is trimmed, and the trimmed value
    /// must be non-empty, at most `maxScalars` Unicode SCALARS, and free of
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
    /// bytes and the `﻿` escape alike (verified; `JSONDecoder` does
    /// not). So a single leading BOM is unobservable here ("\u{FEFF}main"
    /// is stored as "main"), while two leading BOMs leave one behind and
    /// are rejected. That is accepted: the removal cannot inject anything
    /// and no slice needs the stored label to equal the transcript's
    /// bytes. Pinned by
    /// `TranscriptLabelTests.test_label_singleLeadingBOM_isRemovedByJSONSerializationBeforeTheLabelRuleSeesIt`.
    static func label(_ value: Any?, maxScalars: Int) -> String? {
        guard let raw = value as? String else { return nil }
        var scalars = raw.unicodeScalars[...]
        while let first = scalars.first, isEdgeWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isEdgeWhitespace(last) { scalars.removeLast() }
        var scalarCount = 0
        for scalar in scalars {
            scalarCount += 1
            guard scalarCount <= maxScalars, !ControlCharacterDisplay.isEscapedCategory(scalar) else {
                return nil
            }
        }
        guard scalarCount > 0 else { return nil }
        return String(scalars)
    }

    /// Whether `path` is a cwd label exactly as it stands: `label` at
    /// `cwdMaxScalars` accepts it and trims nothing from it. The one
    /// definition of what a stored path may be, for a transcript's `cwd`
    /// and for a root resolved from it alike.
    static func isCWD(_ path: String) -> Bool {
        isVerbatim(path, label(path, maxScalars: cwdMaxScalars))
    }

    /// Whether `identifier` is an identifier label exactly as it stands:
    /// the rule a transcript's `sessionId`, message id and agent id pass
    /// (`label` at `identifierMaxScalars`), with nothing trimmed. For an
    /// identifier that reaches the store from somewhere other than a
    /// transcript line.
    static func isIdentifier(_ identifier: String) -> Bool {
        isVerbatim(identifier, label(identifier, maxScalars: identifierMaxScalars))
    }

    /// Whether `label` (what the label rule made of `raw`) is `raw`
    /// itself. Compared scalar by scalar, because `String`'s `==` is
    /// canonical equivalence and "verbatim" means the same scalars.
    private static func isVerbatim(_ raw: String, _ label: String?) -> Bool {
        guard let label else { return false }
        return label.unicodeScalars.elementsEqual(raw.unicodeScalars)
    }

    /// Whitespace that is trimmed from a label's edges: a space separator
    /// (general category Zs) or a tab. Defined from the Unicode property,
    /// not from `CharacterSet`, so the set is exactly what it says.
    private static func isEdgeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .spaceSeparator || scalar == "\t"
    }
}
