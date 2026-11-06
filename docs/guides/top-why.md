# top and why

Two commands cover the common operator questions without requiring a daemon.

## `xsprof top`

```sh
xsprof top
xsprof top --duration 10s --interval 250ms --preset deep
xsprof top --duration 10s --json --top 20
xsprof top --once
```

- Opens one read-only perf capture.
- Ranks tasks by wait p95/p99 and off-CPU time, shows CPU busy/idle, faults
  minor/major, loss, out-of-order input, and top waker→woken pairs.
- ANSI output is used only when stdout is a TTY; otherwise one final table is
  printed.
- `--json` emits canonical `xsprof/metrics/v1`.
- Missing perf permissions return `SKIP` with a reason and exit 1.

## `xsprof why`

```sh
xsprof why --input session.ndjson
xsprof why --last 10m --dir /var/lib/xsprof
xsprof why --input session.ndjson --json
xsprof why --last 30s --dir /var/lib/xsprof --pid 1234
```

It streams the journal or recorder window, then reports:

- requested and observed event/window counts, loss, and out-of-order rows;
- top wait tasks (p95/p99 and off-CPU p95);
- top wakeup chains (`waker -> woken`, count, p95 wait);
- CPU and fault summary;
- advisor findings and per-rule `finding`/`clear`/`skip` status;
- explicit caveats when data is lost or replayed with timestamp skew.

Exit codes: `0` success, `1` data/read error, `2` usage error.

`why --last` extracts a private temporary window and removes it after analysis.
The command never writes into the recorder state directory and never changes
host policy.
