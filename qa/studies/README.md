# Latency studies (release-bundle evidence)

Deterministic scheduler-latency scenarios that record real evidence with the
published `xsprof` binary and write a compact, reviewable bundle. They are
**evidence generators**, not CI equality gates: assertions are structural
(canonical schemas, non-empty scheduler evidence, `host_mutation=false`,
bounded cause/chain counters), never exact latency numbers, because scheduler
latency is noisy by nature.

The three scenarios are also the walkthrough inputs for
[latency forensics](../../docs/guides/latency-forensics.md). They complement
`qa/latency_smoke.sh --live` (one generic 3 s window) with repeatable workloads
that target a specific scheduler question.

| scenario | workload (bounded 4 s) | what it exercises |
|---|---|---|
| `pingpong.sh` | two shell processes alternate a token over named pipes; every `read` blocks off-CPU and every write wakes the peer | blocking wait → wakeup → wake-to-run latency; wakeup chains; futex-shaped wait/wake pairs without a compiler in the VM |
| `sleep_wake_burst.sh` | eight processes wait on short timers in parallel | timer wakeup bursts, runqueue wakeups, wakeup-to-run latency across CPUs |
| `cpu_hog_sleeper.sh` | two CPU-spinning shells plus two timer sleepers | forced preemption (`prev_state == running` switch-out) mixed with timer wakeups and off-CPU waits |

## Requirements

- Linux, root, readable sched tracefs (`/sys/kernel/tracing` or
  `/sys/kernel/debug/tracing`), and the permissions to open perf tracepoints.
- **A disposable VM/root context.** Live mode refuses to run unless
  `XSPROF_STUDY_VM_CONFIRM=1` is set, as an explicit certification that the
  caller is inside the write-scoped VM. Never run it on a production host; it
  does not change host policy, but it does create scheduler load and writes
  evidence files.
- GNU coreutils `sleep` with fractional seconds, `mkfifo`, and a POSIX `sh`
  (present in the VM image used by `tools/vm_lab.sh`).
- The published/staged `xsprof` binary (`--binary` or `$XSPROF_BIN`; default
  `<repo>/zig-out/bin/xsprof`).

Host-safe check (no root, no capture, no writes):

```sh
sh qa/studies/run_studies.sh --dry-run
```

## Run inside the disposable VM

```sh
# from the staged repository inside the VM, as root:
XSPROF_STUDY_VM_CONFIRM=1 sh qa/studies/run_studies.sh \
  --out /var/tmp/xsprof-studies
```

One scenario only:

```sh
XSPROF_STUDY_VM_CONFIRM=1 sh qa/studies/pingpong.sh \
  --out /var/tmp/xsprof-studies/pingpong-1 --binary /usr/bin/xsprof
```

The durable entry point is the VM lab (`tools/vm_lab.sh`). Until a `studies`
lane is wired there by the release owner, invoke this runner inside the lab
machine after a `probe` run keeps it alive, for example:

```sh
sh tools/vm_lab.sh probe --backend kvm-machine --keep
# ... then run the two commands above inside the machine's root shell
```

The VM-lab lane, when added, is one command:

```sh
sh tools/vm_lab.sh gates --backend kvm-machine --lanes studies
```

and the evidence lands under `dist/vm/evidence/<run-id>/`.

## Output

`run_studies.sh --out DIR` writes one directory per scenario plus a run
summary:

```text
DIR/<scenario>/evidence.json        compact machine report (single JSON line)
DIR/<scenario>/summary.txt          human-readable one-screen summary
DIR/<scenario>/window.ndjson        sanitized canonical window (xsprof/event/v1)
DIR/<scenario>/why.json             xsprof/why/v1 (off-CPU causes, preemption,
                                    critical chains, wakeup pairs)
DIR/<scenario>/why.txt              the same report as text (sections parsed
                                    for the structural counters)
DIR/<scenario>/metrics.json         xsprof/metrics/v1
DIR/<scenario>/incident/            window.ndjson, summary.json, report.html,
                                    trace.json (offline incident bundle)
DIR/<scenario>/daemon.* capture.*   recorder/first-pass logs (never secrets)
DIR/run-summary.json                xsprof/study-run/v1, PASS/FAIL per scenario
DIR/run-summary.txt                 human-readable run summary
```

`evidence.json` is the release-bundle index: scenario, binary version, kernel,
window row/event counts, switch/wakeup totals, off-CPU sample and cause totals,
preemption count, chain edges/roots, `host_mutation:false`, and
`status:"PASS"`. Attach the whole `DIR` (or its tarball) to the release
evidence; do not commit it (evidence corpora stay out of git).

## What is asserted, and what is not

Asserted for every scenario:

- the recorder/`why`/`metrics`/`incident` commands exit 0 and every artifact is
  non-empty;
- the wire schemas are the canonical `xsprof/why/v1`, `xsprof/metrics/v1`, and
  `xsprof/incident-summary/v1`;
- every captured row and every summary carries `host_mutation=false`; the
  incident `report.html` contains no external URL;
- `why` reports at least one `sched_switch` and non-zero events;
- structural bounds hold: cause totals ≤ off-CPU samples, preemptions ≤
  switches, chain roots ≤ chain edges, chain depth ≤ 8.

Not asserted: any p95/p99 number, specific task names, or that a given process
was preempted. Those depend on the VM's CPUs, kernel, and background noise, so
treat them as measurements to read, not thresholds to pass. For a pass/fail
gate use `qa/latency_smoke.sh --live` (structural) or `xsprof compare` with
repeated captures (noise-aware regression).

## Cross-tool validation methodology (manual evidence)

The studies are also the input for an honest cross-tool check against
`perf sched`, `bpftrace`, and `strace`; this is **manual evidence, not a CI
equality gate**, because the tools measure different things:

1. Record the same workload with the same bounded duration on the same VM.
2. `perf sched record` + `perf sched latency` gives per-task scheduler wait
   statistics; compare *rank order and direction* of the top tasks with
   `xsprof why` (never absolute numbers across tools).
3. If the VM provides `bpftrace` and the root that BPF needs there, run
   `runqlat.bt`/`offcputime.bt` for the same window and compare the shape
   (which wait bins dominate, whether a stack-backed blocker explains the
   off-CPU total) with `xsprof why`'s off-CPU causes.
4. `strace -f -c` explains *which syscalls* blocked a task; it is not a
   cross-check of scheduler wait time. Use it only to name the syscall behind
   an off-CPU cause, with its known ptrace overhead in mind.
5. Record the commands, VM kernel, and observed direction of agreement in the
   release evidence. Do not publish a numeric agreement claim without the
   transcript; without a transcript it stays unverified.

Known differences that the comparison documents rather than hides: xsprof
records tracepoints (no kernel stacks), reports histogram-bucket p95 upper
bounds, and the VM's noise is real; `perf sched` and `bpftrace` have their own
overhead and sampling semantics. See
[docs/guides/latency-forensics.md](../../docs/guides/latency-forensics.md) for the
operator-facing comparison table.

## Notes

- No network, no host policy writes, no host `/proc`/`/sys` writes, and no
  privilege escalation: every write stays under `--out` (and the VM lab's
  scoped directories).
- Evidence contains task `comm` names and scheduler events, not argv or
  environment; the canonical serializer redacts `key=value` secrets. Treat the
  output as private host data anyway.
