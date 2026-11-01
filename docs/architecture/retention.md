# Retention measurement and the actual window

`qa/retention_bench.sh` measures the recorder on a disposable Linux VM. It
starts a root recorder with a real workload, then reports events/s,
bytes/event, RSS, loss, the covered wall window, and the window implied by the
configured byte budget.

## What was measured

Host: macOS 27 arm64, podman `applehv`, Fedora 44 aarch64, kernel
`7.2.7-200.fc44.aarch64`, 4 vCPU, 4 GiB RAM, `perf_event_paranoid=2` with
`CAP_PERFMON` as root.

```sh
sudo env XSPROF_BIN=/tmp/xsprof /tmp/retention_bench.sh 120000 0 2G yes
```

The 2-minute run:

| metric | value |
|---|---:|
| captured events | 17,324,079 |
| events/s | 144,360 |
| bytes/event | 160.5 |
| retained bytes | 2,142,981,215 (~2.0 GiB) |
| covered wall window | 92.36 s |
| sample loss / lost events | 0 / 0 |
| retention drops | 38 `retention_loss` markers |
| RSS | 8,008 KiB |
| recorder CPU | 7,532 bp of one CPU (~75.3%) |

The 2 GiB byte budget, not the 10-minute age cap, binds. At this host's
baseline 144k events/s the budget retains about 92 seconds. A hypothetical
50k events/s stream at the same 160.5 bytes/event would retain about 268
seconds (4.5 minutes), still short of ten minutes; ten minutes at 50k/s would
require roughly 71.6 bytes/event.

## The sidecar stall (fixed)

The first 60-second run captured only 2.02M events at 33k/s and counted
2.38M lost events. Each 16 MiB segment close re-read and re-parsed the whole
segment to build its sidecar while the perf rings kept filling, so every
rotation overflowed the rings.

The daemon now accumulates a per-segment `metrics.Index` while writing and
serializes the sidecar from that snapshot at rotation. The re-read is gone.
The same 60-second workload then captured 10.01M events at 166.8k/s with zero
loss markers and zero lost events.

## Limit of this evidence

The planned ten-minute run at 50k events/s was attempted but aborted with
`daemon: InputOutput`. The VM kernel logged `I/O error, dev vda` because the
host's root volume was full; this is a measurement-environment failure, not a
recorder loss result. Only the 120-second aarch64 Fedora result is accepted
here.

The Ubuntu 24.04 and x86_64 matrix was not available. Do not generalize the
aarch64 numbers to x86_64 without rerunning the harness there.

## Product decision

The 10-minute / 2 GiB claim is not made. Instead:

- the Capture screen shows the actual retained wall span (`X covered · cap Y`)
  from the manifest, never the configured cap;
- `incident` records both the requested and actually retained window, sets
  `window.trimmed` when the budget dropped history, and reports it in the
  static HTML;
- memory and archive behavior beyond the raw window is unchanged. Sidecars are
  written from the in-memory per-segment snapshot, but the console and advisor
  still analyze raw windows; sidecar history is not a query path yet.

Closing the ten-minute gap requires a compact wire form, tiered raw + sidecar
history, or both; that is a separate design, not a threshold change.
