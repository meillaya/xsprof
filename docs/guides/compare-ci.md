# Compare captures in CI

`compare` turns captures into a regression decision with a machine exit code.
It matches tasks by `comm` (PIDs change between runs) and compares the pooled
p95 wakeup-to-run latency, off-CPU latency, and switch/wakeup/migration/fault/
loss/CPU-busy totals. It never opens a window, never touches the network, and
never mutates host policy.

`compare` is a hidden automation verb: `xsprof help --all` lists it.

## One capture per side

```sh
xsprof compare \
  --base base.ndjson \
  --candidate candidate.ndjson \
  --fail-on wait.p95=10% \
  --json > compare.json
```

A single capture per side is the legacy path: the threshold is applied directly
to the p95 delta and the noise floor is 0, because one sample has no observed
run-to-run spread. Use it for a quick check, not for a trustworthy gate.

## Multiple runs per side

Scheduler latency moves between identical runs, so a CI gate should measure the
spread. Repeat the flags one to eight times per side:

```sh
xsprof compare \
  --base baseline-1.ndjson --base baseline-2.ndjson --base baseline-3.ndjson \
  --candidate cand-1.ndjson --candidate cand-2.ndjson --candidate cand-3.ndjson \
  --min-runs 3 \
  --fail-on wait.p95=15% --fail-on loss=0 \
  --json > compare.json
```

What happens to the runs:

- Every capture is reduced to the same bounded 64-bucket log2 histograms the
  metrics index keeps, one histogram per `comm` per capture (pooled across the
  PIDs that shared the comm in that capture).
- The buckets are **pooled across the runs on each side**, so the reported p95
  is the p95 of all samples, not an average of per-run p95s.
- `base_runs` / `candidate_runs` (top level and per task) say how many captures
  actually contributed to that side and that comm.
- `--min-runs K` (default 1, max 8) is a preflight: if either side has fewer
  than K captures, `compare` exits with the usage error code (2) before reading
  any data. It does not invent missing runs.

## The noise floor

For each comm, `noise_pct` is:

```text
    max( base-side p95 range, candidate-side p95 range )
    ---------------------------------------------------- x 100
                   pooled baseline p95
```

The range is the spread of that comm's per-run p95 across a side's captures
(max minus min). A side with one capture has no observed range and contributes
0. A task is a **regression iff both**:

```text
delta_pct > threshold_pct   AND   delta_pct > noise_pct
```

So a change that is smaller than the run-to-run spread is not reported as a
regression. Example: three baseline runs with per-run p95 of 1024, 1024 and
4096 us pool to a 1024 us baseline while the spread is 3072 us, a 300% noise
floor. A candidate whose pooled p95 is 2048 us (+100%) is inside that noise and
passes; the same candidate at 16384 us (+1500%) fails.

Noise is an empirical floor from the captures in front of it, not a confidence
interval. It says nothing about runs that were not taken.

## `--fail-on` grammar

Repeat `--fail-on` to gate several signals. Latency thresholds are percentages
(an optional legacy `%` suffix is accepted). Counter thresholds are absolute
and apply to the **mean per run**, so unequal run counts on each side stay
comparable.

| rule | family | threshold | flags |
|---|---|---|---|
| `wait.p50=…`, `wait.p95=…`, `wait.p99=…`, `wait.max=…` | wakeup-to-run latency | percent | per task; noise-aware |
| `offcpu.p95=…` | off-CPU time | percent | per task; noise-aware |
| `preemptions=…` | involuntary preemptions | absolute (events/run) | top-level total |
| `migrations=…` | scheduler migrations | absolute (events/run) | top-level total |
| `loss=…` | dropped/trimmed events | absolute (events/run) | top-level total |

The scalar `threshold_pct` field in the JSON report is the `wait.p95` threshold
(10% when no `--fail-on wait.p95` rule is given); per-task `regression` uses
that scalar plus the noise rule. Gating on `preemptions` requires a build with
the causal-latency metrics; on a build without them the rule is a usage error.

## Exit codes

| code | meaning |
|---|---|
| `0` | no gate rule failed (or no `--fail-on` rules were requested) |
| `1` | data/read error: unreadable capture, malformed journal, or a gated latency rule with **no comparable samples at all** (unknown is not a pass) |
| `2` | usage error: bad flag, bad rule grammar, more than 8 captures per side, or `--min-runs` shortfall |
| `3` | a requested gate failed (threshold **and** noise floor exceeded) |

A failing threshold is data, not a crash: read `compare.json` (schema
`xsprof/compare/v1`) and keep the exit code for the job status.

## The JSON report

Canonical `xsprof/compare/v1` JSON, keys ascending, `host_mutation` always
`false`; schema in [`compare.v1.schema.json`](../../schemas/xsprof/compare.v1.schema.json).

- `base` / `candidate`: summed totals for each side (`preemptions` is `null`
  when the build cannot produce it).
- `base_source` / `candidate_source`: the capture paths (`", "` joined).
- `base_runs` / `candidate_runs`: captures on each side.
- `fail_reasons`: one human/machine-readable string per failed gate rule;
  empty when nothing regressed.
- `tasks[]`: `comm`, `base_p95_us`, `candidate_p95_us`, `delta_pct`,
  `noise_pct`, `regression`, plus switches and run counts. Unknown values are
  `null` — never a fabricated zero.
- `regressions`: number of tasks whose p95 regression passed both the
  threshold and the noise floor.

## In a CI job

The repository ships a composite action:
[`.github/actions/xsprof-compare/action.yml`](../../.github/actions/xsprof-compare/action.yml).
It assumes the workflow already checked out the repository (or restored the
captures and the binary); it does no network access of its own.

```yaml
- name: Record three candidate runs
  run: |
    for i in 1 2 3; do
      ./zig-out/bin/xsprof record --duration 20s --output "candidate-$i.ndjson"
    done

- name: Compare against the cached baseline
  id: compare
  uses: ./.github/actions/xsprof-compare
  with:
    base: "baseline-1.ndjson baseline-2.ndjson baseline-3.ndjson"
    candidate: "candidate-1.ndjson candidate-2.ndjson candidate-3.ndjson"
    min-runs: "3"
    fail-on: "wait.p95=15% loss=0"
    binary: "zig-out/bin/xsprof"
    output: "compare.json"

- name: Keep the report available for inspection
  if: always()
  run: |
    test -f "${{ steps.compare.outputs.compare-json }}"
    cat "${{ steps.compare.outputs.compare-json }}"
```

The action fails the job when `compare` exits 3 (regression) and re-raises any
other non-zero exit code. Its outputs are `compare-json` (report path),
`regressed` (`"true"`/`"false"`) and `exit-code`.

Notes:

- Both inputs are canonical `xsprof/event/v1` NDJSON (or recorder windows
  extracted with `capture`). Keep baseline captures as CI artifacts/caches, not
  in git.
- Record the same workload on the same runner class. A scheduler difference
  between two hardware classes is not a regression.
- `--html report.html` writes a self-contained HTML report (escaped task names,
  no external requests); `--md` writes Markdown to stdout. Both are report
  views: the exit code is unchanged.
- If a capture ends up `SKIP`/`REFUSE` or trimmed, do not rewrite the run as a
  pass: `compare` reports the affected values as unknown, and a gate that has
  no comparable samples exits 1.

## Recommended thresholds and run counts

- **At least 3 captures per side**, up to 8. Two runs can only express a
  two-point range; three or more give the floor something to stand on.
- Same runner class, same kernel/build configuration, same workload and
  isolation (cgroups, CPU pinning, background jobs). Do not compare across
  hardware classes.
- Start with `wait.p95=10%` or `15%` and tighten only after the report shows
  your runner's noise floor. A threshold below the observed `noise_pct` can
  never fire (the noise rule wins); a threshold well above it misses real
  regressions.
- Counters are cheap and stable; `loss=0` and a migrations budget are good
  complements to a latency threshold. Counters ignore the noise floor.
- Keep the captures themselves out of the repository; attach them (or the
  report) to CI artifacts or the incident ticket.

## Honest limits

- Runner noise is real: shared CI hosts, CPU frequency scaling, other jobs, and
  hypervisor steal all move latency. The noise floor only measures the noise
  present in *your* captures; it cannot correct for a noisy baseline.
- Merging is only meaningful for the same workload, kernel, xsprof build, and
  hardware class. The histogram buckets are coarse powers of two, so reported
  p95 values are upper bounds with bucket granularity; small deltas inside one
  bucket appear as 0%.
- Missing, trimmed, or uncollected data stays unknown (`null`), never zero.
  A trimmed capture can therefore hide by absence, which is why a gate with no
  comparable samples exits 1 instead of passing.
- The noise floor is not a confidence interval and does not prove absence of a
  regression; it prevents the most common false positives.
- Compare is a bounded scheduler statistic gate, not a profiler. For the cause
  of a regression, read the captures with `why` and an incident bundle.

See [top & why](top-why.md) for reading individual captures, and
[flight recorder](flight-recorder.md) for producing them.
