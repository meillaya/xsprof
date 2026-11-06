const std = @import("std");

const Writer = std.Io.Writer;

pub fn writeQuickstart(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\▚ xsprof — read-only scheduler & memory profiler
        \\
        \\Try one of these:
        \\  xsprof demo                         bundled replay in the browser
        \\  xsprof top                          live 5s scheduler view (CAP_PERFMON)
        \\  xsprof why --last 10m --dir <state> explain the recorder window
        \\  xsprof record                       save a short capture (default file)
        \\  xsprof doctor                       human-readable host readiness
        \\
        \\Full commands:
        \\  xsprof help
        \\Safety: read-only; every record has host_mutation=false.
        \\
    );
}

pub fn writeCommand(w: *Writer, command: []const u8) Writer.Error!void {
    if (std.mem.eql(u8, command, "top")) {
        return w.writeAll(
            \\xsprof top [--duration 5s] [--interval 500ms]
            \\  [--preset scheduler|memory|deep] [--top N] [--json] [--once]
            \\Open one read-only perf capture and print a ranked terminal view.
            \\Exits 1 with a SKIP/REFUSE reason when perf is unavailable.
            \\
        );
    }
    if (std.mem.eql(u8, command, "why")) {
        return w.writeAll(
            \\xsprof why [--input FILE | --last 10m --dir DIR]
            \\  [--json] [--pid N] [--comm NAME]
            \\Stream a journal or recorder window and explain the dominant waits,
            \\wakeup chains, faults, and advisor findings.
            \\
        );
    }
    if (std.mem.eql(u8, command, "record")) {
        return w.writeAll(
            \\xsprof record [--duration 1s] [--output FILE|-] [--preset NAME] [--force]
            \\Capture scheduler tracepoints read-only. Default output is
            \\session-<timestamp>.ndjson; use '-' for stdout.
            \\
        );
    }
    if (std.mem.eql(u8, command, "capture")) {
        return w.writeAll(
            \\xsprof capture --last 5m [--dir DIR] [--out FILE|-] [--force]
            \\Stream a recorder window to a canonical NDJSON journal.
            \\
        );
    }
    if (std.mem.eql(u8, command, "incident") or std.mem.eql(u8, command, "report")) {
        return w.writeAll(
            \\xsprof incident|report --last 10m [--dir DIR] [--out DIR] [--force]
            \\Write window.ndjson, summary.json, report.html, and trace.json.
            \\Default output is ./xsprof-incident-<timestamp>/.
            \\
        );
    }
    if (std.mem.eql(u8, command, "serve")) {
        return w.writeAll(
            \\xsprof serve [--journal FILE] [--recorder-dir DIR] [--live | --live-dir DIR]
            \\  [--port 8787] [--assets-dir DIR]
            \\Loopback-only console with a random token. The token is printed in
            \\the URL fragment; API requests still require it.
            \\
        );
    }
    if (std.mem.eql(u8, command, "doctor")) {
        return w.writeAll(
            \\xsprof doctor [--json]
            \\Report kernel, perf, tracefs, cgroup, PSI, libbpf, and web-asset
            \\readiness. Never executes a fix or suggests privilege escalation.
            \\
        );
    }
    return writeHelp(w);
}

pub fn writeHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof, read-only Linux scheduler & memory profiler
        \\USAGE:
        \\  xsprof <command> [options]        (no args prints a quickstart)
        \\START HERE:
        \\  demo                    Serve the bundled real capture
        \\  top                     Live ranked scheduler view (no daemon)
        \\  why                     Explain a journal or recorder window
        \\  doctor                  Check what this host can collect
        \\RECORDER:
        \\  daemon [--dir D] [--retain 10m] [--max-bytes 2G]
        \\         [--history-interval 60s] [--history-retain 24h]
        \\                          Foreground read-only flight recorder
        \\  capture --last D        Stream a recorder window (stdout or --out)
        \\  incident --last D       Offline incident bundle (alias: report)
        \\  history --last D        Sidecar history beyond raw retention
        \\  watch [--dir D]         Bounded ANSI recorder view
        \\CAPTURE / ANALYSIS:
        \\  record [--duration D]   One bounded capture (default file)
        \\  advise [--input F]      Seven-rule advisor (--json|--md)
        \\  metrics --input F       Canonical scheduler metrics
        \\  compare --base --candidate  Regression report (--fail-on)
        \\  timeline --input F      Chrome Trace export
        \\VIEWERS:
        \\  serve [--journal F]     Loopback replay/live console
        \\  demo                    Bundled capture
        \\  snapshot [--replay F]   Headless PNG of the console
        \\  ui [--replay F]         Native console (human-run window)
        \\HOST / SAFETY:
        \\  preflight --json        Host facts and capability probes
        \\  capabilities --json     perf/tracepoint/BPF/PMU/sched_ext states
        \\  pressure --json         PSI CPU/memory/IO stalls
        \\  cgroup --json           Read-only cgroup task attribution
        \\  bpf-gate --json         VM-marker-gated no-op BPF gate
        \\  version                 Print version
        \\  completions bash|zsh|fish  Shell completions
        \\  help [command]          This help or command help
        \\REFUSED (unsafe verbs; non-zero exit on host by design):
        \\  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\  Runtime samples never expose argv, environment, secrets, or tokens.
        \\
    );
}
