# Test Spec — M21 simulator-first teaching surface polish

## Status
Draft for consensus review on 2026-04-22

## Scope under test
- simulator-first teaching-path discoverability
- deterministic snapshot proof for selected canonical scenarios
- docs/link alignment for the new teaching path
- explicit preservation of M19/M20 as a bounded observability side lane
- no widening of `zig-scheduler/report` or `src/analysis/*`

## Approved future proof surfaces
- `README.md`
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/project-architecture-and-status.md`
- `docs/m17-scenario-corpus.md`
- `docs/labs/simulator-teaching-pack.md` if added
- `src/tui/root.zig`
- `src/tui/render.zig`
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`

## Required verification
1. docs alignment audit for README + M21 doc + project status + scenario corpus
2. picker/help discoverability snapshot tests for the simulator-first path
3. deterministic explorer snapshot tests for exactly these anchor scenarios:
   - `short-vs-long` + `fcfs`
   - `sleep-wakeup` + `cfs_like`
   - `multicore-balancing` + `fcfs`
4. scenario-metadata/link checks proving surfaced teaching entries still resolve to committed scenario files and explanation docs
5. wording audit that M19/M20 remain a bounded observability side lane
6. boundary audit proving no changes to `zig-scheduler/report` or `src/analysis/*`
7. full regression pass with `zig build test --summary all`

## Minimum checks
- README includes a simulator-first start path for demos/review
- M21 doc names the three anchor scenarios and explicit non-goals
- project status doc describes M21 as a bounded simulator teaching polish cut
- scenario corpus doc points to the teaching-first shortlist or companion doc
- picker snapshot contains discoverability copy for the simulator-first teaching path
- help snapshot contains the same simulator-first framing
- each anchor scenario snapshot is deterministic across repeated renders
- docs/tests do not imply browser/WASM, replay fidelity, Linux-performance, or calibration meaning
- docs/tests keep M19/M20 reachable but clearly secondary
- no report/analysis contract or implementation files are expanded for M21

## Non-goals for this milestone
- exhaustive walkthrough coverage for every canonical scenario
- new analysis/report/export contracts
- browser or WASM delivery
- observability-lane feature growth
- M23-style courseware or packaging breadth
