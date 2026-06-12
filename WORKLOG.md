# WORKLOG

This log records operator-facing checkpoints for the Linux scheduler maturity work. It is tracked on purpose so future agents can reconstruct project intent from a clean clone without relying on ignored `.omo/`, `.omx/`, or local notes.

## Guardrails

- The root project is a fail-closed Linux scheduler operator surface.
- The deterministic simulator is archived under `simulator/` and remains independently runnable from that package root.
- Root code must not claim production readiness.
- Root host commands must not load BPF, attach schedulers, mutate cgroups/cpusets, change affinity/priority, or write scheduler state.
- Real `sched_ext` attach/load/verifier work is VM/lab-gated only until explicit evidence and review gates say otherwise.
- Current release posture is `controlled_lab_pilot_candidate`, not production-ready.

## Historical checkpoints

### Simulator-era baseline

The repository began as a deterministic educational scheduler simulator with scenario fixtures, simulator reports, and a dense terminal dashboard. That simulator work is useful for UI lineage and educational comparisons, but simulator output is not Linux scheduler performance or fidelity proof.

### Root reframe to Linux scheduler operator

Commit `f58efb8` reframed the repository root around fail-closed Linux scheduler work. The root build/test/run graph now focuses on Linux preflight, dry-run control plans, read-only host fact collection, `sched_ext` readiness helpers, and a Linux operator TUI. The simulator was moved under `simulator/` as its own package boundary.

### Future-agent guidance preservation

Commit `defe53c` preserved scheduler guidance for future agents. The important durable rules are now also in tracked `AGENTS.md`, `README.md`, and this worklog: fail closed, keep host surfaces read-only, keep lab mutation VM-only, and preserve the TUI visual family without reusing simulator semantics as Linux claims.

### Controlled lab sched_ext roadmap

Commit `4055942` added the controlled lab `sched_ext` roadmap. That work established the posture that BPF/verifier/attach experiments belong in controlled lab surfaces and that release evidence must distinguish host-safe refusal/SKIP evidence from VM evidence.

### Release reproducibility hardening

Commit `46a8931` made the release gate reproducible. The release path now expects explicit controlled-lab evidence, stable status language, and guardrails against presenting incomplete or skipped lab evidence as production readiness.

### Temporary docs untracking decision

Commit `8c68f53` stopped tracking local docs and agent notes. The next-phase plan supersedes that local-only arrangement: operator guidance and governance sources are intentionally tracked again so a clean archive or fresh clone can pass governance gates without hidden local files.

### Next Linux scheduler maturity plan

The approved next-phase plan is `.omo/plans/next-linux-scheduler-maturity.md`. It restores tracked governance sources, adds a governance manifest, creates clean archive checks, builds a one-command lab harness, strengthens the minimal `sched_ext` path, adds observability and live TUI lifecycle evidence, and defines governance required before any future production-ready language is allowed.

## Current status

- Production posture: `production_ready=false`.
- Release posture: `controlled_lab_pilot_candidate` only after evidence gates pass.
- Host posture: read-only preflight and dry-run planning only.
- VM/lab posture: attach/load work remains isolated to explicit `qa/vm/*` lab flows with rollback, audit, and release evidence.

## Future-agent operating notes

1. Read `AGENTS.md`, `README.md`, `docs/security/threat-model.md`, and `docs/releases/governance-gate.md` before changing scheduler, lab, release, or package behavior.
2. Treat `.omo/` and `.omx/` as local workflow state only. Do not make repository behavior depend on those ignored directories.
3. Keep clean-clone reproducibility in mind: any required policy, runbook, fixture, or gate input must be tracked.
4. If a change touches UI/TUI behavior, preserve the root TUI visual family while keeping Linux concepts separate from simulator concepts.
5. If a change touches mutation-capable behavior, require VM marker evidence, rollback evidence, audit ids, security review, and explicit release governance before broadening scope.

### TUI-driven live lab scheduler plan

The approved plan `.omo/plans/tui-driven-live-lab-scheduler.md` defines the next roadmap toward making the TUI the operator entrypoint for controlled lab scheduler work. The intended path is:

1. keep the root host fail-closed and read-only by default;
2. add typed TUI actions that talk to an internal Zig lifecycle daemon instead of executing shell commands directly;
3. connect those actions to host-safe lab harness flows first;
4. implement disposable VM boot/copy/execute/teardown before claiming live scheduler proof;
5. run `zigsched_minimal` through VM-only verifier and partial-switch attach evidence;
6. stream VM-live runtime samples and scheduler events into the TUI;
7. expose safe stop and rollback controls with audit and incident evidence;
8. keep any non-VM operation as a later separately approved governance gate, not an implementation in the current plan.

The plan intentionally uses uppercase `WORKLOG.md` because the tracked governance and release gates require this file. Lowercase `worklog.md` is not used as a separate repository behavior source.

Current execution posture remains controlled-lab only: not production-ready, not arbitrary-host-safe, and not authorized for ordinary host scheduler mutation.

## Timestamped implementation milestones

The entries below are timestamped worklog records for the new TUI-driven live-lab scheduler features completed or staged in the current implementation wave. Timestamps are log-record times, not production-readiness claims.

- `2026-06-12T12:22:43-04:00` — **T01 / governance worklog restored:** Recreated tracked uppercase `WORKLOG.md`, preserved fail-closed operator guidance, and kept future-agent instructions independent from ignored `.omo/` or `.omx` workflow state.
- `2026-06-12T12:22:43-04:00` — **T02 / typed TUI action protocol:** Added typed operator actions and daemon event JSON contracts for `preflight`, host-safe lab runs, verifier-only checks, VM lab actions, observe, stop, and rollback; parser rejects shell-command fields, unknown actions, path traversal, and control-character injection.
- `2026-06-12T12:22:43-04:00` — **T03 / control lifecycle state machine:** Added a pure fail-closed lifecycle model for read-only, verifier-only, VM partial-switch lab, rollback-pending, rolled-back, refused-host, and incident states; duplicate mutation and invalid rollback transitions are rejected before any executor exists.
- `2026-06-12T12:22:43-04:00` — **T04 / interactive TUI shell:** Extended the root TUI from deterministic snapshots to a testable interactive PTY shell that queues typed actions while preserving the terminal dashboard visual family and never executing lab scripts directly.
- `2026-06-12T12:22:43-04:00` — **T05 / trusted lab command registry:** Added a fixed-argv lab command registry/refusal adapter for host-safe lab, verifier-only, partial attach, observe, stop, and rollback actions; hostile `PATH`, shell strings, and newline arguments are refused or isolated.
- `2026-06-12T12:22:43-04:00` — **T06 / live-lab evidence schemas:** Added validators and Zig schema constants for action journals, daemon event journals, VM transcript indexes, live attach proof, live behavior proof, rollback results, and TUI session transcripts; validators reject surrogate-as-live evidence, missing VM markers, stale git SHAs, and private raw log fields.
- `2026-06-12T12:29:40-04:00` — **T07 / disposable VM execution contract specified:** Added a tracked VM execution contract, a contract validator, and an `execute` mode that refuses with `VM_EXECUTE_NOT_IMPLEMENTED` while recording `host_mutation=false`; read-only smoke still SKIPs/REFUSEs without booting QEMU. This is a contract milestone only, not VM-live scheduler proof.
