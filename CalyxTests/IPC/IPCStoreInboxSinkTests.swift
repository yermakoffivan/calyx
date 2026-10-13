//
//  IPCStoreInboxSinkTests.swift
//  CalyxTests
//
//  Pins IPCStore's inbox-growth report: the one `@Sendable (UUID) -> Void`
//  sink installed with `setInboxAppendedSink(_:)` is called, synchronously
//  inside the actor, with the recipient's peer id each time a message is
//  added to an inbox. The public APIs that add messages are `sendMessage`,
//  `broadcast` (once per recipient) and `requeue`; nothing else calls the
//  sink. With no sink installed nothing happens.
//
//  Because the sink runs inside the actor call that added the message,
//  the record is complete when the awaited store call returns: nothing
//  here waits for time to pass.
//
//  Coverage:
//  - sendMessage: one call, with the recipient's id
//  - broadcast: one call per recipient (compared as a multiset, since
//    the store's peer order is not specified), none for the sender
//  - requeue of a non-empty batch: one call with the peer's id
//  - receiveMessages, cleanup, removePeer, offerWakes, registerPeer,
//    listPeers, inboxCounts, inboxCount: no call
//  - a sendMessage that throws (content too large, unknown recipient), a
//    requeue of an empty batch: no call (inferred from "the inbox grew":
//    none of them adds a message)
//  - a sink set back to nil is no longer called; no sink at all: the
//    store works as before
//  - installing a second sink replaces the first
//

import XCTest
@testable import Calyx

final class IPCStoreInboxSinkTests: XCTestCase {

    // MARK: - Helpers

    /// Records every peer id the sink is called with. Lock-protected,
    /// because the sink runs on the store's executor.
    private final class SinkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UUID] = []

        var calls: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ peerID: UUID) {
            lock.lock()
            recorded.append(peerID)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            recorded.removeAll()
            lock.unlock()
        }
    }

    private func makeStoreWithSink() async -> (IPCStore, SinkRecorder) {
        let store = IPCStore()
        let recorder = SinkRecorder()
        await store.setInboxAppendedSink { peerID in recorder.record(peerID) }
        return (store, recorder)
    }

    /// Occurrence count of each id: a multiset, independent of order.
    private func counts(_ ids: [UUID]) -> [UUID: Int] {
        ids.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: - The three APIs that add messages

    func test_sendMessage_callsTheSinkOnce_withTheRecipient() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id
        XCTAssertEqual(recorder.calls, [], "precondition: registering peers adds no message")

        _ = try await store.sendMessage(from: sender, to: recipient, content: "hello")

        XCTAssertEqual(recorder.calls, [recipient],
                       "sendMessage must report exactly one inbox growth, the recipient's")
    }

    func test_sendMessage_twice_callsTheSinkOncePerMessage() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id

        _ = try await store.sendMessage(from: sender, to: recipient, content: "one")
        _ = try await store.sendMessage(from: sender, to: recipient, content: "two")

        XCTAssertEqual(recorder.calls, [recipient, recipient], "one report per added message")
    }

    func test_broadcast_callsTheSinkOncePerRecipient_andNeverForTheSender() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipientA = await store.registerPeer(name: "a", role: "terminal").id
        let recipientB = await store.registerPeer(name: "b", role: "terminal").id
        let recipientC = await store.registerPeer(name: "c", role: "terminal").id

        let delivered = try await store.broadcast(from: sender, content: "to everyone")

        XCTAssertEqual(delivered.count, 3, "precondition: the broadcast reached three recipients")
        XCTAssertEqual(counts(recorder.calls), [recipientA: 1, recipientB: 1, recipientC: 1],
                       "broadcast must report each recipient's inbox exactly once, and never the sender's")
    }

    func test_requeue_nonEmptyBatch_callsTheSinkOnce_withThePeer() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id
        _ = try await store.sendMessage(from: sender, to: recipient, content: "one")
        _ = try await store.sendMessage(from: sender, to: recipient, content: "two")
        let received = await store.receiveMessages(for: recipient)
        XCTAssertEqual(received.count, 2, "precondition: both messages were received")
        recorder.reset()

        await store.requeue(received, for: recipient)

        XCTAssertEqual(recorder.calls, [recipient],
                       "requeue puts messages back into the inbox and must report that growth once")
        let countAfter = await store.inboxCount(for: recipient)
        XCTAssertEqual(countAfter, 2, "precondition: the requeue really put both messages back")
    }

    // MARK: - APIs that add no message

    func test_receiveMessages_doesNotCallTheSink() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id
        _ = try await store.sendMessage(from: sender, to: recipient, content: "hello")
        recorder.reset()

        let received = await store.receiveMessages(for: recipient)

        XCTAssertEqual(received.count, 1, "precondition: the message was received")
        XCTAssertEqual(recorder.calls, [], "receiving removes messages; it must not report growth")
    }

    func test_cleanup_removePeer_offerWakes_andTheReaders_doNotCallTheSink() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id
        let other = await store.registerPeer(name: "other", role: "terminal").id
        _ = try await store.sendMessage(from: sender, to: recipient, content: "hello")
        _ = try await store.sendMessage(from: sender, to: other, content: "hello")
        recorder.reset()

        let woken = await store.offerWakes(to: [recipient: { _ in true }])
        XCTAssertEqual(woken, [recipient], "precondition: offerWakes handed a wake over")
        _ = await store.listPeers()
        _ = await store.inboxCounts(for: [recipient, other])
        _ = await store.inboxCount(for: recipient)
        _ = await store.registerPeer(name: "late", role: "terminal")
        await store.removePeer(id: other)
        await store.cleanup()

        XCTAssertEqual(recorder.calls, [],
                       "offerWakes, listPeers, inboxCounts, inboxCount, registerPeer, removePeer and cleanup " +
                       "add no message and must never call the sink")
    }

    func test_failedSendMessage_andEmptyRequeue_doNotCallTheSink() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id

        let oversized = String(repeating: "x", count: 65_537)
        do {
            _ = try await store.sendMessage(from: sender, to: recipient, content: oversized)
            XCTFail("precondition: content over 64 KiB must be rejected")
        } catch {}
        do {
            _ = try await store.sendMessage(from: sender, to: UUID(), content: "hello")
            XCTFail("precondition: an unknown recipient must be rejected")
        } catch {}
        await store.requeue([], for: recipient)

        XCTAssertEqual(recorder.calls, [], "nothing was added to any inbox, so nothing may be reported")
        let countAfter = await store.inboxCount(for: recipient)
        XCTAssertEqual(countAfter, 0, "precondition: the inbox really is still empty")
    }

    // MARK: - Installing and removing the sink

    func test_sinkSetBackToNil_isNoLongerCalled_andTheStoreStillDelivers() async throws {
        let (store, recorder) = await makeStoreWithSink()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id
        _ = try await store.sendMessage(from: sender, to: recipient, content: "one")
        XCTAssertEqual(recorder.calls, [recipient], "precondition: the installed sink is called")

        await store.setInboxAppendedSink(nil)
        _ = try await store.sendMessage(from: sender, to: recipient, content: "two")
        _ = try await store.broadcast(from: sender, content: "three")

        XCTAssertEqual(recorder.calls, [recipient], "a sink set back to nil must not be called again")
        let countAfter = await store.inboxCount(for: recipient)
        XCTAssertEqual(countAfter, 3, "with no sink the messages are still delivered")
    }

    func test_secondSink_replacesTheFirst() async throws {
        let (store, first) = await makeStoreWithSink()
        let second = SinkRecorder()
        let sender = await store.registerPeer(name: "sender", role: "terminal").id
        let recipient = await store.registerPeer(name: "recipient", role: "terminal").id

        await store.setInboxAppendedSink { peerID in second.record(peerID) }
        _ = try await store.sendMessage(from: sender, to: recipient, content: "hello")

        XCTAssertEqual(first.calls, [], "the replaced sink must not be called")
        XCTAssertEqual(second.calls, [recipient], "the store holds one sink: the one installed last")
    }
}
