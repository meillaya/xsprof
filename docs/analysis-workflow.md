# analysis workflow

The simulator adds deterministic downstream analysis surfaces that consume only exported `zig-scheduler/report` JSON.

## Supported contract gate
The analyzer accepts exports only when both of these are true:
- `schema == "zig-scheduler/report"`
- `version == 1`

Missing schema/version fields or unsupported values fail fast. The analyzer does not guess or silently coerce unsupported exports.

## CLI workflow
The narrow analysis commands still exist, but the simulator now provides the canonical
single-path regeneration surface for committed artifacts:

```sh
zig build reports
```

Use the simulator commands below when you intentionally want to render one analysis
artifact by hand.

Generate an export from the simulator CLI:

```sh
zig build sim -- --scenario-file scenarios/basic/multicore-contention.zon --policy fcfs --format json \
  > docs/examples/exports/multicore-contention-fcfs.report.json
```

Render the committed Markdown report surface from that export:

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json \
  > docs/examples/analysis/multicore-contention-fcfs.md
```

Render the committed SVG visualization surface from that same export:

```sh
zig build analyze -- --input docs/examples/exports/multicore-contention-fcfs.report.json --format svg \
  > docs/examples/analysis/multicore-contention-fcfs.svg
```

## Committed reproducible artifacts
- Export fixture: `docs/examples/exports/multicore-contention-fcfs.report.json`
- Markdown analysis: `docs/examples/analysis/multicore-contention-fcfs.md`
- SVG visualization: `docs/examples/analysis/multicore-contention-fcfs.svg`

These files are treated as deterministic goldens by the analysis test suite.

## Boundary guarantees
- Analysis code parses exported JSON only.
- Analysis code does not import simulator engine internals or reuse in-process simulation structs.
- Additive version-1 fields are tolerated during parse so long as the contract gate still reports `version == 1`.
- Unsupported export version errors are explicit (`analysis failed: unsupported export version`).

## Scope notes
These artifacts are teaching/reporting surfaces for the simulator export contract only. They do not add Linux integration, service behavior, or kernel-faithful claims.

For the multi-artifact reproducible pipeline layered on top of this workflow,
see `docs/report-pipeline.md`.
