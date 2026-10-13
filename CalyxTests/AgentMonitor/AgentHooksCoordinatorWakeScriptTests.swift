//
//  AgentHooksCoordinatorWakeScriptTests.swift
//  CalyxTests
//
//  Covers how AgentHooksCoordinator handles calyx-ipc-wake-hook, the
//  hook script that belongs to Claude Code alone. These tests drive the
//  real install() / resyncInstalled() / remove() against the default
//  paths, which resolve beneath CalyxPathRoot.testRoot in the unit-test
//  host, so nothing here reaches a real home directory. setUp refuses to
//  run when that is not the case.
//
//  Coverage:
//  - install() with Claude Code present writes the wake script (0755,
//    IPCWakeHookScript.scriptBody) and points Stop's and SessionStart's
//    wake entries at it
//  - install() with Claude Code absent never writes the wake script,
//    although the two shared scripts are written for Codex
//  - resyncInstalled() skips Claude Code, and the wake script with it,
//    when only Codex carries Calyx's hooks
//  - resyncInstalled() upgrades a settings.json written before the wake
//    entry existed, and writes the wake script
//  - a wake script that cannot be written fails Claude Code only: no
//    settings.json is written, Codex and Grok are still wired
//  - remove() takes the wake entries out and leaves the script file
//  - Codex's and Grok's files never name the wake script
//  - I11, behaviourally: once the hooks are installed, resyncInstalled()
//    (the launch-time path) and a second install() leave settings.json
//    byte for byte unchanged, with and without a user-owned Stop group
//    next to Calyx's. The resync and install legs reach the file only
//    through ClaudeHooksConfigManager.installHooks, so a writer that
//    rewrote the wake entry on its own would show up here as changed
//    bytes. That no other type in the app writes the entry cannot be
//    proven from the test bundle; these tests pin the two paths that run
//    on every launch and every Settings install.
//
//  Independence from other tests: whatever another test left at one of
//  the default paths is moved aside in setUp and put back in tearDown,
//  so this class neither depends on running first nor deletes state it
//  did not create.
//

import XCTest
@testable import Calyx

final class AgentHooksCoordinatorWakeScriptTests: XCTestCase {

    // MARK: - Properties

    private struct UnsafeEnvironment: Error, CustomStringConvertible {
        let description: String
    }

    private var claudeDirectory: String!
    private var codexDirectory: String!
    private var grokDirectory: String!
    private var installDirectory: String!
    private var settingsPath: String!
    private var agentScriptPath: String!
    private var approvalScriptPath: String!
    private var wakeScriptPath: String!

    // Set only once setUp has confirmed that every path lies beneath the
    // test root and has moved aside whatever already existed there.
    // tearDown removes nothing while this is false.
    private var ownsCreatedPaths = false

    // Where setUp moved pre-existing paths, keyed by original path, so
    // tearDown can put them back.
    private var movedAside: [String: String] = [:]
    private var asideDirectory: String?

    private static let wakeEvents = ["Stop", "SessionStart"]

    private static let calyxScriptFileNames: Set<String> = [
        "calyx-agent-hook", "calyx-approval-hook", "calyx-ipc-wake-hook",
    ]

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()

        let root = try XCTUnwrap(CalyxPathRoot.testRoot,
                                 "CalyxPathRoot.testRoot must be set in the unit-test host")
        claudeDirectory = AgentToolPaths.claudeConfigDirectory
        codexDirectory = AgentToolPaths.codexConfigDirectory
        grokDirectory = AgentToolPaths.grokConfigDirectory
        installDirectory = AgentHookScript.defaultInstallDirectory
        settingsPath = AgentToolPaths.claudeSettingsPath
        agentScriptPath = (installDirectory as NSString).appendingPathComponent("calyx-agent-hook")
        approvalScriptPath = (installDirectory as NSString).appendingPathComponent("calyx-approval-hook")
        wakeScriptPath = (installDirectory as NSString).appendingPathComponent("calyx-ipc-wake-hook")

        // These tests write to the default paths. Refuse to run unless
        // every one of them lies beneath the test root.
        let openCodeDirectory = AgentToolPaths.openCodeConfigDirectory
        let piDirectory = AgentToolPaths.piConfigDirectory
        let guarded = [
            claudeDirectory!, codexDirectory!, grokDirectory!, installDirectory!, settingsPath!,
            openCodeDirectory, piDirectory,
        ]
        for path in guarded where !path.hasPrefix(root + "/") {
            throw UnsafeEnvironment(description: "\(path) does not lie beneath the test root \(root)")
        }

        // Another test leaving one of these behind would change what
        // install() does here. Move it aside instead of failing, and put
        // it back in tearDown, so this class does not depend on test
        // order and never deletes state it did not create.
        let fm = FileManager.default
        let mustBeAbsent = [
            claudeDirectory!, codexDirectory!, grokDirectory!,
            agentScriptPath!, approvalScriptPath!, wakeScriptPath!,
            openCodeDirectory, piDirectory,
        ]
        movedAside = [:]
        asideDirectory = nil
        for (index, path) in mustBeAbsent.enumerated() where fm.fileExists(atPath: path) {
            let aside: String
            if let existing = asideDirectory {
                aside = existing
            } else {
                aside = root + "/AgentHooksCoordinatorWakeScriptTests-aside-" + UUID().uuidString
                try fm.createDirectory(atPath: aside, withIntermediateDirectories: true)
                asideDirectory = aside
            }
            let destination = aside + "/\(index)"
            try fm.moveItem(atPath: path, toPath: destination)
            movedAside[path] = destination
        }

        ownsCreatedPaths = true
    }

    override func tearDown() {
        if ownsCreatedPaths {
            // Exactly what this class creates. The test root itself, its
            // Calyx/locks directory and the install directory stay.
            let fm = FileManager.default
            for path in [
                claudeDirectory!, codexDirectory!, grokDirectory!,
                agentScriptPath!, approvalScriptPath!, wakeScriptPath!,
            ] {
                try? fm.removeItem(atPath: path)
            }
            for (original, aside) in movedAside {
                try? fm.removeItem(atPath: original)
                try? fm.moveItem(atPath: aside, toPath: original)
            }
            if let asideDirectory {
                try? fm.removeItem(atPath: asideDirectory)
            }
        }
        movedAside = [:]
        asideDirectory = nil
        ownsCreatedPaths = false
        super.tearDown()
    }

    // MARK: - Helpers

    private func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func describe(_ status: ConfigStatus) -> String {
        switch status {
        case .success: return ".success"
        case .skipped(let reason): return ".skipped(\(reason))"
        case .failed(let error): return ".failed(\(error))"
        }
    }

    private func assertSuccess(_ status: ConfigStatus, _ message: String, line: UInt = #line) {
        guard case .success = status else {
            XCTFail("\(message) -- got \(describe(status))", line: line)
            return
        }
    }

    private func assertSkipped(_ status: ConfigStatus, _ message: String, line: UInt = #line) {
        guard case .skipped = status else {
            XCTFail("\(message) -- got \(describe(status))", line: line)
            return
        }
    }

    private func assertFailed(_ status: ConfigStatus, _ message: String, line: UInt = #line) {
        guard case .failed = status else {
            XCTFail("\(message) -- got \(describe(status))", line: line)
            return
        }
    }

    private func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                             "settings.json must hold a JSON object")
    }

    private func hookGroups(_ dict: [String: Any], event: String) -> [[String: Any]] {
        let hooks = dict["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func entries(of group: [String: Any]) -> [[String: Any]] {
        (group["hooks"] as? [[String: Any]]) ?? []
    }

    // Whether a command entry names one of Calyx's three scripts: the
    // last path component of its command, with one pair of surrounding
    // double quotes taken off.
    private func isCalyxEntry(_ entry: [String: Any]) -> Bool {
        guard var command = entry["command"] as? String else { return false }
        if command.hasPrefix("\""), command.hasSuffix("\""), command.count >= 2 {
            command = String(command.dropFirst().dropLast())
        }
        return Self.calyxScriptFileNames.contains((command as NSString).lastPathComponent)
    }

    private var monitorEntry: [String: Any] {
        ["type": "command", "command": "\"\(agentScriptPath!)\"", "timeout": 5, "async": true]
    }

    private var wakeEntry: [String: Any] {
        [
            "type": "command", "command": "\"\(wakeScriptPath!)\"", "timeout": 600,
            "async": true, "asyncRewake": true,
        ]
    }

    // Asserts that Stop and SessionStart each hold exactly one group
    // with a Calyx entry in it, and that this group is [monitor, wake]
    // pointing at the scripts in the install directory.
    private func assertWakeEventsHoldMonitorThenWake(_ dict: [String: Any], line: UInt = #line) {
        for eventName in Self.wakeEvents {
            let ownGroups = hookGroups(dict, event: eventName).filter { group in
                entries(of: group).contains { isCalyxEntry($0) }
            }
            XCTAssertEqual(ownGroups.count, 1, "\(eventName) must hold exactly one Calyx group", line: line)
            XCTAssertEqual(entries(of: ownGroups.first ?? [:]) as NSArray, [monitorEntry, wakeEntry] as NSArray,
                           "\(eventName)'s Calyx group must be [monitor, wake], each command the quoted path " +
                           "of the script in the install directory",
                           line: line)
        }
    }

    // MARK: - install()

    func test_install_claudeCodePresent_writesWakeScriptAndPointsWakeEntriesAtIt() throws {
        try createDirectory(claudeDirectory)

        let result = AgentHooksCoordinator.install()

        assertSuccess(result.claudeCode, "Claude Code is present, so its hooks must be installed")

        XCTAssertTrue(exists(wakeScriptPath),
                      "install() must write calyx-ipc-wake-hook into the install directory for Claude Code")
        let attributes = try? FileManager.default.attributesOfItem(atPath: wakeScriptPath)
        XCTAssertEqual(attributes?[.type] as? FileAttributeType, .typeRegular,
                       "calyx-ipc-wake-hook must be a regular file")
        XCTAssertEqual(attributes?[.posixPermissions] as? Int, 0o755,
                       "calyx-ipc-wake-hook must be executable (0755)")
        let content = FileManager.default.contents(atPath: wakeScriptPath).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(content, IPCWakeHookScript.scriptBody,
                       "The installed wake script must be IPCWakeHookScript.scriptBody")

        let dict = try readSettings()
        for eventName in Self.wakeEvents {
            let commands = hookGroups(dict, event: eventName).flatMap { entries(of: $0) }
            let wakeEntries = commands.filter { $0["asyncRewake"] != nil }
            XCTAssertEqual(wakeEntries.count, 1, "\(eventName) must carry exactly one wake entry")
            XCTAssertEqual(wakeEntries.first?["command"] as? String, "\"\(wakeScriptPath!)\"",
                           "\(eventName)'s wake entry must run the script install() wrote: its quoted path")
        }
        assertWakeEventsHoldMonitorThenWake(dict)
    }

    func test_install_claudeCodeAbsentCodexPresent_neverWritesWakeScript() throws {
        try createDirectory(codexDirectory)

        let result = AgentHooksCoordinator.install()

        assertSkipped(result.claudeCode, "Claude Code is not installed, so its leg must be skipped")
        assertSuccess(result.codex, "Codex is present, so its hooks must be installed")
        XCTAssertTrue(exists(agentScriptPath),
                      "The shared calyx-agent-hook script must have been installed for Codex")
        XCTAssertFalse(exists(wakeScriptPath),
                       "calyx-ipc-wake-hook belongs to Claude Code alone and must not be written when " +
                       "Claude Code's leg is skipped")
        XCTAssertFalse(exists(settingsPath), "No settings.json may be written for an absent Claude Code")
        XCTAssertFalse(exists(claudeDirectory), "install() must not create ~/.claude")
    }

    func test_install_wakeScriptCannotBeWritten_failsClaudeCodeOnlyAndWritesNoEntries() throws {
        try createDirectory(claudeDirectory)
        try createDirectory(codexDirectory)
        try createDirectory(grokDirectory)
        // A directory where the wake script goes: the two shared scripts
        // still install, only the wake script's write throws.
        try createDirectory(wakeScriptPath)

        let result = AgentHooksCoordinator.install()

        assertFailed(result.claudeCode,
                     "The wake script could not be written, so Claude Code's leg must report the failure")
        XCTAssertFalse(exists(settingsPath),
                       "No hook entry may be written when the wake script is missing: settings.json " +
                       "must not exist")

        assertSuccess(result.codex, "A wake script failure must not affect Codex")
        assertSuccess(result.grok, "A wake script failure must not affect Grok")
        XCTAssertTrue(CodexHooksConfigManager.areHooksInstalled(), "Codex's hooks must be installed regardless")
        XCTAssertTrue(GrokHooksConfigManager.areHooksInstalled(), "Grok's hooks must be installed regardless")
        XCTAssertTrue(exists(agentScriptPath), "The shared calyx-agent-hook script must still be installed")
        XCTAssertTrue(exists(approvalScriptPath), "The shared calyx-approval-hook script must still be installed")

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: wakeScriptPath, isDirectory: &isDirectory)
                        && isDirectory.boolValue,
                      "The directory standing in the wake script's place must be left as it was")
    }

    func test_install_allThreeToolsPresent_codexAndGrokFilesNeverNameTheWakeScript() throws {
        try createDirectory(claudeDirectory)
        try createDirectory(codexDirectory)
        try createDirectory(grokDirectory)

        let result = AgentHooksCoordinator.install()

        assertSuccess(result.codex, "Codex is present, so its hooks must be installed")
        assertSuccess(result.grok, "Grok is present, so its hooks must be installed")

        let codexConfig = try String(contentsOfFile: codexDirectory + "/config.toml", encoding: .utf8)
        XCTAssertTrue(codexConfig.contains("calyx-agent-hook"),
                      "Precondition: Codex's config must hold Calyx's hooks")
        XCTAssertFalse(codexConfig.contains("calyx-ipc-wake-hook"),
                       "The wake script belongs to Claude Code alone: Codex's config must not name it")

        let grokHooks = try String(contentsOfFile: GrokHooksConfigManager.defaultConfigPath, encoding: .utf8)
        XCTAssertTrue(grokHooks.contains("calyx-agent-hook"),
                      "Precondition: Grok's hook file must hold Calyx's hooks")
        XCTAssertFalse(grokHooks.contains("calyx-ipc-wake-hook"),
                       "The wake script belongs to Claude Code alone: Grok's hook file must not name it")
    }

    // MARK: - resyncInstalled()

    // Claude Code was installed after Calyx's hooks went into Codex and
    // was never wired. A resync must not spread to it, and must not
    // write the script that only Claude Code uses.
    func test_resyncInstalled_onlyCodexHasCalyxHooks_skipsClaudeCodeAndNeverWritesWakeScript() throws {
        try createDirectory(codexDirectory)
        assertSuccess(AgentHooksCoordinator.install().codex, "Precondition: Codex's hooks must be installed")
        try createDirectory(claudeDirectory)

        let result = AgentHooksCoordinator.resyncInstalled()

        assertSkipped(result.claudeCode, "Claude Code carries none of Calyx's hooks, so a resync must skip it")
        assertSuccess(result.codex, "Codex carries Calyx's hooks, so a resync must refresh it")
        XCTAssertFalse(exists(wakeScriptPath),
                       "calyx-ipc-wake-hook must not be written when Claude Code's leg is skipped")
        XCTAssertFalse(exists(settingsPath), "A resync must not create settings.json for an unwired Claude Code")
    }

    // The upgrade path: a settings.json written before the wake entry
    // existed is brought up to date by the launch-time resync.
    func test_resyncInstalled_settingsWrittenBeforeWakeEntry_writesWakeScriptAndAddsWakeEntries() throws {
        try createDirectory(claudeDirectory)
        let oldSettings: [String: Any] = ["hooks": ["Stop": [["hooks": [monitorEntry]]]]]
        try JSONSerialization.data(withJSONObject: oldSettings).write(to: URL(fileURLWithPath: settingsPath))

        let result = AgentHooksCoordinator.resyncInstalled()

        assertSuccess(result.claudeCode, "Claude Code carries Calyx's hooks, so a resync must refresh it")
        XCTAssertTrue(exists(wakeScriptPath),
                      "A resync that refreshes Claude Code must write calyx-ipc-wake-hook")
        assertWakeEventsHoldMonitorThenWake(try readSettings())
    }

    // MARK: - I11: no rewrite once installed

    func test_resyncInstalled_hooksAlreadyInstalled_leavesSettingsBytesUnchanged() throws {
        try createDirectory(claudeDirectory)
        assertSuccess(AgentHooksCoordinator.install().claudeCode,
                      "Precondition: Claude Code's hooks must be installed")
        let before = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        let result = AgentHooksCoordinator.resyncInstalled()

        assertSuccess(result.claudeCode, "Claude Code carries Calyx's hooks, so a resync must refresh it")
        let after = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        XCTAssertEqual(after, before,
                       "a resync over hooks that are already installed must not change settings.json: the " +
                       "wake entry is written only by installHooks, which leaves an up-to-date file as it is")
        assertWakeEventsHoldMonitorThenWake(try readSettings())
    }

    func test_resyncAndReinstall_withAUserStopGroupPresent_leaveSettingsBytesUnchanged() throws {
        try createDirectory(claudeDirectory)
        let userStopGroup: [String: Any] = [
            "hooks": [["type": "command", "command": "/usr/local/bin/my-own-stop-hook", "timeout": 10]],
        ]
        let userSettings: [String: Any] = ["hooks": ["Stop": [userStopGroup]], "theme": "dark"]
        try JSONSerialization.data(withJSONObject: userSettings).write(to: URL(fileURLWithPath: settingsPath))
        assertSuccess(AgentHooksCoordinator.install().claudeCode,
                      "Precondition: Claude Code's hooks must be installed next to the user's Stop group")
        let installed = try readSettings()
        XCTAssertTrue(
            hookGroups(installed, event: "Stop").contains { group in
                entries(of: group).contains { $0["command"] as? String == "/usr/local/bin/my-own-stop-hook" }
            },
            "Precondition: the user's own Stop group survives the install")
        let before = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        let resync = AgentHooksCoordinator.resyncInstalled()
        assertSuccess(resync.claudeCode, "a resync must refresh Claude Code")
        let afterResync = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let reinstall = AgentHooksCoordinator.install()
        assertSuccess(reinstall.claudeCode, "a second install must succeed")
        let afterReinstall = try Data(contentsOf: URL(fileURLWithPath: settingsPath))

        XCTAssertEqual(afterResync, before,
                       "a resync must not rewrite settings.json when the user's Stop group sits next to " +
                       "Calyx's up-to-date group")
        XCTAssertEqual(afterReinstall, before,
                       "a second install must not rewrite settings.json when the user's Stop group sits next " +
                       "to Calyx's up-to-date group")
    }

    // MARK: - remove()

    func test_remove_afterInstall_removesWakeEntriesAndLeavesWakeScriptInPlace() throws {
        try createDirectory(claudeDirectory)
        assertSuccess(AgentHooksCoordinator.install().claudeCode,
                      "Precondition: Claude Code's hooks must be installed")

        let result = AgentHooksCoordinator.remove()

        assertSuccess(result.claudeCode, "Claude Code carried Calyx's hooks, so remove() must remove them")
        XCTAssertFalse(ClaudeHooksConfigManager.areHooksInstalled(),
                       "No Calyx entry, the wake entry included, may remain after remove()")
        if let data = FileManager.default.contents(atPath: settingsPath) {
            let text = String(decoding: data, as: UTF8.self)
            for fileName in Self.calyxScriptFileNames.sorted() {
                XCTAssertFalse(text.contains(fileName),
                               "settings.json must no longer reference \(fileName) after remove()")
            }
        }
        XCTAssertTrue(exists(wakeScriptPath),
                      "remove() leaves hook scripts in place: calyx-ipc-wake-hook must still be in the " +
                      "install directory, like the other two")
        XCTAssertTrue(exists(agentScriptPath), "remove() leaves calyx-agent-hook in place")
        XCTAssertTrue(exists(approvalScriptPath), "remove() leaves calyx-approval-hook in place")
    }
}
