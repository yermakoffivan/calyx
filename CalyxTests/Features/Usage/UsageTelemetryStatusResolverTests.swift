//
//  UsageTelemetryStatusResolverTests.swift
//  CalyxTests
//
//  R4b section D: what the Usage Tracking row says about reception.
//  Every rule in order (an input matching two rules gets the first),
//  rejection versus accepted export at equal times (a rejection must be
//  strictly later to win), and every text exactly. Times are rendered
//  by a fixed closure, never a real formatter.
//

import XCTest
@testable import Calyx

final class UsageTelemetryStatusResolverTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_000_060)

    /// Everything on, config installed, nothing received yet.
    private func input(
        trackingOn: Bool = true, ipcEnabled: Bool = true, serverRunning: Bool = true,
        config: UsageTelemetryConfigStatus = .installed(port: 41830),
        lastAcceptedAt: Date? = nil, lastRejection: UsageIngestMonitor.Rejection? = nil
    ) -> UsageTelemetryStatusInput {
        UsageTelemetryStatusInput(
            trackingOn: trackingOn, ipcEnabled: ipcEnabled, serverRunning: serverRunning, config: config,
            lastAcceptedAt: lastAcceptedAt, lastRejection: lastRejection)
    }

    private func resolve(_ input: UsageTelemetryStatusInput) -> UsageTelemetryStatus {
        UsageTelemetryStatusResolver.resolve(input)
    }

    private func text(_ status: UsageTelemetryStatus) -> String {
        UsageTelemetryStatusResolver.text(for: status, time: { [t0, t1] date in
            date == t0 ? "T0" : (date == t1 ? "T1" : "UNEXPECTED")
        })
    }

    private let ipcOff = "AI Agent IPC is off."
    private let serverOff = "The IPC server is not running."
    private let claudeMissing = "Claude Code is not set up on this Mac (~/.claude was not found)."

    // MARK: - Rule order

    func test_rule1_trackingOff_isOff_whateverElseHolds() {
        XCTAssertEqual(
            resolve(input(trackingOn: false, ipcEnabled: false, serverRunning: false, config: .failed("x"),
                          lastAcceptedAt: t0, lastRejection: .init(reason: .unauthorized, at: t1))),
            .off)
        XCTAssertEqual(resolve(input(trackingOn: false)), .off)
    }

    func test_rule2_ipcOff_winsOverServerAndConfig() {
        XCTAssertEqual(
            resolve(input(ipcEnabled: false, serverRunning: false, config: .blocked(keys: ["otelHeadersHelper"]))),
            .notReceiving(ipcOff))
        XCTAssertEqual(resolve(input(ipcEnabled: false)), .notReceiving(ipcOff))
    }

    func test_rule3_serverNotRunning_winsOverConfig() {
        XCTAssertEqual(resolve(input(serverRunning: false, config: .claudeNotFound)), .notReceiving(serverOff))
        XCTAssertEqual(resolve(input(serverRunning: false)), .notReceiving(serverOff))
    }

    func test_rule4_blocked_namesTheKeys_joinedByCommaSpace() {
        XCTAssertEqual(
            resolve(input(config: .blocked(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))),
            .notReceiving(
                "Claude Code's settings already contain telemetry settings (OTEL_EXPORTER_OTLP_METRICS_ENDPOINT). "
                    + "Calyx did not change them."))
        XCTAssertEqual(
            resolve(input(config: .blocked(keys: ["CLAUDE_CODE_ENABLE_TELEMETRY", "otelHeadersHelper"]))),
            .notReceiving(
                "Claude Code's settings already contain telemetry settings (CLAUDE_CODE_ENABLE_TELEMETRY, "
                    + "otelHeadersHelper). Calyx did not change them."))
    }

    // A blocked config wins over exports that were received (rule 4 before 8).
    func test_rule4_blocked_winsOverAReceivedExport() {
        XCTAssertEqual(
            resolve(input(config: .blocked(keys: ["otelHeadersHelper"]), lastAcceptedAt: t0)),
            .notReceiving(
                "Claude Code's settings already contain telemetry settings (otelHeadersHelper). Calyx did not change them."))
    }

    func test_rule5_claudeNotFound() {
        XCTAssertEqual(resolve(input(config: .claudeNotFound, lastAcceptedAt: t0)), .notReceiving(claudeMissing))
    }

    func test_rule6_failed_carriesTheDescription() {
        XCTAssertEqual(
            resolve(input(config: .failed("disk full"))),
            .notReceiving("Claude Code's settings could not be updated: disk full"))
    }

    func test_rule7_unknownAndRemoved_areSettingUp_evenWithReceivedExports() {
        XCTAssertEqual(resolve(input(config: .unknown)), .settingUp)
        XCTAssertEqual(resolve(input(config: .removed)), .settingUp)
        XCTAssertEqual(
            resolve(input(config: .unknown, lastAcceptedAt: t0, lastRejection: .init(reason: .tooLarge, at: t1))),
            .settingUp)
    }

    // MARK: - Rule 8: installed

    func test_rule8_nothingReceived_isWaiting() {
        XCTAssertEqual(resolve(input()), .waiting)
    }

    func test_rule8_acceptedOnly_isReceiving() {
        XCTAssertEqual(resolve(input(lastAcceptedAt: t0)), .receiving(lastAt: t0))
    }

    func test_rule8_rejectionLaterThanAccepted_isRefused() {
        XCTAssertEqual(
            resolve(input(lastAcceptedAt: t0, lastRejection: .init(reason: .unauthorized, at: t1))),
            .refused("its token was not accepted. Restart that Claude Code session if this continues.", at: t1))
    }

    func test_rule8_rejectionWithNothingAccepted_isRefused() {
        XCTAssertEqual(
            resolve(input(lastRejection: .init(reason: .undecodable, at: t0))),
            .refused("it could not be read.", at: t0))
    }

    func test_rule8_rejectionEarlierThanAccepted_isReceiving() {
        XCTAssertEqual(
            resolve(input(lastAcceptedAt: t1, lastRejection: .init(reason: .unauthorized, at: t0))),
            .receiving(lastAt: t1))
    }

    // "Later than" is strict: at the same instant the accepted export wins.
    func test_rule8_rejectionAtTheSameTimeAsAccepted_isReceiving() {
        XCTAssertEqual(
            resolve(input(lastAcceptedAt: t0, lastRejection: .init(reason: .unauthorized, at: t0))),
            .receiving(lastAt: t0))
    }

    func test_rule8_eachRefusalReason_hasItsSentence() {
        let expected: [(UsageIngestMonitor.ExporterRejection, String)] = [
            (.unauthorized, "its token was not accepted. Restart that Claude Code session if this continues."),
            (.tooLarge, "it was larger than 16 MB. Restart that Claude Code session."),
            (.undecodable, "it could not be read."),
            (.unavailable, "the usage database could not be written."),
        ]
        for (reason, sentence) in expected {
            XCTAssertEqual(
                resolve(input(lastRejection: .init(reason: reason, at: t1))), .refused(sentence, at: t1), "\(reason)")
        }
    }

    // MARK: - Texts

    func test_text_off_isEmpty() {
        XCTAssertEqual(text(.off), "")
    }

    func test_text_settingUp_usesTheEllipsisCharacter() {
        XCTAssertEqual(text(.settingUp), "Setting up\u{2026}")
        XCTAssertEqual(text(.settingUp).count, 11)
    }

    func test_text_notReceiving_isPrefixed() {
        XCTAssertEqual(text(.notReceiving("AI Agent IPC is off.")), "Not receiving: AI Agent IPC is off.")
    }

    func test_text_waiting() {
        XCTAssertEqual(
            text(.waiting),
            "Waiting for Claude Code. Sessions that were already running when tracking was turned on report after "
                + "they are restarted.")
    }

    func test_text_receiving_rendersItsOwnTime() {
        XCTAssertEqual(text(.receiving(lastAt: t1)), "Receiving. Last export at T1.")
        XCTAssertEqual(text(.receiving(lastAt: t0)), "Receiving. Last export at T0.")
    }

    func test_text_refused_rendersItsOwnTime() {
        XCTAssertEqual(
            text(.refused("it could not be read.", at: t0)), "The last export (T0) was refused: it could not be read.")
    }

    // End to end through both functions, from the row's inputs to its line.
    func test_resolveThenText_forTheMostCommonStates() {
        XCTAssertEqual(text(resolve(input(trackingOn: false))), "")
        XCTAssertEqual(text(resolve(input(ipcEnabled: false))), "Not receiving: AI Agent IPC is off.")
        XCTAssertEqual(
            text(resolve(input(config: .claudeNotFound))),
            "Not receiving: Claude Code is not set up on this Mac (~/.claude was not found).")
        XCTAssertEqual(
            text(resolve(input(lastAcceptedAt: t0, lastRejection: .init(reason: .tooLarge, at: t1)))),
            "The last export (T1) was refused: it was larger than 16 MB. Restart that Claude Code session.")
    }

    // MARK: - defaultTime

    func test_defaultTime_isAbbreviatedDateWithStandardTime() {
        XCTAssertEqual(
            UsageTelemetryStatusResolver.defaultTime(t0), t0.formatted(date: .abbreviated, time: .standard))
    }
}
