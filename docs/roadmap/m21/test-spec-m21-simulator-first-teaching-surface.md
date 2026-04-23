# Test Spec — M21 simulator-first teaching surface polish

## Status
Draft for consensus review on 2026-04-22

## Scope under test
- simulator-first teaching-path discoverability
- deterministic snapshot proof for exactly three anchor scenarios
- docs/link alignment for the new teaching path
- explicit preservation of M19/M20 as a bounded observability side lane
- no widening of `zig-scheduler/report` or `src/analysis/*`

## Approved future proof surfaces
- `README.md`
- `docs/m21-simulator-first-teaching-surface.md`
- `docs/project-architecture-and-status.md`
- `docs/m17-scenario-corpus.md`
- `docs/labs/simulator-teaching-pack.md`
- `src/sim/scenario_pack.zig`
- `src/tui/root.zig`
- `src/tui/render.zig`
- `src/tests/identity_gate_test.zig`
- `src/tests/scenario_pack_test.zig`
- `src/tests/cli_smoke_test.zig`

## Required verification
1. docs alignment audit for README + M21 doc + project status + scenario corpus + `docs/labs/simulator-teaching-pack.md`
2. picker/help discoverability snapshot tests for the simulator-first path, ranking it above M19/M20 shortcuts
3. deterministic explorer snapshot tests for exactly these anchor scenarios:
   - `short-vs-long` + `fcfs`
   - `sleep-wakeup` + `cfs_like`
   - `multicore-balancing` + `fcfs`
4. shared-helper audit proving `src/sim/scenario_pack.zig` is the single source of truth for the exact three-anchor shortlist
5. scenario-metadata/link checks proving surfaced teaching entries still resolve to committed scenario files and explanation docs using existing scenario-pack metadata unless explicitly justified otherwise
6. assertion that the three anchors from the shared helper are the only M21 “start here” shortlist
7. wording audit that M19/M20 remain a bounded observability side lane
8. boundary audit proving no changes to `zig-scheduler/report` or `src/analysis/*` and that report artifacts stay secondary
9. smoke validation in `src/tests/cli_smoke_test.zig` for every command shown in README or `docs/labs/simulator-teaching-pack.md` for the M21 path
10. full regression pass with `zig build test --summary all`

## Minimum checks
- README includes a simulator-first start path for demos/review
- M21 doc names the exact three anchor scenarios and explicit non-goals
- project status doc describes M21 as a bounded simulator teaching polish cut
- scenario corpus doc points to the exact three-scenario shortlist or companion doc
- `docs/labs/simulator-teaching-pack.md` covers only the three anchors as M21 “start here”
- picker snapshot contains discoverability copy for the simulator-first teaching path
- help snapshot contains the same simulator-first framing and ranks it above M19/M20 shortcuts
- each anchor scenario snapshot is deterministic across repeated renders
- `multicore-balancing` has a clear explanation link via docs/current metadata scope
- `src/tests/cli_smoke_test.zig` covers every README/teaching-index command in the M21 path
- docs/tests do not imply browser/WASM, replay fidelity, Linux-performance, or calibration meaning
- docs/tests keep M19/M20 reachable but clearly secondary
- no report/analysis contract or implementation files are expanded for M21
- every command shown in README or the teaching index for the M21 path passes smoke validation

## Non-goals for this milestone
- exhaustive walkthrough coverage for every canonical scenario
- new analysis/report/export contracts
- browser or WASM delivery
- observability-lane feature growth
- extra committed artifact trees beyond one teaching index doc unless strictly needed
- M23-style courseware or packaging breadth
