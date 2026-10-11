// WorktreeTaskCoordinatorTests.swift
// CalyxTests
//
// Pins WorktreeTaskCoordinator (Revision 1): it owns the Worktree Task
// orchestration behind the WorktreeTaskHost protocol. Real git work runs
// against GitScratch repositories; every window-side effect goes through
// FakeWorktreeTaskHost, which records the calls in order.

import Foundation
import Testing
@testable import Calyx

@MainActor
final class FakeWorktreeTaskHost: WorktreeTaskHost {
    var focusedPaneCwd: String?
    var sessionRoot: String
    var loginShell: String = "/bin/zsh"
    var panes: [CockpitPaneInfo] = []
    var confirmAnswer = true
    /// What `openTaskPane` returns; nil simulates a failed tab creation.
    var openTaskPaneResult: UUID? = UUID()
    /// When true, `confirmDiscard` suspends until `resumeConfirm(_:)`.
    var suspendConfirm = false

    /// Call names in order.
    private(set) var calls: [String] = []
    private(set) var presentedSheetCwds: [String?] = []
    private(set) var presentedOnCreate: ((WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void)?
    private(set) var presentedArgumentMemories: [WorktreeTaskArgumentMemory?] = []
    private(set) var busyStates: [Bool] = []
    private(set) var openedPanes: [(cwd: String, spawnArgv: [String])] = []
    private(set) var closedPanes: [(surfaceIDs: [UUID], replacementCwd: String)] = []
    /// Whether `pathToWatch` existed on disk when `closePanes` was called.
    var pathToWatch: String?
    private(set) var pathExistedAtClose: [Bool] = []
    private(set) var errors: [Error] = []
    private(set) var confirmBranches: [String] = []

    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var confirmReachedContinuation: CheckedContinuation<Void, Never>?
    private var confirmReached = false

    init(sessionRoot: String) {
        self.sessionRoot = sessionRoot
    }

    func presentTaskSheet(
        cwd: String?,
        argumentMemory: WorktreeTaskArgumentMemory?,
        onCreate: @escaping (WorktreeTaskRequest, WorktreeTaskRepositoryDescription) -> Void
    ) {
        calls.append("presentTaskSheet")
        presentedSheetCwds.append(cwd)
        presentedArgumentMemories.append(argumentMemory)
        presentedOnCreate = onCreate
    }

    func dismissTaskSheet() { calls.append("dismissTaskSheet") }

    func setTaskSheetBusy(_ busy: Bool) {
        calls.append("setTaskSheetBusy")
        busyStates.append(busy)
    }

    func openTaskPane(cwd: String, spawnArgv: [String]) -> UUID? {
        calls.append("openTaskPane")
        openedPanes.append((cwd, spawnArgv))
        return openTaskPaneResult
    }

    func listPanes() -> [CockpitPaneInfo] {
        calls.append("listPanes")
        return panes
    }

    func closePanes(surfaceIDs: [UUID], replacementCwd: String) {
        calls.append("closePanes")
        closedPanes.append((surfaceIDs, replacementCwd))
        if let pathToWatch {
            pathExistedAtClose.append(FileManager.default.fileExists(atPath: pathToWatch))
        }
    }

    func refreshGitSidebar() { calls.append("refreshGitSidebar") }

    func presentError(_ error: Error) {
        calls.append("presentError")
        errors.append(error)
    }

    func confirmDiscard(branch: String) async -> Bool {
        calls.append("confirmDiscard")
        confirmBranches.append(branch)
        guard suspendConfirm else { return confirmAnswer }
        return await withCheckedContinuation { continuation in
            confirmContinuation = continuation
            confirmReached = true
            confirmReachedContinuation?.resume()
            confirmReachedContinuation = nil
        }
    }

    /// Returns once `confirmDiscard` is suspended.
    func waitUntilConfirmReached() async {
        if confirmReached { return }
        await withCheckedContinuation { confirmReachedContinuation = $0 }
    }

    func resumeConfirm(_ answer: Bool) {
        confirmContinuation?.resume(returning: answer)
        confirmContinuation = nil
    }

    /// `calls` without the busy toggles and pane listing.
    var effectCalls: [String] {
        calls.filter { $0 != "setTaskSheetBusy" && $0 != "listPanes" }
    }
}

@MainActor
struct WorktreeTaskCoordinatorTests {

    private struct Fixture {
        let scratch: URL
        let repo: URL
        let description: WorktreeTaskRepositoryDescription
        let host: FakeWorktreeTaskHost
        let ledger: WorktreeTaskOperationLedger
        let coordinator: WorktreeTaskCoordinator
        /// Where the coordinator puts a task for `branch` (sessionRoot = scratch).
        func taskPath(_ leaf: String) -> String {
            scratch.path + "/.calyx/worktrees/myrepo/" + leaf
        }
    }

    private func makeFixture() async throws -> Fixture {
        let scratch = try GitScratch.makeDirectory("WorktreeTaskCoordinatorTests")
        let repo = scratch.appendingPathComponent("myrepo")
        try GitScratch.run(["init", "-q", "-b", "main", repo.path], in: scratch)
        try GitScratch.configureIdentity(in: repo)
        try GitScratch.commit(file: "base.txt", contents: "base\n", message: "base", in: repo)
        let description = try await WorktreeTaskService.describeRepository(cwd: repo.path)
        let host = FakeWorktreeTaskHost(sessionRoot: scratch.path)
        let ledger = WorktreeTaskOperationLedger()
        return Fixture(
            scratch: scratch, repo: repo, description: description,
            host: host, ledger: ledger,
            coordinator: WorktreeTaskCoordinator(host: host, ledger: ledger)
        )
    }

    /// Creates `task/demo` directly through the service (not under test
    /// here) at the path the coordinator would use.
    private func makeTask(_ fixture: Fixture) async throws -> String {
        let path = fixture.taskPath("task-demo")
        _ = try await WorktreeTaskService.create(
            request: WorktreeTaskRequest(branch: "task/demo", base: "main", agent: .claudeCode, prompt: ""),
            location: fixture.description.location,
            repoDisplayName: "myrepo",
            path: path
        )
        return path
    }

    private func branchExists(_ branch: String, in repo: URL) throws -> Bool {
        !(try GitScratch.run(["branch", "--list", branch], in: repo)).isEmpty
    }

    private func pane(_ id: UUID, cwd: String?) -> CockpitPaneInfo {
        CockpitPaneInfo(
            surfaceID: id, windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "Shell", title: nil, cwd: cwd, isFocused: false,
            agentKind: nil, calyxSessionID: nil
        )
    }

    // MARK: - presentSheet

    @Test func test_presentSheet_passesFocusedPaneCwd() async throws {
        let host = FakeWorktreeTaskHost(sessionRoot: "/unused")
        host.focusedPaneCwd = "/Users/dev/repo/src"
        let coordinator = WorktreeTaskCoordinator(host: host)

        coordinator.presentSheet()

        #expect(host.calls == ["presentTaskSheet"])
        #expect(host.presentedSheetCwds == ["/Users/dev/repo/src"])
        #expect(host.presentedOnCreate != nil)
    }

    @Test func test_presentSheet_nilCwdPassedThrough() async throws {
        let host = FakeWorktreeTaskHost(sessionRoot: "/unused")
        let coordinator = WorktreeTaskCoordinator(host: host)

        coordinator.presentSheet()

        #expect(host.presentedSheetCwds == [nil])
    }

    // MARK: - create

    @Test func test_create_addsWorktreeThenDismissesOpensSpawnedPaneAndRefreshes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = fixture.taskPath("task-demo")

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(branch: "task/demo", base: "main", agent: .claudeCode, prompt: "  hi there\n"),
            repository: fixture.description
        )

        #expect(fixture.host.errors.isEmpty, "unexpected errors: \(fixture.host.errors)")
        #expect(FileManager.default.fileExists(atPath: path + "/base.txt"))
        #expect(try GitScratch.run(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: path)) == "task/demo")
        #expect(fixture.host.effectCalls == ["dismissTaskSheet", "openTaskPane", "refreshGitSidebar"])
        #expect(fixture.host.openedPanes.count == 1)
        #expect(fixture.host.openedPanes.first?.cwd == path)
        #expect(fixture.host.openedPanes.first?.spawnArgv == ["/bin/zsh", "-i", "-l", "-c", "exec 'claude' 'hi there'"])
        #expect(fixture.host.busyStates.first != false, "if the sheet is marked busy, it is marked busy first")
    }

    /// The coordinator uses the host's shell as is; resolving it (passwd,
    /// `$SHELL`, non-POSIX fallback) is the host's job, pinned by
    /// `WorktreeTaskPlanner.loginShell`'s tests.
    @Test func test_create_usesHostLoginShell() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        fixture.host.loginShell = "/opt/homebrew/bin/bash"

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(branch: "t2", base: "main", agent: .hermes, prompt: ""),
            repository: fixture.description
        )

        #expect(fixture.host.openedPanes.first?.cwd == fixture.taskPath("t2"))
        #expect(fixture.host.openedPanes.first?.spawnArgv == ["/opt/homebrew/bin/bash", "-i", "-l", "-c", "exec 'hermes' 'chat'"])
    }

    @Test func test_create_paneNotOpened_presentsPaneErrorKeepsWorktreeAndRefreshes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        fixture.host.openTaskPaneResult = nil
        let path = fixture.taskPath("task-demo")

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(branch: "task/demo", base: "main", agent: .claudeCode, prompt: ""),
            repository: fixture.description
        )

        #expect(fixture.host.effectCalls == ["dismissTaskSheet", "openTaskPane", "presentError", "refreshGitSidebar"])
        #expect(fixture.host.errors.count == 1)
        #expect(fixture.host.errors.first as? WorktreeTaskError == .paneCreationFailed(path))
        #expect(FileManager.default.fileExists(atPath: path + "/base.txt"), "the worktree is not rolled back")
        #expect(try branchExists("task/demo", in: fixture.repo))
    }

    @Test func test_create_launchArgvOverride_replacesAgentArgv() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let coordinator = WorktreeTaskCoordinator(
            host: fixture.host,
            ledger: WorktreeTaskOperationLedger(),
            launchArgvOverride: ["/bin/sleep", "60"]
        )

        await coordinator.create(
            request: WorktreeTaskRequest(branch: "t3", base: "main", agent: .claudeCode, prompt: "ignored"),
            repository: fixture.description
        )

        #expect(fixture.host.openedPanes.first?.spawnArgv == ["/bin/zsh", "-i", "-l", "-c", "exec '/bin/sleep' '60'"])
    }

    @Test func test_create_argumentsGoBetweenProgramAndPrompt() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(
                branch: "t5", base: "main", agent: .claudeCode, prompt: "hi",
                arguments: ["--model", "opus"], argumentsText: "--model opus"
            ),
            repository: fixture.description
        )

        #expect(fixture.host.errors.isEmpty, "unexpected errors: \(fixture.host.errors)")
        #expect(fixture.host.openedPanes.first?.spawnArgv
            == ["/bin/zsh", "-i", "-l", "-c", "exec 'claude' '--model' 'opus' '--' 'hi'"])
    }

    @Test func test_create_success_remembersArgumentsTextForAgent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        memory.remember("--old", for: .claudeCode)
        let coordinator = WorktreeTaskCoordinator(
            host: fixture.host, ledger: WorktreeTaskOperationLedger(), argumentMemory: memory
        )

        await coordinator.create(
            request: WorktreeTaskRequest(
                branch: "t6", base: "main", agent: .codex, prompt: "",
                arguments: ["--model", "o3"], argumentsText: "--model 'o3'"
            ),
            repository: fixture.description
        )

        #expect(memory.arguments(for: .codex) == "--model 'o3'")
        #expect(memory.arguments(for: .claudeCode) == "--old", "other kinds are untouched")
    }

    @Test func test_create_serviceError_doesNotRememberArguments() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let memory = WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        let coordinator = WorktreeTaskCoordinator(
            host: fixture.host, ledger: WorktreeTaskOperationLedger(), argumentMemory: memory
        )

        await coordinator.create(
            request: WorktreeTaskRequest(
                branch: "bad..name", base: "main", agent: .codex, prompt: "",
                arguments: ["--x"], argumentsText: "--x"
            ),
            repository: fixture.description
        )

        #expect(fixture.host.errors.count == 1)
        #expect(memory.arguments(for: .codex) == "")
    }

    /// The sheet's model and the coordinator share one memory: what a
    /// created task remembered is what the next sheet reads.
    @Test func test_presentSheet_passesTheCoordinatorsMemoryToTheSheet() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let scratch = ScratchDefaults()
        defer { scratch.cleanup() }
        let coordinator = WorktreeTaskCoordinator(
            host: fixture.host, ledger: WorktreeTaskOperationLedger(),
            argumentMemory: WorktreeTaskArgumentMemory(defaults: scratch.defaults)
        )
        await coordinator.create(
            request: WorktreeTaskRequest(
                branch: "t7", base: "main", agent: .codex, prompt: "",
                arguments: ["--model", "o3"], argumentsText: "--model o3"
            ),
            repository: fixture.description
        )

        coordinator.presentSheet()

        let memory = try #require(fixture.host.presentedArgumentMemories.last ?? nil)
        let model = WorktreeTaskSheetModel(argumentMemory: memory)
        model.agent = .codex
        #expect(model.argumentsText == "--model o3")
    }

    /// Two creates in quick succession (a double submit) run the service
    /// once: the second would otherwise fail on the existing branch and
    /// present an error.
    @Test func test_create_secondCreateWhileOneIsRunning_isIgnored() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let request = WorktreeTaskRequest(branch: "t8", base: "main", agent: .claudeCode, prompt: "")
        let coordinator = fixture.coordinator
        let description = fixture.description

        let first = Task { await coordinator.create(request: request, repository: description) }
        let second = Task { await coordinator.create(request: request, repository: description) }
        await first.value
        await second.value

        #expect(fixture.host.errors.isEmpty, "unexpected errors: \(fixture.host.errors)")
        #expect(fixture.host.openedPanes.count == 1)
        #expect(fixture.host.effectCalls == ["dismissTaskSheet", "openTaskPane", "refreshGitSidebar"])
    }

    @Test func test_create_hermesPrompt_isNotPassed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(branch: "t4", base: "main", agent: .hermes, prompt: "do it"),
            repository: fixture.description
        )

        #expect(fixture.host.openedPanes.first?.spawnArgv == ["/bin/zsh", "-i", "-l", "-c", "exec 'hermes' 'chat'"])
    }

    // MARK: - UI-test argv override resolution

    @Test func test_uiTestLaunchArgvOverride_onlyUnderUITestingAndNonEmpty() {
        let key = CalyxWindowController.worktreeTaskUITestLaunchArgvEnvironmentKey
        let resolve = CalyxWindowController.worktreeTaskUITestLaunchArgvOverride
        #expect(key == "CALYX_UITEST_WORKTREE_TASK_ARGV")
        #expect(resolve(["Calyx", "--uitesting"], [key: "/bin/sh\u{1F}-c\u{1F}echo hi"]) == ["/bin/sh", "-c", "echo hi"])
        #expect(resolve(["Calyx"], [key: "/bin/sh"]) == nil, "ignored outside --uitesting")
        #expect(resolve(["Calyx", "--uitesting"], [:]) == nil)
        #expect(resolve(["Calyx", "--uitesting"], [key: ""]) == nil)
        #expect(resolve(["Calyx", "--uitesting"], [key: "\u{1F}\u{1F}"]) == nil)
        #expect(resolve(["Calyx", "--uitesting"], [key: "\u{1F}/bin/sh\u{1F}\u{1F}-c"]) == ["/bin/sh", "-c"])
    }

    @Test func test_create_serviceError_presentsErrorKeepsSheetOpenAndOpensNoPane() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }

        await fixture.coordinator.create(
            request: WorktreeTaskRequest(branch: "bad..name", base: "main", agent: .claudeCode, prompt: "x"),
            repository: fixture.description
        )

        #expect(fixture.host.busyStates == [true, false])
        #expect(fixture.host.errors.count == 1)
        #expect(fixture.host.errors.first as? WorktreeTaskError == .invalidBranchName("bad..name"))
        #expect(!fixture.host.calls.contains("dismissTaskSheet"))
        #expect(fixture.host.openedPanes.isEmpty)
        #expect(!fixture.host.calls.contains("refreshGitSidebar"))
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPath("bad..name")))
    }

    // MARK: - merge

    @Test func test_merge_mergesRemovesWorktreeAndBranchThenClosesInsidePanesThenRefreshes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        let mainBefore = try GitScratch.run(["rev-parse", "main"], in: fixture.repo)
        try GitScratch.commit(file: "task.txt", contents: "task\n", message: "task work", in: URL(fileURLWithPath: path))
        let taskCommit = try GitScratch.run(["rev-parse", "task/demo"], in: fixture.repo)
        let inside = UUID(), outside = UUID()
        fixture.host.panes = [pane(inside, cwd: path + "/src"), pane(outside, cwd: fixture.repo.path)]
        fixture.host.pathToWatch = path

        await fixture.coordinator.merge(worktreeRoot: path)

        #expect(fixture.host.errors.isEmpty, "unexpected errors: \(fixture.host.errors)")
        let parents = try GitScratch.run(["rev-list", "--parents", "-n", "1", "main"], in: fixture.repo)
            .split(separator: " ").map(String.init)
        #expect(parents.count == 3, "main must end on a merge commit")
        #expect(Array(parents.dropFirst()) == [mainBefore, taskCommit])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try !branchExists("task/demo", in: fixture.repo))
        #expect(fixture.host.closedPanes.count == 1)
        #expect(fixture.host.closedPanes.first?.surfaceIDs == [inside])
        #expect(fixture.host.closedPanes.first?.replacementCwd == fixture.repo.path)
        #expect(fixture.host.pathExistedAtClose == [false], "panes close only after git removed the worktree")
        #expect(fixture.host.effectCalls.last == "refreshGitSidebar")
        #expect(fixture.host.effectCalls.filter { $0 == "closePanes" || $0 == "refreshGitSidebar" }
            == ["closePanes", "refreshGitSidebar"])
        #expect(fixture.coordinator.inFlightRoots.isEmpty)
    }

    @Test func test_merge_dirtyTask_presentsErrorAndLeavesEverything() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        try "dirty\n".write(toFile: path + "/base.txt", atomically: true, encoding: .utf8)
        fixture.host.panes = [pane(UUID(), cwd: path)]

        await fixture.coordinator.merge(worktreeRoot: path)

        #expect(fixture.host.errors.count == 1)
        #expect(fixture.host.errors.first as? WorktreeTaskError == .taskWorktreeDirty(path))
        #expect(!fixture.host.calls.contains("closePanes"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try branchExists("task/demo", in: fixture.repo))
        #expect(fixture.coordinator.inFlightRoots.isEmpty)
    }

    // MARK: - discard

    @Test func test_discard_declined_doesNothing() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        fixture.host.panes = [pane(UUID(), cwd: path)]
        fixture.host.confirmAnswer = false

        await fixture.coordinator.discard(worktreeRoot: path)

        #expect(fixture.host.confirmBranches == ["task/demo"])
        #expect(fixture.host.effectCalls == ["confirmDiscard"])
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try branchExists("task/demo", in: fixture.repo))
        #expect(fixture.coordinator.inFlightRoots.isEmpty)
    }

    @Test func test_discard_confirmed_removesWorktreeAndBranchClosesPanesRefreshes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        try "unsaved\n".write(toFile: path + "/scratch.txt", atomically: true, encoding: .utf8)
        try GitScratch.commit(file: "wip.txt", contents: "wip\n", message: "wip", in: URL(fileURLWithPath: path))
        let inside = UUID(), outside = UUID()
        fixture.host.panes = [pane(inside, cwd: path), pane(outside, cwd: "/elsewhere")]
        fixture.host.pathToWatch = path
        fixture.host.confirmAnswer = true

        await fixture.coordinator.discard(worktreeRoot: path)

        #expect(fixture.host.errors.isEmpty, "unexpected errors: \(fixture.host.errors)")
        #expect(fixture.host.confirmBranches == ["task/demo"])
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try !branchExists("task/demo", in: fixture.repo))
        #expect(fixture.host.closedPanes.count == 1)
        #expect(fixture.host.closedPanes.first?.surfaceIDs == [inside])
        #expect(fixture.host.closedPanes.first?.replacementCwd == fixture.repo.path)
        #expect(fixture.host.pathExistedAtClose == [false])
        #expect(fixture.host.effectCalls == ["confirmDiscard", "closePanes", "refreshGitSidebar"])
        #expect(fixture.coordinator.inFlightRoots.isEmpty)
    }

    // MARK: - Re-entrancy

    @Test func test_secondOperationOnSameRoot_whileOneIsRunning_reportsInProgress() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        try GitScratch.commit(file: "task.txt", contents: "task\n", message: "task", in: URL(fileURLWithPath: path))
        fixture.host.panes = [pane(UUID(), cwd: path)]
        fixture.host.suspendConfirm = true
        let coordinator = fixture.coordinator
        let root = GitRepositoryLocation.standardize(path)

        let first = Task { @MainActor in await coordinator.discard(worktreeRoot: path) }
        await fixture.host.waitUntilConfirmReached()
        #expect(coordinator.inFlightRoots == [root])
        let callsBefore = fixture.host.calls

        await coordinator.merge(worktreeRoot: path)
        await coordinator.discard(worktreeRoot: path)

        #expect(fixture.host.calls == callsBefore + ["presentError", "presentError"])
        #expect(fixture.host.errors.compactMap { $0 as? WorktreeTaskError }
            == [.operationInProgress("task/demo"), .operationInProgress("task/demo")])
        #expect(fixture.host.confirmBranches.count == 1)
        #expect(FileManager.default.fileExists(atPath: path), "the merge must not have run")
        #expect(try GitScratch.run(["rev-list", "--count", "main"], in: fixture.repo) == "1")
        #expect(coordinator.inFlightRoots == [root])

        fixture.host.resumeConfirm(false)
        await first.value

        #expect(coordinator.inFlightRoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(fixture.host.errors.count == 2)
    }

    /// Two windows' coordinators share one ledger, so the second window's
    /// request is reported in its own window instead of racing.
    @Test func test_operationInAnotherCoordinatorSharingTheLedger_reportsInProgress() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.scratch) }
        let path = try await makeTask(fixture)
        fixture.host.suspendConfirm = true
        let otherHost = FakeWorktreeTaskHost(sessionRoot: fixture.scratch.path)
        let other = WorktreeTaskCoordinator(host: otherHost, ledger: fixture.ledger)

        let first = Task { @MainActor in await fixture.coordinator.discard(worktreeRoot: path) }
        await fixture.host.waitUntilConfirmReached()

        await other.merge(worktreeRoot: path)

        #expect(otherHost.errors.compactMap { $0 as? WorktreeTaskError } == [.operationInProgress("task/demo")])
        #expect(FileManager.default.fileExists(atPath: path), "the merge must not have run")

        fixture.host.resumeConfirm(false)
        await first.value
        #expect(other.inFlightRoots.isEmpty)
    }

    @Test func test_coordinatorsShareTheSharedLedgerByDefault() {
        let host = FakeWorktreeTaskHost(sessionRoot: "/unused")
        let a = WorktreeTaskCoordinator(host: host)
        let b = WorktreeTaskCoordinator(host: host)
        let key = "/tmp/calyx-ledger-default-\(UUID().uuidString)"
        #expect(WorktreeTaskOperationLedger.shared.begin(key))
        defer { WorktreeTaskOperationLedger.shared.end(key) }
        #expect(a.inFlightRoots.contains(key))
        #expect(b.inFlightRoots.contains(key))
    }
}
