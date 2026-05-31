# teaching distribution

This is the canonical the simulator package entrypoint.

the simulator is a **package shell over teaching**, not a new teaching spine. The required
teaching path still comes from the exact teaching shortlist:
- `short-vs-long` + `fcfs`
- `sleep-wakeup` + `cfs-like`
- `multicore-balancing` + `fcfs`

Use this document as the single entrypoint for the first packaged teaching cut.
Other the simulator docs should point back here rather than becoming competing “start
here” surfaces.

## Audience
- self-guided learners who want one bounded path through the simulator
- instructors who want one reproducible package to run in a short session
- reviewers validating that the teaching flow stays grounded in committed repo
  artifacts

## Package structure
This first package ships **four** primary docs total:
1. `docs/courseware/teaching-distribution.md`
2. `docs/courseware/student-onboarding.md`
3. `docs/courseware/instructor-guide.md`
4. `docs/courseware/assignment-pack-01.md`

## Package flow
1. Read the student onboarding guide
2. Validate the repo state with the required build/test commands
3. Work through the three required assignment modules in order
4. Use the instructor guide for pacing, expected observations, and optional
   extension paths

## Package-level reproducibility checklist
Run these before or during package use:

```sh
zig build
zig build test --summary all
```

Required module commands are the same teaching command pairs already published in:
- `README.md`
- `docs/labs/simulator-teaching-pack.md`

the simulator may reorganize and explain those commands, but it does not replace them.

## Canonical underlying teaching spine
The underlying simulator-first spine remains:
- `docs/labs/simulator-teaching-pack.md`

## Appendix — bounded observability side lane (optional)
This appendix is optional and must not be required to complete the core package.

Optional commands:

```sh
zig-out/bin/zig-scheduler --observability
zig-out/bin/zig-scheduler --snapshot --observability
zig-out/bin/zig-scheduler --comparison
zig-out/bin/zig-scheduler --snapshot --comparison
```

Use this appendix only when you want to show bounded offline observability
comparison evidence.

Boundary reminders:
- observability/comparison stay a separate observability-only side lane
- not live capture
- not replay authority
- not Linux-performance evidence
- not required for the three core modules

## Boundaries
This package remains simulator-first:
- no browser/WASM requirement
- no service or hosted-lab scope
- no live capture or replay automation
- no Linux-performance or calibration claims
- no requirement to use the SDK SDK branch to complete the package
