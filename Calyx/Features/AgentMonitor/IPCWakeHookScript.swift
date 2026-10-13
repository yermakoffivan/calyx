// IPCWakeHookScript.swift
// Calyx
//
// The `calyx-ipc-wake-hook` shell script, the third Calyx hook script
// next to `calyx-agent-hook` (AgentHookScript.swift) and
// `calyx-approval-hook` (ApprovalHookScript.swift). It long-polls
// `POST /ipc-wake` (`CalyxMCPServer.routeIPCWake`) for its pane and
// turns the server's note into exit status 2 with that note on stderr.
// That exit status is the single exception to the hook scripts' "every
// path is exit 0" rule, and the condition it is tied to is the most
// important string invariant in this file. It is run by the hook entries
// `ClaudeHooksConfigManager` writes for Claude Code's `Stop` and
// `SessionStart` events, and the file itself is written by
// `AgentHooksCoordinator`'s Claude Code leg.

import Foundation

enum IPCWakeHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager`
    /// to recognize its own `command` entries by path, alongside
    /// `AgentHookScript.fileName` and `ApprovalHookScript.fileName`.
    static let fileName = "calyx-ipc-wake-hook"

    /// The script opens with `AgentHookScriptPrologue.body`, the section
    /// shared by every Calyx hook script: the four fail-open guards and
    /// the endpoint resolution live there, not in this literal. After
    /// it, the script asks `POST /ipc-wake` once whether the peer bound
    /// to this pane has messages the pane was not told about, and waits
    /// for the answer. It is run by the wake entry
    /// `ClaudeHooksConfigManager` writes for `Stop` and `SessionStart`,
    /// with no arguments, so `kind` resolves to `claude-code`.
    ///
    /// Why the exit status matters: Claude Code runs a hook entry marked
    /// `asyncRewake` in the background, and exit status 2 from it wakes
    /// an idle session and shows the hook's stderr to the model. So when
    /// the server answers with a note (`IPCWakeResponse.note`), this
    /// script prints that note to stderr via `printf '%s'`, with no
    /// newline added, and exits 2. Nothing is ever printed on stdout.
    ///
    /// That `exit 2` is the single exception to the hook scripts' "every
    /// path is exit 0" rule (see `ApprovalHookScript.scriptBody`), and
    /// it is taken on exactly one condition: curl exited 0 AND the
    /// response body starts with `IPCWakeResponse.notePrefix`, which is
    /// interpolated into the script rather than retyped. Every failure
    /// stays `exit 0` with nothing printed: a curl error, a non-2xx
    /// answer (turned into a curl error by `--fail`), a timeout, an
    /// empty body (the server's 204), and any body that does not start
    /// with the prefix.
    ///
    /// `stop_hook_active` is not consulted, and stdin is discarded
    /// unread: the server hands out a wake only for messages the pane
    /// was not told about yet, and each message causes at most one wake
    /// (see `IPCWakeCoordinator`'s header comment), so a woken turn
    /// ending cannot re-trigger the same wake.
    ///
    /// `cat > /dev/null` returns once the CLI has closed the hook's
    /// stdin after writing the event to it. That the CLI does close it
    /// is the same assumption `calyx-agent-hook` and
    /// `calyx-approval-hook` make when they read stdin to its end.
    ///
    /// The request has no body and no `Content-Type`: the route takes
    /// the pane's identity from the headers alone. The
    /// `X-Calyx-Surface-ID` value is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}` for the reason given on
    /// `AgentHookScript`'s doc comment. curl's `-m` deadline is
    /// `IPCWakeHookTiming.curlTimeoutSeconds`, interpolated so the
    /// nesting invariant that type documents cannot drift from this
    /// script.
    ///
    /// curl runs BACKGROUNDED, with a `trap` on TERM/HUP/INT that kills
    /// it and exits 0, for the reason documented on
    /// `ApprovalHookScript.scriptBody`: a foregrounded curl would
    /// outlive a killed script and keep the long-poll open. The same
    /// `signalled` / `curl_pid` handshake is used here: the trap only
    /// records `signalled=1` while `curl_pid` is empty, and the script
    /// checks `signalled` once before curl is started and again on the
    /// line right after `curl_pid=$!`. `curl_pid` is emptied again once
    /// `wait` has returned, so a late signal cannot `kill` a pid that is
    /// no longer curl's. From then on a TERM/HUP/INT only records
    /// `signalled=1` and the decision below still runs, so a note curl
    /// already received is still delivered with exit 2 rather than
    /// dropped: the server committed that wake when it answered.
    /// `SIGKILL` cannot be trapped: in that case curl lives on until the
    /// server answers or curl's own `-m` deadline passes.
    ///
    /// The response goes through the script's only temp file, created by
    /// `mktemp` from the template `${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX`:
    /// `TMPDIR` is honoured when set (macOS's bare `mktemp` ignores it),
    /// `/tmp` is used otherwise, and the file name starts with
    /// `calyx-ipc-wake.`. A failing `mktemp`
    /// ends the script with `exit 0` before curl is started. The file is
    /// removed by the `EXIT` trap on every exit path, including the
    /// signal trap's `exit 0`; that trap's body is an `if`, so its own
    /// status can never replace the script's exit status.
    ///
    /// Third fail-open guard, Grok: `kind` resolved to `claude-code`
    /// while `GROK_HOOK_EVENT` is set means Grok picked this entry up
    /// from `~/.claude/settings.json` (see `AgentHookScriptPrologue`).
    /// Without the guard this script would hold a long-poll as if the
    /// pane were Claude Code, and could answer a wake with exit status
    /// 2, a status only Claude Code's `asyncRewake` gives that meaning
    /// to.
    ///
    /// At-most-once boundary: a wake the server already handed over is
    /// not repeated if this script dies before it exits 2 (see
    /// `IPCWakeCoordinator`'s header comment).
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-ipc-wake-hook -- long-polls Calyx's local IPC endpoint (POST
    # /ipc-wake) for this pane. When the server answers with a note, the
    # note is printed to stderr and the script exits 2: Claude Code runs
    # a hook entry marked asyncRewake in the background, and exit status
    # 2 from it wakes an idle session and shows the hook's stderr to the
    # model. That is the only path that is not exit 0; any curl failure,
    # an empty answer or any other body exits 0 and prints nothing. Run
    # by the hook entries ClaudeHooksConfigManager writes for Stop and
    # SessionStart; the file is written by AgentHooksCoordinator's Claude
    # Code leg.
    #
    # curl runs backgrounded with a TERM/HUP/INT trap that kills it and
    # exits 0, as in calyx-approval-hook -- see ApprovalHookScript's doc
    # comment for the full writeup, and IPCWakeHookScript's for what is
    # specific to this script.

    \(AgentHookScriptPrologue.body)

    # Initialised before the traps are set, so that a trap firing early
    # never reads a value inherited from the environment.
    response_file=
    signalled=0
    curl_pid=
    # Written as an `if` so the trap's own status can never replace the
    # script's exit status.
    trap 'if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT
    # Kills and exits only once curl_pid is known; an earlier signal just
    # records signalled=1 for the two checks below. The EXIT trap removes
    # the response file.
    trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT

    # The event on stdin is not used.
    cat > /dev/null

    response_file=$(mktemp "${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX") || exit 0
    if [ "$signalled" = 1 ]; then
        exit 0
    fi

    curl -s -m \(IPCWakeHookTiming.curlTimeoutSeconds) \\
        --fail \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        "http://127.0.0.1:$port/ipc-wake" > "$response_file" &
    curl_pid=$!
    if [ "$signalled" = 1 ]; then
        kill "$curl_pid" 2>/dev/null
        exit 0
    fi
    wait "$curl_pid"
    curl_exit=$?
    curl_pid=

    response=$(cat "$response_file")

    # The one path that is not exit 0: curl succeeded AND the body is a
    # note.
    if [ "$curl_exit" = 0 ]; then
        case "$response" in
            "\(IPCWakeResponse.notePrefix)"*)
                printf '%s' "$response" >&2
                exit 2
                ;;
        esac
    fi

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path. Shares its actual write-then-chmod logic with
    /// `AgentHookScript.install(toDirectory:)` via
    /// `AgentHookScript.installScript(body:fileName:toDirectory:)`.
    static func install(toDirectory directory: String) throws -> String {
        try AgentHookScript.installScript(body: scriptBody, fileName: fileName, toDirectory: directory)
    }
}
