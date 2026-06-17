# sched_ext Fallback Runbook

Status: VM-only runbook for future lab profiles. This project does not provide a host mutation path today. The first-class live operator flow starts from `zig build tui-live-vm` or `zig build tui -- --interactive --screen vm-lab ...`; fallback actions are then staged inside the disposable VM guest.

## Scope and prohibitions

- VM-only: use this runbook only inside a disposable lab VM whose kernel tuple and git SHA are recorded.
- Do not load, attach, enable, mutate, or apply a scheduler on the operator host.
- Do not write cgroup, cpuset, affinity, priority, `/proc/sys`, or BPF state outside the approved VM-only lab profile.
- Every drill requires an audit id, rollback id, operator, git SHA, kernel release, and lab tuple.

## Required evidence before any lab action

Record the following in the lab manifest before the run starts:

1. audit id: `AUD-YYYYMMDDTHHMMSSZ-<gitshort>-<random6>`.
2. rollback id: a rollback snapshot identifier tied to the lab cgroup scope.
3. pre sched_ext state check: read `/sys/kernel/sched_ext/state` and `/sys/kernel/sched_ext/enable_seq` inside the VM.
4. pre cgroup-scope check: record the target cgroup under `/sys/fs/cgroup/zig-scheduler-lab.slice/` only.
5. VM-only warning acknowledged by the operator.

## Fallback triggers

Use the fallback procedure if any of these occur in the VM-only lab:

- scheduler process exit;
- verifier rejection or verifier log uncertainty;
- stalled runnable tasks or watchdog alarm;
- cgroup-scope failure or target outside the allowlist;
- lost SSH or lost operator TUI session;
- kernel reports `nr_rejected` growth or unexpected sched_ext state;
- operator initiates SysRq-S fallback.

## Procedure

1. Freeze the evidence clock: record audit id, rollback id, timestamp, kernel release, and git SHA.
2. Capture pre/post sched_ext state checks: read `/sys/kernel/sched_ext/state`, `/sys/kernel/sched_ext/enable_seq`, and `/sys/kernel/sched_ext/root/ops` when available.
3. If the scheduler process is still running, terminate only the VM lab scheduler process using the lab harness control channel. Do not run host mutation commands.
4. If the VM remains responsive and the lab profile explicitly allows it, use SysRq-S to request sched_ext fallback. SysRq-S is the sched_ext abort/fallback sequence; record the exact lab console transcript.
5. If debug data is required and the VM remains responsive, use SysRq-D to request a sched_ext debug dump. SysRq-D is for diagnostics and does not replace fallback.
6. Apply the rollback id inside the VM-only lab harness. The rollback must restore the lab cgroup membership and scheduler process state recorded before the run.
7. Capture post sched_ext state checks: `/sys/kernel/sched_ext/state`, `/sys/kernel/sched_ext/enable_seq`, `nr_rejected`, and the target cgroup membership snapshot.
8. Mark the run failed closed unless the release owner reviews the audit id, rollback id, verifier log, pre/post sched_ext state checks, and VM-only transcript.

## Lost SSH or hung TUI

- Treat lost SSH as a failed lab drill, not a reason to mutate the host.
- Use the VM console or harness power controls to capture a screenshot/log, then stop the VM.
- Record audit id, rollback id, last pre sched_ext state check, and whether post sched_ext state checks were unavailable.

## Completion criteria

The fallback drill is complete only when the evidence bundle contains audit id, rollback id, VM-only marker, verifier/debug log if applicable, pre/post sched_ext state checks, cgroup-scope snapshot, and operator decision. Missing evidence means unsafe_to_assume.

## TUI-driven rollback and fallback controls

Rollback and fallback drills must be visible from the TUI/daemon path, not only from direct scripts. In test mode, `m` requests a fresh disposable microVM run, `s` asks for a safe stop, `b` asks for rollback confirmation, and stale or duplicate target ids refuse instead of mutating host scheduler state.

Manual QA command for the live rollback control surface:

```bash
printf 'mbbq' | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --screen vm-lab --width 120 --height 30 \
  --daemon-bin "./zig-out/bin/zig-scheduler-daemon" \
  --daemon-state-dir ".omo/evidence/tui-rollback-daemon-state" \
  > ".omo/evidence/tui-rollback-transcript.txt"
```

Review `.omo/evidence/tui-rollback-daemon-state/events.jsonl` for `rollback_completed`, `status=PASS` or `already_rolled_back`, and `host_mutation=false`. Missing target action id, missing rollback id, or stale rollback id must show a refusal instead of attempting host scheduler changes.

SysRq-S remains VM-only. If a future lab profile permits SysRq-S fallback, the transcript must prove the VM marker, audit id, rollback id, pre/post sched_ext state, and console command. The host TUI path must not fire SysRq-S.
