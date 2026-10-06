// UsageTelemetryStatus.swift
// Calyx
//
// What the Usage Tracking row says about reception (R4b, section D):
// a pure resolver from the row's inputs to a status, and the one line
// shown for it.

import Foundation

struct UsageTelemetryStatusInput: Equatable {
    var trackingOn: Bool
    var ipcEnabled: Bool
    var serverRunning: Bool
    var config: UsageTelemetryConfigStatus
    var lastAcceptedAt: Date?
    var lastRejection: UsageIngestMonitor.Rejection?
}

enum UsageTelemetryStatus: Equatable {
    case off
    case settingUp
    case notReceiving(String)
    case waiting
    case receiving(lastAt: Date)
    case refused(String, at: Date)
}

enum UsageTelemetryStatusResolver {

    /// First match wins (contract, section D).
    static func resolve(_ input: UsageTelemetryStatusInput) -> UsageTelemetryStatus {
        guard input.trackingOn else { return .off }
        guard input.ipcEnabled else { return .notReceiving("AI Agent IPC is off.") }
        guard input.serverRunning else { return .notReceiving("The IPC server is not running.") }
        switch input.config {
        case .blocked(let keys):
            return .notReceiving(
                "Claude Code's settings already contain telemetry settings (\(keys.joined(separator: ", "))). "
                    + "Calyx did not change them.")
        case .claudeNotFound:
            return .notReceiving("Claude Code is not set up on this Mac (~/.claude was not found).")
        case .failed(let description):
            return .notReceiving("Claude Code's settings could not be updated: \(description)")
        case .unknown, .removed:
            return .settingUp
        case .installed:
            if let rejection = input.lastRejection {
                // Strictly later: at the same instant the accepted export wins.
                let isLater = input.lastAcceptedAt.map { rejection.at > $0 } ?? true
                if isLater {
                    return .refused(refusalSentence(for: rejection.reason), at: rejection.at)
                }
            }
            if let accepted = input.lastAcceptedAt {
                return .receiving(lastAt: accepted)
            }
            return .waiting
        }
    }

    /// One line for the Settings row and the Usage window; empty for `.off`.
    static func text(for status: UsageTelemetryStatus, time: (Date) -> String) -> String {
        switch status {
        case .off:
            return ""
        case .settingUp:
            return "Setting up\u{2026}"
        case .notReceiving(let reason):
            return "Not receiving: " + reason
        case .waiting:
            return "Waiting for Claude Code. Sessions that were already running when tracking was turned on "
                + "report after they are restarted."
        case .receiving(let lastAt):
            return "Receiving. Last export at \(time(lastAt))."
        case .refused(let sentence, let at):
            return "The last export (\(time(at))) was refused: " + sentence
        }
    }

    /// The one rendering of a time in the status text (Settings row, Usage window).
    static func defaultTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static func refusalSentence(for reason: UsageIngestMonitor.ExporterRejection) -> String {
        switch reason {
        case .unauthorized:
            return "its token was not accepted. Restart that Claude Code session if this continues."
        case .tooLarge:
            return "it was larger than 16 MB. Restart that Claude Code session."
        case .undecodable:
            return "it could not be read."
        case .unavailable:
            return "the usage database could not be written."
        }
    }
}
