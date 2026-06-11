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
8. Security threat model and completed security review checklist.
9. Packaging/default-service proof that install does not auto-start or mutate scheduler state.
10. Wording audit proving no unguarded production-ready or arbitrary-production-host claim.

## Pass/fail rule
The gate fails if any required evidence is missing, stale, unverifiable, or collected outside a disposable VM/lab environment. The gate also fails if the root host path can load, attach, enable, mutate, apply, write cgroups, change affinities, change priorities, or call scheduler/BPF mutation APIs without the lab evidence bundle.

## Approval record
The owner/operator records approval in `.omo/evidence/release-approval-<version>.json` or the release evidence bundle. Approval must include the release version, git SHA, audit ID, reviewer, date, and exact authorized status.
