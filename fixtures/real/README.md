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
