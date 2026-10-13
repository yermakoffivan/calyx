//
//  AgentRegistryPeerBindingNotificationTests.swift
//  CalyxTests
//
//  Pins when AgentRegistry.bindSurface(_:toPeer:) posts
//  `.calyxAgentPeerBindingChanged`. IPCWakeCoordinator re-checks a
//  surface's waiting `/ipc-wake` poll on this notification, so a missing
//  post strands a wake and an extra one names the wrong surface.
//
//  Coverage:
//  - A surface gaining a peer (nil -> P) posts once, with object == the
//    registry and userInfo["surfaceID"] == the surface passed to
//    bindSurface
//  - A surface moving to another peer (P -> Q) posts once more
//  - Re-binding the same surface/peer pair posts nothing
//  - Moving peer P from surface A to surface B posts for B only: A lost
//    its binding, but nothing is posted for A
//  - Taking another surface's peer posts for the argument surface only
//

import os
import XCTest
@testable import Calyx

@MainActor
final class AgentRegistryPeerBindingNotificationTests: XCTestCase {

    /// One observed post: the surface it named, and whether its `object`
    /// was the registry under test.
    private struct Post: Equatable, Sendable {
        let surfaceID: UUID?
        let objectIsRegistry: Bool
    }

    private var registry: AgentRegistry!
    private var observer: NSObjectProtocol?
    private let posts = OSAllocatedUnfairLock<[Post]>(initialState: [])

    override func setUp() async throws {
        try await super.setUp()
        let registry = AgentRegistry()
        self.registry = registry
        let posts = self.posts
        // `queue: nil` delivers synchronously on the posting thread, so
        // every post is recorded before bindSurface returns.
        observer = NotificationCenter.default.addObserver(
            forName: .calyxAgentPeerBindingChanged, object: registry, queue: nil
        ) { notification in
            let post = Post(
                surfaceID: notification.userInfo?["surfaceID"] as? UUID,
                objectIsRegistry: (notification.object as AnyObject?) === registry
            )
            posts.withLock { $0.append(post) }
        }
    }

    override func tearDown() async throws {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        registry = nil
        try await super.tearDown()
    }

    private var recordedPosts: [Post] {
        posts.withLock { $0 }
    }

    private func post(_ surfaceID: UUID) -> Post {
        Post(surfaceID: surfaceID, objectIsRegistry: true)
    }

    // MARK: - Binding changed

    func test_bindSurface_unboundSurface_postsOnceNamingThatSurface() {
        let surface = UUID()
        let peer = UUID()

        registry.bindSurface(surface, toPeer: peer)

        XCTAssertEqual(recordedPosts, [post(surface)],
                       "nil -> P must post exactly once, with object == the registry and " +
                       "userInfo[\"surfaceID\"] == the bound surface")
        XCTAssertEqual(registry.boundPeerID(for: surface), peer)
    }

    func test_bindSurface_surfaceMovesToAnotherPeer_postsAgain() {
        let surface = UUID()
        let peerP = UUID()
        let peerQ = UUID()

        registry.bindSurface(surface, toPeer: peerP)
        registry.bindSurface(surface, toPeer: peerQ)

        XCTAssertEqual(recordedPosts, [post(surface), post(surface)],
                       "nil -> P and then P -> Q must each post exactly once for the surface")
        XCTAssertEqual(registry.boundPeerID(for: surface), peerQ)
    }

    // MARK: - Binding unchanged

    func test_bindSurface_samePairAgain_postsNothing() {
        let surface = UUID()
        let peer = UUID()
        registry.bindSurface(surface, toPeer: peer)
        XCTAssertEqual(recordedPosts.count, 1, "precondition: the first bind posted")

        registry.bindSurface(surface, toPeer: peer)
        registry.bindSurface(surface, toPeer: peer)

        XCTAssertEqual(recordedPosts, [post(surface)],
                       "re-binding a surface to the peer it is already bound to must post nothing")
    }

    // MARK: - Eviction

    func test_bindSurface_peerMovesFromSurfaceAToSurfaceB_postsForBOnly() {
        let surfaceA = UUID()
        let surfaceB = UUID()
        let peer = UUID()
        registry.bindSurface(surfaceA, toPeer: peer)
        XCTAssertEqual(recordedPosts, [post(surfaceA)], "precondition: binding A posted for A")

        registry.bindSurface(surfaceB, toPeer: peer)

        XCTAssertEqual(recordedPosts, [post(surfaceA), post(surfaceB)],
                       "moving the peer to B must post exactly once, naming B; A lost its binding " +
                       "but nothing is posted for A")
        XCTAssertNil(registry.boundPeerID(for: surfaceA), "precondition: A was evicted")
        XCTAssertEqual(registry.boundPeerID(for: surfaceB), peer)
    }

    func test_bindSurface_surfaceTakesAnotherSurfacesPeer_postsForTheArgumentSurfaceOnly() {
        let surfaceA = UUID()
        let surfaceB = UUID()
        let peerP = UUID()
        let peerQ = UUID()
        registry.bindSurface(surfaceA, toPeer: peerP)
        registry.bindSurface(surfaceB, toPeer: peerQ)
        XCTAssertEqual(recordedPosts, [post(surfaceA), post(surfaceB)], "precondition: one post per first bind")

        // A moves P -> Q (a real change for A); B is evicted from Q.
        registry.bindSurface(surfaceA, toPeer: peerQ)

        XCTAssertEqual(recordedPosts, [post(surfaceA), post(surfaceB), post(surfaceA)],
                       "the post must name the argument surface (A) only; the evicted surface (B) " +
                       "gets no post")
        XCTAssertEqual(registry.boundPeerID(for: surfaceA), peerQ)
        XCTAssertNil(registry.boundPeerID(for: surfaceB))
    }

    // MARK: - Scope

    func test_bindSurface_onAnotherRegistry_isNotObservedForThisRegistry() {
        let otherRegistry = AgentRegistry()
        let otherSurface = UUID()
        let otherPosts = OSAllocatedUnfairLock<[Post]>(initialState: [])
        let otherObserver = NotificationCenter.default.addObserver(
            forName: .calyxAgentPeerBindingChanged, object: otherRegistry, queue: nil
        ) { notification in
            let post = Post(
                surfaceID: notification.userInfo?["surfaceID"] as? UUID,
                objectIsRegistry: (notification.object as AnyObject?) === otherRegistry
            )
            otherPosts.withLock { $0.append(post) }
        }
        defer { NotificationCenter.default.removeObserver(otherObserver) }

        otherRegistry.bindSurface(otherSurface, toPeer: UUID())

        XCTAssertEqual(otherPosts.withLock { $0 }, [Post(surfaceID: otherSurface, objectIsRegistry: true)],
                       "positive control: the bind posted exactly once, with object == the other registry")
        XCTAssertEqual(recordedPosts, [],
                       "the post's object must be the registry that changed, so an observer of one " +
                       "registry never sees another registry's binding change")
    }
}
