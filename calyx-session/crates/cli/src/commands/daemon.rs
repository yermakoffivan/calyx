use std::os::fd::AsFd;
use std::path::{Path, PathBuf};

use daemon::{Daemon, DaemonConfig, LOCK_FILE};
use nix::fcntl::{Flock, FlockArg};
use proto::ControlMsg;

use crate::cli::DaemonArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::{resolve_runtime_dir, resolve_state_dir, CommandError};

/// Variables scrubbed from the daemon's own process environment
/// before it starts serving, so a value inherited from whichever
/// client first spawned it can never leak into a session shell for
/// the rest of the daemon's life (a backgrounded daemon outlives the
/// client that spawned it, across Calyx restarts).
///
/// The rule is not which source first set a variable, and not
/// whether its value can go stale: it is whether something
/// re-supplies a fresh value on the path that would otherwise see a
/// stale one, or whether the variable names a pane rather than
/// anything a long-running daemon could ever hold correctly
/// regardless. Staleness by itself never justifies removal. A value
/// left in place, even if stale, still resolves correctly for as
/// long as whatever it points at is still there; a value scrubbed
/// with nothing to replace it resolves nothing at all,
/// unconditionally. So a variable nothing re-supplies stays even
/// though it can go stale -- removing it would be a pure loss, not a
/// fix, which is the trade-off recorded below, not an oversight for
/// a later reader to close.
///
/// - `GHOSTTY_RESOURCES_DIR`, `ZDOTDIR`, `GHOSTTY_ZSH_ZDOTDIR`,
///   `GHOSTTY_SHELL_FEATURES`, `CALYX_ZSH_ZDOTDIR`: every key
///   `resolve_shell_integration_env`
///   (`crates/cli/src/commands/shell_integration.rs`) can push into
///   the env it returns, other than `XDG_DATA_DIRS` (see below).
///   `attach` re-supplies each of these fresh into `SessionSpec.env`
///   on every attach, so a copy already sitting in the daemon's own
///   inherited environment is always overwritten before a session
///   shell sees it, and scrubbing it costs nothing. Confirmed
///   regression motivating this for `GHOSTTY_RESOURCES_DIR`
///   specifically: a long-running daemon held it pointing into a
///   stale DerivedData debug build after the installed app had moved
///   to `/Applications`. Extend this list by re-reading
///   `resolve_shell_integration_env`'s own pushes to `env`, not by
///   guessing; this file's own test suite calls that function
///   directly, across every shell its doc comment names, and fails
///   if a key it can push is missing here.
/// - `CALYX_SURFACE_ID`: names a pane. The daemon outlives any
///   single pane, so no value it could hold is ever correct here,
///   re-supplied or not; `session.rs`'s `spawn_session` already
///   removes it per session spawn for a different reason (a client
///   must not spoof pane identity through `spec.env`), and this
///   closes the same leak one level up, for the daemon's own
///   inherited copy.
/// - `CALYX_SECURE_INPUT_SOCKET`: names one Calyx app instance's
///   secure-input datagram socket. Like `CALYX_SURFACE_ID` it is an
///   instance/pane identifier that no long-lived daemon can hold
///   correctly; `attach` reads its own fresh copy, and `spawn_session`
///   also removes it per session spawn.
///
/// `TERMINFO` and `GHOSTTY_BIN_DIR` are deliberately NOT in this
/// list. `ghostty/src/termio/Exec.zig`'s `Subprocess.init` sets both
/// into every pane's child process the same way it sets
/// `GHOSTTY_RESOURCES_DIR` above (`TERMINFO` derived from
/// `resources_dir`'s own parent directory, `GHOSTTY_BIN_DIR` from
/// the running ghostty binary's own directory), and both can go
/// stale by the identical mechanism. But neither `attach` nor `new`
/// ever puts either one into `SessionSpec.env`
/// (`resolve_shell_integration_env` never pushes them, and `new`
/// sends `SessionSpec.env: vec![]`), so nothing re-supplies a fresh
/// value on any path a session shell can take. A stale `TERMINFO`
/// still resolves terminfo correctly for as long as the build it
/// points at is still on disk; an absent `TERMINFO` cannot resolve
/// `xterm-ghostty` at all on a machine where that entry isn't also
/// installed in a standard terminfo database location. Scrubbing
/// either one, with nothing to replace it, is strictly worse than
/// leaving the stale copy in place, so neither is scrubbed.
/// `Subprocess.init`'s other variables, `TERM`/`COLORTERM`
/// (terminal-type identifiers, nothing to go stale) and its
/// `PATH`/`MANPATH` appends (search-path lists whose stale entries
/// sit inert alongside the user's own real ones), were never scrub
/// candidates for a different reason: not "nothing re-supplies
/// them" but "nothing about them can go wrong by staying," so they
/// were never in this list to begin with.
///
/// `XDG_DATA_DIRS` is also deliberately NOT in this list, even
/// though `resolve_shell_integration_env` can push it too.
/// `CalyxShellIntegrationEnvironment.apply`
/// (`Calyx/Features/CommandLog/CalyxShellIntegrationEnvironment.swift`)
/// appends Calyx's own shell-integration root to whatever
/// `XDG_DATA_DIRS` already held (or seeds it with that root plus
/// fish's own documented defaults when it was unset), so the
/// daemon's inherited copy also carries the user's own real entries
/// (Homebrew, MacPorts, and so on), not just Calyx's. `attach`
/// re-supplies it fresh whenever the attaching client's own env has
/// it (unconditionally on shell type and resources dir), so
/// scrubbing would change nothing for that path; `new` sends
/// `SessionSpec.env: vec![]` and has no fresher value to fall back
/// on, so scrubbing here would strip a `new`-created session down to
/// the XDG default and lose the user's real entries entirely, a
/// worse outcome than an inherited copy that, at worst, carries one
/// stale ghostty-appended entry alongside everything real.
///
/// `SHELL` is deliberately not in this list either: `session.rs`
/// reads it for a session's default argv when `spec.argv` is `None`,
/// and it names the user's login shell, not a pane- or
/// ghostty-scoped value, so the daemon must keep seeing it from its
/// own environment. On macOS the daemon's own `$SHELL` only picks
/// which shell `login(1)` execs (`choose_shell` in the daemon's
/// `login_shell` module) and `login(1)` re-sets the `SHELL` variable
/// inside the session from the passwd entry; with `SHELL` scrubbed,
/// `choose_shell` falls back to that same passwd shell, so a
/// launchd-owned macOS daemon would lose nothing, but a daemon that
/// cannot resolve its passwd entry would then have no shell to choose
/// and every default spawn would fail, and on other platforms the
/// exec target would silently become this crate's `/bin/sh` fallback.
/// Those two losses are what keep `SHELL` out of this list.
const SCRUBBED_ENV_VARS: &[&str] = &[
    "GHOSTTY_RESOURCES_DIR",
    "ZDOTDIR",
    "GHOSTTY_ZSH_ZDOTDIR",
    "GHOSTTY_SHELL_FEATURES",
    "CALYX_ZSH_ZDOTDIR",
    "CALYX_SURFACE_ID",
    "CALYX_SECURE_INPUT_SOCKET",
];

/// Runs (or backgrounds) the session daemon. `--foreground` runs
/// `Daemon::bind(..).run_until_idle()` directly on this process; the
/// default path double-forks into a detached background daemon that
/// holds an exclusive flock so concurrent starts collapse to one.
///
/// With `--handoff-connect` (EXPERIMENTAL, spawned by `upgrade`) the
/// same foreground/background split applies, but the daemon runs
/// `daemon::run_handoff_receiver` instead of binding its own socket:
/// it inherits the running daemon's listener and sessions. That path
/// takes the single-daemon flock only after its ack (the old daemon
/// holds it until then; see `run_handoff_receiver`).
pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: DaemonArgs,
) -> Result<u8, CommandError> {
    // Sound without synchronization: this is the first thing the
    // `daemon` subcommand's entry point does, before this process has
    // spawned any thread, so nothing else can be reading the
    // environment concurrently. Everything downstream that puts a
    // daemon on this environment (the background double-fork below,
    // and the handoff receiver spawned by `upgrade`'s `Command::new`)
    // either forks -- which copies this already-scrubbed environment
    // rather than re-inheriting from a parent -- or starts a fresh
    // process whose own entry point runs this same scrub again.
    for var in SCRUBBED_ENV_VARS {
        std::env::remove_var(var);
    }

    let config = DaemonConfig {
        runtime_dir: resolve_runtime_dir(runtime_dir),
        state_dir: resolve_state_dir(state_dir),
        history_enabled: args.persist_history,
    };

    if let Some(handoff_socket) = args.handoff_connect {
        if args.foreground {
            daemon::run_handoff_receiver(config, &handoff_socket)?;
            return Ok(0);
        }
        if !daemonize()? {
            return Ok(0);
        }
        return run_daemonized_receiver(config, &handoff_socket);
    }

    if args.foreground {
        if args.adopt_existing {
            return run_foreground_single_instance(config);
        }
        Daemon::bind(config)?.run_until_idle()?;
        return Ok(0);
    }

    if !daemonize()? {
        return Ok(0);
    }
    run_daemonized(config)
}

/// `daemon --foreground --adopt-existing` entry point (LaunchAgent
/// only; see `adopt_existing`'s doc comment on `DaemonArgs`): takes the
/// single-daemon flock non-blockingly, binding fresh if it wins, or
/// adopting the daemon that already holds it if it loses.
fn run_foreground_single_instance(config: DaemonConfig) -> Result<u8, CommandError> {
    match daemon::try_acquire_single_daemon_lock(&config.runtime_dir)? {
        Some(lock) => {
            Daemon::bind(config)?.with_lock(lock).run_until_idle()?;
            Ok(0)
        }
        None => adopt_running_daemon(config),
    }
}

/// Connects to the daemon already holding the single-daemon lock as an
/// ordinary client, drives `PrepareHandoff`, and becomes the new
/// daemon via `daemon::run_handoff_receiver` (the receiver side of the
/// same Live Handoff `upgrade` drives, run here by the process that
/// lost the lock race instead of a third-party orchestrator). Never
/// falls back to `Daemon::bind` on any failure: that would delete and
/// rebind the existing socket out from under a daemon that is still
/// alive and serving it.
fn adopt_running_daemon(config: DaemonConfig) -> Result<u8, CommandError> {
    let socket = config.runtime_dir.join(::daemon::SOCKET_FILE);
    let client = DaemonClient::connect(&socket)?;
    let path = match client.request(&ControlMsg::PrepareHandoff)? {
        ControlMsg::PrepareHandoffOk { path } => path,
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    };
    // Keep `client` alive for the whole handoff attempt: the old
    // daemon reports a `handoff-failed` `Err` on this same connection
    // if adoption fails on this side, and dropping the connection
    // early would look identical to a successful takeover.
    daemon::run_handoff_receiver(config, std::path::Path::new(&path))?;
    drop(client);
    Ok(0)
}

/// Double-forks into a detached grandchild (new session in between, so
/// the daemon can never reacquire a controlling terminal). Returns
/// `Ok(false)` in the original process (the daemon runs on detached;
/// the caller just reports success) and `Ok(true)` in the grandchild.
fn daemonize() -> Result<bool, CommandError> {
    // SAFETY: this process is still single-threaded here (nothing has
    // spawned threads before subcommand dispatch), which is the
    // precondition for fork() continuing into arbitrary Rust code in
    // the child.
    let first = unsafe { libc::fork() };
    if first < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    if first > 0 {
        // Original process: reap the intermediate child.
        let mut status: libc::c_int = 0;
        // SAFETY: waiting for the pid fork() just returned.
        unsafe { libc::waitpid(first, &mut status, 0) };
        return Ok(false);
    }

    // Intermediate child: new session, fork again, exit.
    // SAFETY (this whole block): standard daemonization syscalls on a
    // freshly forked, single-threaded child.
    unsafe {
        if libc::setsid() < 0 {
            libc::_exit(1);
        }
        let second = libc::fork();
        if second < 0 {
            libc::_exit(1);
        }
        if second > 0 {
            libc::_exit(0);
        }
    }
    Ok(true)
}

/// stdio -> log file / dev-null: a detached daemon has no terminal.
fn detach_stdio(config: &DaemonConfig) {
    std::fs::create_dir_all(&config.state_dir).ok();
    std::fs::create_dir_all(&config.runtime_dir).ok();

    if let Ok(log) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(config.state_dir.join("daemon.log"))
    {
        let _ = nix::unistd::dup2_stdout(&log);
        let _ = nix::unistd::dup2_stderr(&log);
    }
    if let Ok(devnull) = std::fs::File::open("/dev/null") {
        let _ = nix::unistd::dup2_stdin(&devnull);
    }
}

/// Live Handoff receiver, daemonized. Never returns control to a
/// caller that could double-run main-exit logic: ends in `_exit`
/// (mirrors `run_daemonized`).
fn run_daemonized_receiver(
    config: DaemonConfig,
    handoff_socket: &Path,
) -> Result<u8, CommandError> {
    detach_stdio(&config);
    let code = match daemon::run_handoff_receiver(config, handoff_socket) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("calyx-session daemon (handoff receiver): {e}");
            1
        }
    };
    // SAFETY: ends the daemonized process without unwinding into the
    // CLI's main.
    unsafe { libc::_exit(code) };
}

/// Never returns control to a caller that could double-run main-exit
/// logic: ends in `_exit`.
///
/// Duplicates `daemon::try_acquire_single_daemon_lock`'s open/flock/
/// dup/forget sequence rather than calling it: that function maps a
/// flock failure to `Ok(None)` only for `EWOULDBLOCK` and to `Err`
/// otherwise, while this function needs every flock failure, of any
/// kind, to collapse to the same quiet `_exit(0)` (pinned by
/// `daemon_lock_regression.rs`). See that function's own doc comment
/// for the full reasoning.
fn run_daemonized(config: DaemonConfig) -> Result<u8, CommandError> {
    detach_stdio(&config);

    // Single-daemon lock, held for the daemon's whole life (the guard
    // is deliberately leaked below so it is never unlocked).
    let lock_file = match std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(config.runtime_dir.join(LOCK_FILE))
    {
        Ok(lock_file) => lock_file,
        // SAFETY: _exit in a detached daemon that failed to set up.
        Err(_) => unsafe { libc::_exit(1) },
    };
    let lock = match Flock::lock(lock_file, FlockArg::LockExclusiveNonblock) {
        Ok(lock) => lock,
        // Another daemon already serves this runtime dir.
        // SAFETY: plain _exit.
        Err(_) => unsafe { libc::_exit(0) },
    };
    // Hand a dup of the held lock fd down to the daemon so a later Live
    // Handoff can transfer the exact same open file description to the
    // next generation (P6 review E5). The guard below is still leaked so
    // this process holds the flock for its whole life regardless; the
    // dup shares that one open file description (flock is per open file
    // description), it never independently re-locks.
    let lock_dup = match lock.as_fd().try_clone_to_owned() {
        Ok(fd) => fd,
        // SAFETY: _exit in a detached daemon that failed to set up.
        Err(_) => unsafe { libc::_exit(1) },
    };
    std::mem::forget(lock);

    let code = match Daemon::bind(config).map(|daemon| daemon.with_lock(lock_dup).run_until_idle())
    {
        Ok(Ok(())) => 0,
        Ok(Err(e)) | Err(e) => {
            eprintln!("calyx-session daemon: {e}");
            1
        }
    };
    // SAFETY: ends the daemonized process without unwinding into the
    // CLI's main.
    unsafe { libc::_exit(code) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::shell_integration::resolve_shell_integration_env;
    use std::collections::BTreeSet;

    /// Every key `resolve_shell_integration_env` can push for one
    /// `(shell, resources_dir_present)` combination, probed with
    /// every other queried key present so every conditional branch
    /// that can fire for that combination does.
    fn probed_keys(shell: &str, resources_dir_present: bool) -> BTreeSet<String> {
        let env = resolve_shell_integration_env(|key| {
            if key == "SHELL" {
                return Some(shell.to_string());
            }
            if key == "GHOSTTY_RESOURCES_DIR" && !resources_dir_present {
                return None;
            }
            Some(format!("probe-value-for-{key}"))
        });
        env.into_iter().map(|(k, _)| k).collect()
    }

    /// Pins the invariant `SCRUBBED_ENV_VARS`'s own doc comment
    /// depends on: that const must equal exactly
    /// `resolve_shell_integration_env`'s own key set (minus the
    /// documented `XDG_DATA_DIRS` carve-out) plus `CALYX_SURFACE_ID`
    /// and `CALYX_SECURE_INPUT_SOCKET`, the deliberate additions that
    /// const's doc comment justifies on their own terms (pane/instance
    /// identifiers, not re-supplied values).
    /// Probes across every shell `resolve_shell_integration_env`'s own
    /// doc comment names, zsh (wired) and bash/fish (documented future
    /// extension points), crossed with resources-dir present/absent,
    /// so a later shell-specific branch added to that function is
    /// caught here even before it is wired for zsh specifically.
    /// Asserting equality rather than a subset also catches the
    /// opposite mistake: adding a variable to `SCRUBBED_ENV_VARS` that
    /// neither this function pushes nor the identifier carve-outs justify,
    /// where nothing re-supplies it, so scrubbing it is a pure loss,
    /// not a fix (`SCRUBBED_ENV_VARS`'s own doc comment covers exactly
    /// this trade-off for `TERMINFO`/`GHOSTTY_BIN_DIR`). Without this,
    /// someone could add a new `env.push(...)` to
    /// `resolve_shell_integration_env` and forget to add the matching
    /// key here, or add an unjustified key to `SCRUBBED_ENV_VARS`
    /// itself; this test fails either way instead of the scrub
    /// silently falling behind or over-scrubbing.
    #[test]
    fn scrubbed_env_vars_covers_every_key_resolve_shell_integration_env_can_push() {
        let mut union: BTreeSet<String> = BTreeSet::new();
        for shell in ["/bin/zsh", "/bin/bash", "/usr/bin/fish"] {
            for resources_dir_present in [true, false] {
                union.extend(probed_keys(shell, resources_dir_present));
            }
        }

        assert!(
            union.contains("XDG_DATA_DIRS"),
            "sanity check: XDG_DATA_DIRS should still be a key resolve_shell_integration_env \
             can push; if this fails, the XDG_DATA_DIRS exception below is vacuous and needs \
             reconsidering, not just re-asserting"
        );

        let mut expected: BTreeSet<&str> = union
            .iter()
            .map(String::as_str)
            .filter(|key| *key != "XDG_DATA_DIRS")
            .collect();
        // The additions SCRUBBED_ENV_VARS makes beyond
        // resolve_shell_integration_env's own key set: justified on
        // their own terms (pane/instance identifiers) rather than by
        // re-supply, per that const's own doc comment.
        expected.insert("CALYX_SURFACE_ID");
        expected.insert("CALYX_SECURE_INPUT_SOCKET");
        let scrubbed: BTreeSet<&str> = SCRUBBED_ENV_VARS.iter().copied().collect();

        assert_eq!(
            scrubbed,
            expected,
            "SCRUBBED_ENV_VARS must equal exactly resolve_shell_integration_env's own key \
             set (other than the documented XDG_DATA_DIRS carve-out) plus CALYX_SURFACE_ID and \
             CALYX_SECURE_INPUT_SOCKET: missing {:?} (resolve_shell_integration_env can push \
             these, or they name a pane/instance, but SCRUBBED_ENV_VARS omits them, so a stale copy sitting in the \
             daemon's own inherited environment could leak into a session that never \
             re-supplies it), unjustified extra {:?} (SCRUBBED_ENV_VARS scrubs these even \
             though nothing re-supplies them and they are not a pane/instance identifier, so removing \
             them is a pure loss, not a fix, per SCRUBBED_ENV_VARS's own doc comment)",
            expected.difference(&scrubbed).collect::<Vec<_>>(),
            scrubbed.difference(&expected).collect::<Vec<_>>()
        );
    }
}
