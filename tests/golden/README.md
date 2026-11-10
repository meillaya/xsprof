# Golden fixtures

Byte-stability baselines for the canonical wire form and the compact raw
format. They are small, committed, and schema-checked; they are not evidence
corpora.

## Canonical wire samples

- `root/event_v1_golden.json` — canonical `sched_switch` event.
- `root/event_v1_page_fault_golden.json` — canonical `page_fault` event.
- `root/aggregates_v1_golden.json` — fail-closed aggregates snapshot.
- `root/journal_v1_golden.json` — wrapped journal fixture.
- `root/daemon_replay_golden.jsonl` — archived legacy daemon transcript
  (`xsprof/daemon-event/v1`). The lane is archived and has no maintained schema;
  the schema-conformance registry only checks canonical framing
  (`host_mutation=false`, ascending sequence).

The `root/*` files were captured from the archived C++ predecessor (main history
at commit `44d7594`; there is no archive branch/tag in this repository) and were
used as the byte-stability baseline for the Zig rewrite. Do not “fix” the new
implementation to match known-broken legacy trace output; goldens change only
with a deliberate, reviewed wire/format decision.

## Compact recorder goldens (`0.4+`)

- `recorder/segments/segment_v1_golden.xsraw` — one compact raw segment
  (`xsprof/raw-segment/v1`) covering every event kind, boundary integers, a
  negative timestamp delta, and block-local comm-table reuse.
- `recorder/segment_v1_golden.ndjson` — the canonical extraction the decoder must
  reproduce byte for byte.

These are covered by the segment-reader tests and
`./tools/zig build compact-roundtrip`, not by JSON schema validation. Regenerate
both together only for a deliberate format change.

## Conformance and size

- Every schema-backed committed wire sample — these goldens, the recorder golden
  NDJSON, `fixtures/ui/healthy.ndjson`, and
  `fixtures/real/{scheduler-mix,vm-fragmented,macos-vm-sched}.ndjson` — is
  validated line-by-line against the correct schema by the test root
  (`tests/schema.zig`, wired into `./tools/zig build check`); journal entries are
  validated against `event.v1`.
- Golden bytes are covered by unit tests; UI snapshots/hashes are covered by
  `qa/a11y_smoke.sh` and the offscreen snapshot tests.
- Keep these files small and deterministic; they count against the tracked-tree
  size budget (`qa/repo_size.sh`). Full captures are release assets, never
  goldens.
