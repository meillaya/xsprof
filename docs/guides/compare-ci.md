# Compare captures in CI

`compare` turns two captures into a regression decision with a machine exit
code. It is a hidden automation verb: `xsprof help --all` lists it. It never
opens a window, never touches the network, and never mutates host policy.

## One command

```sh
xsprof compare \
  --base base.ndjson \
  --candidate candidate.ndjson \
  --fail-on wait.p95=10% \
  --json > compare.json
```

Exit codes: `0` no regression, `1` data/read error, `2` usage error, `3` the
candidate exceeded the threshold.

`compare` groups tasks by `comm` because PIDs change between runs. It compares
the maximum task p95 wakeup-to-run latency plus switch, wakeup, migration,
fault, loss, and CPU-busy totals. Missing, trimmed, or uncollected data is
reported as unknown — never compared as zero.

## In a CI job

```sh
set -eu
xsprof record --duration 20s --output candidate.ndjson
# base.ndjson is the checked-in or cached baseline for this workload
xsprof compare --base base.ndjson --candidate candidate.ndjson \
  --fail-on wait.p95=10% --fail-on loss=0 --json > compare.json
```

Notes:

- Both inputs are canonical `xsprof/event/v1` NDJSON (or recorder windows
  extracted with `capture`). Keep baseline captures as CI artifacts, not in
  git.
- Record the same workload on the same runner class; scheduler noise between
  different hardware is not a regression.
- A failing threshold is data, not an error: read `compare.json` (schema
  `xsprof/compare/v1`) and keep the exit code for the job status.
- If a capture ends up `SKIP`/`REFUSE` (missing permissions), fix the runner's
  capture setup; do not rewrite the run as a pass.

## Shareable report

```sh
xsprof compare --base base.ndjson --candidate candidate.ndjson \
  --html report.html
```

The HTML report is self-contained, escapes task names, and makes no external
requests. Attach it to CI artifacts or the incident ticket; there is no host or
server component.

See [top & why](top-why.md) for reading individual captures, and
[flight recorder](flight-recorder.md) for producing them.
