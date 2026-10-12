//
//  CommandHostedSurfacesTests.swift
//  CalyxTests
//
//  CommandHostedSurfaces: the registry of passthrough command-hosted
//  surfaces (worktree-task panes) that must auto-close on child exit.
//  Uses throwaway instances (init() is not private), mirroring
//  HerdrHostedSurfaces' shape, so `.shared` is never polluted.
//

import XCTest
@testable import Calyx

@MainActor
final class CommandHostedSurfacesTests: XCTestCase {

    func test_register_contains_unregister() {
        let registry = CommandHostedSurfaces()
        let id = UUID()
        XCTAssertFalse(registry.contains(id))
        registry.register(id)
        XCTAssertTrue(registry.contains(id))
        XCTAssertFalse(registry.contains(UUID()), "Only the registered ID is recorded")
        registry.unregister(id)
        XCTAssertFalse(registry.contains(id))
    }

    func test_surfaceDestroyedNotification_prunesRegisteredID() {
        let registry = CommandHostedSurfaces()
        registry.startObserving()
        defer { registry._stopObserving() }
        let id = UUID()
        let other = UUID()
        registry.register(id)
        registry.register(other)

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": id])

        XCTAssertFalse(registry.contains(id), "A destroyed surface must be pruned")
        XCTAssertTrue(registry.contains(other), "Other surfaces must stay registered")
    }

    func test_testReset_clearsEverything() {
        let registry = CommandHostedSurfaces()
        let id = UUID()
        registry.register(id)
        registry._testReset()
        XCTAssertFalse(registry.contains(id))
    }
}
