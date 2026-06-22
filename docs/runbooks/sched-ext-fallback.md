# sched_ext Fallback Runbook

Status: VM-only runbook for future lab profiles. This project does not provide a host mutation path today. Fallback actions are staged inside disposable VM guests only.

## Scope

Fallback drills exist to prove that a future sched_ext attach profile can be unwound safely. They are not production host controls.

Allowed evidence:

- VM marker `/run/zig-scheduler-vm-lab.marker` from inside the guest;
- audit id and rollback id;
- pre/post sched_ext state and `enable_seq` inside the guest;
- rollback ledger and cleanup receipt;
- `host_mutation=false` for host-side orchestration.

Forbidden on the host:

- BPF load or attach;
- cgroup/cpuset writes;
- affinity or priority changes;
- scheduler-state writes;
- SysRq fallback actions.

## Fallback scenarios

Future VM-only drills should cover:

- verifier reject;
- attach refusal;
- scheduler process exit inside the guest;
- lost guest runtime stream;
- rollback success and rollback idempotence;
- cleanup residue detection.

## Manual direct-script check

Run VM scripts directly in host-safe mode unless a privileged disposable VM gate is explicitly enabled:

```bash
bash qa/vm/run_all_lab.sh --mode host-safe --out evidence/lab/run-all/manual-fallback --release-version 0.2.0-lab-manual
```

Review the summary for `host_mutation=false`, explicit `SKIP`/`REFUSE` outcomes on ordinary hosts, and cleanup receipts.

SysRq-S remains VM-only. If a future lab profile permits SysRq-S fallback, the transcript must prove the VM marker, audit id, rollback id, pre/post sched_ext state, and console command. The host path must not fire SysRq-S.
