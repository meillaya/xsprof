# sched_ext Governance Gate

This governance gate defines the evidence required before `zig-scheduler` may move beyond path-to-production language.

## Required status before any production claim
The release status remains `path-to-production` until all checks below pass. A successful gate may at most authorize `controlled_lab_pilot_candidate` unless a future owner explicitly approves broader scope.

## Required evidence bundle
A candidate release must provide:

1. Kernel tuple manifest for every supported lab target.
2. BPF verifier log for the scheduler object.
3. VM-only partial-switch attach transcript.
4. Cgroup allowlist proof showing no root/system cgroup attach.
5. Rollback snapshot and rollback drill transcript.
6. Audit ID, operator identity, git SHA, and rollback ID for every mutation-capable run.
7. Stress/chaos evidence for workload liveness and fallback behavior.
8. VM-live scheduler behavior bundle validated by `qa/live_behavior_check.py`, proving the result is not attach-only success.
9. Security threat model and completed security review checklist.
10. Packaging/default-service proof that install does not auto-start or mutate scheduler state.
11. Wording audit proving no unguarded production-ready or arbitrary-production-host claim.

## Production evidence matrix
The current release summary must keep `release_status=controlled_lab_pilot_candidate`,
`production_ready=false`, and `arbitrary_host_safe=false`. Any future status change beyond the controlled lab pilot requires every row below
to be complete, current for the release git SHA, reproducible, and reviewed.

| Evidence category | Required proof before any future production-ready status |
| --- | --- |
| Kernel tuple matrix | Supported kernel tuple matrix with architecture, kernel release, config hash, BTF state, sched_ext state, and repeat count. |
| Verifier logs | BPF object hash, source hash, verifier log, parsed verifier status, and structured failure reasons for every tuple. |
| VM attach evidence | VM-only partial-switch attach transcript proving the root host path did not load or attach. |
| Rollback drills | Reproducible rollback drill transcript, before/after scheduler state, rollback ID, and fallback success. |
| Stress/chaos | Stress/chaos evidence for workload liveness, fallback behavior, no starvation threshold breach, and no repeated reject counters. |
| Audit ledger | Append-only audit ledger validation with unique audit IDs, immutable artifact hashes, and duplicate-replay rejection. |
| Security signoff | Signed security signoff against the tracked threat model and security review checklist. |
| Package install safety | Package install safety drill in a staging root or disposable VM proving no host mutation and no service enablement. |
| Package upgrade safety | Package upgrade safety drill proving config preservation, evidence archive preservation, and rollback of staged files. |
| Package uninstall safety | Package uninstall safety drill proving non-config files are removed while audit/evidence archives are retained. |
| Incident runbook | Incident runbook drill for verifier failure, fallback, rollback, and operator escalation. |
| Privacy review | Privacy review proving runtime samples exclude raw command lines, environments, secrets, and PII. |
| systemd no auto-start | systemd no auto-start proof for installed units; mutation service remains gated by config, marker, and evidence. |

## Pass/fail rule
The gate fails if any required evidence is stale, unverifiable, contradictory, or collected outside a disposable VM/lab environment. If VM-live behavior proof is missing, the gate must write a `SKIP` summary and must not create a controlled-lab approval. The gate also fails if the root host path can load, attach, enable, mutate, apply, write cgroups, change affinities, change priorities, or call scheduler/BPF mutation APIs without the lab evidence bundle.

A controlled-lab candidate requires a VM-live behavior bundle accepted by `qa/live_behavior_check.py`. The bundle must include marker-attested VM evidence, partial-switch `zigsched_minimal` metadata, runtime samples before/during/after attach, stable fatal/reject/fallback counters, daemon runtime events with `host_mutation=false`, live workload evidence, rollback-restored state, and audit ledger validation. Host-safe or surrogate CI evidence may keep the gate green only as `SKIP`; it must not be relabeled as live proof.

## Approval record
The owner/operator records approval in `.omo/evidence/release-approval-<version>.json` or the release evidence bundle. Approval must include the release version, git SHA, audit ID, reviewer, date, and exact authorized status.
