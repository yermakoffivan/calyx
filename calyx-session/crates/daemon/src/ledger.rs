//! The on-disk session ledger: `state_dir/sessions.json`, mode 0600,
//! written atomically (temp file + rename) on every registry change.
//!
//! The ledger is a persistence record, not a mirror of the live
//! registry: exited sessions stay in it (with their final state) so a
//! later daemon generation can still see them, which is also why `load`
//! seeds the map from any file a previous daemon left behind.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use proto::{SessionInfo, SessionState};

const LEDGER_FILE: &str = "sessions.json";

/// How long an `Exited` ledger record is kept before `gc` drops it.
/// `Exited` records exist so a client that never watched the session
/// end (`ControlMsg::ListAll`, read after a daemon death by Calyx's own
/// agent-resume flow) can still learn its exit code; keeping every one
/// forever instead grows `sessions.json` without bound (a real ledger
/// observed carrying 7 stale `Exited(137)` records, each surfacing as a
/// permanent, zero-affordance row in the session browser). One week
/// comfortably covers "picked back up after the weekend" without
/// keeping records indefinitely.
pub(crate) const RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1000;

/// Drops `Exited` records whose `exited_at_ms` is more than
/// `RETENTION_MS` older than `now_ms`. A record with no `exited_at_ms`
/// at all (predating this field, since every code path that flips a
/// record to `Exited` now stamps it) is treated as already past
/// retention rather than kept forever, so ledgers accumulated before
/// this GC existed still get cleaned up on the next bind. `Running`
/// records are always kept, regardless of `created_at_ms`.
///
/// `now_ms` is caller-supplied (never reads the wall clock itself) so
/// unit tests can exercise exact retention-boundary scenarios
/// deterministically.
pub(crate) fn gc(
    sessions: BTreeMap<String, SessionInfo>,
    now_ms: u64,
) -> BTreeMap<String, SessionInfo> {
    sessions
        .into_iter()
        .filter(|(_, info)| match info.state {
            SessionState::Running => true,
            SessionState::Exited { .. } => match info.exited_at_ms {
                // `saturating_sub`: an `exited_at_ms` in the future
                // (clock stepped backwards since the exit) reads as age
                // zero and is kept, never wrapped into "ancient".
                Some(exited_at_ms) => now_ms.saturating_sub(exited_at_ms) <= RETENTION_MS,
                None => false,
            },
        })
        .collect()
}

/// The wall clock as Unix-epoch ms: what callers pass `load_and_gc` /
/// `gc` as `now_ms` (kept out of those functions so they stay
/// deterministic under test) and stamp into `exited_at_ms` at every
/// `Exited` transition. Pre-epoch clock reads collapse to 0, the same
/// treatment `created_at_ms` gets at session creation (session.rs).
pub(crate) fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Loads the ledger (`load`) and applies `gc` against `now_ms`,
/// rewriting the file (`write`) if anything was dropped so a ledger
/// accumulated before this GC existed does not keep every stale record
/// across a restart either. Returns the post-GC map: what
/// `Daemon::run_until_idle` / `run_handoff_receiver` seed `State::ledger`
/// from at bind.
pub(crate) fn load_and_gc(state_dir: &Path, now_ms: u64) -> BTreeMap<String, SessionInfo> {
    let loaded = load(state_dir);
    let loaded_len = loaded.len();
    let kept = gc(loaded, now_ms);
    if kept.len() != loaded_len {
        let snapshot: Vec<SessionInfo> = kept.values().cloned().collect();
        if let Err(e) = write(state_dir, &snapshot) {
            eprintln!(
                "calyx-sessiond: failed to rewrite GC'd ledger {}: {e}",
                state_dir.join(LEDGER_FILE).display()
            );
        }
    }
    kept
}

/// Flips every `Running` ledger record whose id is not `owned` (i.e.
/// not present in the caller's live registry) to `Exited { code: -1 }`,
/// stamping `exited_at_ms` to `now_ms`. Returns the count changed.
///
/// A `Running` record this daemon generation does not own can never be
/// attached to or killed again: its backing process, if it still
/// exists at all, belongs to a pid this daemon has no PTY master for
/// and no session thread watching, so nothing here will ever flip it
/// on its own. Left alone, such a record is a permanent lie — "Running"
/// forever, with no affordance to remove it (`ls --all` shows a dead
/// row, `Kill` cannot reach it because it is absent from the registry).
/// This function deliberately does not signal the recorded pid: pid
/// reuse by the OS since the record was written makes that unsafe, and
/// this daemon holds no PTY master for the session regardless, so a
/// signal would accomplish nothing even when safe.
pub(crate) fn reconcile_unowned_running(
    sessions: &mut BTreeMap<String, SessionInfo>,
    owned: impl Fn(&str) -> bool,
    now_ms: u64,
) -> usize {
    let mut changed = 0;
    for (id, info) in sessions.iter_mut() {
        if matches!(info.state, SessionState::Running) && !owned(id) {
            info.state = SessionState::Exited { code: -1 };
            info.exited_at_ms = Some(now_ms);
            changed += 1;
        }
    }
    changed
}

pub(crate) fn load(state_dir: &Path) -> BTreeMap<String, SessionInfo> {
    let path = state_dir.join(LEDGER_FILE);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => return BTreeMap::new(),
    };
    match serde_json::from_slice::<Vec<SessionInfo>>(&bytes) {
        Ok(sessions) => sessions
            .into_iter()
            .map(|info| (info.id.clone(), info))
            .collect(),
        Err(e) => {
            // A corrupt ledger is not worth refusing to start over; the
            // old contents are kept on disk until the first state
            // change overwrites them.
            eprintln!(
                "calyx-sessiond: ignoring unparseable ledger {}: {e}",
                path.display()
            );
            BTreeMap::new()
        }
    }
}

pub(crate) fn write(state_dir: &Path, sessions: &[SessionInfo]) -> io::Result<()> {
    // The state dir can vanish under a live daemon (wiped by a user or,
    // in tests, a scratch dir torn down around a "restart"); persisting
    // the in-memory ledger matters more than preserving the missing
    // directory as a signal, so recreate it.
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(state_dir)?;

    let json = serde_json::to_vec_pretty(&sessions)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    let path = state_dir.join(LEDGER_FILE);
    let tmp = state_dir.join(".sessions.json.tmp");
    {
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&json)?;
        file.sync_all()?;
    }
    // 0600 explicitly in case the temp file predated this write with
    // other permissions (mode() only applies on creation).
    fs::set_permissions(&tmp, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    fs::rename(&tmp, &path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression test (P2 review bug #8): a ledger written by a newer
    /// daemon generation (carrying a field this build doesn't know
    /// about) must still load, preserving every session this build
    /// *does* understand — not silently drop to an empty ledger the
    /// way a swallowed deserialize error currently would.
    #[test]
    fn load_tolerates_an_unknown_extra_field() {
        let dir = tempfile::tempdir().expect("create scratch state dir");
        let json = r#"[{
            "id": "01J-p2-ledger-compat-1",
            "name": null,
            "cwd": null,
            "state": "Running",
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 123,
            "meta": {},
            "future_field_from_a_newer_daemon": "some-value"
        }]"#;
        fs::write(dir.path().join(LEDGER_FILE), json).expect("write scratch ledger");

        let loaded = load(dir.path());
        let info = loaded
            .get("01J-p2-ledger-compat-1")
            .expect("load should preserve a session despite an unknown extra field, not drop it");
        assert_eq!(info.pid, 123);
    }

    /// Regression test (P2 review bug #8, second half): a ledger
    /// predating some currently-optional field (modeled here by
    /// omitting `name`'s key entirely, not just sending it as `null`)
    /// must still load with that field defaulting to `None` — the same
    /// treatment a *future* optional field addition would need for
    /// old ledger data to keep loading.
    #[test]
    fn load_tolerates_an_optional_field_missing_entirely() {
        let dir = tempfile::tempdir().expect("create scratch state dir");
        let json = r#"[{
            "id": "01J-p2-ledger-compat-2",
            "cwd": null,
            "state": "Running",
            "created_at_ms": 1700000000000,
            "attached_clients": 0,
            "pid": 456,
            "meta": {}
        }]"#;
        fs::write(dir.path().join(LEDGER_FILE), json).expect("write scratch ledger");

        let loaded = load(dir.path());
        let info = loaded.get("01J-p2-ledger-compat-2").expect(
            "load should preserve a session even when an Option field's key is \
             missing entirely (defaulting to None), or a future optional field \
             addition would break parsing of ledger data written before it existed",
        );
        assert_eq!(info.name, None);
    }

    // ==================== `gc` (RED: ledger GC on daemon bind) ====================

    fn make_info(id: &str, state: SessionState, exited_at_ms: Option<u64>) -> SessionInfo {
        SessionInfo {
            id: id.to_string(),
            name: None,
            cwd: None,
            state,
            created_at_ms: 1_700_000_000_000,
            attached_clients: 0,
            pid: 0,
            meta: BTreeMap::new(),
            exited_at_ms,
        }
    }

    /// RED: an `Exited` record whose `exited_at_ms` is well past
    /// `RETENTION_MS` before `now_ms` must be dropped -- the defect
    /// this GC exists to fix (a real ledger observed accumulating 7
    /// such stale `Exited(137)` records with no removal path at all).
    #[test]
    fn gc_drops_exited_entries_past_retention() {
        let now_ms: u64 = 1_800_000_000_000;
        let stale_exited_at = now_ms - RETENTION_MS - (24 * 60 * 60 * 1000); // 8 days before now
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-gc-stale".to_string(),
            make_info(
                "01J-gc-stale",
                SessionState::Exited { code: 137 },
                Some(stale_exited_at),
            ),
        );

        let kept = gc(sessions, now_ms);

        assert!(
            !kept.contains_key("01J-gc-stale"),
            "an Exited record more than RETENTION_MS past its exited_at_ms must be dropped, \
             got {kept:?}"
        );
    }

    /// RED: an `Exited` record well within `RETENTION_MS` must survive
    /// GC untouched -- the resume flow (P4) still needs to read its
    /// exit code, so recent exits must not be swept away alongside
    /// genuinely stale ones.
    #[test]
    fn gc_keeps_exited_entries_within_retention() {
        let now_ms: u64 = 1_800_000_000_000;
        let fresh_exited_at = now_ms - (60 * 60 * 1000); // 1 hour before now
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-gc-fresh".to_string(),
            make_info(
                "01J-gc-fresh",
                SessionState::Exited { code: 0 },
                Some(fresh_exited_at),
            ),
        );

        let kept = gc(sessions, now_ms);

        let info = kept
            .get("01J-gc-fresh")
            .expect("an Exited record well within RETENTION_MS must be kept, not dropped");
        assert_eq!(info.state, SessionState::Exited { code: 0 });
    }

    /// RED: a `Running` record must never be dropped by GC, regardless
    /// of how old `created_at_ms` is -- GC only ever prunes `Exited`
    /// history, never a session that is still alive.
    #[test]
    fn gc_keeps_running_entries_regardless_of_age() {
        let now_ms: u64 = 1_800_000_000_000;
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-gc-running".to_string(),
            make_info("01J-gc-running", SessionState::Running, None),
        );

        let kept = gc(sessions, now_ms);

        assert!(
            kept.contains_key("01J-gc-running"),
            "a Running record must be kept by GC regardless of age, got {kept:?}"
        );
    }

    /// RED: an `Exited` record with no `exited_at_ms` at all (a legacy
    /// ledger entry written before this field existed) must be treated
    /// as already past retention -- the 7 real stale rows observed in
    /// production predate this field and must be cleaned up on the very
    /// next daemon bind, not kept forever for lack of a timestamp.
    #[test]
    fn gc_drops_exited_entries_missing_exited_at_ms() {
        let now_ms: u64 = 1_800_000_000_000;
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-gc-legacy".to_string(),
            make_info("01J-gc-legacy", SessionState::Exited { code: 137 }, None),
        );

        let kept = gc(sessions, now_ms);

        assert!(
            !kept.contains_key("01J-gc-legacy"),
            "an Exited record with no exited_at_ms (legacy, predating this field) must be \
             dropped rather than kept forever, got {kept:?}"
        );
    }

    /// RED: `load_and_gc` must rewrite `sessions.json` on disk once GC
    /// actually drops something, so a ledger accumulated before this GC
    /// existed does not keep re-accumulating the same stale records
    /// across every subsequent restart either.
    #[test]
    fn load_and_gc_rewrites_the_ledger_file_when_stale_entries_are_dropped() {
        let dir = tempfile::tempdir().expect("create scratch state dir");
        let now_ms: u64 = 1_800_000_000_000;
        let stale_exited_at = now_ms - RETENTION_MS - (24 * 60 * 60 * 1000);
        let json = format!(
            r#"[{{
                "id": "01J-gc-rewrite-stale",
                "name": null,
                "cwd": null,
                "state": {{"Exited": {{"code": 137}}}},
                "created_at_ms": 1700000000000,
                "attached_clients": 0,
                "pid": 0,
                "meta": {{}},
                "exited_at_ms": {stale_exited_at}
            }}, {{
                "id": "01J-gc-rewrite-running",
                "name": null,
                "cwd": null,
                "state": "Running",
                "created_at_ms": 1700000000000,
                "attached_clients": 0,
                "pid": 123,
                "meta": {{}}
            }}]"#
        );
        fs::write(dir.path().join(LEDGER_FILE), json).expect("write scratch ledger");

        let kept = load_and_gc(dir.path(), now_ms);
        assert!(
            !kept.contains_key("01J-gc-rewrite-stale"),
            "load_and_gc should drop the stale entry from its returned map"
        );

        let rewritten =
            fs::read_to_string(dir.path().join(LEDGER_FILE)).expect("read rewritten ledger file");
        assert!(
            !rewritten.contains("01J-gc-rewrite-stale"),
            "sessions.json must be rewritten without the dropped stale entry, got: {rewritten}"
        );
        assert!(
            rewritten.contains("01J-gc-rewrite-running"),
            "sessions.json must still retain the untouched Running entry, got: {rewritten}"
        );
    }

    // ==================== `reconcile_unowned_running` (RED: ghost-row cleanup) ====================
    //
    // Bug under fix: the daemon's live registry starts empty on a fresh
    // bind, but the on-disk ledger keeps every `Running` record a prior
    // daemon generation left behind when it died without flipping them
    // to `Exited` -- ~34 such records observed in production, each
    // still carrying a now-dead pid, surfacing forever as "Detached ·
    // Running · 0 client(s)" rows the session browser's Kill can't
    // touch (Kill only reaches ids present in the *live* registry).
    // `reconcile_unowned_running` is the fix: any `Running` ledger
    // record whose id the caller does NOT currently own (i.e. is not in
    // the live registry) gets flipped to `Exited { code: -1 }` -- there
    // is no real exit code to report since the record's backing process
    // is already gone by the time this runs, so `-1` is a hand-picked
    // sentinel, not anything derived from an actual `wait()`.

    /// RED: a `Running` record whose id is not `owned` must become
    /// `Exited { code: -1 }` with `exited_at_ms` stamped to exactly
    /// `now_ms` (the time the daemon noticed the record was stale, not
    /// any unknowable real exit time), and the call must report exactly
    /// one record changed.
    #[test]
    fn reconcile_unowned_running_marks_unowned_running_as_exited() {
        let now_ms: u64 = 1_800_000_000_000;
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-reconcile-unowned".to_string(),
            make_info("01J-reconcile-unowned", SessionState::Running, None),
        );

        let changed = reconcile_unowned_running(&mut sessions, |_id| false, now_ms);

        assert_eq!(
            changed, 1,
            "exactly one unowned Running record was reconciled, must return 1"
        );
        let info = sessions
            .get("01J-reconcile-unowned")
            .expect("reconcile_unowned_running must not remove the record, only flip its state");
        assert_eq!(
            info.state,
            SessionState::Exited { code: -1 },
            "an unowned Running record must be flipped to Exited{{ code: -1 }}, got {:?}",
            info.state
        );
        assert_eq!(
            info.exited_at_ms,
            Some(now_ms),
            "exited_at_ms must be stamped to exactly now_ms, got {:?}",
            info.exited_at_ms
        );
    }

    /// RED: an owned `Running` record must be left completely untouched,
    /// and a pre-existing `Exited` record's own state/exited_at_ms must
    /// survive unchanged too -- this function only ever reconciles
    /// *unowned Running* records, nothing else. Both records here would
    /// be corrupted by a naive `|_| true` owned-closure test, so the
    /// owned predicate below only recognizes the Running id, and the
    /// Exited record carries distinguishable values (a non-sentinel
    /// code and an exited_at_ms far from now_ms) so a clobber is
    /// detectable.
    #[test]
    fn reconcile_unowned_running_keeps_owned_running_and_exited_records() {
        let now_ms: u64 = 1_800_000_000_000;
        let mut sessions = BTreeMap::new();
        sessions.insert(
            "01J-reconcile-owned".to_string(),
            make_info("01J-reconcile-owned", SessionState::Running, None),
        );
        sessions.insert(
            "01J-reconcile-already-exited".to_string(),
            make_info(
                "01J-reconcile-already-exited",
                SessionState::Exited { code: 137 },
                Some(1_750_000_000_000),
            ),
        );

        let changed = reconcile_unowned_running(
            &mut sessions,
            |id| id == "01J-reconcile-owned",
            now_ms,
        );

        assert_eq!(
            changed, 0,
            "no record should be reconciled: the Running record is owned and the other is \
             already Exited, must return 0"
        );
        let owned_info = sessions
            .get("01J-reconcile-owned")
            .expect("the owned record must still be present");
        assert_eq!(
            owned_info.state,
            SessionState::Running,
            "an owned Running record must never be touched, got {:?}",
            owned_info.state
        );
        let exited_info = sessions
            .get("01J-reconcile-already-exited")
            .expect("the already-Exited record must still be present");
        assert_eq!(
            exited_info.state,
            SessionState::Exited { code: 137 },
            "an already-Exited record's code must be left untouched, got {:?}",
            exited_info.state
        );
        assert_eq!(
            exited_info.exited_at_ms,
            Some(1_750_000_000_000),
            "an already-Exited record's exited_at_ms must be left untouched, got {:?}",
            exited_info.exited_at_ms
        );
    }
}
