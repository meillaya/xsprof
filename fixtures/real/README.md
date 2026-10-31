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
