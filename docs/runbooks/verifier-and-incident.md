# Verifier and Incident Runbook

This runbook covers VM-only verifier evidence and controlled incident drills. The root host remains fail-closed: no BPF load, sched_ext attach, cgroup write, affinity write, priority write, or scheduler-state mutation is available from ordinary host commands.

## Verifier-only evidence

Build or skip the minimal BPF object:

```bash
zig build bpf --summary all
```

Run verifier-only host-safe refusal or VM-gated evidence:

```bash
bash qa/vm/verifier_only.sh --object zig-out/bpf/zigsched_minimal.bpf.o --out evidence/lab/verifier-dev
```

On an ordinary host the script must refuse or skip with `host_mutation=false`. Inside a disposable VM with `/run/zig-scheduler-vm-lab.marker`, it may collect verifier logs and pre/post sched_ext state evidence.

## Incident drill requirements

Incident drills should be first-class evidence records with:

- explicit scenario name;
- audit id and rollback id where applicable;
- VM marker when any mutation-capable guest action is involved;
- no private raw logs, credentials, or host-specific secrets;
- rollback/fallback outcome;
- cleanup receipt;
- `host_mutation=false` for host orchestration.

Use direct VM/lab scripts for current checks:

```bash
bash qa/vm/run_all_lab.sh --mode host-safe --out evidence/lab/run-all/incident-dev --release-version 0.2.0-lab-incident-dev
```

Review generated summaries and ledgers before treating the incident drill as evidence. Host-safe SKIP/REFUSE output is acceptable for default CI but is not VM-live proof.
