# Control schema compatibility policy

This backend-only document freezes client-visible v1 control schemas. It is a no frontend implementation policy and does not approve real-host attach and must not claim production readiness.

## Frozen v1 schemas

| Schema | File | Compatibility status |
| --- | --- | --- |
| `zig-scheduler/daemon-event/v1` | `schemas/control/daemon-event.v1.schema.json` | Public client event stream. |
| `zig-scheduler/operator-action/v1` | `schemas/control/operator-action.v1.schema.json` | Public client action input. |
| `zig-scheduler/runtime-sample/v1` | `schemas/control/runtime-sample.v1.schema.json` | Public runtime sample input. |
| `zig-scheduler/matrix-run/v1` | `schemas/control/matrix-run.v1.schema.json` | Standalone VM harness evidence artifact referenced by daemon events; not embedded into daemon-event/v1. |
| `zig-scheduler/benchmark-output/v1` | `schemas/control/benchmark-output.v1.schema.json` | Record-only benchmark provenance artifact for VM/lab evidence; release-ineligible and not a production capacity claim. |

## Compatibility guarantees

- Existing required fields keep their current meaning for all v1 rows.
- Existing enum values remain accepted unless a later v2 schema is introduced.
- New optional fields may be added only when older clients can ignore them safely.
- New event, action, status, state, or incident code values require fixture and documentation updates in the same change.
- Unknown schema versions must be refused or treated as unsupported, never silently reinterpreted as v1.
- A breaking change requires a new `/v2` schema string and a migration note.
- Dotted namespace labels such as `bpf.libbpf_load_failed` are documentation-only groupings. They must not replace underscore-only v1 wire `reason` values such as `libbpf_load_failed`.

## Version matrix

| Producer | Consumer | Supported? | Notes |
| --- | --- | --- | --- |
| daemon-event/v1 | backend client contract pack | yes | Validated by `qa/frontend_contract_pack_check.py` as a no frontend implementation fixture check. |
| operator-action/v1 | stdio daemon | yes | Validated by `zig build daemon-stdio`. |
| operator-action/v1 | UDS JSON-RPC `action_json` | yes | Same dispatcher as stdio. |
| runtime-sample/v1 | replay/runtime stream | yes | Validated by runtime replay and contract pack checks. |
| matrix-run/v1 | daemon-event/v1 artifact reference | yes | The daemon event carries a relative `evidence/lab/matrix/<run-id>/manifest.json` artifact path; the referenced manifest is deep-validated by `qa/matrix_run_contract_check.py`. |
| benchmark-output/v1 | VM/lab evidence and benchmark fixture validators | yes | Validated by `qa/benchmark_output_check.py`; rows remain record-only with `release_eligible=false`, `production_capacity_claim=false`, and `hard_thresholds_enforced=false`. |
| daemon-event/v1 fixture pack | backend consumer harness | yes | No frontend implementation: `qa/consumer_contract_check.py` derives client/store lifecycle state from documented event rows only and refuses success on stale/duplicate targets, missing rollback/cleanup terminal incidents, dotted namespace wire reasons, lost streams, or matrix references that fail deep manifest validation. |
| any v2+ | current daemon | no | Must refuse until a v2 compatibility plan exists. |

## Compatibility changelog

- 2026-06-23: v1 public boundary documented as the backend client integration contract. stdio JSONL remains stable for tests/replay. UDS JSON-RPC is added as the local persistent client transport. Event replay and runtime sample replay cursors are documented separately.
- 2026-06-23: Client contract fixtures expanded prerequisite, cgroup race, DSQ/perf, runtime alert, privacy, and release-ineligible states using existing optional `daemon-event/v1` fields; no v1 schema change is required.
- 2026-06-29: Client contract fixtures expanded JSON-RPC refusal, replay-row refusal, matrix artifact reference, BPF/libbpf/scx, workload capability, runtime sample-loss, and release-ineligible coverage. Existing underscore-only v1 `reason` codes remain stable; dotted phase/source namespace labels are documentation-only and are rejected by the fixture semantics gate if used as wire reasons.
- 2026-06-29: Stream framing and golden fixture lifecycle are documented in `stream-semantics.md`; `events.follow` remains deterministic one-shot replay-equivalent for v1, with true live streaming deferred to a future versioned contract.
- 2026-06-29: `benchmark-output/v1` is explicitly part of the frozen public schema/version matrix as a record-only lab evidence artifact; it does not make release eligibility, production capacity, or hard-threshold claims.
- 2026-06-29: `runtime-sample/v1` added optional mature scheduler observation fields for DSQ depth, queue latency, fairness/starvation, redacted cgroup/class task counts, context-switch/wakeup/migration counters, normalized sched_ext dump/tracepoint counts, record-only benchmark histogram references, and expanded sample-loss/backpressure counters. Required v1 fields and schema strings are unchanged; raw debug dumps, host paths, command lines, argv, environment, and secrets remain forbidden.
- 2026-06-30: `runtime-sample/v1` `policy_abi` added optional ABI-v3 cgroup-policy metadata. Legacy v1 `policy_abi` rows remain forward-compatible, while rows declaring `abi_version=3` must carry exact cgroup semantics, VM-only/host-mutation false flags, and no production/release claims.
- 2026-06-30: `runtime-sample/v1` added optional protected-VM sched_ext evidence fields: `sched_ext_phase`, `task_ext_enabled`, `teardown_state`, `rollback_state`, and `cgroup_semantic_labels`. `task_ext_enabled` is an actual task `ext.enabled` fact when readable (`present` with `true`/`false`), or an explicit unavailable/unknown fact when task-level evidence cannot be read; global sched_ext state is not a substitute.

## Required gates

```sh
python3 qa/control_schema_drift_check.py --protocol src/control/protocol.zig --schemas schemas/control
python3 qa/schema_compatibility_check.py --protocol src/control/protocol.zig --schemas schemas/control --docs docs/control --fixtures fixtures/frontend-contract  # no frontend implementation
python3 qa/frontend_contract_pack_check.py --fixtures fixtures/frontend-contract --schemas schemas/control --docs docs/control  # no frontend implementation
python3 qa/consumer_contract_check.py --fixtures fixtures/frontend-contract --schemas schemas/control --docs docs/control  # no frontend implementation
zig build daemon-stdio
zig build daemon-socket-rpc
```

## Draft and identifier gate

Every public control schema uses JSON Schema draft `https://json-schema.org/draft/2020-12/schema`, carries a non-empty `$id`, and exposes exactly one literal `properties.schema.const` wire value. The compatibility gate refuses missing drafts, unsupported drafts, missing `$id`, or missing schema constants before any fixture is treated as v1 data.

## Compatibility classes

- **Backward compatible:** a new producer row can be consumed by an existing v1 client. For v1 this means existing required fields and enum meanings are unchanged, any new fields are optional, and old clients can ignore them safely.
- **Forward compatible:** a new client can consume existing v1 rows without requiring new fields or reinterpretation. New clients must continue to accept all frozen v1 required fields and enum values.
- **Fully compatible:** both backward and forward compatible. The change is limited to optional, documented metadata or stricter docs/tests that do not reject previously valid v1 rows.
- **Breaking change:** any added v1 required field, removed/renamed field, changed field meaning, enum removal, enum semantic change, schema string change, or requirement that old clients understand new row versions. Breaking changes are not allowed in v1.

## v2 migration playbook

1. Document the incompatible need and why it cannot be represented as optional v1 metadata.
2. Add new `.../v2` schema files with draft 2020-12 declarations, `$id`, and `properties.schema.const` values; do not change v1 schema constants.
3. Add dual-read tests that prove v1 rows are still accepted by v1 consumers and v2 rows are refused by v1 consumers instead of silently reinterpreted.
4. Add v2 fixtures, taxonomy rows, and migration notes in the same change as any new event/action/incident enum or reason code.
5. Keep host fail-closed and VM-lab-only boundaries unchanged; a schema migration is not approval for real-host scheduler mutation or production release.
