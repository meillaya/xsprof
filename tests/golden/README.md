# Golden fixtures

These files were captured from the archived C++ implementation at commit
`44d7594` (tag `cpp-0.1.0`) on 2026-10-31. They are the byte-stability baseline
for the Zig rewrite.

- `root/event_v1_golden.json` — canonical sched_switch event.
- `root/event_v1_page_fault_golden.json` — canonical page_fault event.
- `root/aggregates_v1_golden.json` — empty/fail-closed aggregates.
- `root/journal_v1_golden.json` — journal wrapper fixture.
- `root/daemon_replay_golden.jsonl` — archived daemon replay transcript,
  retained for wire-format reference; the legacy daemon lane is archived.

P1 ports the event/aggregate assertions first. Timeline goldens will be
regenerated with corrected switch durations, paired flows, and consistent
ns/µs units; do not “fix” the new implementation to match the known-broken
trace output.
## Compact recorder goldens (v0.4)

- `recorder/segments/segment_v1_golden.xsraw` — one compact raw
  segment (xsprof/raw-segment/v1) covering every event kind, boundary
  integers, a negative timestamp delta, and block-local comm table reuse.
- `recorder/segment_v1_golden.ndjson` — the canonical extraction that
  the decoder must reproduce byte for byte (tested by `segment_reader.zig`,
  `qa/cli_parity.sh`, and `qa/compact_roundtrip.sh`).

Regenerate only with a deliberate format change: encode the same event list with
`src/recorder/segment.zig` and commit both files together.
