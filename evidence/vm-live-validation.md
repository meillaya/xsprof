# VM-Lab Live Collection Validation

**Status:** PASS — xsprof captures real live scheduler and memory events when privileged.
**Date:** 2026-07-20 · **Host kernel:** 7.1.3-2-cachyos · **VM kernel:** 6.18.38 (nixpkgs)

## What this proves

The deeper code review found that the perf ring-buffer **live-capture loop was not wired
end-to-end** (the collectors could probe and poll `/proc`, but nothing produced a live event
journal). A `record` command backed by a new `live_capture` module was implemented and validated
here in a disposable microVM (the host stays fail-closed at `perf_event_paranoid=2`).

## Environment

- QEMU 11.0.1 + KVM (`/dev/kvm`), 4 vCPU, 1 GiB RAM, `-cpu host`.
- Kernel `linux-6.18.38` bzImage + minimal initramfs (static busybox + xsprof + runtime closure).
- Inside the VM (root): `perf_event_paranoid` lowered `2 -> -1`, tracefs mounted.
- Reproduce: `bash qa/vm-cpp/run_vmlab.sh` (full console log: `evidence/lab/vm-live-capture/run.txt`).

## Results (representative run)

Capabilities flip from SKIP (host) to **READY** (privileged VM):

```
perf_event READY (paranoid=-1) · sched_tracepoints READY · btf READY · sched_ext READY · pmu READY (7 devices)
```

Live capture summary for a 2-second window:

```json
{"capability":"READY","duration_ms":2000,"events_captured":655,"host_mutation":false,
 "lost_samples":0,"page_faults":63,"sched_migrations":4,"sched_switches":391,
 "sched_wakeups":197,"schema":"xsprof/capture-summary/v1"}
```

Sample captured events (real kernel threads via `sched:sched_switch` tracepoint):

```json
{"comm":"rcu_tasks_trace","cpu":1,"event":"sched_switch","host_mutation":false,"pid":0,"ts_ns":247748625}
{"comm":"swapper/1","cpu":1,"event":"sched_switch","host_mutation":false,"pid":45,"ts_ns":247752245}
{"comm":"kcompactd0","cpu":1,"event":"sched_switch","host_mutation":false,"pid":0,"ts_ns":558766830}
```

The live journal reconstructs into a Chrome-Trace timeline (`xsprof timeline --input <journal>`):
`{"displayTimeUnit":"ns","journal_rows":655,"traceEvents":[ ... per-CPU sched slices ... ]}`.

## Invariants preserved

- `host_mutation=false` on every captured record and capability event.
- Fail-closed: on the unprivileged host `xsprof record` reports `SKIP` and exits non-zero, capturing
  nothing (covered by `tests/live_capture_tests.cpp`). No host elevation is ever attempted.
- Privacy: captured `comm` is bounded; runtime samples never carry argv/env/secrets.

## End-to-end pipeline now proven

`perf_event_open tracepoints + software events -> ring-buffer capture -> correlate -> JSONL journal
-> Chrome-Trace timeline`, capability-gated and fail-closed.
