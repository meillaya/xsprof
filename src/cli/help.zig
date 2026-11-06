const std = @import("std");

const Writer = std.Io.Writer;

/// Primary UI-first surface: the console plus the few verbs an operator types
/// directly. Everything else stays valid but is listed by `help --all`.
pub const primary_verbs = [_][]const u8{ "ui", "record", "top", "why", "incident", "doctor" };

pub fn writeQuickstart(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\▚ xsprof — read-only scheduler & memory profiler
        \\
        \\Open the console:
        \\  xsprof                          native console (terminal + display)
        \\  xsprof serve --journal FILE     browser console (loopback, token in fragment)
        \\  xsprof demo                     bundled real replay in the browser
        \\
        \\Headless workflows:
        \\  xsprof record                   save a short capture
        \\  xsprof top                      live ranked scheduler view
        \\  xsprof why --last 10m --dir D   explain the recorder window
        \\  xsprof incident --last 10m      offline incident bundle
        \\  xsprof doctor                   human-readable host readiness
        \\
        \\Automation verbs (daemon, capture, history, verify, ...) are hidden
        \\from this list: xsprof help --all shows every command.
        \\Safety: read-only; every record has host_mutation=false.
        \\
    );
}

pub fn writeCommand(w: *Writer, command: []const u8) Writer.Error!void {
    if (std.mem.eql(u8, command, "ui")) {
        return w.writeAll(
            \\xsprof [ui] [--replay FILE] [--recorder-dir DIR] [--view NAME]
            \\  [--theme NAME] [--smoke]
            \\Open one native console window. Bare xsprof does this when stdout is a
            \\terminal and a display is available; use XSPROF_NO_UI=1 for scripts.
            \\
        );
    }
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
            \\  [--markers-only] [--max-events N] [--max-window-bytes N]
            \\Stream a recorder window to canonical NDJSON. Compact .xsraw segments
            \\are decoded; loss/truncation is always an explicit marker.
            \\
        );
    }
    if (std.mem.eql(u8, command, "incident") or std.mem.eql(u8, command, "report")) {
        return w.writeAll(
            \\xsprof incident|report --last 10m [--dir DIR] [--out DIR] [--force]
            \\  [--max-window-bytes N]
            \\Write window.ndjson, summary.json, report.html, and trace.json.
            \\Default output is ./xsprof-incident-<timestamp>/.
            \\
        );
    }
    if (std.mem.eql(u8, command, "serve")) {
        return w.writeAll(
            \\xsprof serve [--journal FILE] [--recorder-dir DIR] [--live | --live-dir DIR]
            \\  [--port 8787] [--assets-dir DIR]
            \\Loopback-only console with a random token. /api/window serves a
            \\bounded canonical recorder window to the browser.
            \\
        );
    }
    if (std.mem.eql(u8, command, "daemon")) {
        return w.writeAll(
            \\xsprof daemon --foreground [--dir DIR] [--retain 10m] [--max-bytes 2G]
            \\  [--history-interval 60s] [--history-retain 24h] [--duration MS]
            \\Foreground read-only flight recorder writing compact .xsraw segments.
            \\
        );
    }
    if (std.mem.eql(u8, command, "history")) {
        return w.writeAll(
            \\xsprof history --last 10m [--dir DIR] [--json|--md]
            \\Aggregate sidecar buckets that survive raw retention.
            \\
        );
    }
    if (std.mem.eql(u8, command, "watch")) {
        return w.writeAll(
            \\xsprof watch [--dir DIR] [--window 30s] [--duration MS] [--once]
            \\Bounded ANSI recorder view over .xsraw or legacy segments.
            \\
        );
    }
    if (std.mem.eql(u8, command, "verify")) {
        return w.writeAll(
            \\xsprof verify [--dir DIR] [--json]
            \\Decode every segment and report clean/dirty/corrupt/missing state.
            \\Exit 0 only when the state directory verifies READY.
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
        \\  xsprof                 open the console when a terminal + display exist
        \\  xsprof <command> ...   run a specific workflow
        \\PRIMARY COMMANDS:
        \\  ui                      Native console (same as bare xsprof)
        \\  record                  One bounded capture (default file)
        \\  top                     Live ranked scheduler view (no daemon)
        \\  why                     Explain a journal or recorder window
        \\  incident                Offline incident bundle (alias: report)
        \\  doctor                  Check what this host can collect
        \\MORE:
        \\  serve                   Loopback browser console
        \\  demo                    Bundled replay in the browser
        \\  help --all              List every command, including automation verbs
        \\  help <command>          Detailed help for one command
        \\REFUSED (unsafe verbs; non-zero exit on host by design):
        \\  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\  Runtime samples never expose argv, environment, secrets, or tokens.
        \\
    );
}

pub fn writeAllHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof, read-only Linux scheduler & memory profiler
        \\USAGE:
        \\  xsprof [<command>|ui] [options]
        \\CONSOLE:
        \\  ui                      Native console (bare xsprof default)
        \\  serve                   Loopback browser console
        \\  demo                    Bundled real replay in the browser
        \\  snapshot                Headless PNG of the console
        \\CAPTURE / ANALYSIS:
        \\  record                  One bounded capture (NDJSON)
        \\  top                     Live ranked scheduler view
        \\  why                     Streaming root-cause report
        \\  advise                  Seven-rule advisor (--json|--md)
        \\  metrics                 Canonical scheduler metrics
        \\  compare                 Baseline/candidate regression report
        \\  timeline                Chrome Trace export
        \\RECORDER:
        \\  daemon                  Foreground compact-segment flight recorder
        \\  capture                 Stream a recorder window (canonical NDJSON)
        \\  incident                Offline bundle (alias: report)
        \\  history                 Sidecar history beyond raw retention
        \\  watch                   Bounded ANSI recorder view
        \\  verify                  Read-only segment/state verification
        \\HOST / SAFETY:
        \\  preflight --json        Host facts and capability probes
        \\  capabilities --json     perf/tracepoint/BPF/PMU/sched_ext states
        \\  pressure --json         PSI CPU/memory/IO stalls
        \\  cgroup --json           Read-only cgroup task attribution
        \\  bpf-gate --json         VM-marker-gated no-op BPF gate
        \\  doctor                  Human or --json host readiness
        \\  lab                     Headless GUI scenario/QA runner
        \\  version                 Print version
        \\  completions bash|zsh|fish [--all]
        \\  help [command|--all]    This help, command help, or full list
        \\REFUSED (unsafe verbs; non-zero exit on host by design):
        \\  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\
    );
}
