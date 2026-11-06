# C++ parity inventory (archived)

The C++ implementation is on branch `archive/cpp-0.1.0`, tag `cpp-0.1.0`
(commit `44d7594`). This file records the behavior the Zig rewrite must retain
and the defects it intentionally fixes. No C++ source is copied into `main`.

## Retained CLI

- `help|--help|-h`, `version|--version`; no args = help, exit 0.
- `preflight --json`, `capabilities --json`; missing flag = stderr, exit 2.
- `advise [--input F] [--md]`; host facts by default, journal aggregates with
  `--input`; JSON unless `--md`.
- `incident --last DUR --dir D --out D`; one offline bundle with `window.ndjson`,
  `summary.json`, `report.html`, and `trace.json`.
- `history --dir D [--last DUR]`; sidecar timeline that survives raw retention.
- `timeline --input F [--output F] [--window S:E] [--chunk-size N]`.
- `record [--duration MS=1000] [--output F] [--bpf OBJ] [--allow-mutate]
  [--vm-lab] [--audit-id ID] [--rollback-id ID]`.
- Exit codes 0/1/2 as above.
- Nine unsafe verbs and unknown verbs refuse before dispatch; refusal JSON is
  canonical and carries `host_mutation=false`.

## Retained wire contracts

- `xsprof/event/v1`: `schema,event,ts_ns,cpu,pid,tid,a,b,c,host_mutation`;
  optional `comm,detail`. Canonical sorted keys.
- `xsprof/preflight/v1`: `tool,host_mutation,capabilities[],facts{}`.
- `xsprof/capture-summary/v1`: capability, source, counts, duration,
  host_mutation (stderr).
- `xsprof/aggregates/v1`: 21 fields + host_mutation.
- `xsprof/advisor-report/v1`: capabilities, findings (id/severity/confidence/
  summary/evidence/recommendations), rules (id/reason/status), host_mutation.
- `xsprof/incident-summary/v1`: artifacts, capabilities, counts, findings,
  loss, requested/retained window, rules, signals, top tasks, host_mutation.
- `xsprof/incident-result/v1`: artifact paths, status counts, window events.
- `xsprof/history/v1`: per-sidecar entries, totals, first/last wall ns, window ms.
- 18 event kinds: sched_switch, sched_wakeup, sched_migrate,
  runqueue_sample, priority_inversion, lock_contention, page_fault, tlb_miss,
  cache_miss, huge_page, numa_balance, alloc_sample, malloc_hotspot, marker,
  capability, refusal, incident, runtime_sample.
- Capability states READY/DEGRADED/SKIP/REFUSE with reasons.
- Sorted-key compact JSON; `host_mutation=false` constantly.
- Privacy: comm ≤15 bytes, key/value redaction, no argv/env.
- Advisor: 7 rules, defaults `>0.20`, `>0.30`, `>100`, `>1.0 ms`, `>0.05`,
  `>0.50`, priority inversion enabled; stable severity ordering; a rule is
  `CLEAR` only when every required signal was collected, otherwise `SKIP`;
  suggestions only.
- Chrome Trace `X`/`i`/`s`/`f`/`M` shapes, windowing, chunk streaming,
  `SAMPLE_LOSS` as unsafe.
- Journal replay: one JSON object per line; reject wrong schema,
  `host_mutation=true`, malformed rows, oversized/deeply nested lines. Legacy
  cross-ring timestamp skew is tolerated and counted (`out_of_order`); new
  capture batches are sorted before journaling.

## Retained devices (read-only)

- `/proc/stat`, `meminfo`, `buddyinfo`, `schedstat`, `numa_maps`,
  `perf_event_paranoid`, `kptr_restrict`, numeric `/proc/<pid>/stat`.
- `/sys` sched_ext state files, BTF presence, tracefs sched tracepoint
  id/format, hugepages, NUMA cpulists, PMU/IBS presence.
- `perf_event_open`: sched_switch/wakeup/migrate tracepoints, software page
  faults, per-CPU, 8 data pages, 200 ms poll.
- BPF CO-RE via libbpf, host-refused; VM path requires audit/rollback/marker.

## Defects fixed in the rewrite

1. Timeline used `next_pid` as switch duration; flow starts never paired with
   ends; ns/µs units were inconsistent.
2. `--output` open failure silently fell back to stdout.
3. Replay accepted missing required fields; JSON nesting was unbounded.
4. `meminfo` parser was positional; hugepage size lookup used index 12.
5. `SafePath` existed but was unused by sinks.
6. `PERF_RECORD_LOST` was counted but never journaled.
7. BPF VM gate was self-asserted CLI flags only.
8. Wire namespace drifted between `xsprof/*` and `zig-scheduler/*`.

## Archived, not reimplemented

The legacy `zig-scheduler/*` lab/VM control plane (daemon-event/operator-action,
matrix evidence, governance fixtures, frontend contract pack) is preserved on
the archive branch. The profiler-focused rewrite keeps the safety invariants and
the VM-only BPF gate, not the lab lifecycle UI.
