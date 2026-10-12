// WorktreeTaskArgumentParser.swift
// Calyx
//
// Splits the New Worktree Task sheet's "Arguments" text into argv words,
// POSIX-shell-like but without running a shell.

import Foundation

/// Word splitting for the "Arguments" field. Grammar:
///
/// - Unquoted spaces, tabs and newlines separate words; runs of them count
///   as one separator, and leading/trailing ones are ignored.
/// - `'...'`: every character up to the next `'` is literal.
/// - `"..."`: literal except `\"` → `"` and `\\` → `\`; any other `\x`
///   is kept as the two characters `\x`.
/// - `\x` outside quotes: `x` literally (e.g. `\ ` joins a word, `\'`).
/// - Quoted and unquoted parts with no separator between them form one
///   word (`--flag="a b"` → `--flag=a b`); `''` and `""` give an empty word.
/// - No expansion of any kind: `$`, backticks, `~`, globs, `;`, `|` are
///   ordinary characters.
///
/// Empty or whitespace-only text gives `[]`. An unclosed quote throws
/// `.unterminatedQuote`; a trailing unquoted `\` throws `.danglingEscape`.
enum WorktreeTaskArgumentParser {

    enum Error: Swift.Error, Equatable {
        case unterminatedQuote
        case danglingEscape
    }

    private enum State {
        case unquoted
        case singleQuoted
        case doubleQuoted
    }

    static func parse(_ text: String) throws(Error) -> [String] {
        var words: [String] = []
        var current = ""
        /// True once the current word has begun (so `''` yields "").
        var inWord = false
        var state = State.unquoted
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            switch state {
            case .unquoted:
                switch character {
                case " ", "\t", "\n", "\r", "\r\n":
                    if inWord {
                        words.append(current)
                        current = ""
                        inWord = false
                    }
                case "'":
                    state = .singleQuoted
                    inWord = true
                case "\"":
                    state = .doubleQuoted
                    inWord = true
                case "\\":
                    guard let escaped = iterator.next() else { throw Error.danglingEscape }
                    current.append(escaped)
                    inWord = true
                default:
                    current.append(character)
                    inWord = true
                }
            case .singleQuoted:
                if character == "'" {
                    state = .unquoted
                } else {
                    current.append(character)
                }
            case .doubleQuoted:
                switch character {
                case "\"":
                    state = .unquoted
                case "\\":
                    guard let next = iterator.next() else { throw Error.unterminatedQuote }
                    if next == "\"" || next == "\\" {
                        current.append(next)
                    } else {
                        current.append(character)
                        current.append(next)
                    }
                default:
                    current.append(character)
                }
            }
        }
        guard state == .unquoted else { throw Error.unterminatedQuote }
        if inWord { words.append(current) }
        return words
    }
}
