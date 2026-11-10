# Real workload fixtures

`fixtures/real/` keeps small, deterministic **prefixes** of real
`perf_event_open` captures. They are not synthetic, downsampled, or
interpolated: each file is the first N complete NDJSON lines of a capture in
recorded order, ending mid-run. The full captures are release assets, not
tracked in git.

## `scheduler-mix.ndjson`

Real `perf_event_open` capture, not synthetic data.

- Provenance: disposable Fedora 44 podman VM, kernel `7.2.7-200.fc44.aarch64`,
  4 vCPUs, tracefs mounted, `kernel.perf_event_paranoid=2`.
- Capture: `xsprof record --duration 350 --output /tmp/real.ndjson` from an
  `aarch64-linux-gnu` build. Workload: two busy `yes` loops, a
  `find /usr | xargs -P 4 wc -c` walk, and
  `dd if=/dev/urandom of=/dev/null bs=64k` running concurrently.
- Full capture: 112,795 events over 350 ms. This file keeps the first
  **4,000 complete lines** in timestamp order: 579,292 bytes, sha256
  `dae13282270fb0df7e54973ae1d7a4d096f422d7f166b5f47fc2637591e505aa`.
- Shape: 4,000 events on 4 CPUs — 534 `sched_switch`, 69 `sched_wakeup`,
  18 `sched_migrate`, 3,379 `page_fault`; no loss markers; first row is a
  `sched_switch`, last is a `page_fault`.
- Every row is canonical `xsprof/event/v1` with `host_mutation:false`.
- Exercises multi-process scheduler activity, page faults, and multi-CPU
  lanes in tests and snapshots. The console identifies the recorder's own task
  (`xsprof`, `xsprof-*`) and excludes it from rankings and wakeup-churn ratios;
  the captured rows themselves are unchanged.

## `vm-fragmented.ndjson`

- Provenance: same disposable Fedora 44 aarch64 podman VM; fresh
  `xsprof record --duration 500` with four busy `yes` loops.
- Committed prefix: first **4,000 complete lines** (637,483 bytes, sha256
  `b00d535364f3aedc0b66e4b1d85b1655a6fb0c8b80b7c45f670f8851e45c03d6`),
  ending mid-run.
- Shape: 4,000 lines — 3,416 `sched_switch`, 559 `page_fault`, 22
  `sched_wakeup`, 1 `sched_migrate`, plus 2 leading session metadata rows:
  `capture_owner` (recorder pid 1758) and
  `host_memory buddy_fragmentation=0.614654`. The VM's cache topology was not
  readable, so no `cpu_llc` rows were emitted and topology stays uncollected.
- The metadata survives `capture --last`, the recorder task is excluded from
  workload churn, and `advise --input` produces a measured
  `allocator-fragmentation` finding with the buddyinfo evidence.

## `macos-vm-sched.ndjson`

Captured on this Mac through the disposable podman Linux VM, because macOS has
no `perf_event_open` or scheduler tracepoints.

- Host: macOS arm64 host, podman `applehv` Fedora 44 VM, kernel
  `7.2.7-200.fc44.aarch64`, 4 vCPUs.
- Capture: `aarch64-linux-gnu` build of this repository,
  `xsprof record --duration 1200 --output /tmp/real-vm.ndjson`, run as root
  inside the VM after setting the VM kernel's `perf_event_paranoid=1`.
- Workload: four busy `yes` loops plus repeated 8 MiB `dd` writes/removals to
  exercise scheduler switches, wakeups, migrations, and page faults.
- Full capture: **110,298 rows** — the 110,284 captured event rows
  (`94,152` switches, `54` wakeups, `15` migrations, `16,063` page faults over
  `1.201 s` on 4 CPUs) plus 13 prepended capability/marker rows and one
  appended `session_end` marker. Full-file sha256
  `f658213f58939f69f5a887b1211da5bf6cbb7c728111dd4a2ecc93b3c74a39a5`; the
  full capture is a release asset, not tracked here.
- Committed prefix: first **12,000 complete lines** (1,916,786 bytes, sha256
  `e266fcbc6ec41084eb32c2b59817b46dad93be08d89214eef5bd80295dad2006`) —
  7 capability rows, 6 marker rows, 10,478 `sched_switch`, 1,503
  `page_fault`, 6 `sched_wakeup`; it ends mid-run.
- Every row is canonical `xsprof/event/v1` with `host_mutation:false`.
- The console reads this capture as `REPLAY`, not as a live-host claim; header
  identity comes from the `ui_host`, `ui_kernel`, and `ui_arch` markers.

Every file here is generated from a real capture and is safe to replay
offline. Unexplained gaps are never filled, and no committed fixture claims
live-host data.
