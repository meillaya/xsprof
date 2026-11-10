# xsprof wire schemas

Canonical namespace: `xsprof/*`. Every document here is a JSON Schema
(draft 2020-12 subset) for one canonical wire contract. The legacy
`zig-scheduler/*` schemas live on `archive/cpp-0.1.0` and are not served by this
rewrite; the lab/experiment schemas (`lab-scenario.v1`, `lab-run.v1`) were
removed with the lab lane and must not be reintroduced.

## Canonical `$id` and structure

- Every schema's `$id` is exactly
  `https://xsprof.dev/schemas/<basename>`, e.g. `event.v1.schema.json` →
  `https://xsprof.dev/schemas/event.v1.schema.json`. `$id`s are unique; the
  basename and contract name are one-to-one (`event.v1` ↔ `xsprof/event/v1`).
- Every schema declares `$schema` = `https://json-schema.org/draft/2020-12/schema`,
  a non-empty `title`, root `type: object`, and a `properties.schema.const`
  discriminator equal to the contract name.
- Only the supported keyword subset is allowed: `type`, `properties`,
  `required`, `additionalProperties` (boolean), `items`, `minItems`,
  `maxItems`, `anyOf`, `enum`, `const`, `minimum`, `maximum`, `minLength`,
  `maxLength`, and local `#/$defs/<name>` `$ref`. `$schema`, `$id`, `title`,
  and `$defs` are annotations/definitions. Unknown constraint keywords are a
  hard failure, so a schema cannot silently weaken validation.
- `required` names must be documented in `properties`.

## Validation

`src/core/schema.zig` is a bounded, std-only validator for that subset. It
limits schema/instance byte length, JSON nesting depth, `$ref` hops, and
recursion, and reports the failing keyword plus instance path. It is the
validator behind the `xsprof validate` verb; that verb's canonical output
contract is `validate.v1.schema.json`.

`tests/schema.zig` is the committed registry and gate:

- it parses every `schemas/xsprof/*.schema.json` file, enforces the canonical
  `$id`/structure rules above, fails if the directory and the explicit registry
  drift, and rejects unsupported keywords or unresolved `$ref`s;
- it maps each committed wire sample to its schema explicitly and validates
  every `tests/golden/**` JSON/NDJSON wire sample, `fixtures/ui/healthy.ndjson`,
  and `fixtures/real/{scheduler-mix,vm-fragmented,macos-vm-sched}.ndjson` line
  by line. Journal entries are additionally validated against `event.v1`;
- samples with no maintained schema have an explicit disposition instead of an
  implicit skip: the archived legacy `daemon-event` transcript is only checked
  for canonical framing (`host_mutation=false`, ascending `seq`), and the
  binary `.xsraw` segment is covered by the segment-reader tests and the
  compact-roundtrip gate.

Adding or removing a schema or wire sample is intentionally a visible edit to
the registry in `tests/schema.zig`.

## Contracts

Key ordering is lexical and compact; required fields are validated at the
boundary, and every record carries `host_mutation=false`.

| File | Contract |
|---|---|
| `advisor-report.v1.schema.json` | Advisor findings/rules |
| `aggregates.v1.schema.json` | Frozen advisor aggregate snapshot |
| `bpf-gate.v1.schema.json` | VM-marker-gated no-op BPF gate |
| `capture-summary.v1.schema.json` | `record` stderr summary |
| `cgroup.v1.schema.json` | Read-only cgroup attribution |
| `compare.v1.schema.json` | Baseline/candidate comparison |
| `doctor.v1.schema.json` | Read-only environment diagnostics |
| `event.v1.schema.json` | One canonical scheduler/memory event |
| `history.v1.schema.json` | Sidecar history query |
| `incident-result.v1.schema.json` | Incident command result |
| `incident-summary.v1.schema.json` | Incident bundle summary |
| `journal.v1.schema.json` | Legacy wrapped journal |
| `metrics.v1.schema.json` | Metrics, tasks, CPUs, wakeup pairs, ordering |
| `preflight.v1.schema.json` | Host facts/capability snapshot |
| `pressure.v1.schema.json` | PSI CPU/memory/IO stall counters |
| `recorder-manifest.v1.schema.json` | Recorder session/segment index |
| `recorder-result.v1.schema.json` | Daemon result and overhead |
| `recorder-verify.v1.schema.json` | Read-only segment/state verification |
| `validate.v1.schema.json` | `xsprof validate` result |
| `why.v1.schema.json` | `xsprof why` report |

`metrics.v1` adds `out_of_order`, `pairs_truncated`, and `wakeup_pairs`.
`recorder-manifest.v1` adds `history_interval_ms`/`history_retain_ms`, and the
additive `raw_codec`/segment `codec` fields (`ndjson` or `compact_v1`).
`capture-summary.v1` is the documented `record` summary: split
`faults_major`/`faults_minor` plus combined `page_faults`
(`faults_major + faults_minor`), `lost`, and `output`. Existing manifests
without the history fields remain parseable.
