//
//  LSPSettingsBugSpecTests.swift
//  CalyxTests
//
//  Wave 1 RETROFIT — independent regression tests derived purely from the
//  bug specification for `LSPSettings.confirmationMode(confirmationHandler:)`.
//
//  BUG SPEC:
//    When `autoInstallEnabled = false`, `confirmationMode(...)` returns
//    `.prompt(handler: { _ in false })` — a handler that refuses every
//    step. It is only a fail-safe: `LSPInstaller.install(...)` checks
//    `autoInstallEnabled` itself first and reports the explicit
//    "auto-install disabled" failure instead of a misleading
//    `"user declined: <step>"` (covered by LSPInstallerBugSpecTests,
//    Bug 4). These tests pin the three-outcome mapping and that the
//    disabled branch takes priority over `requireInstallConfirmation`.
//
//  These tests are INDEPENDENT of LSPSettingsTests.swift — different test
//  class, derived purely from the bug spec above.
//

import XCTest
@testable import Calyx

final class LSPSettingsBugSpecTests: XCTestCase {

    // MARK: - Rejecting .prompt when auto-install is off

    func test_confirmationMode_returnsRejectingPrompt_whenAutoInstallEnabledFalse() async {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = false

        let mode = LSPSettings.confirmationMode(confirmationHandler: { _ in true })

        switch mode {
        case .prompt(let handler):
            let decision = await handler("any-step")
            XCTAssertFalse(decision, "Disabled auto-install must yield a rejecting handler, not the caller's")
        case .silent:
            XCTFail("Expected rejecting .prompt but got .silent")
        }
    }

    // MARK: - Caller's .prompt when auto-install is on AND confirmation required

    func test_confirmationMode_returnsPrompt_whenAutoInstallEnabledAndConfirmationRequired() async {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = true

        let mode = LSPSettings.confirmationMode(confirmationHandler: { _ in true })

        switch mode {
        case .prompt(let handler):
            let decision = await handler("any-step")
            XCTAssertTrue(decision, "Expected the caller-supplied (approving) handler to be forwarded")
        case .silent:
            XCTFail("Expected .prompt but got .silent")
        }
    }

    // MARK: - .silent when auto-install on AND confirmation NOT required

    func test_confirmationMode_returnsSilent_whenAutoInstallEnabledAndConfirmationNotRequired() {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = false

        let mode = LSPSettings.confirmationMode(confirmationHandler: { _ in true })

        switch mode {
        case .silent:
            // Expected.
            break
        case .prompt:
            XCTFail("Expected .silent but got .prompt")
        }
    }

    // MARK: - Disabled wins over .silent even when confirmation not required

    func test_confirmationMode_disabledTakesPriorityOver_requireConfirmation() async {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = false
        LSPSettings.requireInstallConfirmation = false

        let mode = LSPSettings.confirmationMode(confirmationHandler: { _ in true })

        switch mode {
        case .prompt(let handler):
            // Expected — auto-install off must short-circuit before the
            // requireInstallConfirmation flag is considered.
            let decision = await handler("any-step")
            XCTAssertFalse(decision, "Disabled auto-install must yield a rejecting handler")
        case .silent:
            XCTFail("Expected rejecting .prompt but got .silent — disabled must take priority")
        }
    }
}
