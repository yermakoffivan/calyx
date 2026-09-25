// HerdrSessionPresence.swift
// Calyx
//
// Owns the single question "is a herdr session there right now?".
// Nothing else in Calyx is entitled to answer it: a connection is a
// FUNCTION of presence, never of an unrelated Calyx event such as app
// launch, `applicationDidBecomeActive`, or a sidebar view appearing.
//
// Observation is filesystem events over the directories
// `HerdrSocketWatchRoots.directories` names. Liveness is the same
// non-blocking `connect()` probe `HerdrSessionDiscovery.isAlive(
// socketPath:)` already owns -- a socket special file on disk proves
// nothing (a crashed herdr leaves one behind, and a live one exists on
// disk for a moment between `bind()` and `listen()`), so a filesystem
// event only ever schedules a bounded series of probes, never a
// conclusion of its own.
//
// Identity is device + inode alongside the path: herdr replaces a
// session by unlinking its socket and binding a new one at the SAME
// path, which the path alone cannot distinguish from "nothing changed".

import Darwin
import Foundation

/// The identity of one live herdr session.
struct HerdrSocketIdentity: Sendable, Equatable, Hashable {
    let socketPath: String
    /// `st_dev` of the socket special file.
    let deviceID: UInt64
    /// `st_ino` of the socket special file.
    let inode: UInt64
}

/// A transition in the set of live herdr sessions.
enum HerdrSessionPresenceChange: Sendable, Equatable {
    /// A socket that was not previously live now has a listener behind
    /// it.
    case appeared(HerdrSocketIdentity)
    /// The same socket path is now backed by a DIFFERENT socket file
    /// (the server unlinked and rebound): the previous session is gone
    /// and the current one is live.
    case replaced(previous: HerdrSocketIdentity, current: HerdrSocketIdentity)
    /// A previously live socket no longer accepts a connection.
    case disappeared(HerdrSocketIdentity)
}

/// Notified of every presence transition. Held WEAKLY by
/// `HerdrSessionPresence.setObserver(_:)`.
@MainActor
protocol HerdrSessionPresenceObserver: AnyObject {
    func herdrSessionPresenceDidChange(_ change: HerdrSessionPresenceChange)
}

@MainActor
final class HerdrSessionPresence {

    /// Bounded retry schedule for the `bind()`-then-`listen()` window: a
    /// filesystem event can land while the socket file exists but has no
    /// listener yet, which is indistinguishable from a crashed server's
    /// leftover until a later probe succeeds.
    ///
    /// The schedule is what covers that window, and it is the ONLY thing
    /// that does: once it runs out for a socket file that is there, the
    /// path is not asked about again until something else writes in its
    /// directory (see `readCandidate(at:)`). It is therefore long enough
    /// for a server that is slow rather than dead -- a `bind()`-to-
    /// `listen()` gap stretched by launch-time load, or a listen backlog
    /// momentarily full, which refuses a probe exactly as a leftover
    /// does. It is deliberately still a bounded schedule and not a poll:
    /// presence is observed, never asked for on a timer.
    static let defaultProbeDelays: [Duration] = [
        .milliseconds(150), .milliseconds(600), .seconds(2), .seconds(5),
    ]

    private let configRootDirectory: String
    private let environment: [String: String]
    private let discovery: any HerdrSessionDiscoveryProtocol
    private let probeDelays: [Duration]
    private let sleep: @Sendable (Duration) async -> Void

    private weak var observer: any HerdrSessionPresenceObserver?

    /// The live session at each candidate socket path, as last reported.
    /// A path absent here has no live session behind it.
    private var liveIdentities: [String: HerdrSocketIdentity] = [:]

    /// One filesystem-object source per watched directory, keyed by that
    /// directory's path.
    private var sources: [String: DispatchSourceFileSystemObject] = [:]

    private var isWatching = false

    /// Readings are serialized: a filesystem event arriving while one is
    /// in flight (a bounded probe retry can hold one for the whole
    /// `probeDelays` schedule) coalesces into a single follow-up rather
    /// than racing the reading already running.
    private var isReading = false
    private var needsAnotherReading = false

    init(
        configRootDirectory: String = HerdrConfigPaths.defaultRootDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discovery: any HerdrSessionDiscoveryProtocol = HerdrSessionDiscovery(),
        probeDelays: [Duration] = HerdrSessionPresence.defaultProbeDelays,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.configRootDirectory = configRootDirectory
        self.environment = environment
        self.discovery = discovery
        self.probeDelays = probeDelays
        self.sleep = sleep
    }

    /// Stored WEAKLY -- this type never owns an observer's lifecycle.
    func setObserver(_ observer: any HerdrSessionPresenceObserver?) {
        self.observer = observer
    }

    deinit {
        for source in sources.values {
            source.cancel()
        }
    }

    /// Begins watching, and reports whatever is ALREADY live as an
    /// initial reading through the same `.appeared` path.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        scheduleReading()
    }

    /// Stops watching, and forgets what was live: nothing observed it
    /// since, so nothing here is still true. Keeping it would make a
    /// later `start()` compare against a reading no one has taken, and
    /// silently report nothing for a session that IS live -- see
    /// `start()`'s own contract. No change is reported after this
    /// returns.
    func stop() {
        isWatching = false
        for source in sources.values {
            source.cancel()
        }
        sources = [:]
        liveIdentities = [:]
    }

    // MARK: - Reading

    private func scheduleReading() {
        guard isWatching else { return }
        guard !isReading else {
            needsAnotherReading = true
            return
        }
        isReading = true
        Task { [weak self] in
            await self?.readUntilSettled()
        }
    }

    private func readUntilSettled() async {
        defer { isReading = false }
        repeat {
            needsAnotherReading = false
            await read()
        } while needsAnotherReading && isWatching
    }

    /// One reading: re-aim the watched directories FIRST (so a socket
    /// created between this reading's probes and the next event cannot
    /// go unobserved), then compare every candidate path's socket file
    /// against what is held live.
    private func read() async {
        let roots = await watchRoots()
        guard isWatching else { return }
        updateSources(directories: roots)

        let candidatePaths = await candidateSocketPaths()
        guard isWatching else { return }

        for path in candidatePaths {
            await readCandidate(at: path)
            guard isWatching else { return }
        }

        // A candidate herdr no longer offers at all (its session
        // directory removed) is as gone as one whose socket died.
        for (path, identity) in liveIdentities where !candidatePaths.contains(path) {
            liveIdentities[path] = nil
            report(.disappeared(identity))
        }
    }

    /// Resolves one candidate path against what is held live there.
    ///
    /// A held session whose socket file is still the SAME one (device +
    /// inode unchanged) is not probed again: a server does not stop
    /// listening on a socket it keeps bound, so its session ends by the
    /// file being unlinked or rebound, both of which show up as a
    /// changed reading here.
    ///
    /// Any other socket file at the path is only ever concluded on by a
    /// SUCCESSFUL probe, retried a bounded number of times: a filesystem
    /// event can land in the window between the server's `bind()` and
    /// its `listen()`, where the socket file exists but refuses a
    /// connection exactly as a crashed server's leftover does. A
    /// schedule that runs out concludes nothing (beyond a held session
    /// whose own file is gone). What is guaranteed after that is only
    /// this: the next filesystem event in a watched directory starts a
    /// fresh reading, which asks about every candidate path again. A
    /// socket file that is already there and simply never comes alive
    /// produces no such event by itself, so a server that outlasts the
    /// whole schedule stays unreported until something else in that
    /// directory changes -- which is why `defaultProbeDelays` is sized
    /// for a slow server rather than only an instant one.
    ///
    /// A path with NO file is concluded on immediately: that window is
    /// the only thing the retries exist for, and it cannot be open for
    /// a file that does not exist.
    private func readCandidate(at path: String) async {
        let held = liveIdentities[path]
        var attempt = 0
        while true {
            let observed = await socketIdentity(at: path)
            guard isWatching else { return }
            if let held, observed == held { return }

            if let observed, await isAlive(socketPath: path) {
                guard isWatching else { return }
                liveIdentities[path] = observed
                if let held {
                    report(.replaced(previous: held, current: observed))
                } else {
                    report(.appeared(observed))
                }
                return
            }
            guard isWatching else { return }

            if let held, observed == nil {
                liveIdentities[path] = nil
                report(.disappeared(held))
                return
            }

            // Nothing at this path at all: there is no bind()-to-
            // listen() window to wait out, so there is nothing a retry
            // could learn. `HerdrSessionDiscovery` offers the default
            // socket path as a candidate whether or not a file is there,
            // and a machine without herdr watches directories whose
            // every unrelated write starts a reading -- burning the
            // whole schedule on each of them would be the common case,
            // not the exception. A socket created later arrives as a
            // directory event of its own.
            guard observed != nil else { return }

            guard attempt < probeDelays.count else {
                // A socket file that exists but never came alive: if a
                // session was held here, the file it was bound to is
                // gone either way.
                if let held {
                    liveIdentities[path] = nil
                    report(.disappeared(held))
                }
                return
            }
            await sleep(probeDelays[attempt])
            attempt += 1
            guard isWatching else { return }
        }
    }

    private func report(_ change: HerdrSessionPresenceChange) {
        guard isWatching else { return }
        observer?.herdrSessionPresenceDidChange(change)
    }

    // MARK: - Directory sources

    /// Opens a source for every newly watchable directory and cancels
    /// (releasing its file descriptor) every source whose directory is
    /// no longer part of the set -- a `sessions/<name>` directory herdr
    /// creates later, and the config root itself replacing the ancestor
    /// that stood in for it, both arrive this way.
    private func updateSources(directories: [String]) {
        let wanted = Set(directories)

        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }

        for path in directories where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }

            // `.write` is a socket appearing or vanishing INSIDE the
            // directory; `.delete`/`.rename` are the watched directory
            // ITSELF going away (herdr reinstalled, a config reset, a
            // `HERDR_SOCKET_PATH` parent moved). Without those two, a
            // deleted directory's own descriptor simply stops reporting
            // and nothing ever starts another reading, so presence goes
            // blind for the rest of the process. Reacting is the same
            // reading as any other: `watchRoots()` falls back to the
            // nearest ancestor that still exists, and the recreated
            // directory arrives as an ordinary write there.
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleDirectoryEvent(at: path)
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources[path] = source
        }
    }

    /// One event from the source watching `path`. A `.delete`/`.rename`
    /// is that directory itself going away: the descriptor still refers
    /// to the vanished directory and will never report anything again,
    /// so it is dropped here, BEFORE the reading below re-aims. A
    /// directory recreated at the same path therefore gets a fresh
    /// descriptor rather than the dead one being kept for matching the
    /// path -- which is what makes a delete-then-recreate observable at
    /// all, no matter which order the two land in.
    private func handleDirectoryEvent(at path: String) {
        if let source = sources[path], !source.data.intersection([.delete, .rename]).isEmpty {
            source.cancel()
            sources[path] = nil
        }
        scheduleReading()
    }

    // MARK: - Off-main filesystem work

    /// Directory scanning, socket enumeration and the `connect()` probe
    /// all block; none of them may run on the main actor.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: work())
            }
        }
    }

    private func watchRoots() async -> [String] {
        let configRootDirectory = self.configRootDirectory
        let environment = self.environment
        return await offMain {
            let fm = FileManager.default
            return HerdrSocketWatchRoots.directories(
                configRootDirectory: configRootDirectory,
                environment: environment,
                directoryExists: { path in
                    var isDirectory: ObjCBool = false
                    return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                subdirectories: { path in
                    guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
                    return entries.sorted().compactMap { entry in
                        let entryPath = path + "/" + entry
                        var isDirectory: ObjCBool = false
                        guard fm.fileExists(atPath: entryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                            return nil
                        }
                        return entryPath
                    }
                }
            )
        }
    }

    /// The ONLY paths this type ever looks at: discovery owns which
    /// locations herdr can put a socket at, so an unrelated socket file
    /// inside a watched directory is never mistaken for a session.
    private func candidateSocketPaths() async -> [String] {
        let discovery = self.discovery
        return await offMain { discovery.discover().map(\.socketPath) }
    }

    /// Device + inode of the socket file at `path`, `nil` when nothing
    /// is there. `lstat(2)`, never a followed link: the identity that
    /// matters is the file the server bound.
    ///
    /// `socketPath` carries the CANDIDATE path, which is what every
    /// consumer holds; a path a filesystem event reports has had its
    /// symlinks resolved (`/tmp` is a link to `/private/tmp`) and would
    /// not compare equal to it.
    private func socketIdentity(at path: String) async -> HerdrSocketIdentity? {
        await offMain {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return HerdrSocketIdentity(
                socketPath: path,
                deviceID: UInt64(UInt32(bitPattern: info.st_dev)),
                inode: UInt64(info.st_ino)
            )
        }
    }

    private func isAlive(socketPath: String) async -> Bool {
        let discovery = self.discovery
        return await offMain { discovery.isAlive(socketPath: socketPath) }
    }
}
