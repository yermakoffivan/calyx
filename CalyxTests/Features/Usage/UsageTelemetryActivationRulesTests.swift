//
//  UsageTelemetryActivationRulesTests.swift
//  CalyxTests
//
//  R4b section A: when Calyx's telemetry block should be in Claude
//  Code's settings file. The full truth table (16 combinations of the
//  four inputs, the server port being nil or a port), written out by
//  hand from the contract's four rules, first match wins:
//  1. agent files may not be touched -> untouched;
//  2. tracking off or the IPC setting off -> removed;
//  3. both on, server on a port -> installed(port);
//  4. both on, server not running -> untouched.
//

import XCTest
@testable import Calyx

final class UsageTelemetryActivationRulesTests: XCTestCase {

    private struct Row {
        let mayTouch: Bool
        let tracking: Bool
        let ipc: Bool
        let port: Int?
        let expected: UsageTelemetryTarget
    }

    private let p = 41830

    func test_fullTruthTable() {
        let rows: [Row] = [
            // Rule 1: agent files may not be touched (a UI-test launch without its own root).
            Row(mayTouch: false, tracking: false, ipc: false, port: nil, expected: .untouched),
            Row(mayTouch: false, tracking: false, ipc: false, port: p, expected: .untouched),
            Row(mayTouch: false, tracking: false, ipc: true, port: nil, expected: .untouched),
            Row(mayTouch: false, tracking: false, ipc: true, port: p, expected: .untouched),
            Row(mayTouch: false, tracking: true, ipc: false, port: nil, expected: .untouched),
            Row(mayTouch: false, tracking: true, ipc: false, port: p, expected: .untouched),
            Row(mayTouch: false, tracking: true, ipc: true, port: nil, expected: .untouched),
            Row(mayTouch: false, tracking: true, ipc: true, port: p, expected: .untouched),
            // Rule 2: tracking off, or IPC off.
            Row(mayTouch: true, tracking: false, ipc: false, port: nil, expected: .removed),
            Row(mayTouch: true, tracking: false, ipc: false, port: p, expected: .removed),
            Row(mayTouch: true, tracking: false, ipc: true, port: nil, expected: .removed),
            Row(mayTouch: true, tracking: false, ipc: true, port: p, expected: .removed),
            Row(mayTouch: true, tracking: true, ipc: false, port: nil, expected: .removed),
            Row(mayTouch: true, tracking: true, ipc: false, port: p, expected: .removed),
            // Rule 4: both on, the server is not running.
            Row(mayTouch: true, tracking: true, ipc: true, port: nil, expected: .untouched),
            // Rule 3: both on, the server runs on p.
            Row(mayTouch: true, tracking: true, ipc: true, port: p, expected: .installed(port: 41830)),
        ]
        XCTAssertEqual(rows.count, 16)

        for row in rows {
            XCTAssertEqual(
                UsageTelemetryActivationRules.target(
                    trackingOn: row.tracking, ipcEnabled: row.ipc, serverPort: row.port,
                    mayTouchAgentFiles: row.mayTouch),
                row.expected,
                "mayTouch \(row.mayTouch), tracking \(row.tracking), ipc \(row.ipc), port \(String(describing: row.port))")
        }
    }

    // The row a tracking-first rule gets wrong: everything off AND agent
    // files may not be touched is untouched, never removed.
    func test_mayNotTouch_winsOverEverythingOff() {
        XCTAssertEqual(
            UsageTelemetryActivationRules.target(
                trackingOn: false, ipcEnabled: false, serverPort: nil, mayTouchAgentFiles: false),
            .untouched)
    }

    // A failed or not yet started server never removes the block.
    func test_bothOn_serverNotRunning_isUntouched_notRemoved() {
        XCTAssertEqual(
            UsageTelemetryActivationRules.target(
                trackingOn: true, ipcEnabled: true, serverPort: nil, mayTouchAgentFiles: true),
            .untouched)
    }

    // The port is the one the server runs on, not a constant.
    func test_installed_carriesTheServersPort() {
        XCTAssertEqual(
            UsageTelemetryActivationRules.target(
                trackingOn: true, ipcEnabled: true, serverPort: 1, mayTouchAgentFiles: true),
            .installed(port: 1))
        XCTAssertEqual(
            UsageTelemetryActivationRules.target(
                trackingOn: true, ipcEnabled: true, serverPort: 65535, mayTouchAgentFiles: true),
            .installed(port: 65535))
    }
}
