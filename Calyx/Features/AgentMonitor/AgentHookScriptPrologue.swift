// AgentHookScriptPrologue.swift
// Calyx
//
// The opening section both Calyx hook scripts start with:
// `calyx-agent-hook` (AgentHookScript.swift) and `calyx-approval-hook`
// (ApprovalHookScript.swift). Any future Calyx hook script must start
// with it too. It decides whether this hook invocation belongs to a
// Calyx pane at all, and if so resolves which local IPC endpoint to
// talk to. Written once here and interpolated into each script's body,
// so the guards cannot drift apart between scripts.
//
// Properties each script relies on:
// - Every path out of the prologue is `exit 0`: a hook that has
//   nothing to do must never break the user's hook chain.
// - Falling through it leaves three shell variables set: `kind` (the
//   agent kind, `$1` defaulting to `claude-code`), and `port` and
//   `token` (both non-empty, read from agent-endpoint.json).
// - It runs no network call, sets no trap and creates no file, so a
//   script is free to do its own posting, signal handling and temp
//   files after it.

import Foundation

enum AgentHookScriptPrologue {

    /// The shared `/bin/sh` text, from the first guard's `if` line
    /// through the `fi` of the port/token check, with no leading or
    /// trailing newline. Four fail-open guards and the endpoint
    /// resolution, in this order:
    ///
    /// 1. Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset: the pane
    ///    wasn't launched by Calyx at all.
    /// 2. `HERDR_PANE_ID` non-empty: the shell is herdr-managed and its
    ///    Calyx IDs are inherited, stale ones -- see `AgentHookScript`'s
    ///    doc comment for why only `HERDR_PANE_ID` is that signal.
    /// 3. `kind` resolved to `claude-code` while `GROK_HOOK_EVENT` is
    ///    set: a Claude Code hook entry that Grok picked up from
    ///    `~/.claude/settings.json`. What would go wrong without this
    ///    guard differs per script and is documented on each script's
    ///    own `scriptBody`.
    /// 4. agent-endpoint.json missing, or without a port or token: no
    ///    Calyx server to reach. The file is re-read on every
    ///    invocation (rather than baked in at install time) so a server
    ///    restart or token rotation never leaves a hook using a stale
    ///    port/token.
    static let body: String = """
    if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then
        exit 0
    fi

    # A herdr server started from inside a Calyx pane can spawn shells
    # that inherit that pane's CALYX_SURFACE_ID/CALYX_SESSION_ID -- a
    # non-empty HERDR_PANE_ID means this shell is herdr-managed, so skip
    # posting under that stale, misattributed surface identity. Other
    # HERDR_-prefixed variables (e.g. HERDR_SOCKET_PATH) are NOT this
    # signal: a user may export HERDR_SOCKET_PATH in their own shell
    # profile from inside an ordinary Calyx pane herdr never touched, so
    # only HERDR_PANE_ID itself is checked here.
    if [ -n "$HERDR_PANE_ID" ]; then
        exit 0
    fi

    kind="${1:-claude-code}"

    # Grok scans ~/.claude/settings.json for hooks by default, so Calyx's
    # Claude Code entries -- which pass no kind argument and therefore
    # resolve to claude-code -- also fire inside a Grok session, where
    # a hook shaped for Claude Code must do nothing. GROK_HOOK_EVENT is a
    # reserved variable Grok's hook runner injects into every hook
    # process, so it is set for Calyx's own Grok entries too; those pass
    # an explicit kind and are unaffected. The user's own [compat.*]
    # settings are never touched.
    if [ "$kind" = "claude-code" ] && [ -n "$GROK_HOOK_EVENT" ]; then
        exit 0
    fi

    # CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController alongside
    # CALYX_SURFACE_ID, scoped to wherever this Calyx process actually
    # wrote agent-endpoint.json (a --calyx-path-root scratch directory
    # under test, the real Application Support directory otherwise). The
    # literal fallback covers a pane launched before that injection
    # existed, or a shell that stripped the variable.
    endpoint_file="${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi
    """
}
