const std = @import("std");

const Writer = std.Io.Writer;

pub fn writeHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof, read-only Linux scheduler & memory profiler
        \\USAGE:
        \\  xsprof <command> [options]
        \\COMMANDS (read-only, fail-closed):
        \\  preflight --json        Read-only host facts + capability probes
        \\  capabilities --json     Probe perf/tracepoint/BPF/PMU/sched_ext
        \\  advise --json|--md      Performance Advisor report
        \\  timeline --input <f> [--window start:end] [--chunk-size N]
        \\                          Chrome Trace timeline from a JSONL journal
        \\  record --duration <ms> [--output <f>]
        \\                          Live read-only perf capture (SKIP if unprivileged)
        \\  serve [--journal <f>] [--recorder-dir <d>] [--live]
        \\                          Read-only loopback console; live is Linux-only
        \\  snapshot [--replay <f>] [--recorder-dir <d>] [--theme <t>]
        \\           [--view <s>] [--overlay <o>] [--demo-model <f>]
        \\                          Headless PNG snapshot of the console
        \\  ui [--replay <f>] [--recorder-dir <d>] [--theme <t>] [--view <s>]
        \\                          Native console (human-run window)
        \\  bpf-gate --json         VM-marker-gated no-op BPF gate
        \\  daemon [--dir <d>]      Foreground Linux recorder
        \\  capture --last <dur>    Extract a recorder window
        \\  doctor --json           Read-only environment diagnostics
        \\  demo                    Serve the bundled capture
        \\  watch [--dir <d>]       ANSI live recorder view
        \\  metrics --input <f>     Scheduler metrics as JSON
        \\  compare --base --candidate  Regression report
        \\  pressure --json         PSI CPU/memory/IO stall counters
        \\  cgroup --json           Read-only cgroup task attribution
        \\  version                 Print version
        \\  help                    Print this help
        \\REFUSED (unsafe verbs; non-zero exit on host by design):
        \\  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\  Runtime samples never expose argv, environment, secrets, or tokens.
    );
}
