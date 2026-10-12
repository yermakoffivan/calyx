//
//  ClaudeHooksConfigManagerTests.swift
//  CalyxTests
//
//  Covers ClaudeHooksConfigManager: writes the "hooks" section of
//  ~/.claude/settings.json for the calyx-agent-hook script, following the
//  same file-safety guarantees as ClaudeConfigManager (see
//  ClaudeConfigManagerTests.swift): symlink rejection, no backup file,
//  and preservation of unrelated content.
//
//  Coverage:
//  - installHooks on an empty/new file writes all 10 target events, each
//    with a monitor command entry (type=command, timeout, async=true)
//  - Stop and SessionStart alone carry a second entry after the monitor
//    entry: the wake entry for calyx-ipc-wake-hook (timeout 600,
//    async=true, asyncRewake=true); no other event carries one
//  - a config written before the wake entry existed is upgraded by
//    installHooks: afterwards one Calyx group per event, [monitor, wake]
//    on Stop and SessionStart, no duplicated monitor entry, the user's
//    own group still present and unchanged, and the other eight events'
//    groups as they were
//  - PreToolUse / PostToolUse / PermissionRequest use matcher
//    "*"; Notification uses matcher "permission_prompt"
//  - installHooks preserves the user's own existing hook entries and
//    unrelated top-level keys
//  - Re-installing is idempotent (no duplicate command entries, and a
//    no-op reinstall -- content already matches -- never rewrites
//    settings.json, since withExclusiveConfig writes nothing when the
//    transformed bytes equal what was read)
//  - a reinstall leaves the file's bytes identical with the wake
//    entries in place, also when the user has their own group on Stop
//    and on SessionStart
//  - removeHooks removes only Calyx's own entries, identified by command
//    path (calyx-agent-hook, calyx-approval-hook, calyx-ipc-wake-hook),
//    leaving co-located user hooks untouched
//  - areHooksInstalled recognizes a wake entry alone
//  - symlink config path is rejected
//  - no backup file of the pre-install content is ever created
//

import XCTest
@testable import Calyx

final class ClaudeHooksConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!
    private var scriptPath: String!
    private var approvalScriptPath: String!
    private var wakeScriptPath: String!

    // PermissionRequest fires in sync with the permission dialog
    // appearing, unlike Notification(permission_prompt) which can lag
    // behind it by several seconds — subscribing to it too lets the
    // sidebar flip to blocked immediately instead of waiting for the
    // delayed Notification hook.
    private static let expectedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SessionEnd", "PermissionRequest",
        "SubagentStart", "SubagentStop",
    ]

    // PermissionRequest's matcher is unified with
    // PreToolUse/PostToolUse's "*" (previously omitted entirely) — see
    // ClaudeHooksConfigManager.targetEvents' doc comment. SubagentStart /
    // SubagentStop's matcher tests the agent type, so they share the
    // same unfiltered "*" too.
    private static let expectedMatcherByEvent: [String: String] = [
        "PreToolUse": "*",
        "PostToolUse": "*",
        "PermissionRequest": "*",
        "Notification": "permission_prompt",
        "SubagentStart": "*",
        "SubagentStop": "*",
    ]

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/settings.json"
        scriptPath = tempDir + "/bin/calyx-agent-hook"
        approvalScriptPath = tempDir + "/bin/calyx-approval-hook"
        wakeScriptPath = tempDir + "/bin/calyx-ipc-wake-hook"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ content: String) {
        FileManager.default.createFile(atPath: configPath, contents: Data(content.utf8))
    }

    private func writeConfigDict(_ dict: [String: Any]) throws {
        try writeConfigDict(dict, to: configPath)
    }

    private func writeConfigDict(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func readConfigDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private func hookGroups(_ dict: [String: Any], event: String) -> [[String: Any]] {
        let hooks = dict["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func commandEntries(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    // The two events whose Calyx group carries the wake entry after the
    // monitor entry.
    private static let wakeEvents = ["Stop", "SessionStart"]

    // The three script file names by which a command entry is Calyx's
    // own, written out literally so that these tests do not follow a
    // renamed constant.
    private static let calyxScriptFileNames: Set<String> = [
        "calyx-agent-hook", "calyx-approval-hook", "calyx-ipc-wake-hook",
    ]

    // How many Calyx command entries one event carries: monitor + wake
    // for Stop and SessionStart, monitor + approval for
    // PermissionRequest, the monitor entry alone for the other seven.
    private func expectedCalyxEntryCount(for eventName: String) -> Int {
        Self.wakeEvents.contains(eventName) || eventName == "PermissionRequest" ? 2 : 1
    }

    private var monitorCommand: String { "\"\(scriptPath!)\"" }
    private var approvalCommand: String { "\"\(approvalScriptPath!)\"" }
    private var wakeCommand: String { "\"\(wakeScriptPath!)\"" }

    private var monitorEntry: [String: Any] {
        ["type": "command", "command": monitorCommand, "timeout": 5, "async": true]
    }

    private var approvalEntry: [String: Any] {
        ["type": "command", "command": approvalCommand, "timeout": 600]
    }

    private var wakeEntry: [String: Any] {
        ["type": "command", "command": wakeCommand, "timeout": 600, "async": true, "asyncRewake": true]
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

    // The groups of one event holding at least one Calyx entry.
    private func calyxGroups(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.filter { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).contains { isCalyxEntry($0) }
        }
    }

    // Whether a decoded JSON value is the boolean `true` itself, not a
    // number that merely compares equal to it.
    private func isJSONTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue
    }

    // MARK: - installHooks: fresh file

    // PreToolUse's Calyx-owned group carries only the async monitor
    // entry. PermissionRequest's carries both that same monitor entry
    // and a second, synchronous approval entry (calyx-approval-hook)
    // that blocks the tool call until Calyx's own /approval-request
    // long-poll resolves. Stop's and SessionStart's carry the monitor
    // entry and the wake entry (calyx-ipc-wake-hook). The other seven
    // events get exactly one command entry.
    func test_installHooks_newFile_writesAllTenEventsWithCommandEntry() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let groups = hookGroups(dict, event: eventName)
            XCTAssertFalse(groups.isEmpty, "\(eventName) hook group must be present")

            if let expectedMatcher = Self.expectedMatcherByEvent[eventName] {
                XCTAssertEqual(groups.first?["matcher"] as? String, expectedMatcher,
                               "\(eventName) matcher must be '\(expectedMatcher)'")
            }

            let commands = commandEntries(groups)

            let expectedCount = expectedCalyxEntryCount(for: eventName)
            XCTAssertEqual(commands.count, expectedCount,
                           "\(eventName) must contain exactly \(expectedCount) command entry(ies): the " +
                           "monitor entry, plus the wake entry for Stop and SessionStart and the " +
                           "approval entry for PermissionRequest")

            let monitorEntries = commands.filter { ($0["command"] as? String) == monitorCommand }
            XCTAssertEqual(monitorEntries.count, 1, "\(eventName) must contain exactly one monitor entry")
            let entry = monitorEntries.first ?? [:]
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertNotNil(entry["timeout"], "\(eventName) monitor entry must specify a timeout")
            XCTAssertEqual(entry["async"] as? Bool, true, "\(eventName) monitor entry must be async")
        }
    }

    // The loop in test_installHooks_newFile_writesAllTenEventsWithCommandEntry
    // above already covers PermissionRequest's matcher value via
    // expectedMatcherByEvent; this test additionally pins down that its
    // group holds exactly two Calyx-owned command entries (monitor +
    // approval), unified with PreToolUse/PostToolUse's "*" matcher
    // rather than left without one.
    func test_installHooks_permissionRequest_hasWildcardMatcherAndTwoCommandEntries() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PermissionRequest")

        XCTAssertFalse(groups.isEmpty, "PermissionRequest hook group must be present")
        XCTAssertEqual(groups.first?["matcher"] as? String, "*",
                       "PermissionRequest's matcher must be \"*\", unified with PreToolUse/PostToolUse")

        let commands = commandEntries(groups)
        XCTAssertEqual(commands.count, 2,
                       "PermissionRequest must contain both the async monitor entry and the sync " +
                       "approval entry")
    }

    // MARK: - installHooks: preserves existing content

    func test_installHooks_preservesExistingUserHooksAndOtherTopLevelKeys() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read", "write"]],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")

        let userGroup = preToolUseGroups.first { ($0["matcher"] as? String) == "Bash" }
        XCTAssertNotNil(userGroup, "The user's existing 'Bash' matcher group must be preserved")

        let calyxGroup = preToolUseGroups.first { ($0["matcher"] as? String) == "*" }
        XCTAssertNotNil(calyxGroup, "Calyx's own '*' matcher group must be added")

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"],
                       "Unrelated top-level keys must be preserved")
    }

    // MARK: - installHooks: idempotency

    func test_installHooks_reinstall_isIdempotent() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)
        let beforeModificationDate = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.2)
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let commands = commandEntries(hookGroups(dict, event: eventName))
            let expectedCount = expectedCalyxEntryCount(for: eventName)
            XCTAssertEqual(commands.count, expectedCount,
                           "\(eventName) must contain exactly \(expectedCount) Calyx hook entry(ies) " +
                           "after reinstalling twice")
        }

        // withExclusiveConfig writes nothing when the bytes installHooks's
        // transform returns equal what it read, so a second install of
        // identical content never touches this file -- which a CLI
        // sharing it (claude itself writes permission grants here)
        // depends on to avoid racing Calyx's own writes.
        let afterModificationDate = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date
        XCTAssertEqual(beforeModificationDate, afterModificationDate,
                       "An unchanged reinstall must not rewrite the shared settings.json file")
    }

    // MARK: - PermissionRequest monitor + approval entries

    // PermissionRequest's group carries two Calyx-owned command entries
    // -- the async monitor entry (same shape every other event gets) and
    // a synchronous approval entry that blocks the tool call until
    // Calyx's own /approval-request long-poll resolves. PermissionRequest
    // fires only once the CLI has already decided it needs to show a
    // confirmation prompt, so gating there (rather than PreToolUse, which
    // fires for every tool call regardless of whether it needs approval)
    // avoids a synchronous POST on every single tool call.
    func test_installHooks_permissionRequest_writesMonitorAndApprovalEntriesWithCorrectShapes() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PermissionRequest"))
        XCTAssertEqual(commands.count, 2, "PermissionRequest must have exactly two Calyx command entries")

        let monitor = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(scriptPath!)\"" },
            "The async monitor entry (command = scriptPath) must be present"
        )
        XCTAssertEqual(monitor["type"] as? String, "command")
        XCTAssertEqual(monitor["timeout"] as? Int, 5)
        XCTAssertEqual(monitor["async"] as? Bool, true)

        let approval = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
            "The synchronous approval entry (command = approvalScriptPath) must be present"
        )
        XCTAssertEqual(approval["type"] as? String, "command")
        XCTAssertEqual(approval["timeout"] as? Int, ApprovalHookTiming.hookEntryTimeoutSeconds)
        XCTAssertNil(approval["async"], "The approval entry must be synchronous -- no \"async\" key at all")
    }

    func test_installHooks_permissionRequestApprovalEntry_hasNoAsyncKeyAndCorrectTimeout() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PermissionRequest"))
        let approvalEntry = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
            "The approval entry (command = approvalScriptPath) must be present"
        )

        XCTAssertEqual(approvalEntry["timeout"] as? Int, 600,
                       "The approval entry's timeout must equal ApprovalHookTiming.hookEntryTimeoutSeconds (600)")
        XCTAssertNil(approvalEntry["async"], "The approval entry must have no \"async\" key -- it runs synchronously")
    }

    // MARK: - PreToolUse carries only the monitor entry

    func test_installHooks_preToolUse_hasOnlyMonitorEntry_noApprovalEntry() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PreToolUse"))

        XCTAssertEqual(commands.count, 1, "PreToolUse must contain only the async monitor entry")
        XCTAssertEqual(commands.first?["command"] as? String, "\"\(scriptPath!)\"")
        XCTAssertFalse(commands.contains { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
                       "The approval entry must never be installed under PreToolUse")
    }

    // A config written before this migration has PreToolUse's group with
    // only the async monitor entry -- no approval entry ever existed for
    // it at all. installHooks must leave it a single entry and must not
    // duplicate the "*" matcher group.
    func test_installHooks_existingPreToolUseMonitorOnlyEntry_remainsSingleEntryNoMatcherDuplication() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(scriptPath!)\"", "timeout": 5, "async": true],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PreToolUse")
        let wildcardGroups = groups.filter { ($0["matcher"] as? String) == "*" }
        XCTAssertEqual(wildcardGroups.count, 1, "Reinstalling must not create a second '*' matcher group")

        let commands = commandEntries(groups)
        XCTAssertEqual(commands.count, 1,
                       "PreToolUse must remain a single entry -- the approval entry belongs under " +
                       "PermissionRequest, not here")
        XCTAssertEqual(commands.first?["command"] as? String, "\"\(scriptPath!)\"",
                       "The pre-existing monitor entry must survive unchanged")
    }

    // MARK: - Migration: approval entry moves from PreToolUse to PermissionRequest

    // A config written by a pre-migration Calyx version has the
    // synchronous approval entry living under PreToolUse alongside its
    // async monitor entry, with PermissionRequest already carrying its
    // own monitor-only entry (installHooks always wrote one there too,
    // even before this migration). Reinstalling with the current
    // implementation must relocate the approval entry to
    // PermissionRequest, without duplicating either event's monitor
    // entry -- installHooks' own idempotent re-run doubles as the
    // migration path, with no separate migration function needed.
    func test_installHooks_reinstallOverOldPreToolUseApprovalEntry_migratesApprovalEntryToPermissionRequest() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(scriptPath!)\"", "timeout": 5, "async": true],
                        ["type": "command", "command": "\"\(approvalScriptPath!)\"", "timeout": 600],
                    ]],
                ],
                "PermissionRequest": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(scriptPath!)\"", "timeout": 5, "async": true],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        let preToolUseCommands = commandEntries(hookGroups(dict, event: "PreToolUse"))
        XCTAssertEqual(preToolUseCommands.count, 1, "The approval entry must no longer be present under PreToolUse")
        XCTAssertEqual(preToolUseCommands.first?["command"] as? String, "\"\(scriptPath!)\"",
                       "Only the async monitor entry remains under PreToolUse")

        let permissionRequestCommands = commandEntries(hookGroups(dict, event: "PermissionRequest"))
        XCTAssertEqual(permissionRequestCommands.count, 2,
                       "PermissionRequest must end up with both the monitor and approval entries, " +
                       "without duplicating the monitor entry already there")
        XCTAssertEqual(
            permissionRequestCommands.filter { ($0["command"] as? String) == "\"\(scriptPath!)\"" }.count, 1,
            "The pre-existing PermissionRequest monitor entry must not be duplicated"
        )
        XCTAssertTrue(permissionRequestCommands.contains { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
                     "The approval entry must reappear under PermissionRequest")
    }

    // isOwnCommandEntry must recognize calyx-approval-hook's own filename
    // directly -- independent of ever having gone through installHooks --
    // so a group containing only the approval entry still gets stripped
    // correctly by removeHooks.
    func test_removeHooks_stripsApprovalOnlyEntryByCommandPath() throws {
        let approvalCommand = "\"\(approvalScriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": approvalCommand, "timeout": 600],
                        ["type": "command", "command": "/usr/local/bin/user-approval-hook", "timeout": 3],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PreToolUse"))
        XCTAssertEqual(commands.count, 1, "Only Calyx's own approval entry should be removed")
        XCTAssertEqual(commands.first?["command"] as? String, "/usr/local/bin/user-approval-hook")
    }

    func test_removeHooks_stripsMonitorEntryFromPreToolUsePreservingUserEntries() throws {
        let userCommand = "/usr/local/bin/user-hook"
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": userCommand, "timeout": 10],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PreToolUse")
        XCTAssertEqual(groups.count, 1, "Only the user's own 'Bash' matcher group must remain")
        XCTAssertEqual(commandEntries(groups).first?["command"] as? String, userCommand)
    }

    func test_areHooksInstalled_trueWhenOnlyApprovalEntryPresent() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(approvalScriptPath!)\"", "timeout": 600],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                     "areHooksInstalled must recognize the approval entry alone, without the " +
                     "monitor entry present")
    }

    // MARK: - removeHooks

    func test_removeHooks_removesOnlyOwnEntriesByCommandPath() throws {
        let calyxCommand = "\"\(scriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                        ["type": "command", "command": "/usr/local/bin/my-other-hook", "timeout": 3],
                    ]],
                ],
                "SessionStart": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read"]],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()

        let stopCommands = commandEntries(hookGroups(dict, event: "Stop"))
        XCTAssertEqual(stopCommands.count, 1,
                       "Only Calyx's own Stop hook entry should be removed; the co-located user hook must remain")
        XCTAssertEqual(stopCommands.first?["command"] as? String, "/usr/local/bin/my-other-hook")

        let sessionStartCommands = commandEntries(hookGroups(dict, event: "SessionStart"))
        XCTAssertTrue(sessionStartCommands.isEmpty,
                      "Calyx's only SessionStart hook entry should leave the group empty")

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read"], "Unrelated top-level keys must be preserved")
    }

    // Covers the full installHooks -> removeHooks round trip for
    // PermissionRequest specifically, alongside a co-located third-party
    // hook (e.g. claude-remote-approver) the user installed themselves --
    // installHooks must add both of Calyx's own entries without
    // disturbing it, and removeHooks must take only Calyx's entries back
    // out.
    func test_installThenRemove_permissionRequest_preservesUserOwnHookAndRemovesOnlyCalyxEntry() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    ["hooks": [
                        ["type": "command", "command": "/usr/local/bin/claude-remote-approver", "timeout": 3],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let afterInstall = try readConfigDict()
        let installedCommands = commandEntries(hookGroups(afterInstall, event: "PermissionRequest"))
        XCTAssertEqual(installedCommands.count, 3,
                       "installHooks must add both of Calyx's own PermissionRequest entries (monitor + " +
                       "approval) alongside the user's pre-existing one, not replace or skip it")

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let afterRemove = try readConfigDict()
        let remainingCommands = commandEntries(hookGroups(afterRemove, event: "PermissionRequest"))
        XCTAssertEqual(remainingCommands.count, 1,
                       "removeHooks must remove only Calyx's own PermissionRequest entries")
        XCTAssertEqual(remainingCommands.first?["command"] as? String, "/usr/local/bin/claude-remote-approver",
                       "The user's own PermissionRequest hook (e.g. claude-remote-approver) must " +
                       "survive removeHooks")
    }

    func test_removeHooks_dropsEmptyEventKeysAndHooksKeyWhenAllEmpty() throws {
        // The 10 events installHooks writes only ever contain Calyx's own
        // entry in a fresh install, so removing them should leave neither
        // a dangling "EventName": [] nor an empty "hooks": {} behind.
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertNil(dict["hooks"], "The \"hooks\" key must be removed entirely once every event under it is empty")
    }

    func test_removeHooks_keepsHooksKeyWhenOtherEventsSurvive() throws {
        let calyxCommand = "\"\(scriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                    ]],
                ],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertNil(dict["hooks"].flatMap { ($0 as? [String: Any])?["SessionStart"] },
                    "SessionStart's now-empty group list must be dropped")
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")
        XCTAssertFalse(preToolUseGroups.isEmpty, "PreToolUse's surviving user hook must keep the \"hooks\" key present")
    }

    func test_installThenRemove_restoresOriginalConfig() throws {
        let originalConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read", "write"]],
        ]
        try writeConfigDict(originalConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")
        XCTAssertEqual(preToolUseGroups.count, 1, "Only the user's own PreToolUse group must remain")
        XCTAssertEqual(commandEntries(preToolUseGroups).first?["command"] as? String, "/usr/local/bin/user-hook")

        for eventName in Self.expectedEvents where eventName != "PreToolUse" {
            XCTAssertTrue(hookGroups(dict, event: eventName).isEmpty,
                          "\(eventName) had no user entries, so install→remove must leave it absent")
        }

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"], "Unrelated top-level keys must survive install→remove")
    }

    // MARK: - Security

    // Contract: ~/.claude/settings.json is commonly a
    // dotfiles-managed symlink, and blanket symlink rejection is exactly
    // the bug that silently broke hooks installation end-to-end in that
    // setup (see the dotfiles-fixture tests below for the full
    // real-environment reproduction). Calyx now follows the link and
    // writes through to the real target file, leaving the link intact.
    func test_installHooks_symlinkConfigPath_followsToRealFileAndKeepsLinkIntact() throws {
        let realFile = tempDir + "/real_settings.json"
        writeConfig("{}")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let realFileData = try Data(contentsOf: URL(fileURLWithPath: realFile))
        let realFileDict = (try JSONSerialization.jsonObject(with: realFileData) as? [String: Any]) ?? [:]
        XCTAssertFalse(hookGroups(realFileDict, event: "SessionStart").isEmpty,
                       "installHooks must write through the symlink into the real file")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write, not be replaced with a regular file")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile, "The symlink must still point at the same real file")
    }

    // MARK: - Backup
    //
    // Superseded by the L1.2 "no backup at all" rule
    // (`.claude/plans/ipc-toggle.md`): `withExclusiveConfig` never writes
    // a `.bak`, since L1.3's editors make the write itself
    // non-destructive, leaving nothing for a backup to compensate for.
    // These two replace the prior test_installHooks_createsBackupOfExistingFile
    // / test_removeHooks_createsBackupOfPreRemovalContent (which asserted
    // the opposite) and test_installHooks_reinstallWithNoContentChange_
    // bakStillHoldsOriginalPreCalyxContent (whose entire premise --
    // comparing successive .bak snapshots -- no longer applies once no
    // .bak is ever written).

    func test_installHooks_neverCreatesABackupFile() throws {
        writeConfig("{ \"hooks\": {} }")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath),
                       "installHooks must not create a .bak file")
    }

    func test_removeHooks_neverCreatesABackupFile() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath),
                       "removeHooks must not create a .bak file")
    }

    /// `removeHooks` against a corrupt (not valid JSON) file must throw
    /// `ConfigFileError.invalidJSON`, matching `installHooks`'s own
    /// behavior against the same corrupt file: a user cannot fix a config
    /// Calyx silently no-ops against, and the two entry points must agree
    /// about the same file rather than one throwing and the other
    /// pretending the file is empty.
    func test_removeHooks_corruptJSON_throwsInvalidJSON() throws {
        try Data("{ not valid json".utf8).write(to: URL(fileURLWithPath: configPath))

        XCTAssertThrowsError(try ClaudeHooksConfigManager.removeHooks(configPath: configPath)) { error in
            XCTAssertEqual(error as? ConfigFileError, .invalidJSON,
                           "a corrupt config must throw invalidJSON, not silently no-op")
        }
    }

    // MARK: - Preserving unrecognized hook shapes

    func test_installHooks_unrecognizedEventShape_isLeftUntouched() throws {
        // A malformed/hand-edited/future-format value for one event
        // (here, a bare dict instead of the expected array-of-groups)
        // must survive installHooks verbatim rather than being silently
        // replaced with just Calyx's own group.
        let existingConfig: [String: Any] = [
            "hooks": [
                "Stop": ["unexpectedShape": true],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let hooks = dict["hooks"] as? [String: Any]
        let stopValue = hooks?["Stop"] as? [String: Any]
        XCTAssertEqual(stopValue?["unexpectedShape"] as? Bool, true,
                       "An unrecognized existing shape for an event must be left untouched, not discarded")
    }

    // MARK: - areHooksInstalled

    func test_areHooksInstalled_reflectsInstallState() throws {
        XCTAssertFalse(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "No config file yet -> hooks must not be reported as installed")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "After installHooks, hooks must be reported as installed")
    }

    // MARK: - dotfiles symlink real-environment reproduction
    //
    // This reproduces the exact layout that broke hooks in production:
    // `~/dotfiles/.claude/settings.json` holding the real, user-managed
    // content, with `~/.claude/settings.json` symlinked to it. Earlier
    // rounds' unit tests all passed against the old "reject symlinks"
    // contract precisely because they treated that contract as correct —
    // no test exercised this real directory shape. These do, with no
    // mocking of the filesystem.

    private func makeDotfilesFixture(existingConfig: [String: Any]) throws -> (dotfilesSettingsPath: String, homeSettingsPath: String) {
        let dotfilesDir = tempDir + "/dotfiles/.claude"
        let homeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)

        let dotfilesSettingsPath = dotfilesDir + "/settings.json"
        let data = try JSONSerialization.data(withJSONObject: existingConfig)
        try data.write(to: URL(fileURLWithPath: dotfilesSettingsPath))

        let homeSettingsPath = homeDir + "/settings.json"
        try FileManager.default.createSymbolicLink(atPath: homeSettingsPath, withDestinationPath: dotfilesSettingsPath)

        return (dotfilesSettingsPath, homeSettingsPath)
    }

    func test_installHooks_dotfilesSymlinkedSettingsJSON_writesRealFilePreservesUserHooksAndKeepsLinkIntact() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read", "write"]],
        ]
        let (dotfilesSettingsPath, homeSettingsPath) = try makeDotfilesFixture(existingConfig: existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: homeSettingsPath)

        // The real dotfiles-managed file received Calyx's 10 events...
        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        for eventName in Self.expectedEvents {
            XCTAssertFalse(hookGroups(realDict, event: eventName).isEmpty,
                           "\(eventName) must be installed into the real dotfiles-managed file")
        }

        // ...the user's own pre-existing PreToolUse hook survived alongside it...
        let preToolUseGroups = hookGroups(realDict, event: "PreToolUse")
        XCTAssertTrue(preToolUseGroups.contains { ($0["matcher"] as? String) == "Bash" },
                      "The user's existing 'Bash' matcher group must be preserved in the real file")

        // ...unrelated top-level keys survived too...
        let permissions = realDict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"])

        // ...and ~/.claude/settings.json is still a symlink, not replaced
        // by a plain file (a dotfiles manager tracking that path would
        // otherwise see it "go missing" from its symlink inventory).
        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "~/.claude/settings.json must remain a symlink after installHooks")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: homeSettingsPath)
        XCTAssertEqual(destination, dotfilesSettingsPath)
    }

    func test_installThenRemove_dotfilesSymlink_restoresRealFileAndKeepsLinkIntact() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
        ]
        let (dotfilesSettingsPath, homeSettingsPath) = try makeDotfilesFixture(existingConfig: existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: homeSettingsPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: homeSettingsPath)

        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])

        let preToolUseGroups = hookGroups(realDict, event: "PreToolUse")
        XCTAssertEqual(preToolUseGroups.count, 1, "Only the user's own PreToolUse group must remain in the real file")
        XCTAssertEqual(commandEntries(preToolUseGroups).first?["command"] as? String, "/usr/local/bin/user-hook")

        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "~/.claude/settings.json must remain a symlink after install+remove")
    }

    func test_installHooks_danglingDotfilesSymlink_createsRealFileAtLinkTarget() throws {
        // The classic "pre-linked, target not yet created" dotfiles state:
        // `chezmoi`/`stow`-style tooling can lay down the symlink before
        // the tracked file exists in the repo.
        let dotfilesDir = tempDir + "/dotfiles/.claude"
        let homeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        let dotfilesSettingsPath = dotfilesDir + "/settings.json"
        let homeSettingsPath = homeDir + "/settings.json"
        try FileManager.default.createSymbolicLink(atPath: homeSettingsPath, withDestinationPath: dotfilesSettingsPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dotfilesSettingsPath),
                       "Precondition: the symlink's target must not exist yet (dangling)")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: homeSettingsPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfilesSettingsPath),
                      "installHooks must create the file at the dangling symlink's target path")
        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty)

        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The now-resolved symlink must remain a symlink, not become a regular file")
    }

    // resolveConfigPath follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager.
    func test_installHooks_multiHopDanglingSymlink_createsRealFileAtFinalDestination() throws {
        let finalTarget = tempDir + "/dotfiles/.claude/settings.json"
        try FileManager.default.createDirectory(
            atPath: (finalTarget as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let middleLink = tempDir + "/middle-link.json"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalTarget),
                      "installHooks must create the file at the multi-hop dangling chain's final destination")
        let realData = try Data(contentsOf: URL(fileURLWithPath: finalTarget))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty)

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    func test_installHooks_symlinkedParentDotClaudeDirectory_writesThroughToRealDirectory() throws {
        // A less common but real dotfiles pattern: the whole `.claude`
        // directory is symlinked (`ln -s ~/dotfiles/.claude ~/.claude`)
        // rather than the individual settings.json file.
        let dotfilesClaudeDir = tempDir + "/dotfiles/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesClaudeDir, withIntermediateDirectories: true)
        let dotfilesSettingsPath = dotfilesClaudeDir + "/settings.json"
        try writeConfigDict(
            ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [
                ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
            ]]]]],
            to: dotfilesSettingsPath
        )

        let homeClaudeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(
            atPath: (homeClaudeDir as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: homeClaudeDir, withDestinationPath: dotfilesClaudeDir)
        let homeSettingsPath = homeClaudeDir + "/settings.json"

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: homeSettingsPath)

        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty,
                       "installHooks must write into the real directory reached through the symlinked parent")
        XCTAssertTrue(hookGroups(realDict, event: "PreToolUse").contains { ($0["matcher"] as? String) == "Bash" },
                      "The user's existing hook in the real directory must be preserved")

        let parentAttrs = try FileManager.default.attributesOfItem(atPath: homeClaudeDir)
        XCTAssertEqual(parentAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlinked .claude directory itself must remain a symlink")
    }

    // MARK: - Wake entry (Stop / SessionStart)

    // Stop and SessionStart are the two events whose Calyx group holds a
    // second entry, the wake entry, after the monitor entry. Claude Code
    // runs a hook entry marked asyncRewake in the background and wakes
    // an idle session when it exits 2, so the entry's exact keys matter:
    // without "async" or "asyncRewake" it would block the turn or never
    // wake anything.
    func test_installHooks_stopAndSessionStart_groupIsMonitorThenWakeEntryWithExactShapes() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.wakeEvents {
            let groups = hookGroups(dict, event: eventName)
            XCTAssertEqual(groups.count, 1, "\(eventName) must hold exactly one group on a fresh install")
            let group = groups.first ?? [:]
            XCTAssertNil(group["matcher"], "\(eventName)'s group must have no \"matcher\" key")
            XCTAssertEqual(Set(group.keys), ["hooks"], "\(eventName)'s group must hold the \"hooks\" key only")

            let entries = (group["hooks"] as? [[String: Any]]) ?? []
            XCTAssertEqual(entries.count, 2,
                           "\(eventName)'s group must hold exactly two entries: monitor, then wake")
            guard entries.count == 2 else { continue }

            let monitor = entries[0]
            XCTAssertEqual(Set(monitor.keys), ["type", "command", "timeout", "async"],
                           "\(eventName)'s first entry must be the unchanged monitor entry, without an " +
                           "\"asyncRewake\" key")
            XCTAssertEqual(monitor["type"] as? String, "command")
            XCTAssertEqual(monitor["command"] as? String, "\"\(scriptPath!)\"",
                           "\(eventName)'s first entry must be the monitor entry")
            XCTAssertEqual(monitor["timeout"] as? Int, 5, "\(eventName)'s monitor entry keeps its 5 second timeout")
            XCTAssertTrue(isJSONTrue(monitor["async"]), "\(eventName)'s monitor entry must stay async")
            XCTAssertNil(monitor["asyncRewake"], "\(eventName)'s monitor entry must not be marked asyncRewake")

            let wake = entries[1]
            XCTAssertEqual(Set(wake.keys), ["type", "command", "timeout", "async", "asyncRewake"],
                           "\(eventName)'s wake entry must hold exactly these five keys")
            XCTAssertEqual(wake["type"] as? String, "command")
            XCTAssertEqual(wake["command"] as? String, "\"\(wakeScriptPath!)\"",
                           "\(eventName)'s second entry must be the wake entry: the quoted wake script path")
            XCTAssertEqual(wake["timeout"] as? Int, IPCWakeHookTiming.hookEntryTimeoutSeconds,
                           "\(eventName)'s wake entry timeout must be IPCWakeHookTiming.hookEntryTimeoutSeconds")
            XCTAssertEqual(wake["timeout"] as? Int, 600, "\(eventName)'s wake entry timeout must be 600 seconds")
            XCTAssertTrue(isJSONTrue(wake["async"]),
                          "\(eventName)'s wake entry must be async (JSON true), so it never blocks the turn")
            XCTAssertTrue(isJSONTrue(wake["asyncRewake"]),
                          "\(eventName)'s wake entry must be asyncRewake (JSON true), so exit 2 wakes the session")
        }
    }

    func test_installHooks_eventsOtherThanStopAndSessionStart_carryNoWakeEntry() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let otherEvents = Self.expectedEvents.filter { !Self.wakeEvents.contains($0) }
        XCTAssertEqual(otherEvents.count, 8, "Eight of the ten events carry no wake entry")

        for eventName in otherEvents {
            let commands = commandEntries(hookGroups(dict, event: eventName))
            XCTAssertFalse(commands.isEmpty, "\(eventName) must still carry its monitor entry")
            XCTAssertFalse(commands.contains { (($0["command"] as? String) ?? "").contains(wakeScriptPath) },
                           "\(eventName) must not reference the wake script: only Stop and SessionStart do")
            XCTAssertFalse(commands.contains { $0["asyncRewake"] != nil },
                           "\(eventName) must hold no entry with an \"asyncRewake\" key")
        }
    }

    // A config written before the wake entry existed: one Calyx group
    // per event holding the monitor entry (PermissionRequest: monitor +
    // approval), with the matcher each event uses. installHooks is its
    // own upgrade path, so Stop and SessionStart must end up with one
    // Calyx group, [monitor, wake], and nothing else may change.
    func test_installHooks_upgradeFromConfigWithoutWakeEntry_addsWakeEntryWithoutDuplicatingOrTouchingAnythingElse() throws {
        let userStopGroup: [String: Any] = ["hooks": [
            ["type": "command", "command": "/usr/local/bin/user-stop-hook", "timeout": 3],
        ]]
        var oldHooks: [String: Any] = [:]
        for eventName in Self.expectedEvents {
            let entries = eventName == "PermissionRequest" ? [monitorEntry, approvalEntry] : [monitorEntry]
            var group: [String: Any] = ["hooks": entries]
            if let matcher = Self.expectedMatcherByEvent[eventName] {
                group["matcher"] = matcher
            }
            oldHooks[eventName] = eventName == "Stop" ? [group, userStopGroup] : [group]
        }
        try writeConfigDict(["hooks": oldHooks])
        let before = try readConfigDict()

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let after = try readConfigDict()

        for eventName in Self.wakeEvents {
            let groups = hookGroups(after, event: eventName)
            let ownGroups = calyxGroups(groups)
            XCTAssertEqual(ownGroups.count, 1,
                           "\(eventName) must hold exactly one Calyx group after the upgrade, not a second one " +
                           "next to the old one")
            let entries = (ownGroups.first?["hooks"] as? [[String: Any]]) ?? []
            XCTAssertEqual(entries as NSArray, [monitorEntry, wakeEntry] as NSArray,
                           "\(eventName)'s Calyx group must be exactly [monitor, wake] after the upgrade")
            XCTAssertNil(ownGroups.first?["matcher"], "\(eventName)'s Calyx group must have no \"matcher\" key")
            XCTAssertEqual(commandEntries(groups).filter { ($0["command"] as? String) == monitorCommand }.count, 1,
                           "\(eventName)'s monitor entry must not be duplicated by the upgrade")
        }

        let stopGroups = hookGroups(after, event: "Stop")
        XCTAssertEqual(stopGroups.count, 2, "Stop must hold the user's group and Calyx's group, nothing else")
        let foreignStopGroups = stopGroups.filter { group in
            !((group["hooks"] as? [[String: Any]]) ?? []).contains { isCalyxEntry($0) }
        }
        XCTAssertEqual(foreignStopGroups as NSArray, [userStopGroup] as NSArray,
                       "The user's own Stop group must survive the upgrade unchanged")
        XCTAssertEqual(hookGroups(after, event: "SessionStart").count, 1,
                       "SessionStart must hold Calyx's group only")

        for eventName in Self.expectedEvents where !Self.wakeEvents.contains(eventName) {
            XCTAssertEqual(hookGroups(after, event: eventName) as NSArray,
                           hookGroups(before, event: eventName) as NSArray,
                           "\(eventName) carries no wake entry, so the upgrade must leave its groups as they were")
        }
    }

    // withExclusiveConfig writes nothing when the transform returns the
    // bytes it read. The wake entry's keys must therefore compare equal
    // to what a previous install wrote, or every launch-time resync
    // would rewrite a file Claude Code itself writes to.
    func test_installHooks_reinstallWithWakeEntries_leavesFileBytesIdentical() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))

        let first = try readConfigDict()
        for eventName in Self.wakeEvents {
            XCTAssertEqual(
                commandEntries(hookGroups(first, event: eventName)).filter { ($0["command"] as? String) == wakeCommand }.count, 1,
                "Precondition: the first install must have written \(eventName)'s wake entry, or this test " +
                "says nothing about a reinstall over wake entries"
            )
        }

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(secondBytes, firstBytes,
                       "A second installHooks with the same arguments must leave settings.json byte-identical")
    }

    // The same reinstall, over a config in which the user has their own
    // group on Stop and on SessionStart and nothing else. The second
    // call finds Calyx's groups next to the user's and must still produce
    // the bytes the first call wrote.
    func test_installHooks_reinstallNextToUserGroupsOnStopAndSessionStart_leavesFileBytesIdentical() throws {
        let userStopGroup: [String: Any] = ["hooks": [
            ["type": "command", "command": "/usr/local/bin/user-stop-hook", "timeout": 3],
        ]]
        let userSessionStartGroup: [String: Any] = ["matcher": "startup", "hooks": [
            ["type": "command", "command": "/usr/local/bin/user-session-start-hook"],
        ]]
        try writeConfigDict(["hooks": ["Stop": [userStopGroup], "SessionStart": [userSessionStartGroup]]])
        let userGroupByEvent = ["Stop": userStopGroup, "SessionStart": userSessionStartGroup]

        // The groups of one event that hold no Calyx entry.
        func foreignGroups(_ dict: [String: Any], event: String) -> [[String: Any]] {
            hookGroups(dict, event: event).filter { group in
                !((group["hooks"] as? [[String: Any]]) ?? []).contains { isCalyxEntry($0) }
            }
        }

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))

        let first = try readConfigDict()
        for eventName in Self.wakeEvents {
            let groups = hookGroups(first, event: eventName)
            XCTAssertEqual(groups.count, 2,
                           "Precondition: after the first install \(eventName) holds the user's group and " +
                           "Calyx's group, or this test says nothing about a reinstall next to a user group")
            XCTAssertEqual(calyxGroups(groups).count, 1,
                           "Precondition: the first install wrote one Calyx group on \(eventName)")
            XCTAssertEqual(
                commandEntries(groups).filter { ($0["command"] as? String) == wakeCommand }.count, 1,
                "Precondition: the first install wrote \(eventName)'s wake entry")
            XCTAssertEqual(foreignGroups(first, event: eventName) as NSArray,
                           [userGroupByEvent[eventName]!] as NSArray,
                           "The user's own \(eventName) group must be unchanged after the first install")
        }

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            secondBytes, firstBytes,
            "A second installHooks with the same arguments must leave settings.json byte-identical when " +
            "the user has their own Stop and SessionStart groups.\nAfter the first call:\n" +
            "\(String(decoding: firstBytes, as: UTF8.self))\nAfter the second call:\n" +
            "\(String(decoding: secondBytes, as: UTF8.self))")

        let second = try readConfigDict()
        for eventName in Self.wakeEvents {
            XCTAssertEqual(hookGroups(second, event: eventName).count, 2,
                           "\(eventName) must still hold exactly the user's group and Calyx's group")
            XCTAssertEqual(foreignGroups(second, event: eventName) as NSArray,
                           [userGroupByEvent[eventName]!] as NSArray,
                           "The user's own \(eventName) group must be unchanged after the second install")
        }
    }

    // The full install -> remove round trip with a user's own Stop hook
    // sitting next to Calyx's group: removeHooks must take out all three
    // kinds of Calyx entry, the wake entry included, and nothing else.
    func test_installThenRemove_removesWakeEntriesAndPreservesUserHook() throws {
        let userStopGroup: [String: Any] = ["hooks": [
            ["type": "command", "command": "/usr/local/bin/user-stop-hook", "timeout": 3],
        ]]
        try writeConfigDict(["hooks": ["Stop": [userStopGroup]]])

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, wakeScriptPath: wakeScriptPath, configPath: configPath)

        let installed = try readConfigDict()
        for eventName in Self.wakeEvents {
            XCTAssertEqual(
                commandEntries(hookGroups(installed, event: eventName)).filter { ($0["command"] as? String) == wakeCommand }.count, 1,
                "Precondition: installHooks must have written \(eventName)'s wake entry, or this test says " +
                "nothing about removing one"
            )
        }

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        for fileName in Self.calyxScriptFileNames.sorted() {
            XCTAssertFalse(text.contains(fileName),
                           "removeHooks must leave no reference to \(fileName) anywhere in settings.json")
        }

        let removed = try readConfigDict()
        let hooks = removed["hooks"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(hooks.keys), ["Stop"],
                       "Only Stop, which holds the user's own hook, may remain under \"hooks\"")
        XCTAssertEqual(hookGroups(removed, event: "Stop") as NSArray, [userStopGroup] as NSArray,
                       "The user's own Stop group must survive install -> remove unchanged")
    }

    // A hand-written Stop group holding a user's entry and a wake entry
    // side by side. removeHooks must recognize the wake entry by its
    // file name alone and remove only it: the user's entry keeps its
    // text (key order included) and stays the first entry of the first
    // group.
    func test_removeHooks_groupMixingUserEntryAndWakeEntry_keepsUserEntryInPlaceAndRemovesOnlyWakeEntry() throws {
        let userEntryText =
            "{\n            \"type\": \"command\",\n            \"command\": \"/usr/local/bin/user-stop-hook\",\n" +
            "            \"timeout\": 3\n          }"
        writeConfig(
            "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          " + userEntryText + ",\n" +
            "          {\n            \"type\": \"command\",\n" +
            "            \"command\": \"\\\"/opt/calyx/bin/calyx-ipc-wake-hook\\\"\",\n" +
            "            \"timeout\": 600,\n            \"async\": true,\n            \"asyncRewake\": true\n          }\n" +
            "        ]\n      },\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n" +
            "            \"command\": \"/usr/local/bin/other-user-hook\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        )

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertFalse(text.contains("calyx-ipc-wake-hook"),
                       "removeHooks must remove the wake entry: it is Calyx's own by its file name")
        XCTAssertTrue(text.contains(userEntryText),
                      "The user's entry must keep its original text, key order included")

        let groups = hookGroups(try readConfigDict(), event: "Stop")
        let expectedGroups: [[String: Any]] = [
            ["hooks": [["type": "command", "command": "/usr/local/bin/user-stop-hook", "timeout": 3]]],
            ["hooks": [["type": "command", "command": "/usr/local/bin/other-user-hook"]]],
        ]
        XCTAssertEqual(groups as NSArray, expectedGroups as NSArray,
                       "Both groups must stay where they were; the first one loses only its wake entry")
    }

    // Mirrors test_areHooksInstalled_trueWhenOnlyApprovalEntryPresent: a
    // wake entry alone marks the config as carrying Calyx's hooks, so a
    // launch-time resync and remove() both act on it.
    func test_areHooksInstalled_trueWhenOnlyWakeEntryPresent() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [wakeEntry]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                     "areHooksInstalled must recognize the wake entry alone, without the monitor " +
                     "entry present")
    }
}
