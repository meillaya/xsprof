# Compare a capture in CI

Two capture files are enough:

```sh
./zig-out/bin/xsprof compare \
  --base base.ndjson \
  --candidate candidate.ndjson \
  --fail-on wait.p95=10% \
  --md
```

Exit codes are `0` for no regression, `1` for data errors, `2` for usage
errors, and `3` when the candidate exceeds the threshold.

`compare` groups tasks by comm because PIDs change between runs. It compares
the maximum task p95 wakeup-to-run latency, plus switch, wakeup, migration,
fault, loss, and CPU-busy totals. Missing or trimmed data is shown as unknown;
a missing metric is never treated as zero.

For a shareable report:

```sh
./zig-out/bin/xsprof compare --base base.ndjson --candidate candidate.ndjson \
  --html report.html
```

The report is self-contained, escapes all task names, and makes no external
requests.
