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
sudo env KEEP=1 XSPROF_BIN=/tmp/xsprof /tmp/retention_bench.sh 600000 0 2G yes
```

The 10-minute run:

| metric | value |
|---|---:|
| captured events | 83,908,179 |
| events/s | 139,845 |
| bytes/event | 160.27 |
| retained bytes | 2,132,270,939 (~2.0 GiB) |
| covered raw wall window | 94.44 s |
| sample loss / lost events | 0 / 0 |
| retention drops | 128 `retention_loss` markers |
| RSS | 9,668 KiB |
| recorder CPU | 7,387 bp of one CPU (~73.9%) |

The 2 GiB byte budget, not the 10-minute age cap, binds. At this host's
baseline 140k events/s the raw budget retains about 94 seconds. A hypothetical
50k events/s stream at the same 160.3 bytes/event would retain about 268
seconds (4.5 minutes); ten minutes of raw events at 50k/s would require about
71.6 bytes/event.

The sidecar tier fills that gap. The same retained state, queried with
`history --last 10m`, returned 774 sidecars, 81,409,933 events, 74,900,659
switches, and 3,278 lost events out of 81.4M (0.004%). The sidecar history
covers the full ten-minute request even though raw retention keeps only the
last 94 seconds.

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

The run was 10 minutes at the host's natural 140k events/s, not a
rate-controlled 50k events/s run. The VM has no event-rate throttle; even an
idle capture runs near 145k events/s. The 50k projection above is arithmetic
from the measured bytes/event, not a separate run.

The Ubuntu 24.04 and x86_64 matrix was not available. Do not generalize the
aarch64 numbers to x86_64 without rerunning the harness there. This is an
external environment limit, like the notarization credential gate, not a
threshold decision.

## Product decision

The product is now a two-tier window:

- the Capture screen shows the actual retained wall span (`X covered · cap Y`)
  from the manifest, never the configured cap;
- the raw tier is bounded by the byte budget (~94 seconds here);
- the sidecar tier is the 10-minute history query: `xsprof history --last 10m
  --dir <state>` aggregates per-segment metrics across raw drops, with 0.004%
  lost events in the measured run;
- `incident` streams `window.ndjson` to disk, scans the whole window with a
  bounded-memory analyzer, and keeps at most 200,000 trace events. A 613 MB,
  4,020,874-event window was bundled on the same VM with two findings and a
  `trace.truncated:true` caveat, so there is no 192 MiB refusal.

The raw tier still does not hold ten minutes at 50k events/s. That would need a
compact wire form; it is a separate design, not a threshold change. The ten
minutes are available through history, not through the raw file.
