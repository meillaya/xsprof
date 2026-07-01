# Daemon stream semantics and golden fixture lifecycle

This backend-only document freezes JSONL/NDJSON framing for daemon event journals,
stdio output, replay fixtures, runtime replay conversion, and local JSON-RPC replay
results. It adds no frontend, TUI, WebView, browser, desktop, HTTP, or SSE surface.

## v1 framing contract

- Streams are UTF-8 text.
- Every physical line is exactly one JSON object per line.
- Every fixture and emitted JSONL transcript is newline-terminated.
- Blank rows, JSON arrays, scalar JSON values, and pretty-printed multiline JSON
  are invalid NDJSON/JSONL frames.
- A reader must fail closed on malformed input. It must not normalize invalid
  rows into daemon-event/v1 output.
- Every daemon-event/v1 row keeps `host_mutation=false`, including refusal,
  incident, replay, and stream-loss rows.

## Replay and follow semantics

`events.replay` accepts optional `{ "from_event_seq": N }` and returns persisted
`daemon-event/v1` rows whose source `seq >= N`. Source sequence numbers are
preserved in the returned `events_jsonl` payload.

`events.follow` is replay-equivalent for API v1: for the same cursor and same
journal snapshot, it returns the same deterministic one-shot result as
`events.replay`. v1 follow is not a live stream, does not promise reconnect,
backpressure, long polling, or incremental push delivery, and must not be
presented as such. True live follow/streaming is future v2 or another explicitly
versioned extension.

`--replay-runtime` uses `runtime-sample/v1` input and a separate
`sample_sequence` cursor. It emits daemon-event/v1 `runtime_sample` rows with
new daemon event sequence numbers assigned by the replaying daemon. Already
serialized fixture rows under `fixtures/frontend-contract/` are event replay
input, not raw runtime samples, unless their name explicitly covers runtime
sample cursor behavior.

Lost or truncated streams are unsafe states with reason `lost_stream`. Fixtures such as
`fixtures/frontend-contract/lost-stream.jsonl` and stream-loss/backpressure
incidents document the client-visible refusal/incident state; future consumers
must not infer success from EOF, a gap, or missing terminal evidence.

## Cursor invariants

- Non-replay golden fixtures start at `seq=1` and increment by one per row.
- Event replay cursor fixtures may start at the requested source cursor, but
  rows still increment by one with no duplicates or gaps.
- `fixtures/frontend-contract/replay-event-cursor.jsonl` proves event sequence
  cursor behavior by starting after `seq=1` and carrying
  `replay_cursor=event_seq`.
- `fixtures/frontend-contract/replay-runtime-sample-cursor.jsonl` proves runtime
  sample cursor behavior with a `runtime_sample` row carrying
  `replay_cursor=runtime_sample_sequence` and the accepted sample sequence.
- Any nonmonotonic replay row is an invalid input condition and must be refused,
  not re-numbered silently.

## Fixture lifecycle rules

1. Fixture files live only under `fixtures/control/golden/` and
   `fixtures/frontend-contract/` for this Todo 2 stream contract lane.
2. Every checked `*.jsonl` fixture in those roots must be listed in this
   document. An undocumented fixture is stale by default.
3. Update commands documented here may write only below the two allowed fixture
   roots. Commands that write `/tmp`, `.zig-cache`, `evidence/`, source files,
   schemas, docs, or simulator paths are invalid for fixture lifecycle updates.
4. Refusal fixtures stay documented even when they describe malformed input. The
   stable pack stores the resulting refusal row, not malformed daemon-event rows.
5. Todo 10 should wire `python3 qa/golden_fixture_lifecycle_check.py` into the
   backend API maturity/build gate with the existing stable client pack and
   daemon golden transcript checks; this lane intentionally does not edit
   `build.zig`.

## Allowed fixture update command templates

These commands are templates. They document allowed write roots for lifecycle
checkers; they are not a request to mutate fixtures during ordinary validation.

fixture-update: python3 tools/daemon_stdio_assert.py --update-fixture fixtures/control/golden/queued.jsonl
fixture-update: python3 tools/daemon_stdio_assert.py --update-fixture fixtures/control/golden/stream-backpressure.jsonl
fixture-update: python3 tools/daemon_socket_rpc_test.py --output fixtures/frontend-contract/replay-event-cursor.jsonl
fixture-update: python3 tools/daemon_socket_rpc_test.py --output fixtures/frontend-contract/lost-stream.jsonl

## Documented control golden fixtures

- `fixtures/control/golden/attached-partial-switch-lab.jsonl`
- `fixtures/control/golden/booting.jsonl`
- `fixtures/control/golden/cleaned.jsonl`
- `fixtures/control/golden/duplicate-target.jsonl`
- `fixtures/control/golden/incident.jsonl`
- `fixtures/control/golden/malformed-action.jsonl`
- `fixtures/control/golden/observing.jsonl`
- `fixtures/control/golden/privacy-rejection.jsonl`
- `fixtures/control/golden/queued.jsonl`
- `fixtures/control/golden/rollback-active.jsonl`
- `fixtures/control/golden/rollback-ready.jsonl`
- `fixtures/control/golden/runtime-alert-ordering.jsonl`
- `fixtures/control/golden/stale-git.jsonl`
- `fixtures/control/golden/stale-target.jsonl`
- `fixtures/control/golden/stream-backpressure.jsonl`
- `fixtures/control/golden/verifier.jsonl`

## Documented stable client contract fixtures

- `fixtures/frontend-contract/attached.jsonl`
- `fixtures/frontend-contract/booting.jsonl`
- `fixtures/frontend-contract/bpf-object-metadata-missing.jsonl`
- `fixtures/frontend-contract/cgroup-race-membership-changed.jsonl`
- `fixtures/frontend-contract/cgroup-race-parent-changed.jsonl`
- `fixtures/frontend-contract/cgroup-race-symlink.jsonl`
- `fixtures/frontend-contract/cgroup-race-systemd-escape.jsonl`
- `fixtures/frontend-contract/cgroup-race-target-disappeared.jsonl`
- `fixtures/frontend-contract/cleaned.jsonl`
- `fixtures/frontend-contract/cleanup-residue.jsonl`
- `fixtures/frontend-contract/dsq-perf-fairness-gate.jsonl`
- `fixtures/frontend-contract/duplicate-target.jsonl`
- `fixtures/frontend-contract/incident.jsonl`
- `fixtures/frontend-contract/libbpf-load-failed.jsonl`
- `fixtures/frontend-contract/lost-stream.jsonl`
- `fixtures/frontend-contract/malformed-action.jsonl`
- `fixtures/frontend-contract/malformed-runtime-sample.jsonl`
- `fixtures/frontend-contract/matrix-artifact-reference.jsonl`
- `fixtures/frontend-contract/missing-attestation.jsonl`
- `fixtures/frontend-contract/observing.jsonl`
- `fixtures/frontend-contract/privacy-rejection.jsonl`
- `fixtures/frontend-contract/privacy-runtime-variant.jsonl`
- `fixtures/frontend-contract/qemu-unavailable.jsonl`
- `fixtures/frontend-contract/queued.jsonl`
- `fixtures/frontend-contract/release-ineligible.jsonl`
- `fixtures/frontend-contract/replay-event-cursor.jsonl`
- `fixtures/frontend-contract/replay-row-bad-version.jsonl`
- `fixtures/frontend-contract/replay-row-host-mutation-true.jsonl`
- `fixtures/frontend-contract/replay-row-nonmonotonic-seq.jsonl`
- `fixtures/frontend-contract/replay-runtime-sample-cursor.jsonl`
- `fixtures/frontend-contract/rollback-active.jsonl`
- `fixtures/frontend-contract/rollback-failure.jsonl`
- `fixtures/frontend-contract/rollback-ready.jsonl`
- `fixtures/frontend-contract/rpc-action-mismatch.jsonl`
- `fixtures/frontend-contract/rpc-invalid-version.jsonl`
- `fixtures/frontend-contract/rpc-missing-action-json.jsonl`
- `fixtures/frontend-contract/runtime-alert-nr-rejected.jsonl`
- `fixtures/frontend-contract/runtime-alert-workload-dead.jsonl`
- `fixtures/frontend-contract/runtime-sample-loss.jsonl`
- `fixtures/frontend-contract/scx-register-failed.jsonl`
- `fixtures/frontend-contract/stale-git.jsonl`
- `fixtures/frontend-contract/stale-rollback.jsonl`
- `fixtures/frontend-contract/stale-target.jsonl`
- `fixtures/frontend-contract/stream-backpressure.jsonl`
- `fixtures/frontend-contract/timeout.jsonl`
- `fixtures/frontend-contract/unsupported-btf-tuple.jsonl`
- `fixtures/frontend-contract/unsupported-kernel-tuple.jsonl`
- `fixtures/frontend-contract/unsupported-kvm-tuple.jsonl`
- `fixtures/frontend-contract/verifier-reject.jsonl`
- `fixtures/frontend-contract/verifier.jsonl`
- `fixtures/frontend-contract/workload-capability-missing.jsonl`
