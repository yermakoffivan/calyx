//! `calyx-session attach`: bridges this process's tty to a session.
//!
//! Exit code contract: `0` on a clean session exit (the daemon's
//! `Event(Exited)`), `2` on disconnect/daemon loss.

use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use nix::sys::termios::{self, SetArg, Termios};
use proto::{
    decode_control, encode_control, ControlMsg, FrameReader, FrameType, FrameWriter, SessionSpec,
};

use crate::cli::AttachArgs;
use crate::commands::client::{server_err, unexpected, DaemonClient};
use crate::commands::secure_input_notify::SecureInputNotifier;
use crate::commands::shell_integration::resolve_shell_integration_env;
use crate::commands::terminal_env::resolve_terminal_env;
use crate::commands::{resolve_runtime_dir, resolve_state_dir, socket_path, CommandError};

/// Exit code for "the connection or the daemon went away".
const EXIT_DISCONNECTED: u8 = 2;
/// Bound on auto-start + reconnect attempts.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Bound on waiting for a kickstarted launchd-owned daemon to become
/// healthy (macOS default-session-root route only; see
/// `connect_via_launchd`). Longer than `CONNECT_TIMEOUT`: adopting an
/// existing daemon with many live sessions runs `daemon::handoff`'s
/// receiver, which itself budgets up to `HANDOFF_ACK_TIMEOUT` (10s) to
/// receive the manifest/fds plus a further receive/adopt budget; 20s
/// covers both with margin.
#[cfg(target_os = "macos")]
const HEALTH_TIMEOUT: Duration = Duration::from_secs(20);

pub fn run(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
    args: AttachArgs,
) -> Result<u8, CommandError> {
    let socket = socket_path(runtime_dir);
    let client = match connect_or_spawn(&socket, runtime_dir, state_dir) {
        Ok(client) => client,
        Err(_) => return Ok(EXIT_DISCONNECTED),
    };

    let tty_size = tty_size().unwrap_or((80, 24));
    let (cols, rows) = resolved_initial_size(tty_size, args.initial_cols, args.initial_rows);
    let create = args.create.then(|| {
        let mut env = resolve_terminal_env(|k| std::env::var(k).ok());
        env.extend(resolve_shell_integration_env(|k| std::env::var(k).ok()));
        SessionSpec {
            id: args.id.clone(),
            name: args.name.clone(),
            cwd: args.cwd.clone(),
            argv: (!args.argv.is_empty()).then(|| args.argv.clone()),
            env,
            cols,
            rows,
        }
    });

    match client.request(&ControlMsg::Attach {
        id: args.id.clone(),
        create,
        cols,
        rows,
    })? {
        ControlMsg::AttachOk { .. } => {}
        ControlMsg::Err { code, msg } => return Err(server_err(code, msg)),
        other => return Err(unexpected(&other)),
    }

    let notifier = SecureInputNotifier::from_env(&args.id, |k| std::env::var(k).ok());
    bridge(client.stream, notifier)
}

/// Runs the attached bridge until the session exits (0) or the
/// connection is lost (2). The tty raw-mode guard restores the
/// original termios on every path out, including panics (Drop).
fn bridge(
    stream: UnixStream,
    mut notifier: Option<SecureInputNotifier>,
) -> Result<u8, CommandError> {
    // From here on the stream carries bulk traffic with no
    // request/reply rhythm; reads block until the session ends.
    stream.set_read_timeout(None)?;
    stream.set_write_timeout(None)?;

    let _raw_guard = RawModeGuard::engage();
    let writer = Arc::new(Mutex::new(FrameWriter::new(stream.try_clone()?)));

    // stdin -> Input frames. On stdin EOF the thread just stops: the
    // session keeps running and output keeps flowing.
    {
        let writer = Arc::clone(&writer);
        thread::spawn(move || {
            let mut stdin = std::io::stdin();
            let mut buf = [0u8; 4096];
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let mut w = writer.lock().unwrap_or_else(|p| p.into_inner());
                        if w.write_frame(FrameType::Input, &buf[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }

    // SIGWINCH -> Resize frames; SIGTERM/SIGHUP -> restore the tty and
    // exit 2. Both arrive via the async-signal-safe self-pipe so the
    // handlers themselves stay minimal.
    if let Ok(signal_rx) = install_signal_pipe() {
        let writer = Arc::clone(&writer);
        thread::spawn(move || {
            let mut byte = [0u8; 1];
            loop {
                match nix::unistd::read(&signal_rx, &mut byte) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if byte[0] == b'q' => {
                        // Drop cannot run on a signal-triggered exit;
                        // restore the termios explicitly first.
                        if let Some(saved) = SAVED_TERMIOS
                            .lock()
                            .unwrap_or_else(|p| p.into_inner())
                            .take()
                        {
                            let _ = termios::tcsetattr(std::io::stdin(), SetArg::TCSANOW, &saved);
                        }
                        std::process::exit(i32::from(EXIT_DISCONNECTED));
                    }
                    Ok(_) => {
                        if let Some((cols, rows)) = tty_size() {
                            let Ok(payload) = encode_control(&ControlMsg::Resize { cols, rows })
                            else {
                                break;
                            };
                            let mut w = writer.lock().unwrap_or_else(|p| p.into_inner());
                            if w.write_frame(FrameType::Control, &payload).is_err() {
                                break;
                            }
                        }
                    }
                }
            }
        });
    }

    // Main loop: session output (Replay and Output frames) -> stdout;
    // Event(Exited) is the clean-exit signal; Event(PasswordInput) is
    // forwarded to Calyx's secure-input socket when one is configured.
    let mut reader = FrameReader::new(stream);
    let mut stdout = std::io::stdout();
    let code = loop {
        let frame = match reader.read_frame() {
            Ok(frame) => frame,
            // EOF/reset: daemon or connection is gone.
            Err(_) => break EXIT_DISCONNECTED,
        };
        match frame.frame_type {
            FrameType::Replay | FrameType::Output => {
                if stdout.write_all(&frame.payload).is_err() || stdout.flush().is_err() {
                    break EXIT_DISCONNECTED;
                }
            }
            FrameType::Control => match decode_control(&frame.payload) {
                Ok(ControlMsg::Event(proto::SessionEvent::Exited { .. })) => break 0,
                Ok(ControlMsg::Event(proto::SessionEvent::PasswordInput { active, .. })) => {
                    if let Some(n) = notifier.as_mut() {
                        n.notify(active);
                    }
                }
                _ => {}
            },
            FrameType::Input => {}
        }
    };
    // A lost connection may leave Calyx believing a password prompt is
    // still up; clear it. On a clean exit the daemon already pushed
    // `active: false` before `Exited`. The signal path
    // (`process::exit` in the signal thread) bypasses this: the pane
    // is going away and Calyx clears its per-surface state on surface
    // teardown.
    if code == EXIT_DISCONNECTED {
        if let Some(n) = notifier.as_mut() {
            n.disconnected();
        }
    }
    Ok(code)
}

/// Connects to the daemon, auto-starting it if the socket is dead:
/// take the spawn lock (so concurrent attaches spawn one daemon, not
/// N), start `calyx-session daemon`, and retry with backoff.
///
/// On macOS, when `runtime_dir`/`state_dir` resolve to the real
/// default session root, this instead goes through the launchd-owned
/// daemon route (`connect_via_launchd`): a double-forked daemon
/// inherits the spawning Calyx.app's jetsam coalition and loses
/// `getpwuid` access once that app quits (see `proto::control`'s
/// `GetHealth` doc comment), which a launchd-owned daemon (its own
/// coalition, never double-forked) does not. Every other path (an
/// explicit non-default `--runtime-dir`, e.g. every daemon/cli test
/// fixture and the E2E harness's `/tmp/cxe2e-*` root, or a non-macOS
/// remote host with no launchd) keeps the direct-spawn behavior below
/// unmodified.
fn connect_or_spawn(
    socket: &Path,
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
) -> Result<DaemonClient, CommandError> {
    #[cfg(target_os = "macos")]
    {
        // `default_session_root` resolves without panicking when `HOME`
        // is unset (unlike `resolve_runtime_dir`/`resolve_state_dir`'s
        // `None` fallback, which `.expect()`s it): an explicit
        // `--runtime-dir`/`--state-dir` pair must keep working in a
        // `HOME`-less environment (`env -i`, some CI/launchd contexts)
        // exactly as it did before this route existed, so "can't tell
        // whether this is the default root" degrades to "assume it
        // isn't" rather than crashing.
        if let Some((default_run, default_state)) = crate::commands::default_session_root() {
            if crate::commands::uses_default_session_root(
                runtime_dir,
                state_dir,
                &default_run,
                &default_state,
            ) {
                return connect_via_launchd(socket, &default_run, &default_state);
            }
        }
    }

    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let mut spawned = false;
    loop {
        match DaemonClient::connect(socket) {
            Ok(client) => return Ok(client),
            Err(e) => {
                if Instant::now() >= deadline {
                    return Err(e);
                }
            }
        }
        if !spawned {
            spawned = true;
            spawn_daemon(runtime_dir, state_dir)?;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

/// The launchd-owned daemon route (macOS, default session root only):
///
/// 1. Creates `runtime_dir`/`state_dir` (mode `0700`, same as
///    `Daemon::bind` would) up front: the plist's `StandardOutPath`/
///    `StandardErrorPath` live under `state_dir`, and launchd opens
///    them the moment the job is loaded/kickstarted below, before
///    `Daemon::bind` ever runs inside that job to create them itself.
/// 2. Installs the LaunchAgent's files (idempotent; never calls
///    `launchctl`). A failure here is reported, never silently
///    swallowed into a direct spawn: that would just recreate the
///    broken (double-forked, coalition-bound) daemon this route exists
///    to avoid. This step, loading the job (3), and the first
///    `kickstart` (4) all hold one `InstallLock`, so two concurrent
///    attaches (e.g. several panes restoring at once) can never
///    interleave one attach's `reload` (`bootout`..`bootstrap`) window
///    with another's `kickstart`.
/// 3. Loads the job if it isn't loaded yet (`ensure_loaded`, never
///    `bootout`s).
/// 4. Connects. If nobody answers: only reload the job (`bootout` +
///    `bootstrap`, which can kill a running daemon) when the plist
///    just changed -- a socket that's merely not up yet, with an
///    unchanged plist, needs nothing more than a `kickstart` -- then
///    `kickstart`s and retries until `CONNECT_TIMEOUT`. If the plist
///    did NOT just change, reloading here would be pointless (the
///    on-disk job definition already matches whatever's running or
///    about to run).
/// 5. Once connected, probes health over a throwaway connection (a
///    healthy daemon's own `getpwuid` on its own euid succeeds).
///    Crucially, if the plist changed but the socket answered anyway
///    (a daemon was already serving), this never reloads: `bootout`
///    would kill every live session the very mechanism
///    (`--adopt-existing`) this PR adds exists to preserve.
/// 6. If unhealthy, `kickstart`s again (triggering `--adopt-existing`
///    adoption of whatever daemon was already running) and polls until
///    healthy or `HEALTH_TIMEOUT`. A `Busy` probe (the daemon merely
///    hasn't answered `GetHealth` within its own read timeout yet) is
///    never treated as unhealthy: see `HealthProbe`.
/// 7. On timeout, tries one last connect. A daemon that answers is
///    attached to with a warning: `daemon::handoff` has known failure
///    modes (fd limits, a paused session thread that never resumes)
///    under heavy session counts, and turning those into a hard attach
///    failure would upgrade a display-only prompt bug into "can't open
///    a pane at all". If nobody answers even now (the adopting daemon
///    itself died and the old one has since exited), `kickstart`s once
///    more and retries the connect up to `CONNECT_TIMEOUT` before
///    giving up, rather than warning about a daemon that isn't there
///    and failing anyway.
#[cfg(target_os = "macos")]
fn connect_via_launchd(
    socket: &Path,
    runtime_dir: &Path,
    state_dir: &Path,
) -> Result<DaemonClient, CommandError> {
    ::daemon::create_private_dir(runtime_dir)?;
    ::daemon::create_private_dir(state_dir)?;

    let installer = crate::launch_agent::LaunchAgentInstaller::system()?;
    let current_exe = std::env::current_exe()?;

    let lock = installer.lock()?;
    let outcome = match installer.install_files(&lock, &current_exe, runtime_dir, state_dir) {
        Ok(outcome) => outcome,
        Err(e) => {
            eprintln!("calyx-session: failed to install the launchd session daemon: {e}");
            return Err(CommandError::Io(e));
        }
    };
    if let Err(e) = installer.ensure_loaded(&lock) {
        eprintln!("calyx-session: failed to load the launchd session daemon: {e}");
        return Err(CommandError::Io(e));
    }

    let reachable = UnixStream::connect(socket).is_ok();
    if !reachable {
        if should_reload_before_kickstart(outcome, reachable) {
            if let Err(e) = installer.reload(&lock) {
                eprintln!("calyx-session: failed to reload the launchd session daemon: {e}");
                return Err(CommandError::Io(e));
            }
        }

        let deadline = Instant::now() + CONNECT_TIMEOUT;
        let mut kickstarted = false;
        while UnixStream::connect(socket).is_err() {
            if Instant::now() >= deadline {
                return Err(CommandError::Io(std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    format!("the launchd session daemon did not start within {CONNECT_TIMEOUT:?}"),
                )));
            }
            if !kickstarted {
                kickstarted = true;
                if let Err(e) = installer.kickstart(&lock) {
                    eprintln!("calyx-session: failed to start the launchd session daemon: {e}");
                    return Err(CommandError::Io(e));
                }
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
    drop(lock);

    match probe_health(socket) {
        HealthProbe::Healthy | HealthProbe::Busy => DaemonClient::connect(socket),
        HealthProbe::Unhealthy => {
            {
                let lock = installer.lock()?;
                if let Err(e) = installer.kickstart(&lock) {
                    eprintln!("calyx-session: failed to restart the launchd session daemon: {e}");
                    return Err(CommandError::Io(e));
                }
            }
            let health_deadline = Instant::now() + HEALTH_TIMEOUT;
            while Instant::now() < health_deadline {
                if matches!(probe_health(socket), HealthProbe::Healthy) {
                    return DaemonClient::connect(socket);
                }
                thread::sleep(Duration::from_millis(200));
            }

            match DaemonClient::connect(socket) {
                Ok(client) => {
                    warn_user_lookup_may_be_broken();
                    Ok(client)
                }
                Err(_) => {
                    // The health poll can time out because the
                    // adopting daemon itself died mid-handoff and the
                    // old daemon has since exited too (its own idle
                    // timeout, or it simply crashed), so the socket may
                    // be gone entirely by now. Re-kickstart once for
                    // one more chance at bringing a daemon back, rather
                    // than warning about a daemon that isn't even there
                    // and failing the attach anyway.
                    {
                        let lock = installer.lock()?;
                        if let Err(e) = installer.kickstart(&lock) {
                            eprintln!(
                                "calyx-session: failed to restart the launchd session daemon: {e}"
                            );
                            return Err(CommandError::Io(e));
                        }
                    }
                    let retry_deadline = Instant::now() + CONNECT_TIMEOUT;
                    loop {
                        match DaemonClient::connect(socket) {
                            Ok(client) => {
                                warn_user_lookup_may_be_broken();
                                return Ok(client);
                            }
                            Err(e) => {
                                if Instant::now() >= retry_deadline {
                                    return Err(e);
                                }
                            }
                        }
                        thread::sleep(Duration::from_millis(100));
                    }
                }
            }
        }
    }
}

/// Printed only once an unhealthy daemon has actually been reached
/// again, never merely attempted: a warning about a daemon that is not
/// even there is worse than no warning at all.
#[cfg(target_os = "macos")]
fn warn_user_lookup_may_be_broken() {
    eprintln!(
        "warning: this calyx-session daemon cannot look up your user account; new shells \
         will not be login shells (your login profile, such as /etc/zprofile and \
         ~/.zprofile, will not run, so PATH may lack what it adds) and will lose your \
         user name in the prompt. Restarting the daemon fixes it."
    );
}

/// Whether `connect_via_launchd` should call `reload()` (`bootout` +
/// `bootstrap`, which can kill a running daemon) before retrying a
/// `kickstart`: only when the plist just changed on this install AND
/// the socket is currently unreachable. A changed plist while the
/// socket is reachable (a daemon is serving) must never reload here --
/// that would `bootout` every live session `--adopt-existing` exists to
/// preserve; the plist takes effect the next time the job restarts on
/// its own instead.
#[cfg(target_os = "macos")]
fn should_reload_before_kickstart(
    outcome: crate::launch_agent::InstallOutcome,
    socket_reachable: bool,
) -> bool {
    !socket_reachable && outcome == crate::launch_agent::InstallOutcome::PlistUpdated
}

/// The result of a `GetHealth` probe over a throwaway connection.
///
/// `Busy` (a read/write timeout on the probe connection, from
/// `DaemonClient`'s own `IO_TIMEOUT`) is deliberately distinct from
/// `Unhealthy`: it means the daemon is alive but simply hasn't answered
/// yet (e.g. it's mid-handoff adopting another daemon for a different
/// attach), not that it's broken. Treating a timeout as `Unhealthy`
/// would misclassify a merely-busy daemon as needing re-adoption,
/// burning `HEALTH_TIMEOUT` polling and printing a bogus warning for a
/// daemon that only needed a moment. `Busy` skips both the poll and the
/// warning and attaches immediately.
///
/// A residual case this doesn't detect: a launchd-owned daemon that is
/// definitely, persistently unhealthy while also genuinely running
/// (rather than merely busy) would still classify as `Unhealthy` and
/// get `kickstart`ed, which is correct; there is no known way for that
/// state to be confused with `Busy` (a busy daemon is, by definition,
/// still processing something, not stuck).
#[cfg(target_os = "macos")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HealthProbe {
    Healthy,
    Unhealthy,
    Busy,
}

/// `GetHealth` over a throwaway connection: `Health { user_lookup_ok:
/// true }` is the only healthy reply. `Health { user_lookup_ok: false
/// }`, a decode error, or a closed connection (an older daemon
/// predating `GetHealth` closes on an unknown variant) all count as
/// `Unhealthy`. A read/write timeout counts as `Busy`, not `Unhealthy`;
/// see `HealthProbe`. The health probe is never reused as the real
/// attach connection.
#[cfg(target_os = "macos")]
fn probe_health(socket: &Path) -> HealthProbe {
    let client = match DaemonClient::connect(socket) {
        Ok(client) => client,
        Err(e) => return classify_probe_error(&e),
    };
    match client.request(&ControlMsg::GetHealth) {
        Ok(ControlMsg::Health {
            user_lookup_ok: true,
        }) => HealthProbe::Healthy,
        Ok(_) => HealthProbe::Unhealthy,
        Err(e) => classify_probe_error(&e),
    }
}

/// Classifies a probe-connection/request failure into `Busy` (a read or
/// write timeout, from `DaemonClient`'s own `IO_TIMEOUT`) or
/// `Unhealthy` (everything else: EOF, connection reset, connection
/// refused, a decode error).
#[cfg(target_os = "macos")]
fn classify_probe_error(err: &CommandError) -> HealthProbe {
    let kind = match err {
        CommandError::Io(e) => Some(e.kind()),
        CommandError::Protocol(proto::ProtoError::Io(e)) => Some(e.kind()),
        _ => None,
    };
    match kind {
        Some(std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => HealthProbe::Busy,
        _ => HealthProbe::Unhealthy,
    }
}

fn spawn_daemon(
    runtime_dir: &Option<PathBuf>,
    state_dir: &Option<PathBuf>,
) -> Result<(), CommandError> {
    let runtime = resolve_runtime_dir(runtime_dir);
    let state = resolve_state_dir(state_dir);
    std::fs::create_dir_all(&runtime)?;

    // The daemon itself holds an exclusive flock on this file for its
    // whole life; failing to take it here means a daemon is already
    // running (or being started by someone else), so just retry the
    // connect loop. The probe lock is released *before* spawning:
    // holding it across the spawn would make the daemonized grandchild
    // lose its own lock attempt and exit as a duplicate.
    let lock_file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(runtime.join(::daemon::LOCK_FILE))?;
    match nix::fcntl::Flock::lock(lock_file, nix::fcntl::FlockArg::LockExclusiveNonblock) {
        Ok(lock) => drop(lock),
        Err(_) => return Ok(()),
    }

    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .arg("--runtime-dir")
        .arg(&runtime)
        .arg("--state-dir")
        .arg(&state)
        .arg("daemon")
        .spawn()?;
    // The `daemon` subcommand double-forks; the direct child exits
    // immediately and must be reaped.
    let _ = child.wait();
    Ok(())
}

/// Restores the terminal's original termios on drop. Engages raw mode
/// only when stdin actually is a tty (under a test harness it isn't,
/// and there is nothing to restore or make raw).
struct RawModeGuard {
    saved: Option<Termios>,
}

impl RawModeGuard {
    fn engage() -> RawModeGuard {
        let stdin = std::io::stdin();
        let Ok(saved) = termios::tcgetattr(&stdin) else {
            return RawModeGuard { saved: None };
        };
        let mut raw = saved.clone();
        termios::cfmakeraw(&mut raw);
        if termios::tcsetattr(&stdin, SetArg::TCSANOW, &raw).is_err() {
            return RawModeGuard { saved: None };
        }
        // Mirror for the signal path (SIGTERM/SIGHUP), which can't
        // reach this guard on the bridge's stack.
        *SAVED_TERMIOS.lock().unwrap_or_else(|p| p.into_inner()) = Some(saved.clone());
        RawModeGuard { saved: Some(saved) }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if let Some(saved) = &self.saved {
            let _ = termios::tcsetattr(std::io::stdin(), SetArg::TCSANOW, saved);
        }
        *SAVED_TERMIOS.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }
}

/// This process's tty size, if stdout (or stdin) is a tty.
pub(crate) fn tty_size() -> Option<(u16, u16)> {
    for fd in [libc::STDOUT_FILENO, libc::STDIN_FILENO] {
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: TIOCGWINSZ only writes the winsize out-param.
        // Inferred cast: request is c_ulong on macOS/glibc, c_int on musl.
        let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ as _, &mut ws) };
        if rc == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            return Some((ws.ws_col, ws.ws_row));
        }
    }
    None
}

fn resolved_initial_size(
    tty_size: (u16, u16),
    initial_cols: Option<u16>,
    initial_rows: Option<u16>,
) -> (u16, u16) {
    match (initial_cols, initial_rows) {
        (Some(cols), Some(rows)) => (cols.max(1), rows.max(1)),
        _ => tty_size,
    }
}

/// Write end of the signal self-pipe, read by the signal handlers.
static SIGNAL_PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);

/// The termios to restore on abnormal termination, mirrored here from
/// `RawModeGuard` so the signal path can restore it without access to
/// the guard on the bridge's stack.
static SAVED_TERMIOS: Mutex<Option<Termios>> = Mutex::new(None);

extern "C" fn on_winch(_signal: libc::c_int) {
    signal_pipe_notify(b'w');
}

extern "C" fn on_terminate(_signal: libc::c_int) {
    signal_pipe_notify(b'q');
}

fn signal_pipe_notify(byte: u8) {
    let fd = SIGNAL_PIPE_WRITE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; the fd stays open for
        // the process lifetime once installed.
        unsafe { libc::write(fd, [byte].as_ptr() as *const libc::c_void, 1) };
    }
}

/// Installs the SIGWINCH/SIGTERM/SIGHUP handlers and returns the read
/// end of their shared self-pipe.
fn install_signal_pipe() -> nix::Result<std::os::fd::OwnedFd> {
    let (rx, tx) = nix::unistd::pipe()?;
    nix::fcntl::fcntl(
        &tx,
        nix::fcntl::FcntlArg::F_SETFL(nix::fcntl::OFlag::O_NONBLOCK),
    )?;
    SIGNAL_PIPE_WRITE.store(tx.as_raw_fd(), Ordering::Relaxed);
    // The write end must outlive the handlers; it is intentionally
    // leaked (one per process).
    std::mem::forget(tx);
    // SAFETY: installing handlers that only call async-signal-safe
    // write(2) on a pre-opened fd.
    unsafe {
        libc::signal(
            libc::SIGWINCH,
            on_winch as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            on_terminate as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGHUP,
            on_terminate as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
    }
    Ok(rx)
}

#[cfg(test)]
mod tests {
    use super::resolved_initial_size;

    #[test]
    fn explicit_initial_grid_overrides_bootstrap_tty_size() {
        assert_eq!(
            resolved_initial_size((99, 35), Some(72), Some(31)),
            (72, 31)
        );
    }

    #[test]
    fn absent_initial_grid_uses_current_tty_size() {
        assert_eq!(resolved_initial_size((99, 35), None, None), (99, 35));
    }

    #[cfg(target_os = "macos")]
    mod reload_gating {
        use super::super::should_reload_before_kickstart;
        use crate::launch_agent::InstallOutcome;

        /// A daemon that's already serving (socket reachable) must
        /// never be reloaded, even if the plist just changed: `reload`
        /// would `bootout` every live session.
        #[test]
        fn never_reloads_a_reachable_socket() {
            assert!(!should_reload_before_kickstart(
                InstallOutcome::PlistUpdated,
                true
            ));
            assert!(!should_reload_before_kickstart(
                InstallOutcome::Unchanged,
                true
            ));
        }

        /// An unreachable socket only reloads when the plist actually
        /// changed; an unchanged plist needs nothing beyond a plain
        /// `kickstart`.
        #[test]
        fn unreachable_socket_reloads_only_when_the_plist_changed() {
            assert!(should_reload_before_kickstart(
                InstallOutcome::PlistUpdated,
                false
            ));
            assert!(!should_reload_before_kickstart(
                InstallOutcome::Unchanged,
                false
            ));
        }
    }

    #[cfg(target_os = "macos")]
    mod health_probe_classification {
        use super::super::{classify_probe_error, HealthProbe};
        use crate::commands::CommandError;

        /// A read/write timeout on the probe connection (the daemon is
        /// merely busy, not broken) must classify as `Busy`, never
        /// `Unhealthy`.
        #[test]
        fn read_timeout_classifies_as_busy() {
            let err = CommandError::Io(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "timed out waiting for a reply",
            ));
            assert_eq!(classify_probe_error(&err), HealthProbe::Busy);

            let err = CommandError::Protocol(proto::ProtoError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "timed out waiting for a reply",
            )));
            assert_eq!(classify_probe_error(&err), HealthProbe::Busy);
        }

        /// EOF/connection-reset (an older daemon closing on an unknown
        /// `GetHealth` variant) must classify as `Unhealthy`, not
        /// `Busy`.
        #[test]
        fn eof_and_connection_reset_classify_as_unhealthy() {
            let eof = CommandError::Protocol(proto::ProtoError::Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "connection closed",
            )));
            assert_eq!(classify_probe_error(&eof), HealthProbe::Unhealthy);

            let reset = CommandError::Io(std::io::Error::new(
                std::io::ErrorKind::ConnectionReset,
                "connection reset by peer",
            ));
            assert_eq!(classify_probe_error(&reset), HealthProbe::Unhealthy);
        }

        /// A decode error or any other non-I/O failure must also
        /// classify as `Unhealthy`.
        #[test]
        fn non_io_errors_classify_as_unhealthy() {
            let err = CommandError::Server {
                code: "bad-reply".to_string(),
                msg: "unexpected".to_string(),
            };
            assert_eq!(classify_probe_error(&err), HealthProbe::Unhealthy);
        }
    }
}
