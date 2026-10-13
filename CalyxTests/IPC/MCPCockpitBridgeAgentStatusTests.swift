//
//  MCPCockpitBridgeAgentStatusTests.swift
//  CalyxTests
//
//  The agent_status cases that depend on MCPCockpitBridge APIs planned by
//  Feature B (spec B.2), kept apart from MCPCockpitBridgeTests so that file
//  keeps compiling against the current bridge:
//
//  - init(..., inboxCounts:, usageSummaries:): a bound pane's
//    unread_count comes from the injected inbox-count reader (asked for
//    the bound peer), and usage comes from the injected
//    UsageLiveSummaries keyed by the agent row's session id
//  - handleToolCall(name:arguments:callerSurfaceID:): is_self is true
//    for exactly the caller's pane
//  - MissionMapSnapshotBuilder.approval(for:in:), no longer private:
//    agent_status's per-request `allowable` agrees with the Mission Map
//    card's rule for the same request, for every ApprovalRequest source
//

import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class AgentStatusFakeCockpitAccess: CockpitAppAccessing {
    var panes: [CockpitPaneInfo] = []

    func listPanes() -> [CockpitPaneInfo] { panes }
    func paneExists(_ id: UUID) -> Bool { panes.contains { $0.surfaceID == id } }
    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {}
    func sendKeys(surfaceID: UUID, text: String) throws {}
    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID { throw CockpitAccessError.appUnavailable }
    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab { throw CockpitAccessError.appUnavailable }
    func availablePaletteCommands() -> [CockpitPaletteCommand] { [] }
    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand { throw CockpitAccessError.appUnavailable }
}

/// Records which peer ids the bridge asked about and answers from a
/// fixed table.
private actor InboxCountProbe {
    private let counts: [UUID: Int]
    private(set) var askedPeerIDs: [UUID] = []

    init(counts: [UUID: Int]) { self.counts = counts }

    func inboxCounts(for peerIDs: [UUID]) -> [UUID: Int] {
        askedPeerIDs.append(contentsOf: peerIDs)
        var result: [UUID: Int] = [:]
        for peerID in peerIDs { result[peerID] = counts[peerID] ?? 0 }
        return result
    }
}

@MainActor
final class MCPCockpitBridgeAgentStatusTests: XCTestCase {

    // MARK: - Helpers

    private func pane(surfaceID: UUID = UUID()) -> CockpitPaneInfo {
        CockpitPaneInfo(
            surfaceID: surfaceID, windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "zsh", title: nil, cwd: nil, isFocused: false, agentKind: nil, calyxSessionID: nil
        )
    }

    private func panes(_ text: String) throws -> [String: [String: Any]] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(object["panes"] as? [String: [String: Any]], "panes must be keyed by surface_id: \(text)")
    }

    // MARK: - unread_count via the injected inbox-count reader

    func test_agentStatus_boundPane_unreadCountFromInjectedInboxCounts_unboundIsZero() async throws {
        let bound = pane()
        let unbound = pane()
        let access = AgentStatusFakeCockpitAccess()
        access.panes = [bound, unbound]
        let registry = AgentRegistry()
        let peerID = UUID()
        registry.bindSurface(bound.surfaceID, toPeer: peerID)
        let probe = InboxCountProbe(counts: [peerID: 3])
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(), agentRegistry: registry,
            inboxCounts: { peerIDs in await probe.inboxCounts(for: peerIDs) }
        )

        let text = try await bridge.handleToolCall(name: "agent_status", arguments: ["include_git": false])

        let result = try panes(text)
        XCTAssertEqual(result[bound.surfaceID.uuidString]?["peer_id"] as? String, peerID.uuidString)
        XCTAssertEqual(result[bound.surfaceID.uuidString]?["unread_count"] as? Int, 3,
                       "unread_count must come from the inbox-count reader, not the agent row")
        XCTAssertEqual(result[unbound.surfaceID.uuidString]?["unread_count"] as? Int, 0)
        let asked = await probe.askedPeerIDs
        XCTAssertTrue(asked.contains(peerID), "the bound peer's count must be asked for")
    }

    // MARK: - is_self via callerSurfaceID

    func test_agentStatus_isSelf_trueOnlyForCallerSurface() async throws {
        let caller = pane()
        let other = pane()
        let access = AgentStatusFakeCockpitAccess()
        access.panes = [caller, other]
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap(), agentRegistry: AgentRegistry())

        let text = try await bridge.handleToolCall(
            name: "agent_status", arguments: ["include_git": false], callerSurfaceID: caller.surfaceID
        )

        let result = try panes(text)
        XCTAssertEqual(result[caller.surfaceID.uuidString]?["is_self"] as? Bool, true)
        XCTAssertEqual(result[other.surfaceID.uuidString]?["is_self"] as? Bool, false)
    }

    // MARK: - usage via the injected UsageLiveSummaries

    func test_agentStatus_usage_fromInjectedSummaries_keyedByAgentSession() async throws {
        let withUsage = pane()
        let withoutUsage = pane()
        let access = AgentStatusFakeCockpitAccess()
        access.panes = [withUsage, withoutUsage]
        let registry = AgentRegistry()
        for (surface, session) in [(withUsage.surfaceID, "s-usage"), (withoutUsage.surfaceID, "s-none")] {
            registry.handleHookEvent(
                AgentEvent(hookEventName: "SessionStart", sessionID: session, cwd: "/Users/dev/x", message: nil),
                surfaceID: surface
            )
        }
        XCTAssertEqual(registry.entries[withUsage.surfaceID]?.sessionID, "s-usage", "precondition")
        let summaries = UsageLiveSummaries()
        summaries.set(UsageTokenTotals(input: 100, output: 1_500, cacheRead: 20, cacheCreation: 3), forSession: "s-usage")
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(), agentRegistry: registry, usageSummaries: summaries
        )

        let text = try await bridge.handleToolCall(name: "agent_status", arguments: ["include_git": false])

        let result = try panes(text)
        let usage = try XCTUnwrap(result[withUsage.surfaceID.uuidString]?["usage"] as? [String: Any])
        XCTAssertEqual(usage["input"] as? Int, 100)
        XCTAssertEqual(usage["output"] as? Int, 1_500)
        XCTAssertEqual(usage["cache_read"] as? Int, 20)
        XCTAssertEqual(usage["cache_creation"] as? Int, 3)
        XCTAssertEqual(Set(usage.keys), ["input", "output", "cache_read", "cache_creation"])
        XCTAssertFalse(result[withoutUsage.surfaceID.uuidString]?.keys.contains("usage") ?? true,
                       "a session with no totals must omit usage")
    }

    // MARK: - allowable agrees with Mission Map

    /// For one pending request per source, agent_status's `allowable`
    /// equals "Mission Map's shared rule says .allowable" for that same
    /// request.
    func test_agentStatus_allowable_matchesMissionMapApprovalRule_forEverySource() async throws {
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which?", header: nil,
                    options: [AgentQuestionPrompt.Option(label: "a", description: nil, preview: nil)],
                    multiSelect: false
                ),
            ],
            originalToolInputJSON: Data()
        )
        let sources: [ApprovalRequest.Source] = [
            .mcpTool(name: "pane_run"),
            .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls",
                       offers: AgentHookOffers(permissionUpdates: [], cliOwnsPersistence: false)),
            .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt),
            .mcpApp(viewID: UUID(), title: "Viewer", kind: .openLink(URL(string: "https://example.com")!)),
        ]
        var seenAllowable: Set<Bool> = []
        for source in sources {
            let target = pane()
            let access = AgentStatusFakeCockpitAccess()
            access.panes = [target]
            let approvals = ApprovalInboxStore()
            let request = ApprovalRequest(
                id: UUID(), source: source, targetSurfaceID: target.surfaceID, payload: "", createdAt: Date()
            )
            approvals.submit(request)
            let bridge = MCPCockpitBridge(
                access: access, sessionSurfaceMap: SessionSurfaceMap(), approvals: approvals, agentRegistry: AgentRegistry()
            )

            let text = try await bridge.handleToolCall(name: "agent_status", arguments: ["include_git": false])

            let list = try XCTUnwrap(try panes(text)[target.surfaceID.uuidString]?["pending_approvals"] as? [[String: Any]])
            let reported = try XCTUnwrap(list.first?["allowable"] as? Bool, "\(source)")
            let missionMap = MissionMapSnapshotBuilder.approval(for: target.surfaceID, in: [request])
            let expected: Bool
            switch missionMap {
            case .allowable(let id)?:
                XCTAssertEqual(id, request.id)
                expected = true
            case .openOnly(let id)?:
                XCTAssertEqual(id, request.id)
                expected = false
            case nil:
                XCTFail("Mission Map must see the targeted request for \(source)")
                continue
            }
            XCTAssertEqual(reported, expected, "agent_status and Mission Map disagree for \(source)")
            seenAllowable.insert(reported)
        }
        XCTAssertEqual(seenAllowable, [true, false], "both outcomes must be exercised")
    }
}
