// SessionSpawnPlanner.swift
// Calyx
//
// Decides, per new terminal surface, whether to launch the user's
// ordinary shell (`.passthrough`, today's behavior) or a
// `calyx-session attach --create` command that survives ghostty
// surface teardown (`.persistent`). Gated off by default via
// `SessionSettings.persistentSessionsEnabled`.

import Foundation

/// Where a surface is being spawned. QuickTerminal panes are excluded
/// from persistent sessions by default: they're meant to be ephemeral
/// scratch panes, and reconnect/restore semantics for a
/// summon-on-demand window are out of scope for the initial rollout.
/// `.quickTerminal` itself is currently unreachable — no call site
/// constructs a `SessionSpawnContext` with it yet, since
/// `QuickTerminalController` never routes through `SessionSpawnPlanner`
/// at all — but the case (and `plan(for:)`'s guard against it) is kept
/// as a deliberate tripwire for whenever QuickTerminal *does* get
/// wired through this planner, so that integration starts excluded by
/// default rather than silently persistent.
enum SessionSpawnOrigin: Sendable, Equatable {
    case tab
    case quickTerminal
}

/// Terminal grid the host has already laid out for a new surface.
/// Supplying this to `calyx-session attach` prevents the embedded
/// Ghostty bootstrap grid from becoming the new shell's initial PTY size.
struct SessionInitialGridSize: Sendable, Equatable {
    let columns: UInt16
    let rows: UInt16
}

struct SessionSpawnContext: Sendable, Equatable {
    /// The resolved spawn cwd handed down by `CalyxWindowController
    /// .createManagedSurface` — already that method's own `explicitCwd
    /// ?? sessionFallbackCwd` (see its doc comment for why cwd
    /// resolution collapsed to those two parameters), so `plan(for:)`
    /// has exactly one cwd value to consider, never a priority to
    /// adjudicate between two. `nil` only when the caller resolved
    /// neither and is relying on this type's own `?? NSHomeDirectory()`
    /// fallback below.
    let cwd: String?
    /// The remote ssh host to spawn this session against, `nil` for a
    /// local session (every existing call site, unchanged). Non-nil
    /// makes `plan(for:)` synthesize via
    /// `SessionCommandSynthesizer.remoteAttachCommand` instead of the
    /// local-only `attachCommand`, and skip the local binary-
    /// resolvability guard entirely (see `plan(for:)`'s doc comment).
    let host: String?
    let origin: SessionSpawnOrigin
    let initialGridSize: SessionInitialGridSize?
    /// The program the session runs instead of the user's shell (as
    /// `attach --argv` flags, local and remote); nil runs the shell.
    let argv: [String]?

    init(
        cwd: String? = nil,
        host: String? = nil,
        origin: SessionSpawnOrigin = .tab,
        initialGridSize: SessionInitialGridSize? = nil,
        argv: [String]? = nil
    ) {
        self.cwd = cwd
        self.host = host
        self.origin = origin
        self.initialGridSize = initialGridSize
        self.argv = argv
    }
}

enum SpawnPlan: Sendable, Equatable {
    /// Launch the surface's default shell directly, exactly as today.
    case passthrough
    /// Launch `calyx-session attach --create` for `sessionID`, running
    /// `command` (built by `SessionCommandSynthesizer`). `host` mirrors
    /// `SessionSpawnContext.host` -- `nil` for a local plan, the given
    /// remote host for one synthesized via `remoteAttachCommand` -- so a
    /// caller applying the plan (see `CalyxWindowController
    /// .createManagedSurface`) can build `SessionRef(sessionID:host:)`
    /// without separately remembering the context it came from.
    case persistent(sessionID: String, command: String, host: String?)
}

enum SessionSpawnPlanner {

    /// `.passthrough` when the feature is off, `context.origin` is
    /// `.quickTerminal` (QuickTerminal panes are always excluded, see
    /// `SessionSpawnOrigin`'s doc comment -- this exclusion wins even
    /// with `context.host` set), or (LOCAL context only) `resolver`
    /// can't find the calyx-session binary at all (a `nil` resolution
    /// must not fall back to a hardcoded `"calyx-session"` literal that
    /// assumes `PATH` availability -- see `SessionBinaryResolver`'s doc
    /// comment). Otherwise generates a fresh ULID session ID and the
    /// matching attach command, using `cwd ?? home` as the effective
    /// working directory -- `context.cwd` already IS the caller's fully
    /// resolved spawn cwd (see `SessionSpawnContext.cwd`'s doc comment),
    /// so this planner has no priority left to adjudicate between two
    /// candidates; landing a new split/tab in the right directory (e.g.
    /// the pane it was split from) is entirely the CALLER's job now
    /// (`CalyxWindowController.createManagedSurface`'s
    /// `explicitCwd`/`sessionFallbackCwd`).
    ///
    /// Remote sessions: `context.host != nil` skips the LOCAL
    /// binary-resolvability guard entirely -- a remote session's daemon
    /// lives on the remote machine, so the LOCAL calyx-session binary's
    /// presence or absence says nothing about whether a remote spawn can
    /// proceed -- and synthesizes via
    /// `SessionCommandSynthesizer.remoteAttachCommand` instead of
    /// `attachCommand`. `remoteAttachCommand` never returns `nil`
    /// (`SSHBinaryResolver` always resolves to a path, see its own doc
    /// comment), so a remote `.persistent` plan can never itself fail to
    /// produce a command the way a local one degrading to `.passthrough`
    /// can. The fresh-ULID contract applies identically to both paths.
    static func plan(for context: SessionSpawnContext, resolver: SessionBinaryResolverProtocol = SessionBinaryResolver()) -> SpawnPlan {
        guard SessionSettings.persistentSessionsEnabled, context.origin != .quickTerminal else {
            return .passthrough
        }

        let sessionID = ULID.generate()
        let effectiveCwd = context.cwd ?? NSHomeDirectory()

        if let host = context.host {
            let command = SessionCommandSynthesizer.remoteAttachCommand(
                host: host,
                sessionID: sessionID,
                cwd: effectiveCwd,
                initialGridSize: context.initialGridSize,
                argv: context.argv
            )
            return .persistent(sessionID: sessionID, command: command, host: host)
        }

        guard let binaryPath = resolver.resolve() else {
            return .passthrough
        }
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath,
            sessionID: sessionID,
            cwd: effectiveCwd,
            initialGridSize: context.initialGridSize,
            argv: context.argv
        )
        return .persistent(sessionID: sessionID, command: command, host: nil)
    }
}

/// Minimal ULID (Universally Unique Lexicographically Sortable
/// Identifier) generator: a 48-bit millisecond timestamp followed by 80
/// bits of randomness, both encoded in Crockford's base32 (no
/// third-party dependency — this feature's only consumer is
/// `SessionSpawnPlanner`). Monotonicity within the same millisecond is
/// not required here (see `SessionSpawnPlannerTests
/// .test_plan_enabledTabOrigin_distinctCallsProduceDistinctSessionIDs`,
/// which only asserts distinctness, satisfied by the 80 random bits),
/// so plain per-call randomness is sufficient.
enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        let timestampMS = UInt64(Date().timeIntervalSince1970 * 1000)
        var randomBytes = [UInt8](repeating: 0, count: 10)
        for i in randomBytes.indices {
            randomBytes[i] = UInt8.random(in: 0...255)
        }
        return encodeTimestamp(timestampMS)
            + encode40Bits(randomBytes[0..<5])
            + encode40Bits(randomBytes[5..<10])
    }

    /// Encodes a 48-bit timestamp into 10 base32 characters (50 bits of
    /// capacity; the top 2 bits are always 0 for any millisecond
    /// timestamp before the year 10889, matching the standard ULID
    /// encoding).
    private static func encodeTimestamp(_ ms: UInt64) -> String {
        var chars = [Character](repeating: "0", count: 10)
        for i in 0..<10 {
            let shift = (9 - i) * 5
            chars[i] = alphabet[Int((ms >> UInt64(shift)) & 0x1F)]
        }
        return String(chars)
    }

    /// Encodes exactly 5 bytes (40 bits) into 8 base32 characters — an
    /// even multiple of 5-bit groups, so two calls cover the ULID's
    /// full 80 bits of randomness with no partial group to carry over.
    private static func encode40Bits(_ bytes: ArraySlice<UInt8>) -> String {
        var value: UInt64 = 0
        for byte in bytes {
            value = (value << 8) | UInt64(byte)
        }
        var chars = [Character](repeating: "0", count: 8)
        for i in 0..<8 {
            let shift = (7 - i) * 5
            chars[i] = alphabet[Int((value >> UInt64(shift)) & 0x1F)]
        }
        return String(chars)
    }
}
