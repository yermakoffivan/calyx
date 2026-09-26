//! Forwards the daemon's `SessionEvent::PasswordInput` to Calyx.
//!
//! Calyx opens `$CALYX_SECURE_INPUT_SOCKET`, a Unix datagram socket,
//! once per app instance and exports its path to every pane. `attach`
//! sends one JSON datagram per state change:
//! `{"v":1,"session_id":..,"surface_id":..,"password_input":bool}`
//! (`surface_id` omitted when `CALYX_SURFACE_ID` is unset). The inner
//! PTY belongs to the daemon, so ghostty's own termios-based password
//! detection only sees `attach`'s raw-mode tty; this path restores the
//! signal.
//!
//! A datagram socket keeps each message atomic, needs no connection
//! state, and can be sent non-blocking, so a slow or absent Calyx can
//! never stall the output loop. Any same-uid process can send to the
//! socket and spoof a state, which is no more than the native ghostty
//! path already allows (a same-uid process can flip the pane's termios).

use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;

use serde::Serialize;

#[derive(Serialize)]
struct Message<'a> {
    v: u8,
    session_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    surface_id: Option<&'a str>,
    password_input: bool,
}

/// The JSON datagram payload for one state change.
pub(crate) fn message(session_id: &str, surface_id: Option<&str>, active: bool) -> Vec<u8> {
    serde_json::to_vec(&Message {
        v: 1,
        session_id,
        surface_id,
        password_input: active,
    })
    .expect("serializing a struct of strings and bools to JSON cannot fail")
}

/// Sends deduplicated password-input state changes to Calyx.
pub(crate) struct SecureInputNotifier {
    socket: UnixDatagram,
    target: PathBuf,
    session_id: String,
    surface_id: Option<String>,
    last_sent: Option<bool>,
}

impl SecureInputNotifier {
    /// `None` when `CALYX_SECURE_INPUT_SOCKET` is unset/empty (not
    /// running under Calyx) or no socket could be created.
    pub(crate) fn from_env(session_id: &str, env: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let target = env("CALYX_SECURE_INPUT_SOCKET").filter(|v| !v.is_empty())?;
        let socket = UnixDatagram::unbound().ok()?;
        socket.set_nonblocking(true).ok()?;
        let surface_id = env("CALYX_SURFACE_ID").filter(|v| !v.is_empty());
        Some(Self {
            socket,
            target: PathBuf::from(target),
            session_id: session_id.to_string(),
            surface_id,
            last_sent: None,
        })
    }

    /// Sends `active` unless it equals the last state sent. Never
    /// blocks; send errors (Calyx gone, ENOENT, EAGAIN) are ignored by
    /// design: the notification is advisory.
    pub(crate) fn notify(&mut self, active: bool) {
        if self.last_sent == Some(active) {
            return;
        }
        let payload = message(&self.session_id, self.surface_id.as_deref(), active);
        let _ = self.socket.send_to(&payload, &self.target);
        self.last_sent = Some(active);
    }

    /// Clears a still-active state when the daemon connection is lost.
    pub(crate) fn disconnected(&mut self) {
        if self.last_sent == Some(true) {
            self.notify(false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{message, SecureInputNotifier};
    use std::os::unix::net::UnixDatagram;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Duration;

    /// A short `/tmp/cxsi-<8 hex>` dir (Unix socket paths must stay
    /// under 104 bytes), removed on drop.
    struct ShortDir(PathBuf);
    impl ShortDir {
        fn new() -> Self {
            static N: AtomicU32 = AtomicU32::new(0);
            let seed = std::process::id()
                .wrapping_mul(2_654_435_761)
                .wrapping_add(N.fetch_add(1, Ordering::Relaxed).wrapping_mul(40_503));
            let dir = PathBuf::from(format!("/tmp/cxsi-{seed:08x}"));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).expect("create short socket dir");
            ShortDir(dir)
        }
    }
    impl Drop for ShortDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn receiver() -> (ShortDir, UnixDatagram, String) {
        let dir = ShortDir::new();
        let path = dir.0.join("r.sock");
        let sock = UnixDatagram::bind(&path).expect("bind receiver");
        sock.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        (dir, sock, path.to_str().unwrap().to_string())
    }

    fn recv_json(sock: &UnixDatagram) -> serde_json::Value {
        let mut buf = [0u8; 4096];
        let n = sock.recv(&mut buf).expect("expected a datagram");
        serde_json::from_slice(&buf[..n]).expect("datagram is JSON")
    }

    fn assert_nothing(sock: &UnixDatagram) {
        let mut buf = [0u8; 4096];
        match sock.recv(&mut buf) {
            Ok(n) => panic!(
                "expected no datagram, got {:?}",
                String::from_utf8_lossy(&buf[..n])
            ),
            Err(e) => assert!(
                matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ),
                "expected a timeout, got {e}"
            ),
        }
    }

    fn notifier_for(path: &str) -> SecureInputNotifier {
        let path = path.to_string();
        SecureInputNotifier::from_env("01S", move |k| match k {
            "CALYX_SECURE_INPUT_SOCKET" => Some(path.clone()),
            "CALYX_SURFACE_ID" => Some("SURF".to_string()),
            _ => None,
        })
        .expect("notifier should be built when the socket env is set")
    }

    #[test]
    fn message_bytes_with_surface_id_active() {
        assert_eq!(
            message("01S", Some("ABCD-1"), true),
            br#"{"v":1,"session_id":"01S","surface_id":"ABCD-1","password_input":true}"#.to_vec()
        );
    }

    #[test]
    fn message_bytes_without_surface_id_inactive() {
        assert_eq!(
            message("01S", None, false),
            br#"{"v":1,"session_id":"01S","password_input":false}"#.to_vec()
        );
    }

    #[test]
    fn from_env_is_none_without_socket_env() {
        assert!(SecureInputNotifier::from_env("01S", |_| None).is_none());
        assert!(SecureInputNotifier::from_env("01S", |k| match k {
            "CALYX_SECURE_INPUT_SOCKET" => Some(String::new()),
            "CALYX_SURFACE_ID" => Some("SURF".to_string()),
            _ => None,
        })
        .is_none());
    }

    #[test]
    fn notify_dedupes_consecutive_equal_states() {
        let (_dir, sock, path) = receiver();
        let mut n = notifier_for(&path);
        n.notify(true);
        n.notify(true);
        n.notify(false);

        let first = recv_json(&sock);
        assert_eq!(first["password_input"], serde_json::Value::Bool(true));
        assert_eq!(first["surface_id"], "SURF");
        assert_eq!(first["session_id"], "01S");
        let second = recv_json(&sock);
        assert_eq!(second["password_input"], serde_json::Value::Bool(false));
        assert_eq!(second["surface_id"], "SURF");
        assert_nothing(&sock);
    }

    #[test]
    fn disconnected_sends_false_only_when_last_was_true() {
        let (_dir, sock, path) = receiver();
        let mut n = notifier_for(&path);
        n.notify(true);
        n.disconnected();
        assert_eq!(
            recv_json(&sock)["password_input"],
            serde_json::Value::Bool(true)
        );
        assert_eq!(
            recv_json(&sock)["password_input"],
            serde_json::Value::Bool(false)
        );
        assert_nothing(&sock);

        let mut fresh = notifier_for(&path);
        fresh.disconnected();
        assert_nothing(&sock);
    }
}
