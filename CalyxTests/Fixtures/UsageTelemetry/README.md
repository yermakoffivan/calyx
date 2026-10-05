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
