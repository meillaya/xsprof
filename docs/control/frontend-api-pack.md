# Backend-only Frontend API Pack

This is a backend contract document. It intentionally contains no frontend implementation, no TUI/WebView/browser/desktop artifacts, no theme or hotkey behavior, and no simulator changes.

## Purpose

The API pack freezes the root backend surface future clients can consume without reconstructing scheduler state from internal files. The daemon remains fail-closed on the host: ordinary host modes do not load BPF, mutate cgroups/cpusets/affinity/priority/scheduler state, write `/sys` or `/proc`, or claim production readiness.

## Public contract surfaces

| Surface | Version | Role |
| --- | --- | --- |
| daemon events | `zig-scheduler/daemon-event/v1` | Append-only lifecycle, runtime, rollback, cleanup, validation, refusal, and incident stream. |
| operator actions | `zig-scheduler/operator-action/v1` | Client-submitted commands such as preflight, VM-lab run, stop, rollback, and incident drill. |
| runtime samples | `zig-scheduler/runtime-sample/v1` | Privacy-filtered VM runtime observation input converted into daemon event rows. |

## Transports

| Transport | Status | Contract |
| --- | --- | --- |
| stdio JSONL | Stable test/replay lane | Spawn `zig-scheduler-daemon --foreground --state-dir <relative-dir>` and exchange newline-delimited operator actions and daemon events. |
| Unix-domain socket JSON-RPC 2.0 | Stable local daemon lane | Start `zig-scheduler-daemon --foreground --state-dir <relative-dir> --socket <relative-sock>` and send one JSON-RPC request per line over the local socket. |
| HTTP/SSE bridge | Deferred | Future browser work may bridge to the local daemon, but this repository milestone adds no frontend implementation or HTTP/SSE server. |

The socket path must be relative, pass the same safe path validation as daemon state paths, and live inside the selected `--state-dir`. If the path already exists, it must be a Unix-domain socket; regular files, directories, and symlinks are refused before unlink. The daemon accepts one local socket client, processes requests until client EOF, writes `events.jsonl`, and exits. That shape keeps development and QA deterministic.

## JSON-RPC methods

Requests use JSON-RPC 2.0 with string IDs. Errors include a documented `incident_code` and always report `host_mutation=false` in error data.

| Method | Params | Result |
| --- | --- | --- |
| `daemon.version` | none | daemon name and v1 schema strings. |
| `targets.list` | none | active target/action/rollback IDs restored from the journal. |
| `actions.submit` | `{ "action_json": "<operator-action/v1 JSON>" }` | `events_jsonl` containing newly emitted daemon-event/v1 rows. |
| `actions.rollback` | same as submit | Alias lane for rollback actions; same dispatcher and refusal rules. |
| `actions.stop` | same as submit | Alias lane for stop actions; same dispatcher and refusal rules. |
| `events.replay` | optional `{ "from_event_seq": N }` | `events_jsonl` containing persisted event rows with source `seq >= N`. |
| `events.follow` | optional `{ "from_event_seq": N }` | Deterministic one-shot follow equivalent to replay for this backend contract pack. |

## Replay semantics

There are two independent cursors:

- `--replay-events <jsonl> --from-event-seq <N>` filters already-serialized daemon events by daemon event `seq`. It preserves source event sequence numbers.
- `--replay-runtime <jsonl> --from-sample-seq <N>` filters runtime sample input by runtime `sample_sequence`, then emits daemon-event/v1 `runtime_sample` rows with daemon event sequence numbers assigned by the current daemon output stream.

The legacy aliases remain supported:

- `--stream-runtime` is an alias for `--replay-runtime`.
- `--stream-from` is an alias for `--from-sample-seq`.

Replay mode is the local development surface for future clients that need canonical frames without launching QEMU.

The frontend-contract fixture pack stores already-serialized `daemon-event/v1`
rows. Those JSONL files are consumed with `--replay-events` / `--from-event-seq`;
they are not raw `runtime-sample/v1` input and do not exercise
`--replay-runtime` unless the fixture name explicitly covers runtime sample
cursor behavior.

## Replay fixture classes

The backend contract pack includes canonical rows for these client-visible
states:

| Fixture class | Files | Required semantics |
| --- | --- | --- |
| VM prerequisite refusals | `qemu-unavailable.jsonl`, `unsupported-kernel-tuple.jsonl`, `unsupported-btf-tuple.jsonl`, `unsupported-kvm-tuple.jsonl` | Terminal refusal/unsafe rows with documented prerequisite reason codes and `host_mutation=false`. |
| Cgroup race incidents | `cgroup-race-target-disappeared.jsonl`, `cgroup-race-parent-changed.jsonl`, `cgroup-race-membership-changed.jsonl`, `cgroup-race-symlink.jsonl`, `cgroup-race-systemd-escape.jsonl` | Terminal unsafe rows with documented cgroup race reason codes and relative cgroup evidence artifacts. |
| DSQ/perf fairness gate | `dsq-perf-fairness-gate.jsonl` | Validation/incident rows that withhold proof; the fixture must not contain `PASS`. |
| Runtime alerts | `runtime-alert-nr-rejected.jsonl`, `runtime-alert-workload-dead.jsonl` | A `runtime_sample` row exposes either nonzero `nr_rejected` or `workload_alive=false`, followed by an unsafe incident. |
| Malformed/privacy runtime variants | `malformed-runtime-sample.jsonl`, `privacy-runtime-variant.jsonl` | Redacted unsafe incidents using `malformed_runtime_sample` or `private_fields_rejected`. |
| Release-ineligible state | `release-ineligible.jsonl` | Validation and unsafe incident rows keep eligibility withheld; the fixture must not contain `PASS`. |

## Lifecycle model

Canonical client state is derived only from daemon events, not from UI labels:

1. `state_changed` / `read_only` / `ready`
2. `stage_started` / `queued`
3. VM-lab lifecycle events: `boot`, `marker`, `verifier`, `attach`, `runtime_sample`
4. rollback and cleanup events: `rollback`, `rollback_completed`, `cleanup`
5. `validation`
6. terminal `stage_finished` with `PASS`, `INCIDENT`, `REFUSE`, or `SKIP`

An incident, failed rollback, cleanup residue, stale target, duplicate target,
stale rollback ID, malformed action, stale git SHA, privacy rejection, runtime
alert, VM prerequisite refusal, cgroup race, DSQ/perf fairness gate, timeout,
lost stream, or release-ineligible validation must be treated as
unsafe/incomplete client state. It is not release proof and not production
readiness.

## Safety invariants

- Every daemon event row must have `host_mutation=false`.
- Artifact paths are relative and must not escape the repository.
- Event sequences are monotonic within each transcript, except event replay fixtures may start at the requested source cursor.
- Runtime samples must not expose command lines, argv, environment, secrets, API keys, tokens, or passwords.
- Stop and rollback act on active target IDs and rollback IDs only; stale or duplicate IDs are visible refusals.
- Future clients must not infer success from missing data. Gaps become incidents or refused states.

## Local development commands

```sh
zig build client-contract
zig build daemon-stdio
zig build daemon-socket-rpc
```

These commands are backend contract checks only; they do not launch frontend code and do not require QEMU.
