# Control schema compatibility policy

This backend-only document freezes client-visible v1 control schemas. It is a no frontend implementation policy and does not approve real-host attach or production readiness.

## Frozen v1 schemas

| Schema | File | Compatibility status |
| --- | --- | --- |
| `zig-scheduler/daemon-event/v1` | `schemas/control/daemon-event.v1.schema.json` | Public client event stream. |
| `zig-scheduler/operator-action/v1` | `schemas/control/operator-action.v1.schema.json` | Public client action input. |
| `zig-scheduler/runtime-sample/v1` | `schemas/control/runtime-sample.v1.schema.json` | Public runtime sample input. |

## Compatibility guarantees

- Existing required fields keep their current meaning for all v1 rows.
- Existing enum values remain accepted unless a later v2 schema is introduced.
- New optional fields may be added only when older clients can ignore them safely.
- New event, action, status, state, or incident code values require fixture and documentation updates in the same change.
- Unknown schema versions must be refused or treated as unsupported, never silently reinterpreted as v1.
- A breaking change requires a new `/v2` schema string and a migration note.

## Version matrix

| Producer | Consumer | Supported? | Notes |
| --- | --- | --- | --- |
| daemon-event/v1 | backend client contract pack | yes | Validated by `qa/frontend_contract_pack_check.py` as a no frontend implementation fixture check. |
| operator-action/v1 | stdio daemon | yes | Validated by `zig build daemon-stdio`. |
| operator-action/v1 | UDS JSON-RPC `action_json` | yes | Same dispatcher as stdio. |
| runtime-sample/v1 | replay/runtime stream | yes | Validated by runtime replay and contract pack checks. |
| any v2+ | current daemon | no | Must refuse until a v2 compatibility plan exists. |

## Compatibility changelog

- 2026-06-23: v1 public boundary documented as the backend client integration contract. stdio JSONL remains stable for tests/replay. UDS JSON-RPC is added as the local persistent client transport. Event replay and runtime sample replay cursors are documented separately.
- 2026-06-23: Client contract fixtures expanded prerequisite, cgroup race, DSQ/perf, runtime alert, privacy, and release-ineligible states using existing optional `daemon-event/v1` fields; no v1 schema change is required.

## Required gates

```sh
python3 qa/control_schema_drift_check.py --protocol src/control/protocol.zig --schemas schemas/control
python3 qa/frontend_contract_pack_check.py --fixtures fixtures/frontend-contract --schemas schemas/control --docs docs/control  # no frontend implementation
zig build daemon-stdio
zig build daemon-socket-rpc
```
