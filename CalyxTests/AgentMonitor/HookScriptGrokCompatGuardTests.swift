//
//  HookScriptGrokCompatGuardTests.swift
//  CalyxTests
//
//  Coverage for the Grok compatibility guard every Calyx hook script
//  carries: calyx-agent-hook, calyx-approval-hook and calyx-ipc-wake-hook.
//
//  Grok scans `~/.claude/settings.json` for hooks by default
//  (`[compat.claude] hooks = true`), so Calyx's Claude Code entries --
//  which invoke the scripts with no kind argument and therefore resolve
//  to claude-code -- also fire inside a Grok session. Left alone, a Grok
//  pane would post state events attributed to Claude Code, its
//  approval hook would print a Claude-shaped
//  `hookSpecificOutput.decision` body that Grok's own decision vocabulary
//  (`{"decision":"allow"}`) does not recognize, and its wake hook would
//  hold a `/ipc-wake` long-poll open for a pane that is not running
//  Claude Code.
//
//  The guard uses `GROK_HOOK_EVENT`, a reserved variable Grok's hook
//  runner injects into every hook process and strips from any
//  user-supplied `env` map: when the resolved kind is claude-code and
//  that variable is set and non-empty, the script exits 0 without
//  posting. Calyx's own Grok entries pass an explicit `grok` argument,
//  so they are unaffected -- which is what makes the guard safe to key
//  on a variable that is, by construction, always set for them too.
//  The user's own `[compat.*]` settings are never touched.
//
//  Every assertion here is about curl's invocation count, driven through
//  the shared FakeCurlScriptFixture harness (a real /bin/sh child
//  process with a fake curl ahead of the real one on PATH), following
//  AgentHookScriptHerdrGuardTests' precedent: each script either runs
//  curl in its own foreground or backgrounds it and `wait`s for it, so
//  waitUntilExit already settles whether it ran. The fake curl prints
//  nothing, which calyx-ipc-wake-hook reads as "no wake": it exits 0
//  after its one curl run, like the other two.
//

import XCTest
@testable import Calyx

final class HookScriptGrokCompatGuardTests: XCTestCase {

    // MARK: - Properties

    private var fixtures: [FakeCurlScriptFixture] = []

    // MARK: - Lifecycle

    override func tearDown() {
        for fixture in fixtures {
            try? FileManager.default.removeItem(atPath: fixture.rootDir)
        }
        fixtures = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// A script under test, named for assertion messages.
    private struct HookScript {
        let name: String
        let install: (String) throws -> String
    }

    private let agentHook = HookScript(name: "calyx-agent-hook", install: AgentHookScript.install(toDirectory:))
    private let approvalHook = HookScript(
        name: "calyx-approval-hook", install: ApprovalHookScript.install(toDirectory:)
    )
    private let wakeHook = HookScript(
        name: "calyx-ipc-wake-hook", install: IPCWakeHookScript.install(toDirectory:)
    )

    /// Installs `script` into a fresh fixture, runs it once with
    /// `extraEnv` and `kindArgument`, and returns how many times the
    /// fake curl was invoked alongside the script's exit code.
    private func run(
        _ script: HookScript,
        kindArgument: String?,
        extraEnv: [String: String]
    ) throws -> (curlInvocations: Int, exitCode: Int32) {
        let fixture = try makeFakeCurlScriptFixture(
            port: 41_830, token: "grok-compat-guard-token", install: script.install
        )
        fixtures.append(fixture)
        let recordPath = fixture.rootDir + "/curl-invocations.log"
        try makeFakeCurl(atDirectory: fixture.fakeBinDir, recordingTo: recordPath)

        var env = ["CALYX_SURFACE_ID": UUID().uuidString]
        for (key, value) in extraEnv { env[key] = value }
        let result = try runFakeCurlHookScript(
            fixture, stdinJSON: sampleStdin, extraEnv: env, kindArgument: kindArgument
        )

        let log = (try? String(contentsOfFile: recordPath, encoding: .utf8)) ?? ""
        return (log.split(separator: "\n").count, result.exitCode)
    }

    /// A Grok-shaped PreToolUse envelope: camelCase keys, snake_case
    /// event value. This is what a compat-scanned Claude Code entry
    /// actually receives when it fires inside a Grok session.
    private let sampleStdin = """
    {"hookEventName":"pre_tool_use","sessionId":"grok-1","cwd":"/Users/dev/repo","toolName":"read_file"}
    """

    private let grokHookEventValue = "pre_tool_use"

    // MARK: - The guard: claude-code inside a Grok session

    func test_agentHook_claudeCodeDefaultKind_insideGrokSession_exitsZeroWithoutPosting() throws {
        let result = try run(agentHook, kindArgument: nil, extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue])

        XCTAssertEqual(result.exitCode, 0, "The guard must exit cleanly, never break the user's hook chain")
        XCTAssertEqual(result.curlInvocations, 0,
                       "A Claude Code hook entry compat-scanned into a Grok session must post nothing: " +
                       "the event would otherwise land on the pane's row attributed to claude-code, and " +
                       "a real Claude Code pane's row would be indistinguishable from it")
    }

    func test_approvalHook_claudeCodeDefaultKind_insideGrokSession_exitsZeroWithoutPosting() throws {
        let result = try run(approvalHook, kindArgument: nil, extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.curlInvocations, 0,
                       "The approval hook must be even more strictly suppressed: its stdout becomes the " +
                       "CLI's decision, and a Claude-shaped hookSpecificOutput body is not vocabulary " +
                       "Grok understands")
    }

    func test_wakeHook_claudeCodeDefaultKind_insideGrokSession_exitsZeroWithoutPosting() throws {
        let result = try run(wakeHook, kindArgument: nil, extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue])

        XCTAssertEqual(result.exitCode, 0, "The guard must exit cleanly, never break the user's hook chain")
        XCTAssertEqual(result.curlInvocations, 0,
                       "The wake hook must not start a /ipc-wake long-poll from inside a Grok session: " +
                       "the pane it would be polling for is not running Claude Code, and the script's " +
                       "exit code 2 with a note on stderr is shaped for Claude Code alone")
    }

    func test_everyScript_explicitClaudeCodeKind_insideGrokSession_doNotPost() throws {
        for script in [agentHook, approvalHook, wakeHook] {
            let result = try run(
                script, kindArgument: AgentEntry.claudeCodeKind,
                extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue]
            )

            XCTAssertEqual(result.exitCode, 0, "[\(script.name)]")
            XCTAssertEqual(result.curlInvocations, 0,
                           "[\(script.name)] the guard keys on the RESOLVED kind, not on the argument " +
                           "being absent: claude-code passed explicitly is the same misattribution")
        }
    }

    // MARK: - Counter-pins: everything else still posts

    func test_everyScript_grokKind_insideGrokSession_stillPost() throws {
        for script in [agentHook, approvalHook, wakeHook] {
            let result = try run(
                script, kindArgument: AgentEntry.grokKind,
                extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue]
            )

            XCTAssertEqual(result.exitCode, 0, "[\(script.name)]")
            XCTAssertEqual(result.curlInvocations, 1,
                           "[\(script.name)] Calyx's own Grok entries run with GROK_HOOK_EVENT set too, " +
                           "since Grok injects it into every hook it spawns. A guard that only tested " +
                           "that variable would silence the integration it exists to protect")
        }
    }

    func test_everyScript_claudeCodeOutsideGrok_stillPost() throws {
        for script in [agentHook, approvalHook, wakeHook] {
            let result = try run(script, kindArgument: nil, extraEnv: [:])

            XCTAssertEqual(result.exitCode, 0, "[\(script.name)]")
            XCTAssertEqual(result.curlInvocations, 1,
                           "[\(script.name)] an ordinary Claude Code session sets no GROK_HOOK_EVENT and " +
                           "must be completely unaffected. This is also the harness's own proof that a " +
                           "zero-invocation result above means suppression, not a broken fixture")
        }
    }

    func test_everyScript_claudeCodeWithEmptyGrokHookEvent_stillPost() throws {
        for script in [agentHook, approvalHook, wakeHook] {
            let result = try run(script, kindArgument: nil, extraEnv: ["GROK_HOOK_EVENT": ""])

            XCTAssertEqual(result.exitCode, 0, "[\(script.name)]")
            XCTAssertEqual(result.curlInvocations, 1,
                           "[\(script.name)] the condition is set AND non-empty: a name merely present " +
                           "in the environment, exported empty by an unrelated shell profile, must not " +
                           "cost a Claude Code pane its monitoring")
        }
    }

    func test_everyScript_otherKindsInsideGrokSession_stillPost() throws {
        for script in [agentHook, approvalHook, wakeHook] {
            let result = try run(
                script, kindArgument: AgentEntry.codexKind,
                extraEnv: ["GROK_HOOK_EVENT": grokHookEventValue]
            )

            XCTAssertEqual(result.exitCode, 0, "[\(script.name)]")
            XCTAssertEqual(result.curlInvocations, 1,
                           "[\(script.name)] the guard is scoped to claude-code, the one kind Grok's " +
                           "compat scan can actually produce. Grok does not scan Codex's config, so " +
                           "suppressing codex would only be guesswork")
        }
    }
}
