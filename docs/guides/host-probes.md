# Read-only host probes

Two commands surface pressure and cgroup state without capture privileges. Both
are read-only, emit canonical JSON, and exit non-zero when the signal is
unavailable rather than inventing zero values.

## Pressure (`xsprof pressure --json`)

Reads `/proc/pressure/cpu`, `/proc/pressure/memory`, and `/proc/pressure/io`.
Each resource has an optional `full` sample and a required `some` sample:

```json
{"available":true,"cpu":{"some":{"avg10_bp":0,"avg300_bp":4,"avg60_bp":0,"total_us":2463881}},
 "memory":{...},"io":{...},"host_mutation":false,"reason":"",
 "schema":"xsprof/pressure/v1","source":"proc_pressure","state":"READY"}
```

`avg*_bp` is a basis-point integer: `123` means 1.23%. Storing integers avoids
float/locale drift in the canonical wire form. `total_us` is the kernel counter
in microseconds. `full` is absent where the kernel does not provide it (CPU).

Non-Linux hosts and kernels without PSI return `available:false`,
`state:"SKIP"`, a `reason`, and exit 1.

## Cgroup attribution (`xsprof cgroup --json`)

On cgroup v2, scans bounded `/proc/<pid>/cgroup` membership and joins it with
`/proc/<pid>/comm`. Groups are sorted by task count, then path. Each group
keeps at most three sample task names, and the scan is capped at 512 groups,
three samples, and 100,000 tasks:

```json
{"cgroup_version":2,"groups":[{"path":"/system.slice/sshd.service",
 "sample_comms":["sshd"],"tasks":3}],"tasks":3,"truncated":false,"state":"READY",
 "host_mutation":false,"schema":"xsprof/cgroup/v1","source":"proc_cgroup"}
```

This is a host snapshot, not historical event attribution: the JSON says when
the snapshot was taken by virtue of being a live command. cgroup v1 and
unreadable `/proc` return `state:"SKIP"` or `"REFUSE"` with a reason and exit 1.
The command never creates, joins, or writes a cgroup.

## Recorder overhead meter

`daemon` reads `/proc/self/schedstat` (CPU runtime) and `VmRSS` before and after
the recording. Its result gains:

- `wall_ms`, `cpu_ms`, `rss_kb`;
- `events_per_sec`, `bytes_per_sec`;
- `overhead_bp` — profiler CPU time in basis points of one CPU
  (`10000` is one full CPU);
- `overhead_available` — false when `/proc/self/schedstat` is unreadable.

The recorder uses a freeing allocator for capture batches and sidecars; a
long-running daemon stays bounded instead of accumulating CLI-arena pages.
