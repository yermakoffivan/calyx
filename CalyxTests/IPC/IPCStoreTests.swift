//
//  IPCStoreTests.swift
//  CalyxTests
//
//  Tests for IPCStore actor: peer registration, message delivery,
//  broadcast, delete-on-read receive, TTL expiration, and cleanup.
//
//  Coverage:
//  - Peer registration (name, role, timestamps)
//  - Peer listing (including TTL expiration filtering)
//  - Peer removal (peer + inbox)
//  - Message send/receive (happy path, unregistered sender, unknown recipient)
//  - Broadcast to all other peers
//  - Message limit (101 → keeps newest 100)
//  - Peer TTL (11 min → excluded from list)
//  - Message TTL (6 min → excluded from receive)
//  - Cleanup (full reset)
//  - peerStatus lookup
//  - lastSeen updates on send/receive
//

import XCTest
@testable import Calyx

final class IPCStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> IPCStore {
        IPCStore()
    }

    // ==================== 1. Register Peer ====================

    func test_registerPeer_returnsValidPeer() async {
        // Arrange
        let store = makeStore()

        // Act
        let peer = await store.registerPeer(name: "terminal-1", role: "terminal")

        // Assert
        XCTAssertFalse(peer.id.uuidString.isEmpty,
                       "Peer should have a non-empty UUID")
        XCTAssertEqual(peer.name, "terminal-1",
                       "Peer name should match the registered name")
        XCTAssertEqual(peer.role, "terminal",
                       "Peer role should match the registered role")
        XCTAssertNotNil(peer.lastSeen,
                        "Peer lastSeen should be set")
        XCTAssertNotNil(peer.registeredAt,
                        "Peer registeredAt should be set")
        // lastSeen and registeredAt should be very close to now
        let now = Date()
        XCTAssertTrue(now.timeIntervalSince(peer.lastSeen) < 2.0,
                      "lastSeen should be within 2 seconds of now")
        XCTAssertTrue(now.timeIntervalSince(peer.registeredAt) < 2.0,
                      "registeredAt should be within 2 seconds of now")
    }

    // ==================== 2. List Peers ====================

    func test_listPeers_returnsRegisteredPeers() async {
        // Arrange
        let store = makeStore()
        let peer1 = await store.registerPeer(name: "terminal-1", role: "terminal")
        let peer2 = await store.registerPeer(name: "sidebar", role: "plugin")

        // Act
        let peers = await store.listPeers()

        // Assert
        XCTAssertEqual(peers.count, 2,
                       "listPeers should return both registered peers")
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peer1.id),
                      "Should contain peer1")
        XCTAssertTrue(peerIDs.contains(peer2.id),
                      "Should contain peer2")
    }

    // ==================== 3. Remove Peer ====================

    func test_removePeer_removesPeerAndInbox() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Send a message so peerA has inbox content
        _ = try await store.sendMessage(from: peerB.id, to: peerA.id, content: "hello")

        // Act
        await store.removePeer(id: peerA.id)

        // Assert
        let peers = await store.listPeers()
        XCTAssertEqual(peers.count, 1,
                       "Only peerB should remain after removing peerA")
        XCTAssertEqual(peers.first?.id, peerB.id)

        // peerA's inbox should also be gone
        let messages = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(messages.isEmpty,
                      "Removed peer's inbox should be empty")
    }

    // ==================== 4. Send Message ====================

    func test_sendMessage_deliversToRecipient() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Act
        let message = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hello from A"
        )

        // Assert
        XCTAssertEqual(message.from, peerA.id)
        XCTAssertEqual(message.to, peerB.id)
        XCTAssertEqual(message.content, "hello from A")
        XCTAssertFalse(message.id.uuidString.isEmpty,
                       "Message should have a valid UUID")

        // Recipient should have the message in their inbox
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 1,
                       "Recipient should have exactly 1 message")
        XCTAssertEqual(inbox.first?.content, "hello from A")
    }

    // ==================== 5. Send Message — Unregistered Sender ====================

    func test_sendMessage_unregisteredSender_throws() async {
        // Arrange
        let store = makeStore()
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let fakeID = UUID()

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: fakeID, to: peerB.id, content: "should fail"
            )
            XCTFail("Expected IPCError.unregisteredPeer to be thrown")
        } catch let error as IPCError {
            if case .unregisteredPeer = error {
                // Expected
            } else {
                XCTFail("Expected .unregisteredPeer, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== 6. Send Message — Unknown Recipient ====================

    func test_sendMessage_unknownRecipient_throws() async {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let unknownID = UUID()

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: unknownID, content: "no one home"
            )
            XCTFail("Expected IPCError.peerNotFound to be thrown")
        } catch let error as IPCError {
            if case .peerNotFound(let id) = error {
                XCTAssertEqual(id, unknownID,
                               "peerNotFound should carry the unknown peer's UUID")
            } else {
                XCTFail("Expected .peerNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== 7. Broadcast ====================

    func test_broadcast_sendsToAllOtherPeers() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        // Act
        let messages = try await store.broadcast(from: peerA.id, content: "announcement")

        // Assert — messages delivered to B and C, not A
        XCTAssertEqual(messages.count, 2,
                       "Broadcast should create messages for all peers except sender")

        let recipientIDs = Set(messages.map(\.to))
        XCTAssertTrue(recipientIDs.contains(peerB.id),
                      "Broadcast should deliver to peerB")
        XCTAssertTrue(recipientIDs.contains(peerC.id),
                      "Broadcast should deliver to peerC")
        XCTAssertFalse(recipientIDs.contains(peerA.id),
                       "Broadcast should NOT deliver to sender")

        // Verify inboxes
        let inboxB = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inboxB.count, 1)
        XCTAssertEqual(inboxB.first?.content, "announcement")

        let inboxC = await store.receiveMessages(for: peerC.id)
        XCTAssertEqual(inboxC.count, 1)
        XCTAssertEqual(inboxC.first?.content, "announcement")

        // Sender's inbox should be empty
        let inboxA = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inboxA.isEmpty,
                      "Sender should not receive their own broadcast")
    }

    // ==================== 8. Receive Messages ====================

    func test_receiveMessages_returnsSentMessages() async throws {
        // Contract (delete-on-read): a receiveMessages
        // call returns every message currently in the peer's inbox, and
        // deletes them from the inbox in the same call — a message it
        // returns will not be returned again by a later call. That
        // second half of the contract (and the sibling-peer/later-message
        // isolation it implies) has its own dedicated tests below, under
        // "delete-on-read (at-most-once)"; this test only covers
        // the first receive returning what was sent.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg1 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "first"
        )
        let msg2 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "second"
        )

        // Act
        let inbox = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertEqual(inbox.count, 2,
                       "Should return both sent messages")
        let messageIDs = Set(inbox.map(\.id))
        XCTAssertTrue(messageIDs.contains(msg1.id),
                      "Should contain first message")
        XCTAssertTrue(messageIDs.contains(msg2.id),
                      "Should contain second message")
    }

    // ==================== 10. Message Limit ====================

    func test_messageLimit_dropsOldest() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Act — send 101 messages; limit is 100
        for i in 0..<101 {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "msg-\(i)"
            )
        }

        // Assert
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 100,
                       "Inbox should cap at 100 messages, dropping the oldest")

        // The oldest message (msg-0) should have been dropped
        let contents = inbox.map(\.content)
        XCTAssertFalse(contents.contains("msg-0"),
                       "Oldest message (msg-0) should be dropped")
        XCTAssertTrue(contents.contains("msg-100"),
                      "Newest message (msg-100) should be present")
        XCTAssertTrue(contents.contains("msg-1"),
                      "Second oldest message (msg-1) should still be present")
    }

    // ==================== 11. Peer TTL ====================

    func test_peerTTL_expiresOldPeers() async {
        // Arrange
        let store = makeStore()
        let freshPeer = await store.registerPeer(name: "fresh", role: "terminal")
        let stalePeer = await store.registerPeer(name: "stale", role: "terminal")

        // Note: stale peer has no in-flight message → unread-message pin rule does
        // not apply. Pure lastSeen TTL expiration is the only relevant signal here.
        // Artificially set stalePeer's lastSeen to 11 minutes ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: stalePeer.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        XCTAssertEqual(peers.count, 1,
                       "Only non-expired peers should be returned")
        XCTAssertEqual(peers.first?.id, freshPeer.id,
                       "The fresh peer should remain")
    }

    // ==================== 12. Old Timestamp Message Still Returned (rewrite of message TTL test) ====================

    func test_oldTimestampMessage_isStillReturned_whenRecipientAlive() async throws {
        // After Change 3, message retention is governed by recipient peer
        // liveness, not by individual message timestamps. A 6-minute-old message
        // must still be delivered as long as the recipient peer is alive.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let oldMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "still here"
        )
        let freshMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "fresh"
        )

        // Artificially age oldMsg's timestamp to 6 minutes ago
        let sixMinutesAgo = Date().addingTimeInterval(-6 * 60)
        await store._testSetMessageTimestamp(
            messageId: oldMsg.id, peerId: peerB.id, date: sixMinutesAgo
        )

        // Act
        let inbox = await store.receiveMessages(for: peerB.id)

        // Assert — both messages must be returned (no time-based drop)
        XCTAssertEqual(inbox.count, 2,
                       "Both messages should be returned regardless of message timestamp; recipient peer liveness is the only retention rule")
        let messageIDs = Set(inbox.map(\.id))
        XCTAssertTrue(messageIDs.contains(oldMsg.id),
                      "Old-timestamp message should still be delivered")
        XCTAssertTrue(messageIDs.contains(freshMsg.id),
                      "Fresh message should still be delivered")
    }

    // ==================== 13. Cleanup ====================

    func test_cleanup_removesAllData() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "will be cleaned"
        )

        // Pre-condition
        let peersBefore = await store.listPeers()
        XCTAssertEqual(peersBefore.count, 2)

        // Act
        await store.cleanup()

        // Assert
        let peersAfter = await store.listPeers()
        XCTAssertTrue(peersAfter.isEmpty,
                      "All peers should be removed after cleanup")

        let inboxA = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inboxA.isEmpty,
                      "All messages should be removed after cleanup")

        let inboxB = await store.receiveMessages(for: peerB.id)
        XCTAssertTrue(inboxB.isEmpty,
                      "All messages should be removed after cleanup")
    }

    // ==================== 14. Peer Status ====================

    func test_peerStatus_returnsCorrectPeer() async {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "terminal-1", role: "terminal")

        // Act
        let status = await store.peerStatus(id: peer.id)

        // Assert
        XCTAssertNotNil(status, "peerStatus should return the registered peer")
        XCTAssertEqual(status?.id, peer.id)
        XCTAssertEqual(status?.name, "terminal-1")
        XCTAssertEqual(status?.role, "terminal")
    }

    // ==================== 15. Peer Status — Unknown ====================

    func test_peerStatus_unknownPeer_returnsNil() async {
        // Arrange
        let store = makeStore()

        // Act
        let status = await store.peerStatus(id: UUID())

        // Assert
        XCTAssertNil(status,
                     "peerStatus should return nil for an unknown UUID")
    }

    // ==================== 16. Send Updates lastSeen ====================

    func test_sendMessage_updatesLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Record the initial lastSeen
        let initialLastSeen = peerA.lastSeen

        // Set lastSeen to 1 second ago to ensure a measurable difference
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: oneSecondAgo)

        // Act — send a message from peerA (should update A's lastSeen)
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ping"
        )

        // Assert
        let updatedPeer = await store.peerStatus(id: peerA.id)
        XCTAssertNotNil(updatedPeer)
        XCTAssertTrue(updatedPeer!.lastSeen > oneSecondAgo,
                      "lastSeen should be updated after sending a message")
    }

    // ==================== 17. Receive Updates lastSeen ====================

    func test_receiveMessages_updatesLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hello"
        )

        // Set peerB's lastSeen to 1 second ago to ensure a measurable difference
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)

        // Act — receive messages for peerB (should update B's lastSeen)
        _ = await store.receiveMessages(for: peerB.id)

        // Assert
        let updatedPeer = await store.peerStatus(id: peerB.id)
        XCTAssertNotNil(updatedPeer)
        XCTAssertTrue(updatedPeer!.lastSeen > oneSecondAgo,
                      "lastSeen should be updated after receiving messages")
    }

    // ============================================================
    // MARK: - Issue #31: New TTL auto-extension contract
    // ============================================================

    // ==================== Change 1: Bidirectional Bump ====================

    // Test 1
    func test_sendMessage_bumpsRecipientLastSeen() async throws {
        // Contract: sendMessage(from: A, to: B) must bump BOTH A and B's lastSeen.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)

        // Act — A sends to B; under the new contract, B's lastSeen must bump too.
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ping"
        )

        // Assert
        let updatedB = await store.peerStatus(id: peerB.id)
        XCTAssertNotNil(updatedB, "Recipient should still exist")
        XCTAssertTrue(updatedB!.lastSeen > oneSecondAgo,
                      "Recipient's lastSeen should bump on sendMessage")
    }

    // Test 2
    func test_broadcast_bumpsAllRecipientsLastSeen() async throws {
        // Contract: broadcast(from: A) must bump A and ALL alive recipients' lastSeen.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)
        await store._testSetPeerLastSeen(peerId: peerC.id, date: oneSecondAgo)

        // Act
        _ = try await store.broadcast(from: peerA.id, content: "announcement")

        // Assert
        let updatedB = await store.peerStatus(id: peerB.id)
        let updatedC = await store.peerStatus(id: peerC.id)
        XCTAssertNotNil(updatedB)
        XCTAssertNotNil(updatedC)
        XCTAssertTrue(updatedB!.lastSeen > oneSecondAgo,
                      "Recipient B's lastSeen should bump on broadcast")
        XCTAssertTrue(updatedC!.lastSeen > oneSecondAgo,
                      "Recipient C's lastSeen should bump on broadcast")
    }

    // Test 3
    func test_receiveMessages_bumpsAllSendersLastSeen() async throws {
        // Contract: receiveMessages(for: B) bumps B and ALL distinct senders'
        // lastSeen for messages returned in this call.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        // A and C both send to B
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "from A"
        )
        _ = try await store.sendMessage(
            from: peerC.id, to: peerB.id, content: "from C"
        )

        // Now age both A and C's lastSeen to 1 second ago
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: oneSecondAgo)
        await store._testSetPeerLastSeen(peerId: peerC.id, date: oneSecondAgo)

        // Act — B reads its inbox
        _ = await store.receiveMessages(for: peerB.id)

        // Assert — both senders should be bumped
        let updatedA = await store.peerStatus(id: peerA.id)
        let updatedC = await store.peerStatus(id: peerC.id)
        XCTAssertNotNil(updatedA)
        XCTAssertNotNil(updatedC)
        XCTAssertTrue(updatedA!.lastSeen > oneSecondAgo,
                      "Sender A's lastSeen should bump when B receives A's message")
        XCTAssertTrue(updatedC!.lastSeen > oneSecondAgo,
                      "Sender C's lastSeen should bump when B receives C's message")
    }

    // ==================== Change 2: Unread Message Pinning ====================

    // Test 5
    func test_unreadMessage_pinsRecipientAlive_inListPeers() async throws {
        // Contract: An in-flight (unread) message pins its recipient alive even
        // when the recipient's lastSeen exceeds peerTTL.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // A → B (creates unread message in B's inbox)
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "you have mail"
        )

        // Age only B's lastSeen to 11 min ago (do NOT touch A; this test asserts
        // about B's pinning specifically).
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerB.id),
                      "Recipient B must be pinned alive while it has an unread message")
    }

    // Test 6
    func test_unreadMessage_pinsSenderAlive_inListPeers() async throws {
        // Contract: An in-flight message also pins its sender alive (so the
        // sender is still around to receive a reply).
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "Sender A must be pinned alive while its message is unread")
    }

    // Test 7
    func test_unreadMessage_pinsRecipientAlive_inPeerStatus() async throws {
        // Contract: Pin must also be visible via peerStatus, not only listPeers.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let status = await store.peerStatus(id: peerB.id)

        // Assert
        XCTAssertNotNil(status,
                        "peerStatus must return non-nil while the peer is pinned by an unread message")
        XCTAssertEqual(status?.id, peerB.id)
    }

    // Test 8
    func test_pinLifts_afterReceive_recipientThenPurged() async throws {
        // Contract: Once the unread message is received
        // (receiveMessages deletes it from the inbox as it returns it), the
        // pin is lifted. After the pin is lifted, the recipient's stale
        // lastSeen makes it purgeable on the next listPeers call.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // B receives the message → it's deleted from B's inbox, pin lifts
        _ = await store.receiveMessages(for: peerB.id)

        // Now age B's lastSeen to 11 min ago (note: receive also bumps B,
        // so we override that here)
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerB.id),
                       "Recipient B should be purged after pin lifts and TTL elapses")
    }

    // Test 9
    func test_pinLifts_afterReceive_senderThenPurged() async throws {
        // Contract (mirror of test 8): once the unread message is gone, the
        // sender is no longer pinned and its stale lastSeen makes it purgeable.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // B receives → the message is deleted from the inbox, no in-flight
        // messages remain
        _ = await store.receiveMessages(for: peerB.id)

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "Sender A should be purged after pin lifts and TTL elapses")
    }

    // Test 10
    func test_broadcast_pinsSenderWhileAnyRecipientUnread() async throws {
        // Contract: A broadcaster is pinned alive as long as any recipient
        // still has an unread copy of the broadcast.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        _ = try await store.broadcast(from: peerA.id, content: "broadcast")

        // Age A's lastSeen to 11 min ago. Neither B nor C has received yet.
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "Broadcaster A should be pinned alive while any recipient still has the unread broadcast")
    }

    // Test 11
    func test_broadcast_partialReceive_keepsSenderPinned() async throws {
        // Contract: Pin holds while at least ONE recipient still has the
        // broadcast unread.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        _ = try await store.broadcast(from: peerA.id, content: "broadcast")

        // B receives its copy (deleting it from B's inbox); C has not.
        _ = await store.receiveMessages(for: peerB.id)

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "A should remain pinned while C still has the broadcast unread")
    }

    // Test 12
    func test_broadcast_fullReceive_unpinsSender() async throws {
        // Contract: Once ALL recipients have received (and thereby
        // deleted) their copy, the pin lifts and A's stale lastSeen makes
        // it purgeable.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        _ = try await store.broadcast(from: peerA.id, content: "broadcast")

        // B and C both receive
        _ = await store.receiveMessages(for: peerB.id)
        _ = await store.receiveMessages(for: peerC.id)

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "A should be purged once all recipients have received their copy")
    }

    // ==================== Change 3: No Time-Based Drop ====================

    // Test 14 (test 13 is the rewritten existing #12 above)
    func test_messageRetention_governedByPeerLiveness_purgedWithRecipient() async throws {
        // Contract: Removing a recipient must also remove their inbox.
        // receiveMessages on a removed peer returns [].
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "doomed"
        )

        // Act — remove B
        await store.removePeer(id: peerB.id)

        // Assert — B's inbox is empty (peer + inbox were torn down together)
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertTrue(inbox.isEmpty,
                      "Removed recipient's inbox must be empty; message retention is governed by recipient liveness")
    }

    // ==================== Change 0: Revive Prevention ====================

    // Test 15
    func test_expiredPeer_noUnread_cannotSendMessage() async throws {
        // Contract: An expired peer with no in-flight message must NOT be able
        // to revive itself by calling sendMessage. The call must throw
        // unregisteredPeer, and the peer must be purged.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Age A to 11 min ago. No unread messages exist.
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act & Assert — sendMessage must throw unregisteredPeer
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "should not go"
            )
            XCTFail("Expected IPCError.unregisteredPeer because A is expired with no pin")
        } catch let error as IPCError {
            if case .unregisteredPeer = error {
                // Expected
            } else {
                XCTFail("Expected .unregisteredPeer, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // A must be purged from the store
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "Expired sender must be purged after the rejected sendMessage call")
    }

    // Test 16
    func test_expiredPeer_noUnread_cannotReceiveMessages() async {
        // Contract: An expired peer with no in-flight message must NOT be able
        // to revive itself via receiveMessages. The call must return [] AND the
        // peer must be purged (not bumped).
        // Arrange
        let store = makeStore()
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let result = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertTrue(result.isEmpty,
                      "Expired peer with no unread should receive []")
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerB.id),
                       "Expired peer must be purged on receiveMessages, not silently bumped")
    }

    // Test 18
    func test_expiredRecipient_noUnread_sendThrowsPeerNotFound() async throws {
        // Contract: An alive sender targeting an expired recipient (with no pin)
        // must get peerNotFound. The lazy purge in aliveOrPurge removes the
        // expired recipient before the dictionary check.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Only B is stale
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "should fail"
            )
            XCTFail("Expected IPCError.peerNotFound because B is expired with no pin")
        } catch let error as IPCError {
            if case .peerNotFound(let id) = error {
                XCTAssertEqual(id, peerB.id,
                               "peerNotFound should carry the expired recipient's UUID")
            } else {
                XCTFail("Expected .peerNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== Change 4: peerStatus Purge Unification ====================

    // Test 19
    func test_peerStatus_expiredPeer_purgesPeerAndInbox() async throws {
        // Contract: peerStatus on an expired peer with no pin must return nil
        // AND tear down the peer + inbox (consistent with listPeers' purge).
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act — call peerStatus, which under the new contract should also purge
        let status = await store.peerStatus(id: peerA.id)

        // Assert: returns nil
        XCTAssertNil(status,
                     "peerStatus should return nil for an expired peer with no pin")

        // Assert: A is gone from listPeers (purge happened, not just nil)
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "peerStatus should purge the expired peer, so subsequent listPeers does not see it")

        // Assert: A's inbox is gone — receiveMessages returns []
        let inbox = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inbox.isEmpty,
                      "peerStatus should also tear down the inbox of an expired peer")
    }

    // ==================== inboxCount(for:) ====================

    // Unlike receiveMessages, inboxCount is a read-only query used to
    // refresh AgentRegistry's unread-message badge after a
    // send/broadcast/receive — it must report the real count without the
    // liveness side effect (bumping lastSeen) receiveMessages has.
    func test_inboxCount_returnsMessageCountWithoutMutatingLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let sender = await store.registerPeer(name: "sender", role: "terminal")
        let recipient = await store.registerPeer(name: "recipient", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")

        // Push lastSeen into the recent past (well within the TTL) so a
        // spurious bump by inboxCount is observable via peerStatus.
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        await store._testSetPeerLastSeen(peerId: recipient.id, date: fiveMinutesAgo)
        let statusBeforeOptional = await store.peerStatus(id: recipient.id)
        let statusBefore = try XCTUnwrap(statusBeforeOptional)

        // Act
        let count = await store.inboxCount(for: recipient.id)

        // Assert: the real count, not a side-effect-only stub value.
        XCTAssertEqual(count, 2, "inboxCount must return the peer's actual inbox message count")

        // Assert: lastSeen must be untouched — the defining difference
        // from receiveMessages, which bumps it on every call.
        let statusAfterOptional = await store.peerStatus(id: recipient.id)
        let statusAfter = try XCTUnwrap(statusAfterOptional)
        XCTAssertEqual(statusAfter.lastSeen, statusBefore.lastSeen,
                       "inboxCount must be read-only: unlike receiveMessages, it must not bump lastSeen")
    }

    // ==================== inboxCount reflects current inbox size ====================

    // The delete-on-read change to receiveMessages made any
    // undelivered/delivered distinction moot: inboxCount simply reports
    // how many messages are currently sitting in the inbox, since
    // receiveMessages removes every message it returns instead of merely
    // marking it delivered. The sidebar's unread badge therefore cannot
    // stay lit after the agent has genuinely read its inbox.

    func test_receiveMessages_immediatelyClearsInboxCount() async throws {
        // Arrange
        let store = makeStore()
        let sender = await store.registerPeer(name: "sender", role: "terminal")
        let recipient = await store.registerPeer(name: "recipient", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")

        let countBefore = await store.inboxCount(for: recipient.id)
        XCTAssertEqual(countBefore, 2, "Precondition: both freshly-sent messages are in the inbox")

        // Act
        _ = await store.receiveMessages(for: recipient.id)

        // Assert
        let countAfter = await store.inboxCount(for: recipient.id)
        XCTAssertEqual(countAfter, 0,
                       "receiveMessages must immediately clear inboxCount — it deletes every " +
                       "message it returns")

        // The messages are gone, not merely hidden from the count — a
        // second receiveMessages call returns nothing (delete-on-read).
        let inbox = await store.receiveMessages(for: recipient.id)
        XCTAssertEqual(inbox.count, 0, "Received messages must not remain in the inbox")
    }

    func test_inboxCount_newMessageAfterReceive_countsOnlyTheNewOne() async throws {
        // A message sent AFTER a prior receiveMessages call must still be
        // counted — the earlier receive only cleared what was in the
        // inbox at that time, not some peer-wide "caught up" flag.
        let store = makeStore()
        let sender = await store.registerPeer(name: "sender", role: "terminal")
        let recipient = await store.registerPeer(name: "recipient", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = await store.receiveMessages(for: recipient.id)
        let countAfterReceive = await store.inboxCount(for: recipient.id)
        XCTAssertEqual(countAfterReceive, 0, "Precondition: received (and therefore deleted), so 0")

        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")

        let countAfterNewMessage = await store.inboxCount(for: recipient.id)
        XCTAssertEqual(countAfterNewMessage, 1,
                       "A newly-sent message must count even though an earlier message to the " +
                       "same peer was already received")
    }

    // ==================== inboxCounts(for:) batch ====================

    func test_inboxCounts_returnsCurrentCountPerPeer() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "sender", role: "terminal")
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "terminal")

        _ = try await store.sendMessage(from: sender.id, to: peerA.id, content: "a1")
        _ = try await store.sendMessage(from: sender.id, to: peerA.id, content: "a2")
        _ = try await store.sendMessage(from: sender.id, to: peerB.id, content: "b1")
        // peerC gets nothing.

        let counts = await store.inboxCounts(for: [peerA.id, peerB.id, peerC.id])

        XCTAssertEqual(counts[peerA.id], 2)
        XCTAssertEqual(counts[peerB.id], 1)
        XCTAssertEqual(counts[peerC.id], 0)
    }

    func test_inboxCounts_unknownPeerID_readsZero() async throws {
        let store = makeStore()
        let counts = await store.inboxCounts(for: [UUID()])
        XCTAssertEqual(counts.count, 1)
        XCTAssertEqual(counts.values.first, 0)
    }

    // ==================== updatePeer (rename semantics) ====================
    //
    // register_peer's rename fix (a surface with an already-bound, still-
    // alive peer gets that peer RENAMED rather than a second identity
    // minted) needs a way to update an existing peer's name/role in place
    // while preserving its identity (id, registeredAt). This is that
    // primitive.

    func test_updatePeer_existingPeer_updatesNameAndRole_bumpsLastSeen_preservesIdentity() async throws {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "old-name", role: "old-role")
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        await store._testSetPeerLastSeen(peerId: peer.id, date: oneMinuteAgo)

        // Act
        let updated = await store.updatePeer(id: peer.id, name: "my-task", role: "worker")

        // Assert
        let result = try XCTUnwrap(updated, "updatePeer must return the updated Peer for a known id")
        XCTAssertEqual(result.id, peer.id,
                       "updatePeer must preserve the peer's original id — this is a rename, not a re-registration")
        XCTAssertEqual(result.name, "my-task", "updatePeer must apply the new name")
        XCTAssertEqual(result.role, "worker", "updatePeer must apply the new role")
        XCTAssertEqual(result.registeredAt, peer.registeredAt,
                       "updatePeer must preserve the original registeredAt — it renames the existing " +
                       "registration, it does not recreate it")
        XCTAssertGreaterThan(result.lastSeen, oneMinuteAgo,
                             "updatePeer must bump lastSeen like other liveness-touching operations")

        // The store's own record must reflect the same update, not just the returned copy.
        let statusOptional = await store.peerStatus(id: peer.id)
        let status = try XCTUnwrap(statusOptional)
        XCTAssertEqual(status.name, "my-task")
        XCTAssertEqual(status.role, "worker")
    }

    func test_updatePeer_unknownID_returnsNil() async {
        // Arrange
        let store = makeStore()

        // Act
        let result = await store.updatePeer(id: UUID(), name: "whoever", role: "whatever")

        // Assert
        XCTAssertNil(result, "updatePeer must return nil for an id with no registered peer")
    }

    // `nil` for `name`/`role` means "leave this field
    // unchanged" — `CalyxMCPServer.handleRegisterPeer` relies on this so a
    // `register_peer` call that only supplies one of the two arguments
    // doesn't blank out the other.

    func test_updatePeer_nilName_preservesExistingName() async throws {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "original-name", role: "original-role")

        // Act
        let updated = await store.updatePeer(id: peer.id, name: nil, role: "new-role")

        // Assert
        let result = try XCTUnwrap(updated)
        XCTAssertEqual(result.name, "original-name",
                       "a nil name must leave the existing name unchanged")
        XCTAssertEqual(result.role, "new-role", "a non-nil role must still apply")
    }

    func test_updatePeer_nilRole_preservesExistingRole() async throws {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "original-name", role: "original-role")

        // Act
        let updated = await store.updatePeer(id: peer.id, name: "new-name", role: nil)

        // Assert
        let result = try XCTUnwrap(updated)
        XCTAssertEqual(result.name, "new-name", "a non-nil name must still apply")
        XCTAssertEqual(result.role, "original-role",
                       "a nil role must leave the existing role unchanged")
    }

    func test_updatePeer_bothNil_preservesNameAndRole_stillBumpsLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "original-name", role: "original-role")
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        await store._testSetPeerLastSeen(peerId: peer.id, date: oneMinuteAgo)

        // Act
        let updated = await store.updatePeer(id: peer.id, name: nil, role: nil)

        // Assert
        let result = try XCTUnwrap(updated)
        XCTAssertEqual(result.name, "original-name")
        XCTAssertEqual(result.role, "original-role")
        XCTAssertGreaterThan(result.lastSeen, oneMinuteAgo,
                             "updatePeer must still bump lastSeen even when both fields are preserved " +
                             "unchanged — it's still a liveness-touching operation")
    }

    // ==================== Delete-on-read (at-most-once) ====================
    //
    // Message.delivered and ackMessages are gone entirely: a message is
    // now removed from the recipient's inbox by the SAME receiveMessages
    // call that returns it, instead of staying present (merely marked
    // "delivered") until a separate ackMessages call. These describe that
    // contract directly; test_receiveMessages_returnsSentMessages above
    // (formerly test_receiveMessages_returnsUnackedMessages, which
    // asserted the opposite — that a second receiveMessages call still
    // returned both messages) was rewritten to stop asserting the
    // now-contradicted at-least-once behavior.

    func test_receiveMessages_deletesReturnedMessages_secondReceiveIsEmpty() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "only once")

        // Act — the first receive returns the message.
        let firstInbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(firstInbox.count, 1,
                       "Precondition: the first receiveMessages call must return the sent message")

        // Act — a second receive for the same peer, with no new message sent.
        let secondInbox = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertTrue(secondInbox.isEmpty,
                      "receiveMessages must delete-on-read: a message already returned by an earlier " +
                      "call must not be returned again, with no separate ackMessages step required " +
                      "to remove it")
    }

    func test_receiveMessages_deleteOnRead_doesNotAffectOtherPeersOrLaterMessages() async throws {
        // Contract: delete-on-read removes exactly the messages THIS call
        // returned for THIS peer — a sibling peer's inbox, and a message
        // sent to the same peer afterward, must be unaffected.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "terminal")

        _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "for B")
        _ = try await store.sendMessage(from: peerA.id, to: peerC.id, content: "for C")

        // Act — B receives (and, under delete-on-read, deletes its own message).
        let inboxB = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inboxB.count, 1)

        // A new message arrives for B after the delete-on-read receive above.
        _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "after the first receive")

        // Assert — C's inbox (untouched by B's receive) is still intact.
        let inboxC = await store.receiveMessages(for: peerC.id)
        XCTAssertEqual(inboxC.count, 1,
                       "Receiving B's inbox must not delete C's unrelated message")

        // Assert — the message sent to B after its receive is still delivered.
        let inboxBAgain = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inboxBAgain.count, 1,
                       "A message sent after a delete-on-read receive must still be returned on the " +
                       "next receive — deletion is per-message, not a peer-wide flag")
        XCTAssertEqual(inboxBAgain.first?.content, "after the first receive")
    }

    // test_receiveMessages_deletedMessages_inboxCountIsZero removed
    // (review): duplicated test_receiveMessages_immediatelyClearsInboxCount
    // above, which already covers the same "inboxCount reads 0 right
    // after receiveMessages" contract — including the stale delivered-flag
    // comment this test had carried over from before the rewrite.

    // ==================== requeue (undo a downstream failure) ====================
    //
    // requeue exists solely so CalyxMCPServer.handleReceiveMessages can
    // put messages back if it fails to serialize receiveMessages' result
    // — receiveMessages already deleted them from the store by that
    // point, so without requeue they'd be lost outright rather than
    // merely returned as a retryable error.

    func test_requeue_restoresMessagesToFrontInOriginalOrder() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg1 = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "first")
        let msg2 = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "second")

        let received = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(received.count, 2, "Precondition: both messages were received (and deleted)")

        // Act — simulate the serialization-failure recovery path.
        await store.requeue(received, for: peerB.id)

        // Assert
        let redelivered = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(redelivered.map(\.id), [msg1.id, msg2.id],
                       "requeue must restore messages to the inbox in their original order")
    }

    func test_requeue_placesMessagesAheadOfArrivalsDuringTheGap() async throws {
        // Contract: a message that arrived in the window between the
        // failed receiveMessages call and the requeue call must not jump
        // ahead of the requeued (earlier-sent) messages.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg1 = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "first")
        let received = await store.receiveMessages(for: peerB.id)

        // A new message arrives during the gap before requeue runs.
        let msg2 = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "arrived during the gap")

        // Act
        await store.requeue(received, for: peerB.id)

        // Assert
        let redelivered = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(redelivered.map(\.id), [msg1.id, msg2.id],
                       "requeued messages must be returned before anything that arrived after the " +
                       "failed receive")
    }

    func test_requeue_emptyMessages_isNoOp() async throws {
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "untouched")

        await store.requeue([], for: peerB.id)

        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 1, "requeue([]) must not disturb the existing inbox")
    }

    func test_requeue_expiredPeer_isNoOp() async throws {
        // Contract: requeue must not revive a peer that expired in the
        // gap between the failed receiveMessages call and the requeue
        // call — same revive-prevention rule every other IPCStore API
        // follows.
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let msg = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "hi")
        let received = await store.receiveMessages(for: peerB.id)

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        await store.requeue(received, for: peerB.id)

        let peers = await store.listPeers()
        XCTAssertFalse(peers.map(\.id).contains(peerB.id),
                       "requeue on an expired peer must not revive it")
    }

    func test_requeue_capsCombinedTotal_dropsOldestOfTheRequeuedMessagesFirst() async throws {
        // Contract: if requeuing would push the peer's inbox over
        // maxMessagesPerPeer (100), requeue must trim from the FRONT of
        // the combined array — same drop-oldest-first policy as
        // appendCapped — so the oldest of the requeued (earlier-sent)
        // messages are dropped before any message that arrived during
        // the gap.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // 60 messages, all received (and thereby deleted) in one call.
        for i in 0..<60 {
            _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "requeued-\(i)")
        }
        let received = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(received.count, 60, "Precondition: all 60 messages were received in one call")

        // 50 more arrive during the gap before requeue runs — 60 + 50 = 110, over the 100 cap.
        for i in 0..<50 {
            _ = try await store.sendMessage(from: peerA.id, to: peerB.id, content: "gap-\(i)")
        }

        // Act
        await store.requeue(received, for: peerB.id)

        // Assert
        let redelivered = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(redelivered.count, 100,
                       "Combined total must be trimmed to maxMessagesPerPeer (100)")

        let contents = redelivered.map(\.content)
        for i in 0..<10 {
            XCTAssertFalse(contents.contains("requeued-\(i)"),
                           "The oldest 10 of the requeued messages must be dropped to make room")
        }
        for i in 10..<60 {
            XCTAssertTrue(contents.contains("requeued-\(i)"),
                          "Requeued messages after the dropped oldest 10 must survive the trim")
        }
        for i in 0..<50 {
            XCTAssertTrue(contents.contains("gap-\(i)"),
                          "Messages that arrived during the gap must all survive the trim")
        }
        XCTAssertEqual(contents.first, "requeued-10",
                       "The oldest surviving requeued message must still be returned first")
    }

    // ============================================================
    // MARK: - IPC wake: offerWakes and the per-message nudged flag
    // ============================================================
    //
    // A message carries one flag, `nudged`: whether a waiting `/ipc-wake`
    // poll has already been told about it. `offerWakes(to:)` is the only
    // writer. For each peer in `takers` that has at least one un-nudged
    // message it builds an IPCWakeTicket and calls that peer's taker; the
    // un-nudged messages become nudged only if the taker returns true.
    // The flag is part of the Message value, so every operation that
    // moves or drops messages moves or drops the flag with them.

    private func wakeTaker(
        _ recorder: WakeTicketRecorder, accept: Bool
    ) -> @Sendable (IPCWakeTicket) -> Bool {
        { ticket in
            recorder.record(ticket)
            return accept
        }
    }

    // ==================== offerWakes: ticket contents ====================

    func test_offerWakes_unNudgedMessages_callsTakerWithNewSenderAndUnreadCounts() async throws {
        let store = makeStore()
        let senderX = await store.registerPeer(name: "X", role: "terminal")
        let senderY = await store.registerPeer(name: "Y", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: senderX.id, to: recipient.id, content: "x1")
        _ = try await store.sendMessage(from: senderX.id, to: recipient.id, content: "x2")
        _ = try await store.sendMessage(from: senderY.id, to: recipient.id, content: "y1")
        let recorder = WakeTicketRecorder()

        _ = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [IPCWakeTicket(newCount: 3, senderCount: 2, unreadCount: 3)],
                       "the taker must be called exactly once, with 3 new messages from 2 distinct " +
                       "senders out of 3 in the inbox")
    }

    func test_newMessages_startUnNudged() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        let sent = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.broadcast(from: sender.id, content: "two")

        XCTAssertFalse(sent.nudged, "a freshly sent message must not be nudged")
        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [false, false], "sent and broadcast messages must both start un-nudged")
    }

    // ==================== offerWakes: taker decides ====================

    func test_offerWakes_takerReturnsTrue_marksThoseMessagesAndReturnsThePeer() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(woken, [recipient.id], "a peer whose taker returned true must be in the result")
        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [true, true], "both offered messages must be nudged once the taker accepted")
        let count = await store.inboxCount(for: recipient.id)
        XCTAssertEqual(count, 2, "a wake only marks messages; it never removes them from the inbox")
    }

    func test_offerWakes_takerReturnsFalse_changesNothingAndReturnsNothing() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: false)])

        XCTAssertEqual(recorder.tickets.count, 1, "precondition: the taker was offered the wake")
        XCTAssertEqual(woken, [], "a peer whose taker returned false must not be in the result")
        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [false, false], "a refused wake must leave every message un-nudged")

        // The refused messages are offered again, unchanged, next time.
        let secondRecorder = WakeTicketRecorder()
        let wokenAgain = await store.offerWakes(to: [recipient.id: wakeTaker(secondRecorder, accept: true)])
        XCTAssertEqual(secondRecorder.tickets, [IPCWakeTicket(newCount: 2, senderCount: 1, unreadCount: 2)])
        XCTAssertEqual(wokenAgain, [recipient.id])
    }

    // ==================== offerWakes: nothing to offer ====================

    func test_offerWakes_emptyInbox_doesNotCallTaker() async {
        let store = makeStore()
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [], "a peer with no message must not have its taker called")
        XCTAssertEqual(woken, [])
    }

    func test_offerWakes_allMessagesAlreadyNudged_doesNotCallTaker() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        let flagsBefore = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsBefore, [true], "precondition: the only message is nudged")
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [],
                       "a nudged message must never cause a second wake: the taker must not be called")
        XCTAssertEqual(woken, [])
    }

    func test_offerWakes_unknownPeer_doesNotCallTaker() async {
        let store = makeStore()
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [UUID(): wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [])
        XCTAssertEqual(woken, [])
    }

    func test_offerWakes_noTakers_returnsEmptyAndMarksNothing() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")

        let woken = await store.offerWakes(to: [:])

        XCTAssertEqual(woken, [])
        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [false], "a peer that is not in takers must keep its messages un-nudged")
    }

    // ==================== offerWakes: nudged and un-nudged mixed ====================

    func test_offerWakes_mixedInbox_countsNewAndSendersAmongUnNudgedOnly_unreadForWholeInbox() async throws {
        let store = makeStore()
        let senderX = await store.registerPeer(name: "X", role: "terminal")
        let senderY = await store.registerPeer(name: "Y", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        // X's message is nudged by a first wake.
        _ = try await store.sendMessage(from: senderX.id, to: recipient.id, content: "x1")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        // Y's two messages arrive afterwards and are un-nudged.
        _ = try await store.sendMessage(from: senderY.id, to: recipient.id, content: "y1")
        _ = try await store.sendMessage(from: senderY.id, to: recipient.id, content: "y2")
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [IPCWakeTicket(newCount: 2, senderCount: 1, unreadCount: 3)],
                       "newCount counts the 2 un-nudged messages, senderCount their 1 sender (Y; X only " +
                       "sent the nudged one), unreadCount all 3 in the inbox")
        XCTAssertEqual(woken, [recipient.id])
        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [true, true, true])
    }

    func test_offerWakes_afterAWake_onlyLaterArrivalsAreInTheNextTicket() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        let firstRecorder = WakeTicketRecorder()
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(firstRecorder, accept: true)])
        XCTAssertEqual(firstRecorder.tickets, [IPCWakeTicket(newCount: 2, senderCount: 1, unreadCount: 2)],
                       "precondition: the first wake counted both messages")

        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "three")
        let flagsBetween = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsBetween, [true, true, false], "only the later arrival is un-nudged")
        let secondRecorder = WakeTicketRecorder()
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(secondRecorder, accept: true)])

        XCTAssertEqual(secondRecorder.tickets, [IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 3)],
                       "the second ticket must count only the message that arrived after the first wake")
    }

    // ==================== offerWakes: several peers ====================

    func test_offerWakes_severalPeersInOneCall_areIndependent() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let accepting = await store.registerPeer(name: "accepting", role: "terminal")
        let refusing = await store.registerPeer(name: "refusing", role: "terminal")
        let empty = await store.registerPeer(name: "empty", role: "terminal")
        let notOffered = await store.registerPeer(name: "not-offered", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: accepting.id, content: "a1")
        _ = try await store.sendMessage(from: sender.id, to: refusing.id, content: "r1")
        _ = try await store.sendMessage(from: sender.id, to: refusing.id, content: "r2")
        _ = try await store.sendMessage(from: sender.id, to: notOffered.id, content: "n1")
        let acceptingRecorder = WakeTicketRecorder()
        let refusingRecorder = WakeTicketRecorder()
        let emptyRecorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [
            accepting.id: wakeTaker(acceptingRecorder, accept: true),
            refusing.id: wakeTaker(refusingRecorder, accept: false),
            empty.id: wakeTaker(emptyRecorder, accept: true),
        ])

        XCTAssertEqual(woken, [accepting.id], "only the peer whose taker accepted is in the result")
        XCTAssertEqual(acceptingRecorder.tickets, [IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)])
        XCTAssertEqual(refusingRecorder.tickets, [IPCWakeTicket(newCount: 2, senderCount: 1, unreadCount: 2)])
        XCTAssertEqual(emptyRecorder.tickets, [], "the peer with an empty inbox is never offered a wake")
        let acceptingFlags = await store._testNudgedFlags(for: accepting.id)
        let refusingFlags = await store._testNudgedFlags(for: refusing.id)
        let notOfferedFlags = await store._testNudgedFlags(for: notOffered.id)
        XCTAssertEqual(acceptingFlags, [true])
        XCTAssertEqual(refusingFlags, [false, false], "one peer's accepted wake must not mark another's messages")
        XCTAssertEqual(notOfferedFlags, [false], "a peer that is not in takers is untouched")
    }

    // ==================== offerWakes: read-only apart from the flag ====================

    func test_offerWakes_doesNotBumpLastSeen() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let accepting = await store.registerPeer(name: "accepting", role: "terminal")
        let refusing = await store.registerPeer(name: "refusing", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: accepting.id, content: "a1")
        _ = try await store.sendMessage(from: sender.id, to: refusing.id, content: "r1")
        // Well within the TTL, so a spurious bump is observable.
        let fiveMinutesAgo = Date().addingTimeInterval(-5 * 60)
        for peer in [sender, accepting, refusing] {
            await store._testSetPeerLastSeen(peerId: peer.id, date: fiveMinutesAgo)
        }
        let senderBefore = await store.peerStatus(id: sender.id)?.lastSeen
        let acceptingBefore = await store.peerStatus(id: accepting.id)?.lastSeen
        let refusingBefore = await store.peerStatus(id: refusing.id)?.lastSeen
        XCTAssertEqual(acceptingBefore, fiveMinutesAgo, "precondition: lastSeen was set back")

        let woken = await store.offerWakes(to: [
            accepting.id: wakeTaker(WakeTicketRecorder(), accept: true),
            refusing.id: wakeTaker(WakeTicketRecorder(), accept: false),
        ])
        XCTAssertEqual(woken, [accepting.id], "precondition: one wake was accepted and one refused")

        let senderAfter = await store.peerStatus(id: sender.id)?.lastSeen
        let acceptingAfter = await store.peerStatus(id: accepting.id)?.lastSeen
        let refusingAfter = await store.peerStatus(id: refusing.id)?.lastSeen
        XCTAssertEqual(acceptingAfter, acceptingBefore, "an accepted wake must not bump the recipient's lastSeen")
        XCTAssertEqual(refusingAfter, refusingBefore, "a refused wake must not bump the recipient's lastSeen")
        XCTAssertEqual(senderAfter, senderBefore, "a wake must not bump the sender's lastSeen")
    }

    /// Every liveness-gated API purges an expired peer it is asked about.
    /// offerWakes is not one of them: the expired entry is left exactly as
    /// it was. `_testSetPeerLastSeen` only changes a peer that is still
    /// stored, so making the peer fresh again afterwards and then reading
    /// it tells a kept entry (non-nil) from a purged one (nil).
    func test_offerWakes_doesNotPurgeAnExpiredPeer() async {
        let store = makeStore()
        let expired = await store.registerPeer(name: "expired", role: "terminal")
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: expired.id, date: elevenMinutesAgo)
        let recorder = WakeTicketRecorder()

        let woken = await store.offerWakes(to: [expired.id: wakeTaker(recorder, accept: true)])

        XCTAssertEqual(recorder.tickets, [], "the expired peer has no message, so its taker is not called")
        XCTAssertEqual(woken, [])
        await store._testSetPeerLastSeen(peerId: expired.id, date: Date())
        let status = await store.peerStatus(id: expired.id)
        XCTAssertEqual(status?.id, expired.id,
                       "offerWakes must not purge an expired peer: its entry must still be stored")
    }

    // ==================== The flag travels with the message ====================

    func test_receiveMessages_returnsMessagesCarryingTheirFlags() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        let first = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        let second = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        let third = try await store.sendMessage(from: sender.id, to: recipient.id, content: "three")

        let received = await store.receiveMessages(for: recipient.id)

        XCTAssertEqual(received.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(received.map(\.nudged), [true, true, false],
                       "received messages must carry the flag they had in the inbox")
        let flagsAfter = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsAfter, [], "receiveMessages removes the messages, and their flags with them")
    }

    func test_requeue_restoresMessagesWithTheFlagsTheyHadWhenDrained() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "three")
        let received = await store.receiveMessages(for: recipient.id)
        XCTAssertEqual(received.count, 3, "precondition: all three messages were drained")

        await store.requeue(received, for: recipient.id)

        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [true, true, false],
                       "requeue must keep each message's flag: nudged stays nudged, un-nudged stays un-nudged")

        // The requeued nudged messages cause no second wake; the requeued
        // un-nudged one is still owed its wake.
        let recorder = WakeTicketRecorder()
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])
        XCTAssertEqual(recorder.tickets, [IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 3)])
    }

    func test_requeue_aheadOfANewArrival_keepsEachMessagesOwnFlag() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        let received = await store.receiveMessages(for: recipient.id)
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "arrived during the gap")

        await store.requeue(received, for: recipient.id)

        let flags = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flags, [true, false],
                       "the requeued (nudged) message goes first and the gap arrival stays un-nudged")
    }

    // ==================== The flag is dropped with the message ====================

    func test_messageLimit_overflowDropsFlagsTogetherWithTheOldestMessages() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        for i in 0..<100 {
            _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "old-\(i)")
        }
        let recorder = WakeTicketRecorder()
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])
        XCTAssertEqual(recorder.tickets, [IPCWakeTicket(newCount: 100, senderCount: 1, unreadCount: 100)],
                       "precondition: all 100 messages were nudged by one wake")

        // One more pushes the oldest (nudged) message out.
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "new-0")

        let flagsAfterOne = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsAfterOne, Array(repeating: true, count: 99) + [false],
                       "the inbox stays at 100: 99 surviving nudged messages and the 1 new un-nudged one")

        // 99 more push out every nudged message.
        for i in 1..<100 {
            _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "new-\(i)")
        }

        let flagsAfterAll = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsAfterAll, Array(repeating: false, count: 100),
                       "no nudged flag may outlive the message it belonged to")
    }

    func test_removePeer_dropsFlagsTogetherWithTheMessages() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        let flagsBefore = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsBefore, [true, false], "precondition: one nudged and one un-nudged message")

        await store.removePeer(id: recipient.id)

        let flagsAfter = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsAfter, [], "removing the peer removes its messages and their flags")
        let recorder = WakeTicketRecorder()
        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])
        XCTAssertEqual(recorder.tickets, [], "a removed peer has nothing left to be woken for")
        XCTAssertEqual(woken, [])
    }

    func test_cleanup_dropsFlagsTogetherWithTheMessages() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "one")
        _ = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "two")
        let flagsBefore = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsBefore, [true, false], "precondition: one nudged and one un-nudged message")

        await store.cleanup()

        let flagsAfter = await store._testNudgedFlags(for: recipient.id)
        XCTAssertEqual(flagsAfter, [], "cleanup removes every message and its flag")
        let recorder = WakeTicketRecorder()
        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(recorder, accept: true)])
        XCTAssertEqual(recorder.tickets, [])
        XCTAssertEqual(woken, [])
    }

    // ==================== Message's Codable form does not carry the flag ====================
    //
    // `nudged` is in-memory wake bookkeeping. The encoded form of a
    // Message is what it was before the field existed: exactly `id`,
    // `from`, `to`, `content`, `timestamp`. Encoding never emits the flag,
    // and JSON without it decodes to an un-nudged message.

    /// Sends one message and has a wake accepted for it, then drains it:
    /// the returned value is a nudged Message obtained the real way.
    private func makeNudgedMessage() async throws -> Message {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        _ = try await store.sendMessage(from: sender.id, to: recipient.id, content: "nudged one")
        let woken = await store.offerWakes(to: [recipient.id: wakeTaker(WakeTicketRecorder(), accept: true)])
        XCTAssertEqual(woken, [recipient.id], "precondition: the wake was accepted")
        let received = await store.receiveMessages(for: recipient.id)
        let message = try XCTUnwrap(received.first)
        XCTAssertTrue(message.nudged, "precondition: the drained message is nudged")
        return message
    }

    private func encodedKeys(of message: Message) throws -> Set<String> {
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    func test_messageEncoding_unNudgedMessage_hasExactlyTheFiveOriginalKeys() async throws {
        let store = makeStore()
        let sender = await store.registerPeer(name: "S", role: "terminal")
        let recipient = await store.registerPeer(name: "R", role: "terminal")
        let message = try await store.sendMessage(from: sender.id, to: recipient.id, content: "plain")
        XCTAssertFalse(message.nudged, "precondition: a freshly sent message is un-nudged")

        let keys = try encodedKeys(of: message)

        XCTAssertEqual(keys, ["id", "from", "to", "content", "timestamp"],
                       "an encoded Message must have exactly its five original keys; nudged is never serialized")
    }

    func test_messageEncoding_nudgedMessage_hasExactlyTheFiveOriginalKeys() async throws {
        let message = try await makeNudgedMessage()

        let keys = try encodedKeys(of: message)

        XCTAssertEqual(keys, ["id", "from", "to", "content", "timestamp"],
                       "an encoded Message must have exactly its five original keys, nudged or not")
    }

    /// The JSON below is written by hand in the shape JSONEncoder produced
    /// before the field existed: UUIDs as strings and, with the encoder's
    /// default date strategy, the timestamp as seconds since the reference
    /// date.
    func test_messageDecoding_jsonWithTheFiveOriginalKeys_succeedsWithNudgedFalse() throws {
        let json = Data("""
        {"id":"0A0B0C0D-1111-4222-8333-444455556666",
         "from":"1A1B1C1D-1111-4222-8333-444455556666",
         "to":"2A2B2C2D-1111-4222-8333-444455556666",
         "content":"from before the flag",
         "timestamp":700000000.5}
        """.utf8)

        let message = try JSONDecoder().decode(Message.self, from: json)

        XCTAssertEqual(message.id, UUID(uuidString: "0A0B0C0D-1111-4222-8333-444455556666"))
        XCTAssertEqual(message.from, UUID(uuidString: "1A1B1C1D-1111-4222-8333-444455556666"))
        XCTAssertEqual(message.to, UUID(uuidString: "2A2B2C2D-1111-4222-8333-444455556666"))
        XCTAssertEqual(message.content, "from before the flag")
        XCTAssertEqual(message.timestamp, Date(timeIntervalSinceReferenceDate: 700_000_000.5))
        XCTAssertFalse(message.nudged, "a decoded Message is un-nudged")
    }

    func test_messageCodableRoundTrip_nudgedMessage_comesBackUnNudgedWithTheOtherFieldsEqual() async throws {
        let message = try await makeNudgedMessage()

        let decoded = try JSONDecoder().decode(Message.self, from: try JSONEncoder().encode(message))

        XCTAssertFalse(decoded.nudged, "the encoded form does not carry the flag, so a round trip yields un-nudged")
        XCTAssertEqual(decoded.id, message.id)
        XCTAssertEqual(decoded.from, message.from)
        XCTAssertEqual(decoded.to, message.to)
        XCTAssertEqual(decoded.content, message.content)
        XCTAssertEqual(decoded.timestamp, message.timestamp)
    }
}

/// Records every ticket a wake taker is offered. A taker is `@Sendable`
/// and runs inside the IPCStore actor, so the record is lock-protected
/// rather than a captured local.
private final class WakeTicketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [IPCWakeTicket] = []

    func record(_ ticket: IPCWakeTicket) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(ticket)
    }

    var tickets: [IPCWakeTicket] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
