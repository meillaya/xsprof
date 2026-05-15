# M16 reproducible report pipeline

M16 turns the existing analysis and benchmark surfaces into one canonical,
deterministic regeneration path for the curated teaching/research artifact set.

## Canonical commands

Regenerate the committed report pack in place:

```sh
zig build reports
```

Run the same pipeline into a separate directory for smoke testing:

```sh
zig build reports -- --output-dir zig-out/report-smoke
```

Check for drift without rewriting files:

```sh
zig build reports -- --check
```

## Artifact set

The pipeline regenerates these committed artifacts:

- `docs/examples/exports/multicore-contention-fcfs.report.json`
- `docs/examples/analysis/multicore-contention-fcfs.md`
- `docs/examples/analysis/multicore-contention-fcfs.svg`
- `docs/benchmarks/baselines.md`
- `docs/benchmarks/baselines.json`
- `docs/labs/reproducible-report-pack.md`

The generated notebook/index (`docs/labs/reproducible-report-pack.md`) records
the curated fixture set and keeps the regeneration path visible for future
contributors.

## Scope rules

- Inputs come from committed fixtures only.
- Outputs must remain deterministic across repeated runs unless fixtures or code
  intentionally change.
- Simulator-local wording still applies; this pipeline does not turn the repo
  into a Linux-performance or kernel-fidelity tool.

## Relationship to earlier milestones

- M4 still defines the export-only analysis boundary.
- M4.5 still defines the benchmark baseline contract and fixture matrix.
- M16 adds the repo-native path that regenerates those surfaces together.
