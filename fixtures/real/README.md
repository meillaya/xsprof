# Real workload fixture

`scheduler-mix.ndjson` is a real `perf_event_open` capture, not synthetic data.

## Provenance

- Host: disposable Fedora 44 podman VM, kernel `7.2.7-200.fc44.aarch64`,
  4 vCPUs, tracefs mounted, `kernel.perf_event_paranoid=2`.
- Capture binary: `xsprof record --duration 350 --output /tmp/real.ndjson`,
  built for `aarch64-linux-gnu` from the same commit that added this fixture.
- Workload: two busy `yes` loops, a `find /usr | xargs -P 4 wc -c` walk, and
  `dd if=/dev/urandom of=/dev/null bs=64k` running concurrently.
- Captured 112,795 events at 350 ms. This fixture keeps the first 12,000
  complete NDJSON lines in timestamp order (1.8 MiB). It is a prefix, not a
  downsampled or interpolated stream.

## Expected shape

- 12,000 events, 4 CPUs, 4,574 switches, 206 wakeups, 40 migrations,
  7,180 minor faults, 0 loss markers.
- Every row is canonical `xsprof/event/v1` with `host_mutation:false`.
- The first event is a `sched_switch`; the prefix ends mid-run, so the last
  event may be any kind. Unexplained gaps are never filled.

This fixture exercises multi-process scheduler activity, page faults, and
multi-CPU lanes in tests and snapshots.

The console now identifies the recorder's own task (`xsprof`, `xsprof-*`) and
excludes it from rankings and wakeup-churn ratios; the captured rows themselves
are unchanged. That is why the demo no longer presents the profiler as the
hottest workload.

## VM fragmentation capture

`vm-fragmented.ndjson` is the first 12,000 complete lines of a fresh
`xsprof record --duration 500` capture from the same disposable Fedora 44
aarch64 podman VM, taken with four busy `yes` loops. It starts with the new
session metadata rows: `capture_owner` (the recorder pid), and
`host_memory buddy_fragmentation=0.614654`; the VM's cache topology was not
readable, so no `cpu_llc` rows were emitted and topology stays uncollected.

The fixture exists to prove the offline path end to end: the metadata survives
`capture --last`, the recorder task is excluded from workload churn, and
`advise --input` produces a measured `allocator-fragmentation` finding with the
buddyinfo evidence. It is a timestamp-ordered prefix, not an interpolated or
downsampled stream.

## macOS Linux VM capture

`macos-vm-sched.ndjson` is the full-fidelity capture used for the current
console demo video and live screenshots. It was captured on this Mac through
the disposable podman Linux VM, because macOS has no `perf_event_open` or
scheduler tracepoints.

- Host: macOS arm64 host, podman `applehv` Fedora 44 VM, kernel
  `7.2.7-200.fc44.aarch64`, 4 vCPUs.
- Capture binary: `aarch64-linux-gnu` build of this repository,
  `xsprof record --duration 1200 --output /tmp/real-vm.ndjson`, run as root
  inside the VM after setting the VM kernel's `perf_event_paranoid=1`.
- Workload: four busy `yes` loops plus repeated 8 MiB `dd` writes/removals to
  exercise scheduler switches, wakeups, migrations, and page faults.
- Raw result: **110,284 real events** (`94,152` sched switches, `54` wakeups,
  `15` migrations, `16,063` page faults) over **1.204 s**, 4 CPUs.
- Enrichment: real capability/marker rows were prepended (actual podman VM,
  kernel, CPU count, perf/tracefs/PMU state) and a `session_end` marker was
  appended. The 110,284 captured event rows are unchanged.
- Every row is canonical `xsprof/event/v1` with `host_mutation:false`.
- The file is the full capture, not a prefix or interpolation.
- Console source reads `REPLAY`; it is a replay of a real capture, not a live
  host claim. Header identity comes from the `ui_host`, `ui_kernel`, and
  `ui_arch` markers.

## Native live capture

The native console follows a recorder state directory exported from the
disposable Linux VM. The media under `design/media/xsprof-native-live-replay.*`
is an offscreen native render of a bounded excerpt of this real capture,
labelled REPLAY and `host_mutation:false`; it is not a real-window screen
recording. The VM's live recorder is exercised by `qa/live_smoke.sh`,
`qa/service_smoke.sh`, and `qa/retention_bench.sh`; evidence is under
`docs/evidence/v0.5.0-vm/`. The browser/SSE lane was removed in 0.5.0.
