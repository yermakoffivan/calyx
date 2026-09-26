//! `attach` forwards the daemon's `PasswordInput` events as JSON
//! datagrams to `$CALYX_SECURE_INPUT_SOCKET`.

use std::os::unix::net::UnixDatagram;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

mod common;
use common::{bin, spawn_foreground_daemon};

struct ShortDir(PathBuf);
impl Drop for ShortDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn short_dir() -> ShortDir {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .subsec_nanos();
    let seed = std::process::id().wrapping_mul(2_654_435_761) ^ nanos;
    let dir = PathBuf::from(format!("/tmp/cxsi-{seed:08x}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create short dir");
    ShortDir(dir)
}

fn recv_json(sock: &UnixDatagram) -> serde_json::Value {
    let mut buf = [0u8; 4096];
    let n = sock
        .recv(&mut buf)
        .expect("expected a secure-input datagram from attach");
    serde_json::from_slice(&buf[..n]).expect("datagram is JSON")
}

#[test]
fn attach_forwards_password_input_events_to_the_secure_input_socket() {
    let dir = short_dir();
    let runtime_dir = dir.0.join("run");
    let state_dir = dir.0.join("st");
    let sock_path = dir.0.join("r.sock");
    let receiver = UnixDatagram::bind(&sock_path).expect("bind receiver");
    receiver
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();

    let _guard = spawn_foreground_daemon(
        &runtime_dir,
        &state_dir,
        |cmd| {
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        },
        String::new,
    );

    let id = "01J-secure-input-cli-notify";
    let surface = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
    let attach = Command::new(bin())
        .args(["--runtime-dir", runtime_dir.to_str().unwrap()])
        .args(["--state-dir", state_dir.to_str().unwrap()])
        .args([
            "attach",
            id,
            "--create",
            "--argv",
            "/bin/sh",
            "--argv",
            "-c",
            "--argv",
            "stty -echo; sleep 0.5; stty echo; sleep 0.5",
        ])
        .env("CALYX_SECURE_INPUT_SOCKET", &sock_path)
        .env("CALYX_SURFACE_ID", surface)
        .env_remove("GHOSTTY_RESOURCES_DIR")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn `calyx-session attach`");

    let first = recv_json(&receiver);
    let second = recv_json(&receiver);
    let output = attach.wait_with_output().expect("wait for attach");

    for (msg, active) in [(&first, true), (&second, false)] {
        assert_eq!(msg["v"], 1, "{msg}");
        assert_eq!(msg["session_id"], id, "{msg}");
        assert_eq!(msg["surface_id"], surface, "{msg}");
        assert_eq!(
            msg["password_input"],
            serde_json::Value::Bool(active),
            "{msg}"
        );
    }
    assert_eq!(
        output.status.code(),
        Some(0),
        "attach should exit 0; stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
