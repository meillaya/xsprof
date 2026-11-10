# top and why

Two commands cover the common operator questions without requiring a daemon.
Both are read-only, both exit non-zero when a required signal is unavailable,
and neither writes to the recorder state directory.

## `xsprof top`

```sh
xsprof top
xsprof top --duration 10s --interval 250ms --preset deep
xsprof top --duration 10s --json --top 20
xsprof top --once
```

- Opens one read-only perf capture for the requested duration.
- Ranks tasks by wait p95/p99 and off-CPU time; shows CPU busy/idle, faults
  minor/major, loss, out-of-order input, and top waker→woken pairs.
- ANSI output is used only when stdout is a TTY; otherwise one final table is
  printed. `--once` takes one sample and exits.
- `--json` emits canonical `xsprof/metrics/v1`.
- Missing perf permissions return `SKIP` with a reason and exit 1. Use
  [recording permissions](capture-permissions.md) if you want to fix that on
  purpose; xsprof will not elevate.

`--preset scheduler|memory|deep` matches the recorder presets, so a `top` run
and a recorder session see the same event families.

## `xsprof why`

```sh
xsprof why --input session.ndjson
xsprof why --last 10m --dir /var/lib/xsprof
xsprof why --input session.ndjson --json
xsprof why --last 30s --dir /var/lib/xsprof --pid 1234
xsprof why --last 30s --dir /var/lib/xsprof --comm worker
```

It streams the journal or recorder window, then reports:

- requested and observed event/window counts, loss, and out-of-order rows;
- top wait tasks (p95/p99 and off-CPU p95);
- top wakeup chains (`waker -> woken`, count, p95 wait);
- CPU and fault summary;
- advisor findings and per-rule `finding`/`clear`/`skip` status;
- explicit caveats when data is lost or replayed with timestamp skew.

`--pid`/`--comm` focus the report without rewriting the underlying window.

Exit codes: `0` success, `1` data/read error, `2` usage error.

`why --last` extracts a private temporary window and removes it after analysis.
The command never writes into the recorder state directory and never changes
host policy. Findings are printed/copied only — the advisor never applies a
recommendation.

## When to use which

| Question | Command |
|---|---|
| "What is happening right now?" | `top` |
| "Why was this task waiting?" | `why --input` / `why --last` |
| "What does the recorder still hold?" | `verify --dir` then `capture --last` |
| "What should I fix?" | `advise` / the Advisor screen — suggestions only |

See [flight recorder](flight-recorder.md) for windows and incident bundles, and
[compare in CI](compare-ci.md) for regression gates.
