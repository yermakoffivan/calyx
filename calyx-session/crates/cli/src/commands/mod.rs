//! Subcommand implementations.

pub mod attach;
pub(crate) mod client;
pub mod daemon;
pub mod history;
pub mod kill;
pub mod ls;
pub mod meta;
pub mod new;
pub mod remote_install;
pub(crate) mod secure_input_notify;
pub(crate) mod shell_integration;
pub(crate) mod terminal_env;
pub mod upgrade;

use std::fmt;
use std::path::{Path, PathBuf};

/// Error type returned by every subcommand's `run`.
#[derive(Debug)]
pub enum CommandError {
    Io(std::io::Error),
    Protocol(proto::ProtoError),
    Daemon(::daemon::DaemonError),
    /// The daemon replied with `ControlMsg::Err`.
    Server {
        code: String,
        msg: String,
    },
    RemoteInstall(remote_install::RemoteInstallError),
}

impl fmt::Display for CommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CommandError::Io(e) => write!(f, "{e}"),
            CommandError::Protocol(e) => write!(f, "{e}"),
            CommandError::Daemon(e) => write!(f, "{e}"),
            CommandError::Server { code, msg } => write!(f, "daemon error [{code}]: {msg}"),
            CommandError::RemoteInstall(e) => write!(f, "{e}"),
        }
    }
}

impl From<remote_install::RemoteInstallError> for CommandError {
    fn from(e: remote_install::RemoteInstallError) -> Self {
        CommandError::RemoteInstall(e)
    }
}

impl From<std::io::Error> for CommandError {
    fn from(e: std::io::Error) -> Self {
        CommandError::Io(e)
    }
}

impl From<proto::ProtoError> for CommandError {
    fn from(e: proto::ProtoError) -> Self {
        CommandError::Protocol(e)
    }
}

impl From<::daemon::DaemonError> for CommandError {
    fn from(e: ::daemon::DaemonError) -> Self {
        CommandError::Daemon(e)
    }
}

/// Resolves the runtime directory: `runtime_dir` if given, else
/// `$HOME/.calyx/run`. Every subcommand takes `runtime_dir` from the
/// top-level `Cli` (global flag), so tests always pass an explicit
/// scratch directory here and never hit the `$HOME` fallback.
pub fn resolve_runtime_dir(runtime_dir: &Option<PathBuf>) -> PathBuf {
    runtime_dir
        .clone()
        .unwrap_or_else(|| default_home_subdir("run"))
}

/// Resolves the state directory: `state_dir` if given, else
/// `$HOME/.calyx/state`. See `resolve_runtime_dir`.
pub fn resolve_state_dir(state_dir: &Option<PathBuf>) -> PathBuf {
    state_dir
        .clone()
        .unwrap_or_else(|| default_home_subdir("state"))
}

fn default_home_subdir(leaf: &str) -> PathBuf {
    let home = std::env::var_os("HOME")
        .expect("HOME must be set to resolve the default calyx-session directories");
    Path::new(&home).join(".calyx").join(leaf)
}

/// Where every non-`daemon` subcommand finds the daemon's socket.
pub fn socket_path(runtime_dir: &Option<PathBuf>) -> PathBuf {
    resolve_runtime_dir(runtime_dir).join(::daemon::SOCKET_FILE)
}

// Whether `attach`'s launchd-owned daemon path may be used, true only
// when `runtime_dir`/`state_dir` resolve to exactly the real default
// session root (`default_run`/`default_state`,
// i.e. `$HOME/.calyx/run` and `$HOME/.calyx/state` in production),
// never merely when both are `None`. Deliberately NOT
// `runtime_dir.is_none() && state_dir.is_none()`: Calyx's Swift side
// always passes both flags explicitly (`SessionCommandSynthesizer.swift`),
// so an `is_none()` check would make the launchd route dead code in
// the one caller that matters, even though its explicit paths equal
// the real default. See `launchd_route_tests` below for the pinned
// contract.
//
// `default_run`/`default_state` are parameters rather than read from
// `$HOME` internally: mutating the real, process-wide `HOME`
// environment variable from a test would race every other test
// running in the same `cargo test` process, since env vars are
// shared, unsynchronized global state. Taking the defaults as plain
// parameters instead keeps this a pure function testable without
// touching `std::env` at all. Production wiring is expected to pass
// `default_home_subdir("run")`/`default_home_subdir("state")`.

/// Resolves the real default session root (`$HOME/.calyx/{run,state}`)
/// for deciding whether `attach`'s launchd route applies, WITHOUT
/// panicking when `HOME` is unset -- unlike
/// `resolve_runtime_dir`/`resolve_state_dir`'s `None` fallback, which
/// `.expect()`s it. An explicit `--runtime-dir`/`--state-dir` pair
/// (every real caller always passes both) must keep resolving
/// correctly even in a `HOME`-less environment (`env -i`, some
/// CI/launchd contexts) exactly as it did before the launchd route
/// existed; "can't compute the default root to compare against" must
/// degrade to "this isn't the default root" (`None`, so the launchd
/// route is skipped), never crash a caller that was never asking for
/// the default root in the first place.
#[cfg(target_os = "macos")]
pub fn default_session_root() -> Option<(PathBuf, PathBuf)> {
    default_session_root_with(|key| std::env::var_os(key))
}

/// `lookup` is injected so the "no `HOME`" case is tested as a pure
/// function without mutating the real, process-wide `HOME` environment
/// variable, which would race any other test running in parallel in
/// the same `cargo test` process (the same reason `default_home_subdir`
/// itself isn't touched here).
#[cfg(target_os = "macos")]
fn default_session_root_with(
    lookup: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> Option<(PathBuf, PathBuf)> {
    let home = lookup("HOME")?;
    let home = Path::new(&home);
    Some((
        home.join(".calyx").join("run"),
        home.join(".calyx").join("state"),
    ))
}

/// Whether `attach`'s launchd-owned daemon route (macOS only) may be
/// used: true only when `runtime_dir`/`state_dir` resolve to exactly
/// `default_run`/`default_state`. Compares resolved paths, not raw
/// `Option`s (see the block comment above), and does not canonicalize
/// either side, since the default directories may not exist yet.
#[cfg(target_os = "macos")]
pub fn uses_default_session_root(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    default_run: &Path,
    default_state: &Path,
) -> bool {
    // Resolved against the caller-supplied defaults, not
    // `resolve_runtime_dir`/`resolve_state_dir` (which fall back to the
    // real `$HOME`): this keeps the function pure and testable without
    // touching real, process-wide environment state.
    let resolved_run = runtime_dir
        .clone()
        .unwrap_or_else(|| default_run.to_path_buf());
    let resolved_state = state_dir
        .clone()
        .unwrap_or_else(|| default_state.to_path_buf());
    resolved_run == default_run && resolved_state == default_state
}

#[cfg(all(test, target_os = "macos"))]
mod launchd_route_tests {
    use super::*;

    /// An explicit, non-default `--runtime-dir` (every daemon/cli test
    /// fixture, and the `/tmp/cxe2e-*` E2E harness) must never be
    /// treated as the default session root, regardless of `state_dir`.
    #[test]
    fn explicit_non_default_runtime_dir_is_not_the_default_session_root() {
        let default_run = PathBuf::from("/Users/example/.calyx/run");
        let default_state = PathBuf::from("/Users/example/.calyx/state");
        let runtime_dir = Some(PathBuf::from("/tmp/scratch-1/run"));
        let state_dir = Some(default_state.clone());

        assert!(!uses_default_session_root(
            &runtime_dir,
            &state_dir,
            &default_run,
            &default_state
        ));
    }

    /// Both flags absent resolves (via `resolve_runtime_dir`/
    /// `resolve_state_dir`'s own `None` fallback) to the default
    /// session root.
    #[test]
    fn both_flags_absent_resolves_to_the_default_session_root() {
        let default_run = PathBuf::from("/Users/example/.calyx/run");
        let default_state = PathBuf::from("/Users/example/.calyx/state");

        assert!(uses_default_session_root(
            &None,
            &None,
            &default_run,
            &default_state
        ));
    }

    /// The load-bearing case: Calyx's own Swift side always passes
    /// `--runtime-dir`/`--state-dir` EXPLICITLY (never `None`), so the
    /// launchd route must still fire when those explicit paths happen
    /// to equal the real default session root. An `is_none()`-based
    /// check would make this case false and the launchd route
    /// permanently dead in production.
    #[test]
    fn explicit_paths_equal_to_the_default_still_count_as_the_default_session_root() {
        let default_run = PathBuf::from("/Users/example/.calyx/run");
        let default_state = PathBuf::from("/Users/example/.calyx/state");
        let runtime_dir = Some(default_run.clone());
        let state_dir = Some(default_state.clone());

        assert!(uses_default_session_root(
            &runtime_dir,
            &state_dir,
            &default_run,
            &default_state
        ));
    }

    /// `default_session_root_with` must return `None`, not panic, when
    /// `HOME` is absent from the lookup (the "no `HOME`" case a real
    /// `HOME`-less environment would hit via `default_session_root`'s
    /// `std::env::var_os` lookup).
    #[test]
    fn default_session_root_with_no_home_returns_none_without_panicking() {
        assert_eq!(default_session_root_with(|_key| None), None);
    }

    /// `default_session_root_with` resolves to `<home>/.calyx/{run,state}`
    /// when `HOME` is present.
    #[test]
    fn default_session_root_with_home_present_resolves_calyx_subdirs() {
        let resolved = default_session_root_with(|key| {
            (key == "HOME").then(|| std::ffi::OsString::from("/Users/example"))
        });
        assert_eq!(
            resolved,
            Some((
                PathBuf::from("/Users/example/.calyx/run"),
                PathBuf::from("/Users/example/.calyx/state"),
            ))
        );
    }
}
