// IPCWakeHookTiming.swift
// Calyx
//
// Single source of truth for the timing constants that must nest
// strictly inside one another for one `/ipc-wake` long-poll: Calyx's own
// `POST /ipc-wake` long-poll timeout must resolve before the curl `-m`
// deadline of `calyx-ipc-wake-hook` (`IPCWakeHookScript`), the client
// long-polling `/ipc-wake`, gives up on it, which itself must fire
// before the CLI's own hook-entry timeout kills that client outright.
// Same shape, and the same reasoning, as `ApprovalHookTiming`:
//
// - If curl's timeout were <= the server's, curl would give up while
//   Calyx is still legitimately holding the poll open, and the client
//   would see a curl timeout instead of the server's own 204.
// - If the CLI's own hook-entry timeout were <= curl's, the CLI could
//   kill the client before curl's own `-m` deadline ever gets a chance
//   to run. That kill is uncontrolled: it can land the instant after
//   curl has already received a wake from the server but before the
//   client has used it, discarding a wake the server has already
//   committed (see `IPCWakeCoordinator`'s header comment for why that
//   wake is not handed out a second time).
//
// So the invariant this file exists to enforce is:
//     serverTimeoutMs < curlTimeoutSeconds * 1000 < hookEntryTimeoutSeconds * 1000
//
// A pane is wakeable only while a `calyx-ipc-wake-hook` process is
// long-polling `/ipc-wake` for it, and one poll lasts at most
// `holdSeconds` (about ten minutes): once the hook entry's timeout has
// passed, nothing is left to receive a wake until another poll starts.
// `IPCStore.peerTTL` has the same length: a peer expires only when 10
// minutes have passed since its last IPC operation AND it is neither the
// sender nor the recipient of an undelivered message (see `IPCStore`'s
// liveness rule).
//
// See IPCWakeHookTimingTests.test_nestingInvariant_serverBeforeCurlBeforeHookEntry
// for the specced ordering assertions.

import Foundation

enum IPCWakeHookTiming {
    /// The hook entry's own timeout, in seconds -- the outermost
    /// deadline in the chain, and the value every other constant here
    /// is derived backward from. The same length as `IPCStore.peerTTL`
    /// (see this file's header comment).
    static let holdSeconds = 600

    /// `CalyxMCPServer.ipcWakeTimeoutMs`'s default: the server's own
    /// `POST /ipc-wake` long-poll timeout, in milliseconds. 30s of
    /// margin under `holdSeconds * 1000` so the server always answers
    /// -- with a 204 when there is nothing to wake for -- strictly
    /// before curl's own deadline below would otherwise give up on it.
    static let serverTimeoutMs = holdSeconds * 1000 - 30_000

    /// The curl `-m` deadline of `calyx-ipc-wake-hook`
    /// (`IPCWakeHookScript.scriptBody` interpolates it), in seconds. 15s
    /// of margin under `holdSeconds` so curl gives up on its own
    /// strictly after the server has already answered, and strictly
    /// before the CLI's own hook-entry timeout below would instead kill
    /// the client outright, uncontrolled.
    static let curlTimeoutSeconds = holdSeconds - 15

    /// The CLI's own hook-entry timeout that kills the polling client if
    /// it hasn't exited by then: the `timeout` of the wake entry
    /// `ClaudeHooksConfigManager` writes for `Stop` and `SessionStart`.
    /// Restated here (equal to `holdSeconds`) purely so every link of
    /// the nesting invariant has its own named constant to compare
    /// against.
    static let hookEntryTimeoutSeconds = holdSeconds
}
