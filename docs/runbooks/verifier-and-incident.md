# Verifier Rejection and Incident Runbook

Status: VM-only incident guide. It is documentation for a future lab harness, not permission to mutate the host.

## Incident classes

Use this runbook for verifier rejection, scheduler process exit, watchdog alert, cgroup-scope failure, lost SSH, SysRq-D debug collection, or SysRq-S fallback escalation.

## Mandatory identifiers

Every incident record must include:

- audit id for the attempted lab run;
- rollback id for the lab cgroup and process snapshot;
- VM-only lab tuple and kernel tuple;
- git SHA and BPF object hash if a verifier object exists;
- pre/post sched_ext state checks, or a reason the post check was unavailable.

## Verifier rejection

1. Stop before attach. A verifier rejection means the scheduler object is not approved for any attach path.
2. Record audit id, rollback id, object hash, verifier log path, and kernel release.
3. Capture pre/post sched_ext state checks to prove the scheduler was not attached.
4. Confirm no cgroup membership delta under `/sys/fs/cgroup/zig-scheduler-lab.slice/`.
5. Mark release status unsafe_to_assume until a new verifier log and review pass.

## Watchdog or scheduler process exit

1. Treat watchdog alarm or scheduler process exit as fail-closed.
2. Capture audit id and rollback id before collecting more logs.
3. Capture sched_ext state, enable_seq, nr_rejected, and any events file exposed by the VM kernel.
4. If fallback did not already occur, escalate to the fallback runbook and consider SysRq-S inside the VM-only lab profile.
5. Capture post sched_ext state checks and rollback evidence.

## Cgroup-scope failure

1. Refuse the run if the target is not below `/sys/fs/cgroup/zig-scheduler-lab.slice/`.
2. Record audit id and rollback id even for rejected attempts.
3. Capture the rejected target path and a pre/post sched_ext state check showing no attach occurred.
4. Do not repair scope by moving host processes; recreate the VM-only lab fixture instead.

## SysRq-D debug dump

SysRq-D is a diagnostic action for sched_ext debug dump collection. It does not terminate the BPF scheduler and does not replace SysRq-S fallback. Record audit id, rollback id, tracepoint/log path, and pre/post sched_ext state checks.

## SysRq-S fallback

SysRq-S is the emergency sched_ext fallback action referenced by the kernel documentation. Use it only inside the VM-only lab profile after recording audit id, rollback id, and pre sched_ext state checks. After it runs, capture post sched_ext state checks and the rollback transcript.

## Operator decision

Close the incident with one of these decisions: verifier rejected, fallback completed, rollback completed, evidence incomplete, or unsafe_to_assume. Any missing audit id, rollback id, VM-only marker, or pre/post sched_ext state checks blocks release progression.

## TUI-driven incident drill

The incident drill is exposed through the TUI key `i` and daemon action `incident_drill`. It simulates verifier rejection, scheduler process exit, lost runtime stream, rollback completion, and fallback completion in a controlled fixture or VM lab profile.

Manual QA command:

```bash
printf 'iq' | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --fixture fixtures/lab/preflight-ready.json \
  --screen sched-ext --width 120 --height 30 \
  --daemon-bin ./zig-out/bin/zig-scheduler-daemon \
  --daemon-state-dir .omo/evidence/tui-incident-daemon-state \
  > .omo/evidence/tui-incident-transcript.txt
```

Required evidence:

- TUI transcript contains `INCIDENT rollback/fallback drill`;
- daemon journal contains an `incident` event for `incident_drill` with `status=INCIDENT` and `host_mutation=false`;
- incident summary exists at `evidence/lab/incident-drill/tui-incident/summary.json`;
- incident journal exists at `evidence/lab/incident-drill/tui-incident/incident-events.jsonl`;
- rollback ledger validates with `python3 qa/audit_ledger_check.py --ledger evidence/lab/incident-drill/tui-incident/rollback-drill/audit-ledger.jsonl`.

A successful incident drill means the operator surface represented failure and rollback/fallback evidence. It does not authorize non-VM operation.
