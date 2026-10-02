// UsageActivity.swift
// Calyx
//
// What an accepted Claude Code hook event tells the usage ledger: which
// session did something, and where that session says its transcript is.

import Foundation

struct UsageActivity: Sendable, Equatable {
    let sessionID: String
    /// The hook payload's `transcript_path`, verbatim and unvalidated
    /// (possibly empty); `ClaudeTranscriptLocator` decides whether it is
    /// read.
    let transcriptPath: String
    let hookEventName: String
}
