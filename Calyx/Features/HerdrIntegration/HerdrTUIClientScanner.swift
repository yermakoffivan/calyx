// HerdrTUIClientScanner.swift
// Calyx
//
// Finds herdr TUI clients (`herdr`, `herdr --session NAME`,
// `herdr session attach NAME`) running inside THIS machine's Calyx panes,
// so the session browser can mark a herdr server's workspace rows as
// already displayed ("Show") when the user runs the herdr TUI in an
// ordinary Calyx pane rather than through a native herdr tab.
//
// Why a process-table scan: herdr's own API reports nothing about its
// connected clients (`session.snapshot` and the rest of `herdr api schema`
// carry no client list), so the server side cannot tell us which pane is
// showing it. The only deterministic link is environment inheritance:
// every Calyx pane's shell exports `CALYX_SURFACE_ID` (and
// `CALYX_SESSION_ID` for daemon-backed panes) -- see
// `GhosttySurface.swift` -- and a herdr TUI client started from that
// shell inherits both. So the scan reads each `herdr` process's argv and
// environment (`KERN_PROCARGS2`) and maps it to (socket path, surface
// hint).
//
// Exclusions (`classify` returns nil):
//   - processes with no controlling terminal: the `herdr server` child a
//     TUI client spawns inherits the same env but has no tty, and must not
//     count as a client;
//   - any argv other than the three TUI-client forms above -- `server`,
//     `terminal attach` (Calyx's own native-tab bridge, already tracked
//     by `HerdrTabCoordinator`), `status`, `api`, `pane`, `--remote`, ...;
//   - processes carrying neither `CALYX_SESSION_ID` nor a parseable
//     `CALYX_SURFACE_ID` (not started from a Calyx pane).
// Whether a surface hint actually belongs to THIS Calyx process is not
// decided here -- `SessionBrowserModel.defaultResolveTUISurface` does
// that on the main actor.

import Darwin
import Foundation

/// One herdr TUI client process: which server socket it is attached to,
/// and which Calyx pane it runs in.
struct HerdrTUIClient: Equatable, Sendable {
    /// The Calyx pane the client runs in, as inherited from its shell env.
    enum SurfaceHint: Equatable, Sendable {
        /// `CALYX_SESSION_ID` -- a daemon-backed pane; resolved to a
        /// surface through `SessionSurfaceMap`.
        case sessionID(String)
        /// `CALYX_SURFACE_ID` -- the pane's own surface UUID.
        case surfaceID(UUID)
    }

    let socketPath: String
    let surfaceHint: SurfaceHint
}

protocol HerdrTUIClientScanning: Sendable {
    /// Synchronous and blocking (walks the process table); call it off
    /// the main thread.
    func scan() -> [HerdrTUIClient]
}

/// Production `HerdrTUIClientScanning` -- see this file's header comment.
struct HerdrTUIClientScanner: HerdrTUIClientScanning {
    private let configRootDirectory: String

    init(configRootDirectory: String = HerdrConfigPaths.defaultRootDirectory) {
        self.configRootDirectory = configRootDirectory
    }

    /// Walks every pid, keeping only processes whose `pbi_comm` is
    /// `herdr`, then classifies each one. A pid that exits mid-scan, or
    /// whose info/args cannot be read (e.g. another user's process), is
    /// skipped -- it simply is not a client this scan can see.
    func scan() -> [HerdrTUIClient] {
        Self.allPIDs().compactMap { pid in
            guard let info = Self.bsdInfo(pid: pid), Self.command(of: info) == "herdr" else { return nil }
            guard let arguments = Self.argumentsAndEnvironment(pid: pid) else { return nil }
            return Self.classify(
                argv: arguments.argv,
                env: arguments.env,
                hasControllingTerminal: info.e_tdev != UInt32.max && info.e_tdev != 0,
                configRootDirectory: configRootDirectory
            )
        }
    }

    /// Pure mapping from one process's (argv, env, tty) to a client, or
    /// nil when it is not a Calyx-hosted herdr TUI client -- see this
    /// file's header comment for the exclusions.
    static func classify(
        argv: [String],
        env: [String: String],
        hasControllingTerminal: Bool,
        configRootDirectory: String
    ) -> HerdrTUIClient? {
        guard hasControllingTerminal else { return nil }

        let derivedSocketPath: String
        switch Array(argv.dropFirst()) {
        case []:
            derivedSocketPath = configRootDirectory + "/herdr.sock"
        case let arguments where arguments.count == 2 && arguments[0] == "--session":
            derivedSocketPath = sessionSocketPath(name: arguments[1], configRootDirectory: configRootDirectory)
        case let arguments where arguments.count == 3 && arguments[0] == "session" && arguments[1] == "attach":
            derivedSocketPath = sessionSocketPath(name: arguments[2], configRootDirectory: configRootDirectory)
        default:
            return nil
        }

        let socketPath: String
        if let override = env["HERDR_SOCKET_PATH"], !override.isEmpty {
            socketPath = override
        } else {
            socketPath = derivedSocketPath
        }

        let surfaceHint: HerdrTUIClient.SurfaceHint
        if let sessionID = env["CALYX_SESSION_ID"], !sessionID.isEmpty {
            surfaceHint = .sessionID(sessionID)
        } else if let rawSurfaceID = env["CALYX_SURFACE_ID"], let surfaceID = UUID(uuidString: rawSurfaceID) {
            surfaceHint = .surfaceID(surfaceID)
        } else {
            return nil
        }

        return HerdrTUIClient(socketPath: socketPath, surfaceHint: surfaceHint)
    }

    private static func sessionSocketPath(name: String, configRootDirectory: String) -> String {
        configRootDirectory + "/sessions/" + name + "/herdr.sock"
    }

    // MARK: - Process table access

    /// Every pid currently in the process table. The buffer is sized from
    /// a first count-only call plus slack for processes spawned between
    /// the two calls.
    private static func allPIDs() -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let bufferSize = Int32(pids.count * MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, bufferSize)
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard written == expectedSize else { return nil }
        return info
    }

    /// `pbi_comm`: the NUL-terminated short command name (at most
    /// `MAXCOMLEN` bytes).
    private static func command(of info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { buffer in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Parses `KERN_PROCARGS2`: an `Int32` argc, the NUL-terminated exec
    /// path followed by NUL padding, then argc argv strings, then
    /// `KEY=VALUE` environment strings, each NUL-terminated.
    private static func argumentsAndEnvironment(pid: pid_t) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // NUL padding

        // Reads one NUL-terminated string starting at `index`, or nil when
        // the buffer ends before its terminator.
        func nextString() -> String? {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            guard index < size else { return nil }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }

        // argv strings may legitimately be empty, so exactly argc of them
        // are read, never skipping empty ones.
        var argv: [String] = []
        argv.reserveCapacity(Int(argc))
        for _ in 0..<Int(argc) {
            guard let argument = nextString() else { return nil }
            argv.append(argument)
        }

        // The environment block ends at the first empty string (or the
        // end of the buffer).
        var env: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return (argv, env)
    }
}
