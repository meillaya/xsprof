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
