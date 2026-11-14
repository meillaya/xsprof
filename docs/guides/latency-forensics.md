# Latency forensics: from capture to root cause

This guide walks an operator through one scheduler-latency incident using the
shipped evidence tooling: record the window, explain it with `why`, read the
off-CPU cause and the wakeup chain, then decide with `compare`. It also states
honestly what each step cannot tell you and how the approach differs from
`perf sched`, `bpftrace`, and `strace`.

All commands are read-only: `xsprof` never writes scheduler or memory policy,
never opens a network socket, and every serialized record carries
`host_mutation=false`. Capture itself needs privileges (see
[recording permissions](capture-permissions.md)).

For the vocabulary of `a`/`b`/`c`/`comm` fields on each event kind, read
[event field semantics](../architecture/events.md). For the recorder lifecycle,
read [flight recorder](flight-recorder.md); for individual-capture reports,
read [top & why](top-why.md).

## 1. Capture the incident window

A flight recorder keeps the last bounded window, so the capture step after the
incident is an extraction, not a new recording:

```sh
# long-lived on the production host (see flight-recorder.md and install.md)
sudo xsprof daemon --foreground --dir /var/lib/xsprof --retain 10m --max-bytes 2G

# after the slow response, extract the retained window
sudo xsprof capture --last 5m --dir /var/lib/xsprof --out incident.ndjson
```

`capture` writes canonical `xsprof/event/v1` NDJSON and emits explicit markers
for loss, corruption, torn tails, or a trimmed window. If the window was
trimmed, `why` says so and numbers are lower bounds — never treat a trimmed
window as complete data.

For a reproducible lab incident, the deterministic workload drivers in the
[study harness](../../qa/studies/README.md) produce the same shape of evidence
inside a disposable VM:

```sh
XSPROF_STUDY_VM_CONFIRM=1 sh qa/studies/run_studies.sh --out dist/studies
```

## 2. Explain it with `why`

```sh
xsprof why --input incident.ndjson
xsprof why --input incident.ndjson --json > why.json
xsprof why --input incident.ndjson --pid 1234        # focus one task
xsprof why --input incident.ndjson --comm worker     # focus one comm
```

The text report starts with the window header and the causal-latency summary:

```text
xsprof why  source=incident.ndjson  window=...ms  events=... malformed=...
switches=... wakeups=... migrations=... faults=.../... lost=... out_of_order=...
latency: offcpu_samples=... offcpu_unresolved=... causes=... preemptions=... \
  preempt_unresolved=... chain_edges=... chain_roots=... chain_cycles=... \
  chain_depth_cuts=... chain_truncated=no
```

Then it prints four sections that did not exist before v0.7, plus the advisor
insights:

- `TOP WAIT TASKS` — per-task p95/p99 wakeup-to-run and off-CPU p95;
- `WAKEUP CHAINS (waker -> woken)` — who wakes whom, with counts and p95 wait;
- `OFF-CPU CAUSES` — blocked time attributed to the switch-out `prev_state`;
- `PREEMPTION` — involuntary switch-outs and their counted p95;
- `CRITICAL CHAINS` — ranked wakeup paths from a root to a leaf task.

The same data in canonical `xsprof/why/v1` JSON (schema:
[why.v1.schema.json](../../schemas/xsprof/why.v1.schema.json)) lives under
`latency`:

| field | meaning |
|---|---|
| `latency.offcpu_samples` | switch-out samples where a blocked state could be measured |
| `latency.offcpu_unresolved` | switch-outs with no usable cause/duration in this window — **unknown, not zero** |
| `latency.causes[]` | `reason` (`interruptible`, `uninterruptible`, `idle`, `other`, `unknown`, ...), `count`, `total_us` |
| `latency.preemptions` | involuntary preemptions detected (running-state switch-out, no intervening wakeup) |
| `latency.preempt_p95_us`, `latency.preempt_unresolved` | preempted wait p95 upper bound; unresolved count |
| `latency.chains[]` | `root_pid`, `leaf_pid`/`leaf_comm`, `depth`, `count`, `total_wait_us`, `p95_wait_us` |
| `latency.chain_edges`, `chain_roots`, `chain_cycles_cut`, `chain_depth_cut`, `chain_truncated` | bounded chain counters; cuts are counted, never silently dropped |
| `pairs[]` | `waker_pid`/`waker_comm` → `woken_pid`/`woken_comm`, `count`, `p95_wait_us` |

### Off-CPU cause: why was the task not running?

Read the `OFF-CPU CAUSES` section first. It answers the first forensic
question — was the task blocked in an interruptible sleep (`interruptible`),
stuck in uninterruptible I/O (`uninterruptible`), parked/stopped, or merely
preempted (`preempted`)? The same attribution is grouped per task in
`metrics.json` as `offcpu_by_reason`.

On a committed fixture this is directly reproducible without a VM:

```sh
xsprof why --input fixtures/ui/latency-mixed.ndjson
```

The committed `why` golden keeps that report byte-stable, so the section
headers and field names above are not hand-waving examples — they are the
shipped output. The fixture is synthetic and says nothing about a real host;
its numbers are illustrative only.

Two honest caveats: the cause is the kernel's *switch-out state*, not a
blocking syscall or a stack; and `offcpu_unresolved` counts samples the window
could not attribute. If `offcpu_unresolved` is large, the report is partial —
do not read the cause totals as a complete breakdown.

### Wakeup chain: what was on the critical path?

`pairs[]` gives direct waker→woken edges. `latency.chains[]` follows those
edges transitively and ranks the accumulated wait, so you can ask "which root
wakeup delayed this leaf task the most?" Each chain is bounded: depth ≤ 8,
cycles are cut (`chain_cycles_cut`), and an edge past the bound increments
`chain_depth_cut`. A root whose own waker was not in the window is a lower
bound, not a measurement of zero.

### Preemption: was the task runnable but not running?

`latency.preemptions` counts switch-outs with `prev_state == running` that
resumed without an intervening wakeup — the task was runnable and got the CPU
taken away. `preempt_p95_us` is an upper bound from the same log2 histogram
buckets as the wait metrics. `preempt_unresolved` counts preemption waits whose
resume was not observed; they stay unknown.

## 3. Bundle the evidence

```sh
xsprof incident --last 10m --dir /var/lib/xsprof --out incident/
xsprof verify --dir /var/lib/xsprof --json
```

The folder is self-contained and offline: `window.ndjson`, `summary.json`
(including the causal-latency section), `report.html` (inline CSS, no scripts,
no external requests), and `trace.json` for Perfetto/`chrome://tracing`. Use
this as the artifact attached to the ticket; `why` is for reading, `incident`
is for keeping.

## 4. Decide with `compare`

Latency is noisy, so a single capture is a quick check, not a decision. Repeat
the workload on each side (1–8 captures per side), then gate on the causal
metrics with the noise-aware fork of `compare`:

```sh
xsprof compare \
  --base baseline-1.ndjson --base baseline-2.ndjson --base baseline-3.ndjson \
  --candidate cand-1.ndjson --candidate cand-2.ndjson --candidate cand-3.ndjson \
  --min-runs 3 \
  --fail-on wait.p95=15% --fail-on offcpu.p95=10% --fail-on preemptions=10 \
  --fail-on loss=0 \
  --json > compare.json
```

Exit codes: `0` no gate failed, `1` data error or a gated signal with no
comparable samples (unknown is not a pass), `2` usage error, `3` a regression
passed both the threshold and the observed noise floor. In `compare.json`
(`xsprof/compare/v1`), `base_runs`/`candidate_runs`, `delta_pct`, `noise_pct`,
`regression`, and `fail_reasons` are the decision fields; missing values are
`null`, never fabricated zeros. The full method, thresholds, and honest limits
are in [compare captures in CI](compare-ci.md).

## Importing an existing `perf script` trace (v0.7 interop)

If the incident was already recorded with `perf`/`perf sched` and converted to
text, the strict importer converts the supported lines into canonical events
instead of asking for a re-record:

```sh
# record only the two tracepoints the importer supports (perf sched record
# also captures migration/fork/exit events, which the strict subset refuses):
perf record -e sched:sched_switch -e sched:sched_wakeup -- sleep 3
perf script -i perf.data > trace.txt
xsprof import --perf-script trace.txt > converted.ndjson
xsprof why --input converted.ndjson
```

The accepted grammar is deliberately narrow: the default `perf script` line
layout (`comm`, sample pid, `[cpu]`, `sec.usec` or `--ns` `sec.nsec`,
`sched:sched_switch`/`sched:sched_wakeup`, then the exact `TP_printk` payload),
printable ASCII comms, and no custom `-F` layouts. Unsupported events and any
payload deviation fail closed with line numbers and a bounded diagnostic count;
the importer never guesses. The exact grammar, the `R+` normalization, and the
bounds are documented at the top of
[`src/viz/perf_script_import.zig`](../../src/viz/perf_script_import.zig). This is
the v0.7 automation surface: if `xsprof help --all` on your build does not list
`import`, the wiring is not present — convert with the recipe from the
matching release notes instead.

## How this compares with `perf sched`, `bpftrace`, and `strace`

The tools answer overlapping but different questions. All statements below are
about the tools' documented model of operation; no benchmark numbers are
claimed here.

| question | xsprof (`record`/`daemon` + `why`/`compare`) | `perf sched` | `bpftrace` runqlat/offcputime | `strace` |
|---|---|---|---|---|
| who waited for the CPU, how long | yes: per-task p95/p99/off-CPU, log2 histograms | yes: `perf sched latency`/`timehist` reports wait stats | yes: histograms of run-queue latency / off-CPU time (with stacks) | no: syscall time, not scheduler wait |
| why a task was off-CPU | bounded `prev_state` cause + unresolved counter | partly: state in `perf sched timehist -w` context | offcputime groups by kernel stack; no state-cause table by default | names the blocking syscall (when traced) |
| wakeup chain / critical path | yes: bounded transitive chains, counted cuts | limited: wakeup/schedule events, no ranked chain report | needs a custom script; the stock tools report a single task/histogram | no |
| preemption cost | yes: involuntary switch-outs, counted p95, unresolved | partial: `perf sched` shows scheduling context, not a preemption-cost table | custom script required | no |
| output format | canonical schema-validated JSON + offline HTML/trace bundle | human text / `perf.data` tooling | free-form script text | free-form text |
| regression decision | `compare`: repeated runs, empirical noise floor, exit codes | manual comparison of two runs | manual comparison of two runs | manual comparison of two runs |
| needs on the host | read-only perf tracepoints; recorder runs as a service | perf binary + perf.data file | root + BPF + `libbpf`/tracefs; xsprof gates BPF to the VM and refuses it on the host by design | ptrace + per-syscall overhead |
| stacks / call graphs | no: tracepoint attribution, not stacks | no (scheduler tracepoints only) | yes, offcputime/runqlat can attach kernel stacks | no |
| committed evidence shape | schema + golden bytes + QA gates | not a schema | not a schema | not a schema |

Practical translation notes:

- `perf sched latency` and `xsprof why` rank tasks by scheduler wait. Compare
  *rank order and direction*, not absolute numbers: they group by different
  keys (perf by pid/comm across its recorded events, xsprof by `comm` for
  `compare` and by pid for the window report) and use different histograms.
- `bpftrace` `offcputime` answers "which stack blocked" (a superset in stack
  detail xsprof does not collect); `xsprof` answers "what scheduler state and
  which wakeup chain" with canonical JSON that other tooling can validate.
  If both are available in the disposable VM, treat them as complementary
  evidence and record the commands, kernel, and observed direction of
  agreement — see the manual cross-tool methodology in the
  [study harness README](../../qa/studies/README.md).
- `strace` is not a substitute: it explains syscalls, not scheduler wait, and
  its ptrace overhead changes the workload it measures.
- xsprof's BPF gate is VM-marker-gated and host-refused by design; a host
  `xsprof` will not run `bpftrace`-style probes for you. That is a safety
  property, not a missing feature to work around on a production host.

## Known limitations

- **Tracepoints, not stacks.** The capture path records scheduler tracepoints.
  There is no kernel-stack/call-graph attribution in `why`; when you need the
  blocking stack, pair the evidence with a stack profiler in the VM.
- **Bucket granularity.** p95/p99/max are upper bounds from bounded log2
  histograms (coarse powers of two); small deltas inside one bucket can show as
  0%. `compare` is built on the same buckets.
- **Noise is measured, not eliminated.** The `compare` noise floor is the
  observed run-to-run spread and says nothing about runs not taken. A noisy
  baseline can hide a real regression; an unlucky run can look like one.
- **Unknown stays unknown.** Lost, corrupt, trimmed, or out-of-window data is
  reported as loss/unresolved/`null`, never zero-filled. A large
  `offcpu_unresolved`/`preempt_unresolved`/`chain_depth_cut` means the report
  is partial; fix retention or widen the window instead of reading it as data.
- **PID reuse and cross-window edges.** Correlation is best-effort across the
  captured window: a wakeup whose switch-in falls outside the window, or a pid
  reused after a task exited, limits chain attribution. The chain counters and
  `pairs_truncated` exist to keep that visible.
- **Single-domain matching.** `compare` matches by `comm` because PIDs churn;
  different workloads with the same comm can be compared as if they were the
  same task family, so keep the workload identical across sides.
- **Import subset.** The `perf script` importer accepts only the documented
  default-layout subset (two sched events, printable ASCII comms); it does not
  reconstruct lost-event records or custom field layouts, and `R+` preemption
  is normalized to the canonical running state. Files outside the subset are
  refused with line diagnostics instead of partially imported.
- **Read-only by design.** xsprof never applies an advisor recommendation,
  never tunes the scheduler, and never suggests privilege escalation; fixing
  the cause is still an operator decision.

## Next

- [top & why](top-why.md) — reading one capture
- [compare captures in CI](compare-ci.md) — noise-aware regression gates
- [flight recorder](flight-recorder.md) — bounded capture, retention, bundles
- [study harness](../../qa/studies/README.md) — reproducible latency evidence
- [event field semantics](../architecture/events.md) — exact field meanings
- [recording permissions](capture-permissions.md) — making capture READY
