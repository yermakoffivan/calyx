// SecureInputE2ETests.swift
// CalyxUITests
//
// A password prompt (`stty -echo`) inside a persistent-session pane must
// surface the secure-input overlay ("calyx.secureInput.overlay") and hide
// it again once echo is restored. The daemon detects the prompt and
// notifies Calyx via the secure-input datagram channel.
// Launch/isolation pattern mirrors SessionPersistenceE2ETests.

import XCTest

final class SecureInputE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    override func setUp() async throws {
        continueAfterFailure = false
        // Short /tmp root: sun_path limit (see SessionPersistenceE2ETests).
        homeDir = "/tmp/cxe2e-\(UUID().uuidString.prefix(8))-h"
        sessionDir = "/tmp/cxe2e-\(UUID().uuidString.prefix(8))-s"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        launchApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let homeDir { try? FileManager.default.removeItem(atPath: homeDir) }
        if let sessionDir { try? FileManager.default.removeItem(atPath: sessionDir) }
        try await super.tearDown()
    }

    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"] ?? ""
        terminateStaleAppUnderTestInstances()
        app.launch()
    }

    /// Literal id: AccessibilityID for SecureInputOverlay.
    private var overlay: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "calyx.secureInput.overlay").firstMatch
    }

    func test_passwordPromptInPersistentPane_showsSecureInputOverlay() {
        createNewTabViaMenu()
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear.")

        let ledger = DaemonLedgerReader(homeDir: homeDir)
        let running = ledger.poll(
            timeoutAttempts: 15,
            sleepInterval: 2,
            transform: { $0.contains(where: ledger.isRunning) },
            until: { $0 }
        )
        XCTAssertTrue(running.value, "No running persistent session. Ledger: \(running.raw)")
        XCTAssertFalse(overlay.exists, "overlay visible before the password prompt")

        typeIntoPane("stty -echo; sleep 3; stty echo\n")

        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "secure-input overlay did not appear for stty -echo in a persistent pane")

        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: overlay)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed,
                       "secure-input overlay did not disappear after stty echo")
    }
}
