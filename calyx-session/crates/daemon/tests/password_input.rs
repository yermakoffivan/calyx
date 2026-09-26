//! The daemon watches each session's PTY termios and pushes
//! `SessionEvent::PasswordInput { id, active }` (active = ICANON set and
//! ECHO clear) to attached clients on change, replays an active state
//! right after `Replay` for a late attach, and sends `active: false`
//! before `Exited` when the child exits mid-prompt.

mod common;

use std::os::unix::net::UnixStream;

use proto::{ControlMsg, FrameReader, FrameType, SessionEvent, SessionSpec};

fn spec(id: &str, script: &str) -> SessionSpec {
    SessionSpec {
        id: id.to_string(),
        name: None,
        cwd: None,
        argv: Some(vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            script.to_string(),
        ]),
        env: vec![],
        cols: 80,
        rows: 24,
    }
}

/// Reads frames until an `Exited` event (inclusive), collecting every
/// decoded Control frame and skipping Output/Replay. A read error (the
/// connection's read timeout) panics with what was collected so far.
fn collect_controls_until_exited(reader: &mut FrameReader<UnixStream>) -> Vec<ControlMsg> {
    let mut out = Vec::new();
    loop {
        let frame = match reader.read_frame() {
            Ok(f) => f,
            Err(e) => panic!("read frame failed before Exited ({e}); collected so far: {out:?}"),
        };
        if frame.frame_type != FrameType::Control {
            continue;
        }
        let msg = proto::decode_control(&frame.payload).expect("decode control frame");
        let done = matches!(msg, ControlMsg::Event(SessionEvent::Exited { .. }));
        out.push(msg);
        if done {
            return out;
        }
    }
}

fn attach_create_and_collect(id: &str, script: &str) -> Vec<ControlMsg> {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: Some(spec(id, script)),
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(
        matches!(reply, ControlMsg::AttachOk { .. }),
        "expected AttachOk, got {reply:?}"
    );
    let mut reader = FrameReader::new(stream.try_clone().expect("clone for reader"));
    collect_controls_until_exited(&mut reader)
}

fn password_input(id: &str, active: bool) -> ControlMsg {
    ControlMsg::Event(SessionEvent::PasswordInput {
        id: id.to_string(),
        active,
    })
}

fn assert_active_inactive_exited(id: &str, controls: &[ControlMsg]) {
    assert_eq!(
        controls.len(),
        3,
        "expected exactly 3 control events, got {controls:?}"
    );
    assert_eq!(controls[0], password_input(id, true), "got {controls:?}");
    assert_eq!(controls[1], password_input(id, false), "got {controls:?}");
    assert!(
        matches!(&controls[2], ControlMsg::Event(SessionEvent::Exited { id: eid, .. }) if eid == id),
        "expected Exited for {id}, got {controls:?}"
    );
}

#[test]
fn attached_client_receives_active_then_inactive_then_exited() {
    let id = "01J-secure-input-toggle";
    let controls = attach_create_and_collect(id, "stty -echo; sleep 0.5; stty echo; sleep 0.5");
    assert_active_inactive_exited(id, &controls);
}

#[test]
fn child_exiting_while_active_sends_inactive_before_exited() {
    let id = "01J-secure-input-exit-active";
    let controls = attach_create_and_collect(id, "stty -echo; sleep 0.5");
    assert_active_inactive_exited(id, &controls);
}

#[test]
fn attach_to_detached_session_already_in_password_input_receives_active_right_after_replay() {
    let daemon = common::ScratchDaemon::spawn();
    let stream = daemon.connect().expect("connect to daemon socket");
    common::hello(&stream);

    let id = "01J-secure-input-late-attach";
    let reply = common::roundtrip(
        &stream,
        &ControlMsg::New {
            spec: spec(id, "stty -echo; sleep 30"),
        },
    )
    .expect("New round-trip");
    assert!(
        matches!(reply, ControlMsg::NewOk { .. }),
        "expected NewOk, got {reply:?}"
    );

    std::thread::sleep(std::time::Duration::from_millis(300));

    let attach_stream = daemon.connect().expect("connect second stream");
    common::hello(&attach_stream);
    let reply = common::roundtrip(
        &attach_stream,
        &ControlMsg::Attach {
            id: id.to_string(),
            create: None,
            cols: 80,
            rows: 24,
        },
    )
    .expect("Attach round-trip");
    assert!(
        matches!(reply, ControlMsg::AttachOk { .. }),
        "expected AttachOk, got {reply:?}"
    );

    let mut reader = FrameReader::new(attach_stream.try_clone().expect("clone for reader"));
    let first = reader.read_frame().expect("read frame after AttachOk");
    assert_eq!(
        first.frame_type,
        FrameType::Replay,
        "first frame after AttachOk must be Replay"
    );
    let second = reader.read_frame().expect("read frame after Replay");
    assert_eq!(
        second.frame_type,
        FrameType::Control,
        "frame right after Replay must be the PasswordInput Control event, got {:?}",
        second.frame_type
    );
    let msg = proto::decode_control(&second.payload).expect("decode control frame");
    assert_eq!(msg, password_input(id, true));

    let reply = common::roundtrip(&stream, &ControlMsg::Kill { id: id.to_string() })
        .expect("Kill round-trip");
    assert_eq!(reply, ControlMsg::KillOk);
    // Drain until the session reports its exit.
    let _ = collect_controls_until_exited(&mut reader);
}
