# teaching simulator-first teaching surface polish

teaching is the recommended next optional distribution/teaching cut after the now-
implemented M15-comparison surfaces.

## Intent

Strengthen the repo's local teaching/demo experience without changing the
project's simulator-first identity.

This milestone is intentionally about **making existing local surfaces easier
to use well**, not about introducing a new platform requirement.

## Target outcome

A contributor, reviewer, or instructor should be able to:
- pick a canonical M17 scenario quickly
- run the relevant CLI/TUI command locally
- inspect a deterministic snapshot or report artifact
- follow a short walkthrough explaining what to look for
- reproduce the same output from committed inputs

## Recommended scope

- expand walkthrough-style documentation for exactly these three start-here anchors:
  - `short-vs-long` + `fcfs`
  - `sleep-wakeup` + `cfs-like`
  - `multicore-balancing` + `fcfs`
- add or strengthen deterministic TUI snapshot proof surfaces for those three anchors
- make local demo commands easier to discover from README/docs and the picker/help path
- keep the canonical scenario corpus connected to one teaching index doc:
  - `docs/labs/simulator-teaching-pack.md`
- prefer committed fixtures and deterministic tests over ad hoc examples or new artifact trees

## Explicit non-goals

teaching should **not** become:
- a browser-first or WASM-required interface
- a replacement for the existing CLI/TUI/report boundaries
- a Linux-facing expansion beyond the approved observability/comparison observability branch
- a replay-fidelity, calibration, or Linux-performance effort
- a packaging/courseware milestone beyond repo-native artifacts and docs
- a broad teaching-pack rewrite for every canonical scenario
- a new committed artifact tree beyond one index doc unless tests cannot express the proof

## Expected proof surfaces

The proof shape for this cut should stay small and auditable:
- README updates that point users at the exact three-scenario start path
- `docs/project-architecture-and-status.md` alignment
- deterministic TUI snapshot tests for picker/help plus the three anchors
- one canonical teaching index:
  - `docs/labs/simulator-teaching-pack.md`
- one shortlist source of truth in `src/sim/scenario_pack.zig`

## Why this is the recommended next route

The codebase already has the hard parts of the local teaching loop:
- deterministic simulator core
- committed canonical fixtures
- TUI + snapshot rendering
- report/analysis regeneration pipeline
- bounded observability branch that does not need widening right now

The highest-value next step is therefore to make those existing surfaces easier
to teach and review, rather than to add a new runtime or widen the Linux-facing
branch.
