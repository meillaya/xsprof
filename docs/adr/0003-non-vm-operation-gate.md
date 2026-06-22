# ADR 0003: Non-VM operation gate

## Status

Status: Proposed / not implemented.

This ADR is a design gate only. It does not add, approve, or imply non-VM
scheduler mutation. Root-host attach, full-host switch, cgroup mutation,
affinity/priority mutation, BPF loading, and scheduler-state writes remain
refused until a future explicit approval updates both code and governance gates.

## Context

The current implementation is intentionally split into two safety domains:

1. ordinary-host commands, which are read-only or dry-run and must remain
   fail-closed; and
2. disposable VM lab commands, which may exercise verifier-only and partial
   `sched_ext` behavior only when VM evidence, rollback evidence, and audit
   identity are captured.

Disposable VM lab work is meant to prove observability and rollback behavior in a disposable lab. It is not permission to run the scheduler against a non-VM host. A later non-VM path would carry a different risk profile:
it can affect the operator's real host scheduler, cgroups, and workloads, and
therefore needs its own approval record and evidence package.

## Decision

non-VM operation remains a documented future gate, not an implementation target
for the current plan. Until this ADR is superseded by a later accepted ADR and a
signed release/governance approval, all non-VM mutation-capable actions must
continue to refuse with `host_mutation=false` evidence.

The only acceptable current non-VM behavior is:

- read-only preflight and facts collection;
- dry-run planning;
- daemon dispatch that refuses hazardous actions on the host;
- package install/upgrade/uninstall checks that do not enable services or start
  mutation-capable units; and
- evidence validation of disposable VM lab artifacts.
- release/package gates that prove the VM/lab backend milestone only, with
  no frontend/root UI artifacts and no simulator changes.

The following are explicitly out of scope in this ADR:

- loading or attaching BPF programs on the operator host;
- switching the host scheduler class or mode;
- modifying host cgroups, cpusets, CPU affinity, niceness, priorities, or kernel
  scheduler state;
- auto-starting a daemon or systemd unit that can mutate scheduler state; and
- treating host-safe surrogate evidence as VM-live or non-VM proof.

## Evidence matrix before any future production-ready language is allowed

Any later ADR that proposes non-VM operation must provide the full matrix below
before implementation can be enabled outside the disposable VM lab:

| Evidence category | Minimum required proof |
| --- | --- |
| Kernel tuple matrix | Supported kernel versions, configs, BTF status, `CONFIG_SCHED_CLASS_EXT`, BPF JIT, architecture, and distro packaging tuple. |
| Verifier logs | Verifier-only BPF logs, object hash, metadata hash, parsed failure reasons, and exact kernel tuple linkage. |
| Partial attach scope | Allowlisted target cgroup, partial-switch mode, before/during/after sched_ext state, workload liveness, and rollback id. |
| Live behavior | Runtime samples before/during/after attach, fairness/latency series, stable fatal/reject/fallback counters, and daemon stream evidence. |
| Rollback drills | Reproducible rollback transcript, idempotent second rollback, state-restored proof, and fallback summary. |
| Incident drills | Verifier failure, scheduler exit, lost stream, rollback/fallback event journal, and operator-visible `INCIDENT` state. |
| Audit ledger | Append-only action ledger with audit id, rollback id, git SHA, command argv hash, artifact hashes, and cleanup receipt. |
| Security review | Signoff for privilege boundaries, shell/argv handling, config parsing, systemd defaults, and no secret leakage. |
| Packaging safety | Install, upgrade, uninstall, no-auto-start, no service enablement, config preservation, and evidence archive preservation. |
| Operator controls | Daemon stop and rollback controls with visible state, refusal reasons, and stale-target handling. |
| Wording and governance | Wording audit, governance manifest update, release gate approval, and explicit scope statement for the target host class. |

## Required implementation changes in a future ADR

A future ADR must define all of the following before any code path may stop
refusing non-VM mutation:

1. explicit operator opt-in configuration with a disabled default;
2. a marker or policy file proving the operator intended to leave VM-only mode;
3. a typed action protocol extension with audit id and rollback id requirements;
4. a pre-attach verifier-only phase with structured failure reasons;
5. a preflight blocklist for unsupported kernel tuples and missing rollback
   support;
6. automatic rollback snapshot capture before any attach attempt;
7. bounded runtime stream backpressure and privacy validation;
8. package/service behavior that never auto-starts mutation-capable units; and
9. a rollback/fallback runbook tested on the exact target tuple.

## Consequences

- The current daemon and package surfaces should keep showing refusal or
  controlled-lab states for host mutation actions.
- VM-live artifacts can graduate controlled lab confidence only; they cannot be
  relabeled as non-VM evidence.
- VM/lab backend package artifacts must be inert outside the disposable lab:
  mutation-capable systemd units stay disabled/refusing by default and require
  VM marker, config marker, approval evidence, audit id, and rollback id.
- Any future non-VM work must add tests that fail if host mutation becomes
  possible without the matrix above.
- This ADR should be cited by future agents when they are asked to "just run it
  on the host" or to bypass the VM lab gates.

## Verification

- `bash qa/wording_audit.sh`
- `grep -n "^Status: Proposed / not implemented" docs/adr/0003-non-vm-operation-gate.md`
- `grep -n "^non-VM operation remains" docs/adr/0003-non-vm-operation-gate.md`
- Future implementation plans must add a RED test proving ordinary-host mutation
  remains refused before adding any new non-VM gate behavior.
