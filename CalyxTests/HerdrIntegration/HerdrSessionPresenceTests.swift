//
//  HerdrSessionPresenceTests.swift
//  CalyxTests
//
//  Covers HerdrSessionPresence: the single owner of "is a herdr session
//  there right now?". Presence is observed from real filesystem
//  activity and concluded ONLY from a real non-blocking connect()
//  probe, so every fixture here is a real directory and a real AF_UNIX
//  socket -- nothing about this type can be honestly tested against a
//  fake filesystem.
//
//  Contract this file pins:
//  - A live socket appearing in a watched directory reports .appeared
//    EXACTLY once, carrying that socket file's own device + inode.
//  - A socket file that exists but has no listener yet (the window
//    between bind() and listen()) reports NOTHING; .appeared follows
//    once a bounded probe retry finds the listener.
//  - A socket already live when start() runs is reported through the
//    same .appeared path as an initial reading -- bootstrap is not a
//    separate mechanism.
//  - The same path rebound to a DIFFERENT socket file reports
//    .replaced(previous:current:) -- the path alone cannot distinguish
//    a replaced server from an unchanged one, so identity is device +
//    inode.
//  - A live socket that goes away reports .disappeared.
//  - Filesystem activity that is not a socket becoming live or dying
//    reports nothing.
//  - A crashed server's leftover socket file is never .appeared: the
//    file existing is not the server existing.
//  - A candidate path with NO socket file is concluded on immediately:
//    the bounded retry exists for the bind()-to-listen() window, which
//    a file that does not exist cannot be in.
//  - A socket that only comes alive late in that schedule is still
//    reported: the schedule is the only thing covering a slow server.
//  - A watched directory deleted and recreated is still watched, and a
//    live socket inside it is still reported.
//  - stop() forgets what was live, so a later start() reports it again.
//  - A session directory created AFTER start() is picked up, sockets
//    inside it included.
//  - After stop(), nothing is ever reported again.
//  - The observer is held weakly.
//
//  Darwin's sockaddr_un.sun_path is only 104 bytes, so every fixture
//  here is rooted at a short /tmp/<8-hex-chars> directory --
//  deliberately NOT FileManager.default.temporaryDirectory, which alone
//  is already 50-70+ bytes before any fixture-specific suffix.
//  bindUnixSocketFixture(at:listenBacklog:) guards this with an explicit
//  length precondition, mirroring HerdrSessionDiscoveryTests.
//

import Darwin
import XCTest
@testable import Calyx

// MARK: - Observer recorder

/// Records every reported change in order, and can hand out an
/// expectation that fulfills once a given number of changes has been
/// recorded (immediately, if that many already have been). Exact
/// ORDERED comparison against `changes` is what every assertion below
/// uses -- "some change arrived" would pass for the wrong change.
@MainActor
private final class RecordingPresenceObserver: HerdrSessionPresenceObserver {
    private(set) var changes: [HerdrSessionPresenceChange] = []
    private var awaitedCount: Int?
    private var awaitedExpectation: XCTestExpectation?

    func herdrSessionPresenceDidChange(_ change: HerdrSessionPresenceChange) {
        changes.append(change)
        if let awaitedCount, changes.count >= awaitedCount {
            awaitedExpectation?.fulfill()
            self.awaitedCount = nil
            awaitedExpectation = nil
        }
    }

    func expectation(changeCount: Int, _ description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        if changes.count >= changeCount {
            expectation.fulfill()
        } else {
            awaitedCount = changeCount
            awaitedExpectation = expectation
        }
        return expectation
    }
}

// MARK: - Injected sleep gate

/// Suspends every injected `sleep` call until the test releases it, so
/// a test can hold a bounded probe retry in place, change the world
/// underneath it, and then let exactly that retry run. A no-op sleep
/// would instead let every retry fire before the test could act.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting.count
    }

    func sleep() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Releases everything currently waiting AND everything arriving
    /// afterward.
    func open() {
        lock.lock()
        isOpen = true
        let pending = waiting
        waiting = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// Counts injected `sleep` calls, for the assertion that a path with
/// nothing at it never reaches the bounded probe retry at all.
private final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    /// Increments and returns the new count, so a caller can act on a
    /// SPECIFIC retry rather than on "some retry".
    @discardableResult
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

// MARK: - HerdrSessionPresenceTests

@MainActor
final class HerdrSessionPresenceTests: XCTestCase {

    private var fixtureRoots: [String] = []
    private var openFileDescriptors: [Int32] = []
    private var startedPresences: [HerdrSessionPresence] = []

    override func tearDown() {
        for presence in startedPresences { presence.stop() }
        startedPresences = []
        for fd in openFileDescriptors { close(fd) }
        openFileDescriptors = []
        for root in fixtureRoots { try? FileManager.default.removeItem(atPath: root) }
        fixtureRoots = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A short `/tmp`-rooted directory (8 hex characters, NOT a full
    /// UUID, and deliberately NOT FileManager.default.temporaryDirectory)
    /// so every socket path built under it stays far under Darwin's
    /// 104-byte sockaddr_un.sun_path limit.
    private func shortSocketFixtureRoot() -> String {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/hsp-\(suffix)"
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        fixtureRoots.append(path)
        return path
    }

    private enum UnixSocketFixtureError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case statFailed(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let detail): return "fixture socket path too long: \(detail)"
            case .socketCreateFailed(let e): return "socket() failed: errno \(e)"
            case .bindFailed(let e): return "bind() failed: errno \(e)"
            case .listenFailed(let e): return "listen() failed: errno \(e)"
            case .statFailed(let path, let e): return "lstat(\(path)) failed: errno \(e)"
            }
        }
    }

    /// Binds (and, when `listenBacklog` is non-nil, listens on) a real
    /// AF_UNIX SOCK_STREAM socket at `path`, returning the raw fd.
    /// `listenBacklog` non-nil is a live herdr server; nil (bind only)
    /// is the bind-before-listen window, and -- once the fd closes --
    /// a crashed server's leftover socket file.
    @discardableResult
    private func bindUnixSocketFixture(at path: String, listenBacklog: Int32?) throws -> Int32 {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 100 else {
            throw UnixSocketFixtureError.pathTooLong(
                "\(pathBytes.count) bytes (limit ~100 to stay under sockaddr_un's 104-byte sun_path): \(path)"
            )
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketFixtureError.socketCreateFailed(errno) }

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
            close(fd)
            throw UnixSocketFixtureError.bindFailed(bindErrno)
        }

        if let listenBacklog {
            guard listen(fd, listenBacklog) == 0 else {
                let listenErrno = errno
                close(fd)
                throw UnixSocketFixtureError.listenFailed(listenErrno)
            }
        }

        openFileDescriptors.append(fd)
        return fd
    }

    /// The identity the socket file at `path` currently has, read
    /// INDEPENDENTLY of any Calyx code, straight from lstat(2).
    private func socketIdentity(at path: String) throws -> HerdrSocketIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw UnixSocketFixtureError.statFailed(path, errno)
        }
        return HerdrSocketIdentity(
            socketPath: path,
            deviceID: UInt64(UInt32(bitPattern: info.st_dev)),
            inode: UInt64(info.st_ino)
        )
    }

    /// A presence rooted at `configRoot`, with an EMPTY environment (the
    /// host's own HERDR_SOCKET_PATH must never leak into a fixture) and
    /// a discovery whose only job here is its real connect() probe.
    /// `stop()`ped by tearDown.
    private func makePresence(
        configRoot: String,
        probeDelays: [Duration] = [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
    ) -> HerdrSessionPresence {
        let presence = HerdrSessionPresence(
            configRootDirectory: configRoot,
            environment: [:],
            discovery: HerdrSessionDiscovery(environment: [:], configRootDirectory: configRoot),
            probeDelays: probeDelays,
            sleep: sleep
        )
        startedPresences.append(presence)
        return presence
    }

    // MARK: - Bounded polling

    /// Polls `condition` until true or `timeout` elapses, returning
    /// whether it became true. Used ONLY to wait for the world to
    /// settle before a negative assertion, or for a probe to reach the
    /// sleep gate -- never as the assertion itself.
    @discardableResult
    private func poll(timeout: Duration = .seconds(2), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Lets pending filesystem events and probe retries land before a
    /// "nothing was reported" assertion, so that assertion is about the
    /// contract rather than about being early.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Appearance

    func test_start_whenLiveSocketAppearsInWatchedDirectory_reportsAppearedExactlyOnce() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)
        presence.start()

        let appeared = observer.expectation(changeCount: 1, "a live socket appearing must be reported")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        await settle()
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "a socket that became live in a watched directory must be reported exactly once, carrying that " +
            "socket file's own device and inode"
        )
    }

    func test_start_socketFileBoundButNotYetListening_reportsNothingUntilListenBegins() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let gate = SleepGate()
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root, sleep: { _ in await gate.sleep() })
        presence.setObserver(observer)
        presence.start()

        // bind() without listen(): the socket FILE exists, but a
        // connect() probe against it is refused -- exactly herdr's own
        // startup window.
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: nil)
        await poll { gate.pendingCount >= 1 }
        XCTAssertEqual(
            observer.changes, [],
            "a socket file with no listener behind it is not a session -- nothing may be reported while the " +
            "server is still between bind() and listen()"
        )

        // The server finishes starting up; the bounded probe retry the
        // gate is holding is what must now find it.
        XCTAssertEqual(listen(fd, 1), 0, "Precondition: listen() on the fixture socket must succeed")
        let appeared = observer.expectation(changeCount: 1, "a bounded probe retry must find the now-listening socket")
        gate.open()
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "once the listener exists, the SAME socket file must be reported as appeared -- exactly once, " +
            "not once per probe retry"
        )
    }

    func test_start_whenSocketIsAlreadyLive_reportsAppearedAsInitialReading() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        let identity = try socketIdentity(at: socketPath)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)

        let appeared = observer.expectation(changeCount: 1, "an already-live socket must be reported at start()")
        presence.start()
        await fulfillment(of: [appeared], timeout: 5)

        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "a session that was already there when start() ran must be reported through the SAME .appeared " +
            "path -- bootstrap is not a separate mechanism"
        )
    }

    func test_sessionDirectoryCreatedAfterStart_liveSocketInsideItIsReported() async throws {
        let root = shortSocketFixtureRoot()
        try FileManager.default.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)
        presence.start()

        // A named session herdr creates after Calyx started watching.
        let sessionDirectory = root + "/sessions/work"
        try FileManager.default.createDirectory(atPath: sessionDirectory, withIntermediateDirectories: true)
        let socketPath = sessionDirectory + "/herdr.sock"
        let appeared = observer.expectation(changeCount: 1, "a socket inside a newly created session directory must be reported")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "a session directory that did not exist at start() must still be watched once created -- " +
            "otherwise every session started after Calyx is invisible"
        )
    }

    // MARK: - Replacement

    func test_socketRebound_atSamePath_reportsReplacedWithPreviousAndCurrentIdentities() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let firstFD = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        let firstIdentity = try socketIdentity(at: socketPath)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)

        let appeared = observer.expectation(changeCount: 1, "the first session must be reported first")
        presence.start()
        await fulfillment(of: [appeared], timeout: 5)

        // A REPLACEMENT server: a different socket file taking over the
        // same path, moved into place atomically so the path is never
        // momentarily absent (that would be a disappearance, a
        // different transition entirely).
        let stagingPath = root + "/staging.sock"
        try bindUnixSocketFixture(at: stagingPath, listenBacklog: 1)
        let replaced = observer.expectation(changeCount: 2, "rebinding the same path must be reported")
        XCTAssertEqual(rename(stagingPath, socketPath), 0, "Precondition: rename() over the old socket must succeed")
        close(firstFD)
        openFileDescriptors.removeAll { $0 == firstFD }
        await fulfillment(of: [replaced], timeout: 5)

        let secondIdentity = try socketIdentity(at: socketPath)
        XCTAssertNotEqual(
            secondIdentity.inode, firstIdentity.inode,
            "Precondition: the replacement must genuinely be a different socket file"
        )
        XCTAssertEqual(
            observer.changes, [.appeared(firstIdentity), .replaced(previous: firstIdentity, current: secondIdentity)],
            "a socket path rebound to a different socket file must be reported as a replacement carrying " +
            "BOTH identities -- the path alone cannot tell a replaced server from an unchanged one"
        )
    }

    // MARK: - Disappearance

    func test_liveSocketRemoved_reportsDisappeared() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        let identity = try socketIdentity(at: socketPath)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)

        let appeared = observer.expectation(changeCount: 1, "the session must be reported present first")
        presence.start()
        await fulfillment(of: [appeared], timeout: 5)

        let disappeared = observer.expectation(changeCount: 2, "the session going away must be reported")
        close(fd)
        openFileDescriptors.removeAll { $0 == fd }
        try FileManager.default.removeItem(atPath: socketPath)
        await fulfillment(of: [disappeared], timeout: 5)

        XCTAssertEqual(
            observer.changes, [.appeared(identity), .disappeared(identity)],
            "a session that is gone must be reported gone, carrying the identity that was live"
        )
    }

    // MARK: - Non-events

    func test_unrelatedFileInWatchedDirectory_reportsNothing() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)
        presence.start()

        // herdr writes ordinary files into the same directory; none of
        // them is a session appearing.
        FileManager.default.createFile(atPath: root + "/session.json", contents: Data(#"{"name":"default"}"#.utf8))
        await settle()
        XCTAssertEqual(
            observer.changes, [],
            "a file that is not a socket becoming live must report nothing"
        )

        // Positive control: the watcher is still live and still able to
        // report a real appearance after the unrelated write.
        let appeared = observer.expectation(changeCount: 1, "a real socket must still be reported afterwards")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(observer.changes, [.appeared(identity)])
    }

    /// The bounded probe retry exists for ONE window: a socket file that
    /// is bound but not yet listening. A path with no file at all cannot
    /// be in that window, and `HerdrSessionDiscovery` offers the default
    /// socket path as a candidate whether or not a file is there -- so
    /// burning the whole schedule on it would be what every reading on
    /// every machine without herdr does, plus every unrelated write in a
    /// watched directory afterwards.
    func test_candidatePathWithNoSocketFile_concludesImmediately_withoutBurningTheProbeSchedule() async throws {
        let root = shortSocketFixtureRoot()
        let sleepCount = SleepCounter()
        let observer = RecordingPresenceObserver()
        let presence = makePresence(
            configRoot: root,
            probeDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)],
            sleep: { _ in sleepCount.increment() }
        )
        presence.setObserver(observer)
        presence.start()

        // Nothing is ever created: the only candidate is the default
        // socket path, which does not exist.
        await settle()

        XCTAssertEqual(
            sleepCount.value, 0,
            "a candidate path with no socket file must be concluded on immediately -- there is no bind()-to-" +
            "listen() window to wait out, and a socket created later arrives as a directory event of its own"
        )
        XCTAssertEqual(observer.changes, [], "nothing is live, so nothing may be reported")

        // Positive control: concluding immediately must not have cost
        // the watcher its ability to see a real socket appear.
        let socketPath = root + "/herdr.sock"
        let appeared = observer.expectation(changeCount: 1, "a real socket must still be reported afterwards")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)
        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(observer.changes, [.appeared(identity)])
    }

    /// The bounded schedule is the ONLY thing covering a server that is
    /// slow between `bind()` and `listen()`: nothing polls, and a socket
    /// file that is already there produces no filesystem event of its
    /// own by simply becoming reachable. A schedule with fewer retries
    /// silently loses every server slower than it.
    func test_socketThatOnlyComesAliveLateInTheProbeSchedule_isStillReported() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let observer = RecordingPresenceObserver()

        // bind() without listen(): present, but refusing a probe.
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: nil)
        let retries = SleepCounter()
        // The server finishes starting up only during the FOURTH retry.
        // A schedule that stops earlier never probes again.
        let presence = makePresence(
            configRoot: root,
            probeDelays: HerdrSessionPresence.defaultProbeDelays,
            sleep: { _ in
                if retries.incrementAndGet() == 4 {
                    _ = listen(fd, 1)
                }
            }
        )
        presence.setObserver(observer)
        presence.start()

        let appeared = observer.expectation(changeCount: 1, "a late listener must still be found by the schedule")
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "the default probe schedule must outlast a slow bind()-to-listen(), or that session stays invisible " +
            "until something unrelated writes in its directory"
        )
    }

    // MARK: - The watched directory itself going away

    /// `~/.config/herdr` being removed and recreated (a herdr
    /// reinstall, a config reset) must not blind presence: the
    /// descriptor watching a deleted directory reports nothing ever
    /// again, so nothing would start another reading.
    func test_watchedDirectoryDeletedAndRecreated_stillReportsALiveSocketInsideIt() async throws {
        let root = shortSocketFixtureRoot()
        let configRoot = root + "/cfg"
        try FileManager.default.createDirectory(atPath: configRoot, withIntermediateDirectories: true)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: configRoot)
        presence.setObserver(observer)
        presence.start()
        await settle()
        XCTAssertEqual(observer.changes, [], "Precondition: nothing is live yet")

        try FileManager.default.removeItem(atPath: configRoot)

        let socketPath = configRoot + "/herdr.sock"
        let appeared = observer.expectation(
            changeCount: 1, "a session inside a recreated watch root must still be reported"
        )
        try FileManager.default.createDirectory(atPath: configRoot, withIntermediateDirectories: true)
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "the watch root vanishing must be observed like any other change -- a descriptor for a deleted " +
            "directory never reports again, and nothing else would start a reading"
        )
    }

    // MARK: - stop() forgets

    func test_stopThenStart_reportsAStillLiveSessionAgain() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)

        // Backlog room for BOTH probes: this test is the only one that
        // probes the same fixture twice, and an unaccepted connection
        // from the first probe still occupies the queue.
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 8)
        presence.start()
        let appeared = observer.expectation(changeCount: 1, "Precondition: the live socket must be reported once")
        await fulfillment(of: [appeared], timeout: 5)
        let identity = try socketIdentity(at: socketPath)

        presence.stop()
        presence.start()

        let reappeared = observer.expectation(
            changeCount: 2, "a session still live must be reported again to an observer that was told nothing since"
        )
        await fulfillment(of: [reappeared], timeout: 5)
        XCTAssertEqual(
            observer.changes, [.appeared(identity), .appeared(identity)],
            "stop() must forget what was live: nothing observed it while stopped, so start()'s own initial " +
            "reading has to report it exactly as it would on a first launch"
        )
    }

    func test_crashLeftoverSocketFile_isNeverReportedAsAppeared() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)
        presence.start()

        // A crashed herdr: the socket special file survives on disk with
        // nothing listening behind it.
        let crashedFD = try bindUnixSocketFixture(at: socketPath, listenBacklog: nil)
        close(crashedFD)
        openFileDescriptors.removeAll { $0 == crashedFD }
        await settle()
        XCTAssertEqual(
            observer.changes, [],
            "a leftover socket file with no listener must never be reported as a session -- the file " +
            "existing is not the server existing"
        )

        // A genuine restart replaces that leftover with a live socket.
        try FileManager.default.removeItem(atPath: socketPath)
        let appeared = observer.expectation(changeCount: 1, "the restarted server must be reported")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)

        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "the restarted server is the FIRST appearance at this path -- the leftover file that preceded " +
            "it was never a session, so this is not a replacement"
        )
    }

    // MARK: - stop()

    func test_stop_reportsNothingAfterwards() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let fd = try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        let identity = try socketIdentity(at: socketPath)
        let observer = RecordingPresenceObserver()
        let presence = makePresence(configRoot: root)
        presence.setObserver(observer)

        let appeared = observer.expectation(changeCount: 1, "the session must be reported while watching")
        presence.start()
        await fulfillment(of: [appeared], timeout: 5)

        presence.stop()
        close(fd)
        openFileDescriptors.removeAll { $0 == fd }
        try FileManager.default.removeItem(atPath: socketPath)
        try bindUnixSocketFixture(at: root + "/other.sock", listenBacklog: 1)
        await settle()

        XCTAssertEqual(
            observer.changes, [.appeared(identity)],
            "after stop(), no filesystem activity whatsoever may be reported -- neither the watched " +
            "session going away nor a new one appearing"
        )
    }

    // MARK: - Observer lifetime

    func test_observerIsHeldWeakly_releasingItReportsNothingAndDoesNotCrash() async throws {
        let root = shortSocketFixtureRoot()
        let socketPath = root + "/herdr.sock"
        let presence = makePresence(configRoot: root)
        var observer: RecordingPresenceObserver? = RecordingPresenceObserver()
        weak let weakObserver = observer
        presence.setObserver(observer)
        presence.start()

        let appeared = observer!.expectation(changeCount: 1, "the observer must be notified while it is alive")
        try bindUnixSocketFixture(at: socketPath, listenBacklog: 1)
        await fulfillment(of: [appeared], timeout: 5)
        let identity = try socketIdentity(at: socketPath)
        XCTAssertEqual(observer?.changes, [.appeared(identity)])

        observer = nil
        XCTAssertNil(
            weakObserver,
            "setObserver(_:) must store its argument weakly -- this type never owns an observer's lifecycle"
        )

        // Further activity with no observer left must be harmless.
        try FileManager.default.removeItem(atPath: socketPath)
        await settle()
    }
}
