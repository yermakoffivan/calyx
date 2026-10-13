// CalyxEndpointFileFallbackConsistencyTests.swift
// CalyxTests
//
// Ties the seven generated bodies that read agent-endpoint.json --
// AgentHookScript, ApprovalHookScript, IPCWakeHookScript,
// OpenCodePluginManager,
// PiExtensionManager, and ShellIntegrationInstaller's zsh (calyxZshBody)
// and fish (fishIntegrationBody) bodies -- to one shared source of
// truth for their literal CALYX_ENDPOINT_FILE fallback path:
// AgentEndpointFile.shellFallbackPath /
// .javascriptFallbackPathExpression, both built from the same
// AgentEndpointFile.homeRelativePath literal. A per-generator test file
// already pins its own body's exact fallback expression; this file
// exists so that if a future edit changes one generator's literal
// without going through AgentEndpointFile, the resulting drift between
// generators is caught here rather than only visible as seven separately
// worded (and now silently disagreeing) fallback paths.
//
// Coverage: every one of the seven bodies contains CALYX_ENDPOINT_FILE,
// and every one of the five shell-syntax bodies contains the exact
// same AgentEndpointFile.shellFallbackPath literal
// ("$HOME/Library/Application Support/Calyx/agent-endpoint.json"),
// while the two JavaScript bodies contain the exact same
// AgentEndpointFile.javascriptFallbackPathExpression literal.

import XCTest
@testable import Calyx

final class CalyxEndpointFileFallbackConsistencyTests: XCTestCase {

    // MARK: - Every generated body references CALYX_ENDPOINT_FILE

    func test_everyGeneratedBody_referencesCalyxEndpointFile() {
        let bodies: [(name: String, body: String)] = [
            ("AgentHookScript", AgentHookScript.scriptBody),
            ("ApprovalHookScript", ApprovalHookScript.scriptBody),
            ("IPCWakeHookScript", IPCWakeHookScript.scriptBody),
            ("OpenCodePluginManager", OpenCodePluginManager.scriptBody),
            ("PiExtensionManager", PiExtensionManager.scriptBody),
            ("ShellIntegrationInstaller.calyxZshBody", ShellIntegrationInstaller.calyxZshBody),
            ("ShellIntegrationInstaller.fishIntegrationBody", ShellIntegrationInstaller.fishIntegrationBody),
        ]

        for (name, body) in bodies {
            XCTAssertTrue(body.contains("CALYX_ENDPOINT_FILE"),
                         "\(name) must reference CALYX_ENDPOINT_FILE")
        }
    }

    // MARK: - Every shell-syntax body agrees on the same literal fallback path

    func test_everyShellBody_carriesTheSameLiteralFallbackPath() {
        let shellBodies: [(name: String, body: String)] = [
            ("AgentHookScript", AgentHookScript.scriptBody),
            ("ApprovalHookScript", ApprovalHookScript.scriptBody),
            ("IPCWakeHookScript", IPCWakeHookScript.scriptBody),
            ("ShellIntegrationInstaller.calyxZshBody", ShellIntegrationInstaller.calyxZshBody),
            ("ShellIntegrationInstaller.fishIntegrationBody", ShellIntegrationInstaller.fishIntegrationBody),
        ]

        for (name, body) in shellBodies {
            XCTAssertTrue(body.contains(AgentEndpointFile.shellFallbackPath),
                         "\(name) must carry AgentEndpointFile.shellFallbackPath verbatim " +
                         "(\"\(AgentEndpointFile.shellFallbackPath)\"), not its own copy of the literal")
        }
    }

    // MARK: - Every JavaScript body agrees on the same literal fallback expression

    func test_everyJavaScriptBody_carriesTheSameLiteralFallbackExpression() {
        let jsBodies: [(name: String, body: String)] = [
            ("OpenCodePluginManager", OpenCodePluginManager.scriptBody),
            ("PiExtensionManager", PiExtensionManager.scriptBody),
        ]

        for (name, body) in jsBodies {
            XCTAssertTrue(body.contains(AgentEndpointFile.javascriptFallbackPathExpression),
                         "\(name) must carry AgentEndpointFile.javascriptFallbackPathExpression " +
                         "verbatim (\"\(AgentEndpointFile.javascriptFallbackPathExpression)\"), not " +
                         "its own copy of the literal")
        }
    }
}
