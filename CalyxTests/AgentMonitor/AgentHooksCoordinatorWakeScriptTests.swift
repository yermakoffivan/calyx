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
    // test root and that none of them exists yet. tearDown removes
    // nothing while this is false.
    private var ownsCreatedPaths = false

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
        // install() does here, and tearDown would then delete state this
        // class did not create.
        let fm = FileManager.default
        let mustBeAbsent = [
            claudeDirectory!, codexDirectory!, grokDirectory!,
            agentScriptPath!, approvalScriptPath!, wakeScriptPath!,
            openCodeDirectory, piDirectory,
        ]
        for path in mustBeAbsent where fm.fileExists(atPath: path) {
            throw UnsafeEnvironment(description: "\(path) already exists: another test leaked state under the test root")
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
        }
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
