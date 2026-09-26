// SecureInputChannel.swift
// Calyx
//
// Out-of-band password-prompt signal for persistent-session panes.
//
// A persistent-session pane runs `calyx-session attach`, which keeps the
// outer pty in raw mode for its whole lifetime, so libghostty's
// termios-based password-prompt detection (ICANON on, ECHO off) never
// fires and `SurfaceView.passwordInput` is never set. Instead the
// calyx-session daemon watches the session's inner PTY, and the attach
// client forwards each transition as a JSON datagram to the Unix
// datagram socket opened here (path exported to every surface as
// CALYX_SECURE_INPUT_SOCKET).

import Foundation
import Darwin
import os

/// One password-prompt transition reported by `calyx-session attach`
/// (see calyx-session/crates/cli/src/commands/secure_input_notify.rs),
/// sent when the daemon reports that the session's PTY entered or left
/// ICANON-without-ECHO mode.
///
/// Wire format (one datagram, UTF-8 JSON):
/// `{"v":1,"session_id":"…","surface_id":"…","password_input":true}`
struct SecureInputMessage: Decodable, Equatable, Sendable {
    let v: Int
    let session_id: String?
    let surface_id: String?
    let password_input: Bool

    /// Upper bound on an accepted datagram; also the receive buffer size.
    static let maxBytes = 4096

    /// Decodes one datagram. Returns nil when the payload exceeds
    /// `maxBytes`, is not a valid message, or has a version other than 1.
    static func decode(_ data: Data) -> SecureInputMessage? {
        guard data.count <= maxBytes else { return nil }
        guard let message = try? JSONDecoder().decode(SecureInputMessage.self, from: data) else {
            return nil
        }
        guard message.v == 1 else { return nil }
        return message
    }
}

/// Nonisolated BSD-socket layer: binds a Unix datagram socket, reads it on
/// a private dispatch queue, and hands every decodable datagram to
/// `onMessage` (on that queue). Undecodable datagrams are dropped.
final class SecureInputDatagramReceiver: Sendable {
    enum Error: Swift.Error, Equatable {
        case pathTooLong(String)
        case socket(errno: Int32)
        case bind(errno: Int32)
        case chmod(errno: Int32)
        case nonBlocking(errno: Int32)
    }

    private struct State {
        var fileDescriptor: Int32?
        var source: (any DispatchSourceRead)?
    }

    let socketPath: String
    private let onMessage: @Sendable (SecureInputMessage) -> Void
    private let queue = DispatchQueue(label: "com.calyx.secureInput.receiver")
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(socketPath: String, onMessage: @escaping @Sendable (SecureInputMessage) -> Void) {
        self.socketPath = socketPath
        self.onMessage = onMessage
    }

    /// Binds `socketPath` (replacing any existing file) under umask 0077
    /// so the node is created 0600, re-asserts mode 0600, switches the fd
    /// to non-blocking and starts receiving. Every failure closes the fd,
    /// removes the socket file (once bound) and throws.
    func start() throws {
        let pathBytes = Array(socketPath.utf8)
        var addr = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Error.pathTooLong(socketPath)
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() { buffer[index] = byte }
            buffer[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Error.socket(errno: errno) }

        unlink(socketPath)
        let (bindResult, bindErrno): (Int32, Int32) = {
            let previous = umask(0o077)
            defer { umask(previous) }
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            return (result, errno)
        }()
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw Error.bind(errno: bindErrno)
        }
        guard chmod(socketPath, 0o600) == 0 else {
            let chmodErrno = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw Error.chmod(errno: chmodErrno)
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else {
            let fcntlErrno = errno
            Darwin.close(fd)
            unlink(socketPath)
            throw Error.nonBlocking(errno: fcntlErrno)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let onMessage = self.onMessage
        source.setEventHandler {
            Self.drain(fd: fd, onMessage: onMessage)
        }
        // Captures `fd` by value: closes it exactly once, after the
        // source is cancelled and no event handler can still be running.
        source.setCancelHandler {
            Darwin.close(fd)
        }
        state.withLock {
            $0.fileDescriptor = fd
            $0.source = source
        }
        source.resume()
    }

    /// Cancels the read source (its cancel handler closes the fd) and
    /// removes the socket file.
    func stop() {
        let source = state.withLock { state -> (any DispatchSourceRead)? in
            let source = state.source
            state.source = nil
            state.fileDescriptor = nil
            return source
        }
        source?.cancel()
        unlink(socketPath)
    }

    private static func drain(fd: Int32, onMessage: @Sendable (SecureInputMessage) -> Void) {
        var buffer = [UInt8](repeating: 0, count: SecureInputMessage.maxBytes)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                // EAGAIN/EWOULDBLOCK: drained. Any other error: the read
                // source fires again if the socket stays readable.
                return
            }
            if let message = SecureInputMessage.decode(Data(buffer[0..<count])) {
                onMessage(message)
            }
        }
    }
}

/// Owns the per-process secure-input socket and applies received
/// messages to the matching `SurfaceView.passwordInput` (which drives
/// `SecureInput.shared` exactly like ghostty's native detection).
///
/// - Opened unconditionally at launch: this is a security feature and
///   must not depend on the AI Agent IPC switch.
/// - Named `calyx-secure-input-<pid>.sock` so multiple Calyx instances
///   (e.g. the UI-test app next to a developer's copy) never collide;
///   sockets left behind by dead pids are removed on start.
/// - Lives in the per-user temp directory with mode 0600, so only the
///   same uid can send. A same-uid process could spoof a message, but
///   that is equivalent to what the native path already allows: any
///   same-uid process can flip the pty's termios to trigger it.
@MainActor
final class SecureInputChannel {
    static let shared = SecureInputChannel(directories: [NSTemporaryDirectory(), "/tmp"])

    static let socketPrefix = "calyx-secure-input-"
    static let socketSuffix = ".sock"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
        category: "SecureInputChannel"
    )

    /// Candidate directories, tried in order by `start()`.
    let directories: [String]
    /// The directory whose socket is bound; nil when not started.
    private(set) var directory: String?
    var sessionSurfaceMap: SessionSurfaceMap = .shared
    var surfaceLocator: SurfaceLocator = .shared
    private(set) var socketPath: String?
    private var receiver: SecureInputDatagramReceiver?

    init(directories: [String]) {
        self.directories = directories
    }

    convenience init(directory: String) {
        self.init(directories: [directory])
    }

    /// Tries each candidate directory in order: removes stale sockets of
    /// dead processes there, then binds this process's socket; the first
    /// success wins. No-op when already started. When every directory
    /// fails, logs a fault listing each attempt and leaves `socketPath`
    /// nil (surfaces then get no CALYX_SECURE_INPUT_SOCKET);
    /// `ensureStarted()` retries later.
    func start() {
        guard receiver == nil else { return }
        var failures: [String] = []
        for candidate in directories {
            removeStaleSockets(in: candidate)
            let path = (candidate as NSString).appendingPathComponent(
                "\(Self.socketPrefix)\(getpid())\(Self.socketSuffix)")
            let receiver = SecureInputDatagramReceiver(socketPath: path) { [weak self] message in
                Task { @MainActor in self?.apply(message) }
            }
            do {
                try receiver.start()
            } catch {
                failures.append("\(path): \(String(describing: error))")
                continue
            }
            self.receiver = receiver
            socketPath = path
            directory = candidate
            return
        }
        Self.logger.fault("Failed to open secure input socket in every candidate directory; password-prompt detection for persistent sessions is disabled until the next retry: \(failures.joined(separator: "; "), privacy: .public)")
    }

    /// Returns the bound socket path, first calling `start()` when not
    /// yet started so a failure at launch is retried.
    func ensureStarted() -> String? {
        if receiver == nil { start() }
        return socketPath
    }

    /// Routes a message to its surface: `session_id` via
    /// `sessionSurfaceMap` first, then `surface_id`. An unknown target is
    /// a normal case (detached or already-closed pane) and is ignored.
    func apply(_ message: SecureInputMessage) {
        let surfaceID: UUID?
        if let sessionID = message.session_id, !sessionID.isEmpty,
           let mapped = sessionSurfaceMap.surfaceID(for: sessionID) {
            surfaceID = mapped
        } else {
            surfaceID = message.surface_id.flatMap(UUID.init(uuidString:))
        }
        guard let surfaceID, let view = surfaceLocator.view(for: surfaceID) else { return }
        view.passwordInput = message.password_input
    }

    func stop() {
        receiver?.stop()
        receiver = nil
        socketPath = nil
        directory = nil
    }

    private func removeStaleSockets(in directory: String) {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            Self.logger.error("Failed to list \(directory, privacy: .public) for stale secure input sockets: \(String(describing: error), privacy: .public)")
            return
        }
        for entry in entries {
            guard entry.hasPrefix(Self.socketPrefix), entry.hasSuffix(Self.socketSuffix) else { continue }
            let pidString = entry.dropFirst(Self.socketPrefix.count).dropLast(Self.socketSuffix.count)
            guard !pidString.isEmpty, pidString.allSatisfy(\.isASCII), pidString.allSatisfy(\.isNumber),
                  let pid = pid_t(pidString) else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                unlink((directory as NSString).appendingPathComponent(entry))
            }
        }
    }
}
