# Captured Claude Code telemetry fixtures (sanitized)

Source: real Claude Code sessions (v2.1.289, 2026-10-05) run with
CLAUDE_CODE_ENABLE_TELEMETRY=1, OTEL_METRICS_EXPORTER=otlp, http/json, CUMULATIVE temporality,
export interval 5 s, OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false. Each export-NNNN.json is one POST body
to .../v1/metrics, in arrival order. Personal values were replaced by sentinels and are still PRESENT
(user.email = fixture@example.invalid, user.id, organization.id; session.id = a fixed fake UUID), so
tests can prove they never reach the database. transcript-skeleton.jsonl keeps only each transcript
line's type / timestamp / sessionId / cwd (fake) and the full cost-state lines (numbers only).
expected-cost-state.json = the last cost-state line's token totals per model.

- run1: headless (`-p`), two background Explore subagents. 7 exports. Final cumulative sums per model
  equal expected-cost-state exactly (input 24, output 2114, cacheRead 176467, cacheCreation 51986).
- run2: INTERACTIVE, advisor call (model claude-fable-5-1, query_source main, no effort), two Explore
  subagents, auxiliary requests (title generation on haiku; prompt suggestions). 14 exports. In this
  session the transcript lacks the final line for 3 of 5 subagent responses; the metric is still exact.
  The skeleton ends at run 2's exit (two identical cost-state lines are written at exit).
- run3: headless RESUME of run2's session (same session.id, new process: new series start times,
  values restart at 0). cost-state is cumulative across the resume: run2 sums + run3 sums equal run3's
  expected-cost-state exactly. The skeleton is the whole transcript (run 2's lines, then run 3's).
- run4: headless, model label with a suffix: `claude-opus-5-5[1m]` in the metric and in cost-state
  (the transcript's message.model says `claude-opus-5-5`), effort `xhigh`.

Facts the captures show: values arrive as `asDouble` holding an integer; startTimeUnixNano /
timeUnixNano are decimal strings; aggregationTemporality is 2; once a series appears it is present in
every later export of that process; other metrics (session.count, cost.usage, active_time.total) share
the payload; the first export of a process may carry no token.usage at all.

## Runs 5-8: how a session is born and continued (added for the reconciliation slices)

In these runs a capture can hold several sessions. Files are then numbered in order of appearance:
`transcript-skeleton-N.jsonl`, `expected-cost-state-N.json`. `expected-metric-sums.json` holds the final
cumulative metric sums per (fake) session id. A skeleton line additionally keeps a `forkedFrom` object
when the original line had one (its values replaced by fixed fake ids).

- run5: INTERACTIVE, `/clear` in the middle. Two sessions in ONE process: ...551 (fresh) and ...552 (born
  by `/clear`). `claude_code.session.count` exists only for ...551 (it counts process starts). `/clear`
  writes ...551's cost-state, and the new session's totals start at zero: each session's metric sums equal
  its own cost-state. ...552 ends with two identical cost-state lines with only a `last-prompt` line
  between them.
- run6: headless `--resume <run2's session> --fork-session`. New session id ...661, start_type `resume`.
  The fork's cost-state INCLUDES the parent's totals (run3's cumulative totals plus the fork's own
  usage), while the metric reports only the fork's own usage (`expected-metric-sums.json`). The file
  starts with two `queue-operation` lines stamped at fork time, followed by the parent's history lines
  with their ORIGINAL (older) timestamps and no marker; the parent's cost-state lines are not copied.
- run7: INTERACTIVE, `/branch` in the middle. Parent ...771 (fresh) and branch ...772, born in the same
  process (no `session.count` for it). `/branch` writes the parent's cost-state, and the branch's totals
  start at zero: both equal their metric sums. The branch's file BEGINS with the parent's history lines,
  each carrying a `forkedFrom` object and its original timestamp; its first own line is a `system` line.
  skeleton-1 is the parent's file as it was when run7 ended (34 lines).
- run8: INTERACTIVE, a new fresh session ...881, then `/resume <run7's parent>` inside the same process.
  ...881 gets its cost-state at the switch. The resumed session's file (skeleton-2: the whole file, same
  session id ...771 as run7's parent) gains a second run whose cost-state is CUMULATIVE (run7's totals
  plus this stretch); the metric reports only this stretch under the resumed session id, and there is no
  `session.count` for it. Two cost-state lines close that run, with only lines WITHOUT a timestamp
  between them.

More facts these captures show:
- A finished transcript ends with a newline, and its last line is the cost-state line.
- Timestamps are NOT monotonic in file order even in an ordinary session: `attachment` lines can be
  stamped slightly earlier than the `user` line written before them (run5 skeleton-1), and the lines of
  the `/clear` command are stamped earlier than the first line of the session it creates (skeleton-2).
- The start type is decided by the launch arguments alone (`--resume` / `--from-pr` -> `resume`,
  `--continue` -> `continue`, otherwise `fresh`): a process that starts with another session's totals
  (run6) is never `fresh`, and a `fresh` process always starts from zero.
- run9: INTERACTIVE, one process, three sessions with SEVERAL turns: ...aa1 (fresh, one turn), then `/clear`
  -> ...aa2 (two turns), then `/branch` -> ...aa3 (two turns), then exit. 26 exports. Each session's metric
  sums equal its own cost-state (`/clear` and `/branch` both start from zero). Unlike runs 5 and 7, the
  sessions born inside the process receive usage in MORE than one export, so withholding the last exports
  leaves them partly received.
