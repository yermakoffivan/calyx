//
//  SecureInputChannelTests.swift
//  CalyxTests
//
//  SecureInputMessage decoding, SecureInputChannel.apply routing, and the
//  Unix datagram socket lifecycle (bind 0600, receive, stale cleanup, stop).
//

import XCTest
import Darwin
@testable import Calyx

@MainActor
final class SecureInputChannelTests: XCTestCase {

    private var dir: String!
    private var channel: SecureInputChannel?
    private var views: [SurfaceView] = []
    private var extraDirs: [String] = []

    override func setUp() async throws {
        dir = "/tmp/cxsi-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for v in views { v.passwordInput = false }
        views = []
        channel?.stop()
        channel = nil
        try? FileManager.default.removeItem(atPath: dir)
        for d in extraDirs { try? FileManager.default.removeItem(atPath: d) }
        extraDirs = []
    }

    // MARK: Helpers

    private func makeView() -> SurfaceView {
        let v = SurfaceView(frame: .zero)
        views.append(v)
        return v
    }

    private func makeChannel() -> (SecureInputChannel, SurfaceLocator, SessionSurfaceMap) {
        let c = SecureInputChannel(directory: dir)
        let locator = SurfaceLocator()
        let map = SessionSurfaceMap()
        c.surfaceLocator = locator
        c.sessionSurfaceMap = map
        channel = c
        return (c, locator, map)
    }

    private func msg(_ json: String) -> SecureInputMessage {
        guard let m = SecureInputMessage.decode(Data(json.utf8)) else {
            XCTFail("fixture failed to decode: \(json)")
            return SecureInputMessage.decode(Data(#"{"v":1,"password_input":false}"#.utf8))!
        }
        return m
    }

    private func send(_ payload: String, to path: String) {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        XCTAssertLessThan(bytes.count, MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let data = Array(payload.utf8)
        let sent = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                sendto(fd, data, data.count, 0, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(sent, data.count, "sendto failed errno=\(errno)")
    }

    private func waitPassword(_ view: SurfaceView, _ expected: Bool, timeout: TimeInterval = 2) {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in MainActor.assumeIsolated { view.passwordInput == expected } },
            object: nil)
        wait(for: [exp], timeout: timeout)
    }

    // MARK: Decode

    func test_decode_validFullMessage() {
        let sid = "sess-1"
        let surf = "11111111-2222-3333-4444-555555555555"
        let m = SecureInputMessage.decode(Data(#"{"v":1,"session_id":"\#(sid)","surface_id":"\#(surf)","password_input":true}"#.utf8))
        XCTAssertEqual(m?.v, 1)
        XCTAssertEqual(m?.session_id, sid)
        XCTAssertEqual(m?.surface_id, surf)
        XCTAssertEqual(m?.password_input, true)
    }

    func test_decode_surfaceIDOmitted_isNil() {
        let m = SecureInputMessage.decode(Data(#"{"v":1,"session_id":"s","password_input":false}"#.utf8))
        XCTAssertNotNil(m)
        XCTAssertNil(m?.surface_id)
        XCTAssertEqual(m?.session_id, "s")
        XCTAssertEqual(m?.password_input, false)
    }

    func test_decode_passwordInputMissing_returnsNil() {
        XCTAssertNil(SecureInputMessage.decode(Data(#"{"v":1,"session_id":"s"}"#.utf8)))
    }

    func test_decode_passwordInputString_returnsNil() {
        XCTAssertNil(SecureInputMessage.decode(Data(#"{"v":1,"session_id":"s","password_input":"yes"}"#.utf8)))
    }

    func test_decode_version2_returnsNil() {
        XCTAssertNil(SecureInputMessage.decode(Data(#"{"v":2,"session_id":"s","password_input":true}"#.utf8)))
    }

    func test_decode_oversizedPayload_returnsNil() {
        let prefix = #"{"v":1,"password_input":true,"session_id":""#
        let suffix = #""}"#
        let pad = String(repeating: "a", count: 4097 - prefix.utf8.count - suffix.utf8.count)
        let data = Data((prefix + pad + suffix).utf8)
        XCTAssertEqual(data.count, 4097)
        XCTAssertNil(SecureInputMessage.decode(data))
    }

    func test_decode_nonJSON_returnsNil() {
        XCTAssertNil(SecureInputMessage.decode(Data("not json".utf8)))
    }

    // MARK: Apply

    func test_apply_surfaceID_setsAndClearsPasswordInput() {
        let (c, locator, _) = makeChannel()
        let view = makeView()
        let id = UUID()
        locator.registerView(id: id, view: view)
        c.apply(msg(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":true}"#))
        XCTAssertTrue(view.passwordInput)
        c.apply(msg(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":false}"#))
        XCTAssertFalse(view.passwordInput)
    }

    func test_apply_registeredSessionID_resolvesViaMap() {
        let (c, locator, map) = makeChannel()
        let view = makeView()
        let id = UUID()
        locator.registerView(id: id, view: view)
        map.register(sessionID: "sess-a", surfaceID: id)
        c.apply(msg(#"{"v":1,"session_id":"sess-a","password_input":true}"#))
        XCTAssertTrue(view.passwordInput)
    }

    func test_apply_unregisteredSessionID_fallsBackToSurfaceID() {
        let (c, locator, _) = makeChannel()
        let view = makeView()
        let id = UUID()
        locator.registerView(id: id, view: view)
        c.apply(msg(#"{"v":1,"session_id":"unknown","surface_id":"\#(id.uuidString)","password_input":true}"#))
        XCTAssertTrue(view.passwordInput)
    }

    func test_apply_bothUnknown_leavesViewUntouched() {
        let (c, locator, _) = makeChannel()
        let view = makeView()
        locator.registerView(id: UUID(), view: view)
        c.apply(msg(#"{"v":1,"session_id":"nope","surface_id":"\#(UUID().uuidString)","password_input":true}"#))
        XCTAssertFalse(view.passwordInput)
    }

    func test_apply_releasedView_noCrash() {
        let (c, locator, _) = makeChannel()
        let id = UUID()
        autoreleasepool {
            let v = SurfaceView(frame: .zero)
            locator.registerView(id: id, view: v)
        }
        c.apply(msg(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":true}"#))
        XCTAssertNil(locator.view(for: id))
    }

    // MARK: Socket

    func test_start_bindsSocketWithMode0600() throws {
        let (c, _, _) = makeChannel()
        c.start()
        let expected = "\(dir!)/calyx-secure-input-\(getpid()).sock"
        XCTAssertEqual(c.socketPath, expected)
        var st = stat()
        XCTAssertEqual(stat(expected, &st), 0, "socket file missing")
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }

    func test_socketRoundTrip_appliesTrueThenFalse() throws {
        let (c, locator, _) = makeChannel()
        let view = makeView()
        let id = UUID()
        locator.registerView(id: id, view: view)
        c.start()
        let path = try XCTUnwrap(c.socketPath)
        send(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":true}"#, to: path)
        waitPassword(view, true)
        send(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":false}"#, to: path)
        waitPassword(view, false)
    }

    func test_socket_garbageThenValid_validIsApplied() throws {
        let (c, locator, _) = makeChannel()
        let view = makeView()
        let id = UUID()
        locator.registerView(id: id, view: view)
        c.start()
        let path = try XCTUnwrap(c.socketPath)
        send("garbage\u{01}{{", to: path)
        send(#"{"v":1,"surface_id":"\#(id.uuidString)","password_input":true}"#, to: path)
        waitPassword(view, true)
    }

    func test_stop_clearsPathAndRemovesFile() throws {
        let (c, _, _) = makeChannel()
        c.start()
        let path = try XCTUnwrap(c.socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        c.stop()
        XCTAssertNil(c.socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_start_removesDeadPidSocketsKeepsLiveOnes() throws {
        var deadPid: Int32 = 999_999
        while !(kill(deadPid, 0) == -1 && errno == ESRCH) { deadPid -= 1 }
        let deadFile = "\(dir!)/calyx-secure-input-\(deadPid).sock"
        let liveFile = "\(dir!)/calyx-secure-input-\(getppid()).sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: deadFile, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: liveFile, contents: Data()))

        let (c, _, _) = makeChannel()
        c.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: deadFile), "dead-pid socket not cleaned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveFile), "live-pid socket was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir!)/calyx-secure-input-\(getpid()).sock"))
    }

    // MARK: Fallback / retry

    func test_start_fallsBackToSecondDirectoryWhenFirstPathTooLong() throws {
        let longDir = "\(dir!)/" + String(repeating: "l", count: 110)
        try FileManager.default.createDirectory(atPath: longDir, withIntermediateDirectories: true)
        XCTAssertGreaterThanOrEqual(longDir.utf8.count, 104)
        let second = "/tmp/cxsi2-\(UUID().uuidString.prefix(8).lowercased())"
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        extraDirs.append(second)

        let c = SecureInputChannel(directories: [longDir, second])
        channel = c
        c.start()
        XCTAssertEqual(c.directory, second)
        XCTAssertEqual(c.socketPath, "\(second)/calyx-secure-input-\(getpid()).sock")
    }

    func test_ensureStarted_retriesAfterFailure() throws {
        let missing = "/tmp/cxsi3-\(UUID().uuidString.prefix(8).lowercased())"
        extraDirs.append(missing)
        let c = SecureInputChannel(directories: [missing])
        channel = c
        XCTAssertNil(c.ensureStarted())
        XCTAssertNil(c.directory)

        try FileManager.default.createDirectory(atPath: missing, withIntermediateDirectories: true)
        let path = try XCTUnwrap(c.ensureStarted())
        XCTAssertEqual(c.directory, missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
