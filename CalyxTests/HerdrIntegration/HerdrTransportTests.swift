//
//  HerdrTransportTests.swift
//  CalyxTests
//
//  Two independent conformers of `HerdrTransport`, covered separately
//  below:
//
//  1. `InMemoryHerdrTransport` -- the fully-real (not a stub) test
//     double `HerdrSocketSessionTests` builds on. These tests PASS
//     already: the double is test infrastructure, not
//     under-development production logic. They exist so the double's
//     own contract -- capture-what-was-sent, and EOF vs failure as
//     distinct, stream-terminating events -- is pinned and trustworthy
//     before HerdrSocketSessionTests relies on it.
//
//     Coverage:
//     - connect() records the socket path
//     - send() captures lines verbatim, in order
//     - send() throws once closed
//     - simulateLine() delivers a line on `incoming`
//     - simulateEOF() yields .eof then finishes the stream -- no
//       further .line ever follows
//     - simulateFailure() yields .failure (carrying the message) then
//       finishes the stream -- distinct from simulateEOF(), the core
//       "EOF surfaced distinctly from a [transport] error" regression
//       pin at the transport layer
//     - close() is idempotent and finishes `incoming`
//
//  2. `BSDHerdrTransport` -- the production conformer, a real BSD
//     Unix-domain socket. Exercised here against a real local socket
//     this file itself binds and listens on, the same fixture approach
//     `HerdrSessionDiscoveryTests` already established for
//     `HerdrSessionDiscovery.isAlive(socketPath:)` (short `/tmp`-rooted
//     fixture directories, mindful of sockaddr_un.sun_path's 104-byte
//     limit) -- see HerdrTransport.swift's own header for why this type
//     needed exactly this, not `InMemoryHerdrTransport`.
//
//     Coverage:
//     - connect() against a live listener succeeds; against a
//       nonexistent path throws
//     - send() before connect() throws .notConnected; connect() called
//       twice throws .alreadyConnected; send() after close() throws
//       .alreadyClosed
//     - a line written by the peer arrives on `incoming` as `.line`
//     - send() writes the line to the peer VERBATIM, including the
//       transport's own added trailing newline (the transport owns
//       framing, not the caller)
//     - a clean peer disconnect (peer-side close(), recv() == 0)
//       surfaces `.eof`, never `.failure`, and the stream finishes
//       immediately after -- no further element
//     - a line that fails UTF-8 decoding surfaces `.failure` instead,
//       completing the eof-vs-failure distinctness pin from the real
//       socket path (the other half already lives in
//       `InMemoryHerdrTransport`'s own simulateEOF/simulateFailure
//       tests above)
//     - close() actually releases the OS-level file descriptor (probed
//       via `fcntl(fd, F_GETFD)` after capturing the connected fd
//       through the `testOnlyConnectedFileDescriptor()` test seam on
//       `BSDHerdrTransport`), not merely flips internal state
//     - the instance deallocates once its only strong reference is
//       released after close() (a weak reference observably goes nil)
//
//     Deliberately NOT covered: interruptible-blocked-write recovery,
//     SIGPIPE suppression, and EINTR retry
//     (`BSDHerdrTransport.writeAll(_:to:)` /
//     `.waitForWritability(fd:)`). Reproducing them deterministically
//     needs either filling the kernel socket send buffer to force a
//     genuine EAGAIN/EWOULDBLOCK stall or killing the peer mid-write to
//     force SIGPIPE/EPIPE -- both are timing- and buffer-size-dependent
//     in a way a unit test cannot pin down reliably; see
//     `BSDHerdrTransport`'s own doc comments for the (unmeasured, by
//     its own admission) reasoning behind that code instead.
//

import Darwin
import XCTest
@testable import Calyx

final class HerdrTransportTests: XCTestCase {

    // MARK: - connect()

    func test_connect_recordsSocketPath() async throws {
        let transport = InMemoryHerdrTransport()

        try await transport.connect(socketPath: "/tmp/herdr-test/herdr.sock")

        let recorded = await transport.lastConnectedSocketPath()
        XCTAssertEqual(recorded, "/tmp/herdr-test/herdr.sock")
    }

    // MARK: - send()

    func test_send_capturesLinesVerbatimInOrder() async throws {
        let transport = InMemoryHerdrTransport()

        try await transport.send(#"{"id":"1","method":"ping"}"#)
        try await transport.send(#"{"id":"2","method":"session.snapshot"}"#)

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent, [
            #"{"id":"1","method":"ping"}"#,
            #"{"id":"2","method":"session.snapshot"}"#,
        ])
    }

    func test_send_throwsAfterClose() async throws {
        let transport = InMemoryHerdrTransport()
        await transport.close()

        do {
            try await transport.send(#"{"id":"1","method":"ping"}"#)
            XCTFail("expected send() to throw once the transport is closed")
        } catch {
            // expected
        }
    }

    // MARK: - simulateLine()

    func test_simulateLine_deliversLineOnIncomingStream() async throws {
        let transport = InMemoryHerdrTransport()
        var iterator = transport.incoming.makeAsyncIterator()

        await transport.simulateLine(#"{"id":"1","result":{}}"#)

        let event = await iterator.next()
        XCTAssertEqual(event, .line(#"{"id":"1","result":{}}"#))
    }

    // MARK: - simulateEOF() vs simulateFailure() -- the transport-level distinctness pin

    func test_simulateEOF_yieldsEOFThenFinishesStream_noLineEverFollows() async throws {
        let transport = InMemoryHerdrTransport()
        var iterator = transport.incoming.makeAsyncIterator()

        await transport.simulateEOF()
        // A line simulated AFTER EOF must be dropped -- the transport
        // is already closed, mirroring a real dead connection.
        await transport.simulateLine(#"{"id":"1","result":{}}"#)

        let first = await iterator.next()
        XCTAssertEqual(first, .eof)
        let second = await iterator.next()
        XCTAssertNil(second, "the stream must finish immediately after .eof -- no further element, not even a late .line")
    }

    func test_simulateFailure_yieldsFailureThenFinishesStream_distinctFromEOF() async throws {
        let transport = InMemoryHerdrTransport()
        var iterator = transport.incoming.makeAsyncIterator()

        await transport.simulateFailure("recv() returned EBADF")

        let first = await iterator.next()
        XCTAssertEqual(first, .failure(HerdrTransportFailure(message: "recv() returned EBADF")))
        XCTAssertNotEqual(first, .eof, "a transport failure must never be observably equal to a clean EOF")
        let second = await iterator.next()
        XCTAssertNil(second, "the stream must finish immediately after .failure")
    }

    // MARK: - close()

    func test_close_isIdempotent_andFinishesIncomingStream() async throws {
        let transport = InMemoryHerdrTransport()
        var iterator = transport.incoming.makeAsyncIterator()

        await transport.close()
        await transport.close() // second call must not crash / double-finish

        let next = await iterator.next()
        XCTAssertNil(next, "close() must finish `incoming` with no elements when nothing was ever simulated")
    }

    // MARK: - BSDHerdrTransport fixtures (real bound-and-listening AF_UNIX sockets)
    //
    // Mirrors HerdrSessionDiscoveryTests' own fixture style: a short
    // `/tmp`-rooted directory (never
    // FileManager.default.temporaryDirectory, which alone already eats
    // most of sockaddr_un.sun_path's 104-byte budget on macOS) plus a
    // raw socket(2)/bind(2)/listen(2) fixture the test itself owns both
    // ends of. Unlike HerdrSessionDiscoveryTests (which only ever probes
    // liveness with connect()), these tests also accept the resulting
    // connection and read/write real bytes on it, so this section adds
    // acceptOnePeer/readBytes/writeAll fixture helpers
    // HerdrSessionDiscoveryTests never needed.

    private enum TransportFixtureError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pollFailed(Int32)
        case acceptFailed(Int32)
        case acceptTimedOut
        case readFailed(Int32)
        case readTimedOut
        case writeFailed(Int32)

        var description: String {
            switch self {
            case .pathTooLong(let detail): return "fixture socket path too long: \(detail)"
            case .socketCreateFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e): return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            case .pollFailed(let e): return "poll() failed: errno \(e)"
            case .acceptFailed(let e): return "accept() failed: errno \(e)"
            case .acceptTimedOut: return "accept() saw no pending connection within the fixture deadline"
            case .readFailed(let e): return "recv() failed: errno \(e)"
            case .readTimedOut: return "did not receive the expected byte count within the fixture deadline"
            case .writeFailed(let e): return "write() failed: errno \(e)"
            }
        }
    }

    /// A short `/tmp`-rooted directory (8 hex characters, deliberately
    /// NOT `FileManager.default.temporaryDirectory`) so every socket
    /// path built under it stays far under Darwin's 104-byte
    /// `sockaddr_un.sun_path` limit -- mirrors
    /// `HerdrSessionDiscoveryTests`' own `shortSocketFixtureRoot()`.
    private func shortSocketFixtureRoot() -> String {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/hbt-\(suffix)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Binds and listens a real AF_UNIX SOCK_STREAM socket at `path`,
    /// returning the raw listening fd (caller closes it, and is
    /// responsible for removing the containing fixture directory --
    /// this only creates the socket special file inside it).
    private func bindAndListenUnixSocketFixture(at path: String, backlog: Int32 = 1) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 100 else {
            throw TransportFixtureError.pathTooLong(
                "\(pathBytes.count) bytes (limit ~100 to stay under sockaddr_un's 104-byte sun_path): \(path)"
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportFixtureError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            Darwin.close(fd)
            throw TransportFixtureError.bindFailed(bindErrno)
        }

        guard listen(fd, backlog) == 0 else {
            let listenErrno = errno
            Darwin.close(fd)
            throw TransportFixtureError.listenFailed(listenErrno)
        }

        return fd
    }

    /// `poll(2)`s `fd` for `POLLIN` readability for up to
    /// `timeoutMilliseconds`, retrying internally on `EINTR`. One
    /// bounded wait, never an indefinite block -- the building block
    /// both `acceptOnePeer` and `readBytes` loop on below to enforce
    /// their own overall wall-clock deadlines.
    private func pollReadable(fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&pfd, 1, timeoutMilliseconds)
            if result < 0 {
                let pollErrno = errno
                if pollErrno == EINTR { continue }
                throw TransportFixtureError.pollFailed(pollErrno)
            }
            return result > 0 && (pfd.revents & Int16(POLLIN) != 0)
        }
    }

    /// Accepts one pending connection on `listenerFD`, waiting via a
    /// bounded, repeated `poll(2)` (never a fixed `sleep`) for up to
    /// `deadlineSeconds`. AF_UNIX `connect()` completes synchronously at
    /// the kernel level (no handshake latency, unlike TCP), so in
    /// practice this returns on its very first poll once
    /// `BSDHerdrTransport.connect(socketPath:)` has already returned --
    /// polling rather than assuming keeps this deterministic instead of
    /// relying on that timing.
    private func acceptOnePeer(listenerFD: Int32, deadlineSeconds: Double = 5.0) throws -> Int32 {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while Date() < deadline {
            if try pollReadable(fd: listenerFD, timeoutMilliseconds: 100) {
                let peerFD = accept(listenerFD, nil, nil)
                if peerFD >= 0 { return peerFD }
                let acceptErrno = errno
                if acceptErrno == EINTR || acceptErrno == EAGAIN || acceptErrno == EWOULDBLOCK { continue }
                throw TransportFixtureError.acceptFailed(acceptErrno)
            }
        }
        throw TransportFixtureError.acceptTimedOut
    }

    /// Reads from `fd` via a bounded, repeated `poll(2)` + `recv(2)`
    /// loop (never a fixed `sleep`) until either at least
    /// `minimumByteCount` bytes have accumulated or `deadlineSeconds`
    /// elapses. Used to observe exactly what `BSDHerdrTransport.send(_:)`
    /// wrote to a peer, byte for byte.
    private func readBytes(from fd: Int32, minimumByteCount: Int, deadlineSeconds: Double = 5.0) throws -> Data {
        var collected = Data()
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.count < minimumByteCount, Date() < deadline {
            guard try pollReadable(fd: fd, timeoutMilliseconds: 100) else { continue }
            let bytesRead = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress, raw.count, 0)
            }
            if bytesRead > 0 {
                collected.append(contentsOf: buffer[0..<bytesRead])
                continue
            }
            if bytesRead == 0 { break } // peer closed -- nothing more will ever arrive
            let readErrno = errno
            if readErrno == EINTR || readErrno == EAGAIN || readErrno == EWOULDBLOCK { continue }
            throw TransportFixtureError.readFailed(readErrno)
        }
        guard collected.count >= minimumByteCount else {
            throw TransportFixtureError.readTimedOut
        }
        return collected
    }

    /// Writes `data` to `fd` in full via a plain blocking `write(2)`
    /// loop, retrying on `EINTR`. The fixture's payloads are always a
    /// few dozen bytes, far under the kernel's AF_UNIX socket buffer, so
    /// this never actually blocks in practice -- unlike
    /// `BSDHerdrTransport.writeAll(_:to:)`, which the production type
    /// under test needs a full non-blocking-plus-`poll`-wait strategy
    /// for (see that method's own doc comment), this fixture helper does
    /// not need to reproduce that.
    @discardableResult
    private func writeAll(_ data: Data, to fd: Int32) throws -> Int {
        var written = 0
        let total = data.count
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while written < total {
                let n = Darwin.write(fd, base.advanced(by: written), total - written)
                if n > 0 {
                    written += n
                    continue
                }
                let writeErrno = errno
                if n < 0, writeErrno == EINTR { continue }
                throw TransportFixtureError.writeFailed(n == 0 ? 0 : writeErrno)
            }
        }
        return written
    }

    /// Polls `condition` with a bounded wall-clock deadline (never a
    /// fixed sleep) -- needed for observing two of `close()`'s side
    /// effects that are NOT themselves awaitable Swift Concurrency
    /// operations: `BSDHerdrTransport.close()`'s own `DispatchSourceRead`
    /// cancel handler closes the fd on a LATER turn of its private
    /// `queue` (see `BSDHerdrTransport.close()`'s own doc comment), and
    /// the instance's deallocation likewise depends on that same queued
    /// closure fully releasing its capture of `self` -- both can lag
    /// slightly behind `await transport.close()` returning.
    @discardableResult
    private func waitUntilTrue(deadlineSeconds: Double = 5.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        return true
    }

    // MARK: - BSDHerdrTransport: connect()

    func test_connect_toLiveListener_succeeds() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)

        // "Didn't throw" alone would also pass a broken implementation
        // that silently no-ops -- confirm the connection is real and
        // observable from BOTH ends: the fixture listener actually has a
        // peer to accept, and the transport itself reports a connected
        // fd (not `.notConnected`/`.closed`).
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }
        let connectedFD = await transport.testOnlyConnectedFileDescriptor()
        XCTAssertNotNil(connectedFD, "a successful connect() must leave the transport in the .connected state")

        await transport.close()
    }

    func test_connect_toNonexistentPath_throwsConnectFailed() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/never-created.sock"

        let transport = BSDHerdrTransport()
        do {
            try await transport.connect(socketPath: socketPath)
            XCTFail("expected connect() to throw when nothing is listening at socketPath")
        } catch let error as HerdrTransportError {
            guard case .connectFailed = error else {
                XCTFail("expected .connectFailed, got \(error)")
                return
            }
        }
    }

    func test_connect_calledTwice_throwsAlreadyConnected() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)

        do {
            try await transport.connect(socketPath: socketPath)
            XCTFail("expected a second connect() call on an already-connected transport to throw")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyConnected)
        }

        await transport.close()
    }

    // MARK: - BSDHerdrTransport: send() error paths

    func test_send_beforeConnect_throwsNotConnected() async throws {
        let transport = BSDHerdrTransport()

        do {
            try await transport.send(#"{"id":"1","method":"ping"}"#)
            XCTFail("expected send() to throw before connect() has ever succeeded")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func test_send_afterClose_throwsAlreadyClosed() async throws {
        let transport = BSDHerdrTransport()
        await transport.close()

        do {
            try await transport.send(#"{"id":"1","method":"ping"}"#)
            XCTFail("expected send() to throw once the transport is closed")
        } catch let error as HerdrTransportError {
            XCTAssertEqual(error, .alreadyClosed)
        }
    }

    // MARK: - BSDHerdrTransport: incoming lines from the peer

    func test_incoming_lineSentByPeer_arrivesAsLineEvent() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }

        var iterator = transport.incoming.makeAsyncIterator()

        let line = #"{"id":"1","result":{}}"#
        try writeAll(Data((line + "\n").utf8), to: peerFD)

        let event = await iterator.next()
        XCTAssertEqual(
            event, .line(line),
            "a newline-terminated line the peer writes must arrive on `incoming` as `.line`, with the " +
            "framing newline already stripped"
        )

        await transport.close()
    }

    // MARK: - BSDHerdrTransport: send() writes to the peer

    func test_send_writesLineVerbatimIncludingFramingNewline() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }

        let line = #"{"id":"1","method":"ping"}"#
        try await transport.send(line)

        let expected = Data((line + "\n").utf8)
        let received = try readBytes(from: peerFD, minimumByteCount: expected.count)
        XCTAssertEqual(
            received, expected,
            "send(_:) must write the line to the peer verbatim, plus EXACTLY one trailing newline the " +
            "transport itself adds -- the caller's own line must never already include one"
        )

        await transport.close()
    }

    // MARK: - BSDHerdrTransport: peer EOF vs. malformed-UTF8 failure

    func test_incoming_peerClose_surfacesEOF_notFailure() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)

        var iterator = transport.incoming.makeAsyncIterator()

        Darwin.close(peerFD) // simulate the herdr server disconnecting cleanly (a real recv() == 0)

        let first = await iterator.next()
        XCTAssertEqual(first, .eof, "a clean peer disconnect must surface .eof, never .failure")
        let second = await iterator.next()
        XCTAssertNil(second, "the stream must finish immediately after .eof -- no further element")
    }

    func test_incoming_lineWithInvalidUTF8_surfacesFailureNotEOF() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }

        var iterator = transport.incoming.makeAsyncIterator()

        // 0xC3 starts a 2-byte UTF-8 sequence but 0x28 ("(") is not a
        // valid continuation byte -- a well-known invalid UTF-8 vector.
        // NDJSON is always UTF-8 by protocol, so this is a
        // transport-integrity failure, not routine unexpected content
        // (contrast HerdrSocketSession.handleLine, which silently drops
        // an individual malformed/undecodable JSON LINE -- this is about
        // the bytes not even decoding to a String at all).
        let malformed = Data([0xC3, 0x28, UInt8(ascii: "\n")])
        try writeAll(malformed, to: peerFD)

        let event = await iterator.next()
        XCTAssertEqual(
            event, .failure(HerdrTransportFailure(message: "received a line that was not valid UTF-8")),
            "a line that fails UTF-8 decoding must surface .failure, distinctly from .eof"
        )
        let next = await iterator.next()
        XCTAssertNil(next, "the stream must finish immediately after .failure")
    }

    // MARK: - BSDHerdrTransport: close() releases the real fd

    func test_close_releasesFileDescriptor() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        let transport = BSDHerdrTransport()
        try await transport.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }

        let capturedFDOrNil = await transport.testOnlyConnectedFileDescriptor()
        let capturedFD = try XCTUnwrap(
            capturedFDOrNil,
            "must capture the connected fd BEFORE close() -- once closed, state is .closed and this is nil"
        )

        await transport.close()

        let released = await waitUntilTrue {
            fcntl(capturedFD, F_GETFD) == -1 && errno == EBADF
        }
        XCTAssertTrue(
            released,
            "close() must actually release the OS-level file descriptor (fcntl(_:F_GETFD) must fail with " +
            "EBADF), not merely flip internal state"
        )
    }

    // MARK: - BSDHerdrTransport: deallocation after close()

    func test_deallocates_afterClose_weakReferenceGoesNil() async throws {
        let root = shortSocketFixtureRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/herdr.sock"
        let listenerFD = try bindAndListenUnixSocketFixture(at: socketPath)
        defer { Darwin.close(listenerFD) }

        // `var` + force-unwrap (not `let`): this test's whole point is
        // releasing the ONLY strong reference by reassigning this
        // variable to `nil` below, which a `let` cannot express --
        // `transport` is guaranteed non-nil for every unwrap up to that
        // reassignment.
        var transport: BSDHerdrTransport? = BSDHerdrTransport()
        try await transport!.connect(socketPath: socketPath)
        let peerFD = try acceptOnePeer(listenerFD: listenerFD)
        defer { Darwin.close(peerFD) }

        weak let weakTransport = transport
        await transport!.close()
        transport = nil

        let deallocated = await waitUntilTrue { weakTransport == nil }
        XCTAssertTrue(
            deallocated,
            "the instance must deallocate once close() has run and the test's own local variable -- its " +
            "only remaining strong reference -- was released"
        )
    }
}
