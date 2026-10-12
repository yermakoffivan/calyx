// WorktreeTaskArgumentParserTests.swift
// CalyxTests
//
// Pins WorktreeTaskArgumentParser: POSIX-shell-like word splitting of the
// New Worktree Task sheet's "Arguments" field, without running a shell
// and without any expansion.

import Testing
@testable import Calyx

struct WorktreeTaskArgumentParserTests {

    @Test func test_parse_simpleWords() throws {
        #expect(try WorktreeTaskArgumentParser.parse("--model opus --effort high")
            == ["--model", "opus", "--effort", "high"])
    }

    @Test func test_parse_multipleSpacesAndTabsSeparate() throws {
        #expect(try WorktreeTaskArgumentParser.parse("  a \t\t b   c\t") == ["a", "b", "c"])
    }

    @Test func test_parse_singleQuotesAreLiteral() throws {
        #expect(try WorktreeTaskArgumentParser.parse("'a b' '$HOME' 'x\\y' '\"q\"'")
            == ["a b", "$HOME", "x\\y", "\"q\""])
    }

    @Test func test_parse_doubleQuotesAllowQuoteAndBackslashEscapes() throws {
        // Input text:  "say \"hi\"" "c:\\dir" "a b"
        #expect(try WorktreeTaskArgumentParser.parse("\"say \\\"hi\\\"\" \"c:\\\\dir\" \"a b\"")
            == ["say \"hi\"", "c:\\dir", "a b"])
    }

    @Test func test_parse_backslashSpaceOutsideQuotesJoinsWord() throws {
        // Input text:  my\ file other
        #expect(try WorktreeTaskArgumentParser.parse("my\\ file other") == ["my file", "other"])
    }

    @Test func test_parse_backslashOutsideQuotesEscapesQuoteChar() throws {
        // Input text:  it\'s
        #expect(try WorktreeTaskArgumentParser.parse("it\\'s") == ["it's"])
    }

    @Test func test_parse_quotedPartJoinsAdjacentUnquotedPart() throws {
        #expect(try WorktreeTaskArgumentParser.parse("--flag=\"a b\" --x='c d'e")
            == ["--flag=a b", "--x=c de"])
    }

    @Test func test_parse_noExpansionOfDollarBackticksGlobsTilde() throws {
        #expect(try WorktreeTaskArgumentParser.parse("$(id) `id` * ~ $HOME ; |")
            == ["$(id)", "`id`", "*", "~", "$HOME", ";", "|"])
        #expect(try WorktreeTaskArgumentParser.parse("\"$HOME `id`\"") == ["$HOME `id`"])
    }

    @Test func test_parse_emptyQuotesYieldEmptyWord() throws {
        #expect(try WorktreeTaskArgumentParser.parse("a '' \"\" b") == ["a", "", "", "b"])
    }

    @Test func test_parse_emptyAndWhitespaceOnly_isEmpty() throws {
        #expect(try WorktreeTaskArgumentParser.parse("") == [])
        #expect(try WorktreeTaskArgumentParser.parse("   \t  ") == [])
    }

    @Test func test_parse_unterminatedSingleQuote_throws() {
        #expect(throws: WorktreeTaskArgumentParser.Error.unterminatedQuote) {
            try WorktreeTaskArgumentParser.parse("--x 'abc")
        }
    }

    @Test func test_parse_unterminatedDoubleQuote_throws() {
        #expect(throws: WorktreeTaskArgumentParser.Error.unterminatedQuote) {
            try WorktreeTaskArgumentParser.parse("--x \"abc \\\"")
        }
    }

    @Test func test_parse_danglingBackslash_throws() {
        #expect(throws: WorktreeTaskArgumentParser.Error.danglingEscape) {
            try WorktreeTaskArgumentParser.parse("--x abc\\")
        }
    }

    @Test func test_parse_unicodeWords() throws {
        #expect(try WorktreeTaskArgumentParser.parse("--name 日本語 '漢字 かな'")
            == ["--name", "日本語", "漢字 かな"])
    }
}
