// AgentHookScript.swift
// Calyx
//
// The `calyx-agent-hook` shell script installed under
// `~/Library/Application Support/Calyx/bin/`. Forwards a Claude Code hook's
// stdin JSON to the local Calyx IPC server's /agent-event endpoint.

import Foundation

enum AgentHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` to
    /// recognize its own `command` entries by path.
    static let fileName = "calyx-agent-hook"

    /// Default install directory: `~/Library/Application Support/Calyx/bin`.
    static var defaultInstallDirectory: String {
        (AgentEndpointFile.defaultDirectory as NSString).appendingPathComponent("bin")
    }

    /// The script opens with `AgentHookScriptPrologue.body`, the section
    /// shared by every Calyx hook script: the guards and the endpoint
    /// resolution described below live there, not in this literal.
    ///
    /// Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset means this
    /// pane wasn't launched by Calyx at all (e.g. a plain Terminal.app
    /// tab running `claude`) — exit immediately so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token. Every exit path is `exit 0`: a failed or unreachable
    /// POST must never break the user's hook chain.
    ///
    /// `$1` is the agent kind, forwarded as the `X-Calyx-Agent-Kind`
    /// header so the server can attribute the event to the right CLI.
    /// Defaulting to `claude-code` when `$1` is unset keeps this script
    /// compatible with Claude Code's own hook `command` entries (installed
    /// by `ClaudeHooksConfigManager`), which invoke it with no arguments;
    /// `CodexHooksConfigManager` installs Codex's entries as
    /// `"<scriptPath>" codex` to pass `codex` explicitly.
    ///
    /// The `X-Calyx-Surface-ID` header value itself is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}`: a persistent-session
    /// pane's calyx-session ID survives ghostty surface re-creation
    /// (reconnect) while `CALYX_SURFACE_ID` does not, so `CALYX_SESSION_ID`
    /// is preferred whenever set, falling back to the ordinary
    /// `CALYX_SURFACE_ID` otherwise. The fail-open guard above checks
    /// both variables (not just `CALYX_SURFACE_ID`) so a hypothetical
    /// future caller that sets only `CALYX_SESSION_ID` still gets its
    /// event forwarded, rather than the guard silently depending on an
    /// invariant ("`CALYX_SESSION_ID` is only ever set alongside
    /// `CALYX_SURFACE_ID`") that happens to hold today but isn't
    /// enforced anywhere.
    ///
    /// Second fail-open guard, herdr environment contamination: running
    /// a herdr server from inside a Calyx pane's shell means every
    /// shell herdr itself spawns can inherit that pane's
    /// `CALYX_SURFACE_ID`/`CALYX_SESSION_ID` — the guard above alone
    /// does NOT catch this, because that inherited ID is non-empty
    /// (just stale/misattributed, not unset). The guard is
    /// `[ -n "$HERDR_PANE_ID" ]`: of every `HERDR_`-prefixed variable
    /// herdr sets inside a managed pane (`HERDR_PANE_ID`,
    /// `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`,
    /// `HERDR_ENV`, empirically confirmed against a real herdr pane),
    /// only `HERDR_PANE_ID` reliably means "this shell is running
    /// inside a herdr-managed pane". The others are not that signal —
    /// `HERDR_SOCKET_PATH` in particular is user-facing configuration a
    /// person may export in their own shell profile (to select a herdr
    /// session by default) from inside an ORDINARY Calyx pane herdr
    /// never touched at all, so a guard that suppressed on ANY
    /// `HERDR_`-prefixed name would silently cost that pane its agent
    /// monitoring the moment the user exports it. An earlier
    /// implementation matched any `HERDR_`-prefixed variable NAME via
    /// `awk`'s `ENVIRON` keys for exactly this over-broad reason and
    /// was replaced. Reading `$HERDR_PANE_ID` directly, rather than
    /// scanning the environment for a name/value match, also sidesteps
    /// the class of problem a text-based `env | grep` scan would have:
    /// an unrelated variable's VALUE can never be misread as its own
    /// `HERDR_PANE_ID=...` assignment, since this guard never inspects
    /// any value other than that one named parameter's own.
    ///
    /// Known residual path (tracked, not closable by this guard):
    /// Claude Code's own MCP client config (`ClaudeConfigManager`)
    /// writes the `X-Calyx-Surface-ID` header as the literal string
    /// `${CALYX_SURFACE_ID:-}`, which Claude Code itself expands from
    /// its OWN process environment at MCP-connection time, entirely
    /// inside the agent binary — a separate code path this hook script
    /// never runs in and cannot intercept. A stale `CALYX_SURFACE_ID`
    /// inherited by a herdr-managed shell can still reach that header
    /// this way. Tracked for the herdr socket-integration stage.
    ///
    /// Third fail-open guard, Grok: `kind` resolved to `claude-code`
    /// while `GROK_HOOK_EVENT` is set means Grok picked this entry up
    /// from `~/.claude/settings.json` (see `AgentHookScriptPrologue`).
    /// Without the guard this script would post events attributed to
    /// the wrong CLI.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-agent-hook — forwards a Claude Code hook's stdin JSON to
    # Calyx's local Agent Monitor IPC endpoint. Installed and removed by
    # ClaudeHooksConfigManager / CodexHooksConfigManager.

    \(AgentHookScriptPrologue.body)

    curl -s -m 2 \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$port/agent-event" > /dev/null 2>&1

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path.
    static func install(toDirectory directory: String) throws -> String {
        try installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }

    /// Shared installer body: writes `body` to `fileName` inside
    /// `directory` (creating it if needed) and marks it executable
    /// (0755), returning the script's absolute path. Used by both
    /// `AgentHookScript.install(toDirectory:)` above and
    /// `ApprovalHookScript.install(toDirectory:)`, so the actual
    /// write logic exists in exactly one place. Routes through
    /// `ConfigFileUtils.withExclusiveConfig`, which resolves the
    /// script's path, takes its exclusive lock, and writes atomically
    /// at 0755 -- the mode an agent CLI executes -- applied to the temp
    /// file before the rename inside the lock, so no other process can
    /// observe or race an intermediate permission state.
    static func installScript(body: String, fileName: String, toDirectory directory: String) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let scriptPath = (directory as NSString).appendingPathComponent(fileName)
        let data = Data(body.utf8)
        try ConfigFileUtils.withExclusiveConfig(path: scriptPath, mode: 0o755, restoreModeOnNoWrite: true) { _ in data }
        return scriptPath
    }
}
