# Retention model and measured windows

The recorder has two tiers:

1. **Raw tier** — append-only compact `.xsraw` segments under a byte budget
   (`--max-bytes`) and an age cap (`--retain`). The cap is an upper bound; the
   byte budget can bind first, and higher event rates shorten the covered span.
2. **History tier** — bounded metrics sidecars every `--history-interval`
   (default 60 s), retained for `--history-retain` (default 24 h). Aggregates
   survive raw drops; they are not event detail.

The recorder and `verify` report the **actual** covered wall span from the
manifest (`X covered · cap Y`), never the configured cap. Extracting data older
than the retained window emits a `retention_loss` marker instead of zero-filling.

## Compact raw tier

`0.4+` stores raw events in compact `.xsraw` segments
([raw-segment-v1.md](raw-segment-v1.md)): 64-byte header, CRC-32C blocks,
block-local comm tables, ~12–13 bytes/event versus ~160 bytes/event for
canonical NDJSON. The default 2 GiB budget therefore usually lets the
ten-minute age cap bind; the byte budget remains the safety backstop for high
rates or larger event text. Segments rotate at 16 MiB or 30 s; retention plans
which closed segments are over the byte/age budget, then deletes the oldest
prefix. A failed delete is not silent: the manifest entry is kept, one
`retention_loss … delete_failed=1 path=… error=…` marker is written for that
attempt, and the next rotation retries. An entry whose file is already gone is
dropped rather than retried forever.

At startup the daemon reconciles the segment directory with the manifest: any
unmanifested `.xsraw` file is adopted chronologically (a clean footer is trusted
without decoding; a dirty/corrupt tail is decoded for its complete prefix) and
the session records one
`capture_recovered_orphan adopted=… dirty=… corrupt=… unreadable=…` marker.
Unknown files are never deleted or rewritten. The manifest rename is fsynced at
the file and state-directory level, and `verify` compares each segment footer's
event/block counts against the decoded payload; a mismatch is `REFUSE` with an
explicit `footer_mismatch` reason rather than READY.

## Measured result (disposable KVM VM)

A 10-minute recorder run in a disposable KVM Fedora CoreOS VM
(kernel 7.2, 4 vCPU/4 GiB, `/dev/kvm`) measured:

| metric | value |
|---|---:|
| duration | 600,000 ms |
| events retained | 51,912,224 |
| event rate | 86,517 events/s |
| compact bytes/event | 12.06 |
| retained bytes | 625,946,419 |
| covered raw window | 600.01 s |
| retained loss | 0 |
| `retention_loss` markers | 0 |
| history events / lost | 51,912,222 / 0 |
| sidecars | 10 |
| recorder RSS | 12,928 KiB |
| recorder overhead | 6,148 basis points of one CPU |
| canonical bytes/event (same VM) | 160.10 |
| canonical/compact ratio | 13.28x |

The age cap bound before the byte budget at this rate (projected ~2,058 s of
raw coverage at 12.06 B/event). The same VM passed the live-capture and
service gates: 93,534 recorded rows with a clean SIGTERM, and 3 compact
segments with 421,068 extracted lines including lock refusal and SIGKILL
recovery.

These measurements are environment-specific (one VM, one kernel, one
workload). The committed repository does not carry the VM logs or benchmark
output: those are kept as release/CI artifacts. Rerun the harness on
new hardware/builds before generalizing the numbers.

## Acceptance thresholds

The root-only retention gate is part of `check-vm`:

```sh
./tools/zig build check-vm          # on a disposable KVM Linux VM, as root
# equivalent: qa/retention_bench.sh 600000 0 2G yes
```

It must report **compact bytes/event ≤ 25.6** (hard), **covered_s ≥ 590**, no
retained loss events, and a canonical/compact ratio **≥ 4x** measured from a
same-VM canonical sample. The gate also verifies that the manifest reports the
real covered span and that history-sidecar loss stays under the configured
target. A failure is a retention regression, not a warning.

## The sidecar stall (fixed, kept as a regression note)

The original sidecar path re-read each 16 MiB segment at rotation while perf
rings kept filling, so every rotation overflowed and lost events (2.38M lost in
60 s in the first measurement). The daemon now accumulates a per-segment metrics
index while writing and serializes the sidecar from that snapshot; rotation no
longer re-reads. Do not reintroduce a rotation-time re-read.

## Incident windows

`incident` streams its window to disk and scans the whole window with bounded
memory. The canonical window artifact and the Chrome Trace prefix are bounded
(`--max-window-bytes`, trace capped at 200,000 events); when a bound trims the
trace, `summary.json` and the report set `trace.truncated` and say so. A
613 MB, 4,020,874-event window was bundled successfully on the KVM VM with
explicit truncation caveats.

## Practical guidance

- Watch the reported covered span; raise `--max-bytes` only if the event rate or
  event text grows.
- On high-rate hosts the raw tier is seconds-to-minutes; use the history tier
  for long-horizon trends and `capture --last` for detail.
- Never mix numbers measured under a different compact format, sidecar cadence,
  or event-rate profile without saying so.
