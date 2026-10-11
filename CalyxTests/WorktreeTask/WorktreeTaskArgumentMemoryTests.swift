// WorktreeTaskArgumentMemoryTests.swift
// CalyxTests
//
// Pins WorktreeTaskArgumentMemory: the last "Arguments" text used per
// agent kind, stored in an injectable UserDefaults.

import Foundation
import Testing
@testable import Calyx

/// A fresh, empty UserDefaults suite; call `cleanup()` when done.
struct ScratchDefaults {
    let suiteName = "calyx.tests.worktreeTaskArgs.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

struct WorktreeTaskArgumentMemoryTests {

    @Test func test_unrememberedKind_isEmpty() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        for kind in WorktreeTaskAgentKind.allCases {
            #expect(memory.arguments(for: kind) == "", "\(kind.rawValue)")
        }
    }

    @Test func test_rememberRecall_isPerKind() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--model opus", for: .claudeCode)
        memory.remember("-m o3", for: .codex)

        #expect(memory.arguments(for: .claudeCode) == "--model opus")
        #expect(memory.arguments(for: .codex) == "-m o3")
        #expect(memory.arguments(for: .openCode) == "")
        #expect(memory.arguments(for: .hermes) == "")
    }

    @Test func test_remember_overwritesAndPersistsAcrossInstances() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        WorktreeTaskArgumentMemory(defaults: scratch.defaults).remember("--a", for: .pi)
        WorktreeTaskArgumentMemory(defaults: scratch.defaults).remember("--b 'x y'", for: .pi)
        #expect(WorktreeTaskArgumentMemory(defaults: scratch.defaults).arguments(for: .pi) == "--b 'x y'")
    }

    @Test func test_rememberEmpty_clears() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--a", for: .grok)
        memory.remember("", for: .grok)
        #expect(memory.arguments(for: .grok) == "")
    }

    // MARK: - Secrets (SecretRedactor's patterns)

    @Test func test_rememberOpenAIStyleKey_isNotStoredAndClearsEarlierText() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--model opus", for: .codex)
        memory.remember("--model o3 --key sk-abcdefghijklmnopqrstuvwxyz012345", for: .codex)
        #expect(memory.arguments(for: .codex) == "")
        #expect(scratch.defaults.object(forKey: "calyx.worktreeTask.arguments.codex") == nil)
    }

    @Test func test_rememberApiKeyFlagValue_isNotStoredAndClearsEarlierText() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--model opus", for: .claudeCode)
        memory.remember("--api-key hunter2", for: .claudeCode)
        #expect(memory.arguments(for: .claudeCode) == "")
        memory.remember("--model opus", for: .grok)
        memory.remember("--api-key=hunter2", for: .grok)
        #expect(memory.arguments(for: .grok) == "")
    }

    @Test func test_rememberWithoutSecret_isStored() {
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--model opus --effort high", for: .claudeCode)
        #expect(memory.arguments(for: .claudeCode) == "--model opus --effort high")
    }
}
