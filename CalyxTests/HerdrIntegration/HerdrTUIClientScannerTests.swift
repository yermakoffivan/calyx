//
//  HerdrTUIClientScannerTests.swift
//  CalyxTests
//
//  TDD Red (feature: herdr TUI client detection for the session
//  browser's "Show"/focus-pane integration). `HerdrTUIClient`,
//  `HerdrTUIClientScanning`, and `HerdrTUIClientScanner` do not exist
//  yet anywhere in the production target -- every test below fails to
//  COMPILE (expected Red: unresolved identifiers `HerdrTUIClient`,
//  `HerdrTUIClientScanner`), not merely to run-and-fail. Only
//  `HerdrTUIClientScanner.classify(argv:env:hasControllingTerminal:
//  configRootDirectory:)` is exercised here -- it is a pure function of
//  its four arguments, so it is unit-testable without ever touching a
//  real process table (`scan()` itself, built on `proc_listallpids` +
//  `KERN_PROCARGS2`, is deliberately NOT unit-tested -- see the feature
//  spec).
//

import XCTest
@testable import Calyx

final class HerdrTUIClientScannerTests: XCTestCase {

    private let configRoot = "/cfg"
    private let surfaceUUID = UUID(uuidString: "8C6B3F2A-1234-4E56-9ABC-1234567890AB")!

    // MARK: - Default socket, argv == [] (bare "herdr" attach), .surfaceID hint

    func test_classify_bareHerdr_ttyWithSurfaceIDEnv_returnsDefaultSocketAndSurfaceIDHint() {
        let client = HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        )

        XCTAssertEqual(client?.socketPath, "/cfg/herdr.sock")
        XCTAssertEqual(client?.surfaceHint, .surfaceID(surfaceUUID))
    }

    // MARK: - "--session NAME" and "session attach NAME" both resolve to the named session's socket

    func test_classify_dashDashSessionForm_returnsNamedSessionSocket() {
        let client = HerdrTUIClientScanner.classify(
            argv: ["herdr", "--session", "work"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        )

        XCTAssertEqual(client?.socketPath, "/cfg/sessions/work/herdr.sock")
    }

    func test_classify_sessionAttachForm_withFullExecutablePath_returnsSameNamedSessionSocket() {
        let client = HerdrTUIClientScanner.classify(
            argv: ["/opt/homebrew/bin/herdr", "session", "attach", "work"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        )

        XCTAssertEqual(client?.socketPath, "/cfg/sessions/work/herdr.sock")
    }

    // MARK: - HERDR_SOCKET_PATH env override wins over the argv-derived path

    func test_classify_herdrSocketPathEnvOverride_winsOverArgvDerivedPath() {
        let client = HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: [
                "HERDR_SOCKET_PATH": "/x/herdr.sock",
                "CALYX_SURFACE_ID": surfaceUUID.uuidString,
            ],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        )

        XCTAssertEqual(client?.socketPath, "/x/herdr.sock")
    }

    // MARK: - CALYX_SESSION_ID wins over CALYX_SURFACE_ID when both are set

    func test_classify_bothCalyxEnvVarsSet_sessionIDWins() {
        let client = HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: [
                "CALYX_SESSION_ID": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                "CALYX_SURFACE_ID": surfaceUUID.uuidString,
            ],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        )

        XCTAssertEqual(client?.surfaceHint, .sessionID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
    }

    // MARK: - nil cases

    func test_classify_serverSubcommand_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr", "server"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_terminalAttachSubcommand_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["/opt/homebrew/bin/herdr", "terminal", "attach", "w1:p1"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_statusSubcommand_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr", "status"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_apiSnapshotSubcommand_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr", "api", "snapshot"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_remoteFlag_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr", "--remote", "host"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_noControllingTerminal_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: ["CALYX_SURFACE_ID": surfaceUUID.uuidString],
            hasControllingTerminal: false,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_noCalyxEnvAtAll_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: [:],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }

    func test_classify_surfaceIDEnvNotAValidUUID_isNil() {
        XCTAssertNil(HerdrTUIClientScanner.classify(
            argv: ["herdr"],
            env: ["CALYX_SURFACE_ID": "not-a-uuid"],
            hasControllingTerminal: true,
            configRootDirectory: configRoot
        ))
    }
}
