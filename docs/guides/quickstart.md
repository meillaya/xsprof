# Quickstart

`xsprof` is read-only: it opens perf tracepoints, reads `/proc`/`/sys`, and writes
only its own journals, reports, and snapshots. Every record carries
`host_mutation=false`.

## 1. Run the bundled capture (no privileges)

```sh
./tools/zig build
./zig-out/bin/xsprof demo
```

Open the printed `http://127.0.0.1:<port>/#token=…` URL. The token stays in the
fragment and is used only for same-origin API calls.

## 2. Live view

```sh
sudo ./zig-out/bin/xsprof top --duration 5s
sudo ./zig-out/bin/xsprof top --duration 5s --json > top.json
```

`top` needs `CAP_PERFMON` (or `perf_event_paranoid <= 1`) and readable tracefs.
Without them it prints a canonical capability record and exits 1.

## 3. Explain a window

```sh
sudo ./zig-out/bin/xsprof why --last 10m --dir /var/lib/xsprof
./zig-out/bin/xsprof why --input session.ndjson --json
```

`why` streams the journal; it does not load a multi-GB window into memory.

## 4. Record an incident

```sh
sudo ./zig-out/bin/xsprof daemon --foreground --dir /var/lib/xsprof
sudo ./zig-out/bin/xsprof incident --last 10m --dir /var/lib/xsprof
xsprof history --last 10m --dir /var/lib/xsprof
```

The incident folder is self-contained and offline. SIGTERM to the daemon
flushes the current segment, writes `capture_stop`, and marks the manifest
`stopped`.

## Check this host

```sh
xsprof doctor              # human-readable
xsprof doctor --json       # machine-readable
```

A `SKIP`/`REFUSE` state always includes a reason. The tool never elevates or
changes host policy.
