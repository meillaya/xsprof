//! Single source of truth for the xsprof CLI command surface.
//!
//! One `commands` table drives:
//!   - dispatch (`src/cli/root.zig` switches on `Command.handler`),
//!   - `help`, `help --all`, and `help <command>`,
//!   - shell completions (`src/cli/completions_cmd.zig`),
//!   - the canonical manifest (`help --json --all`), committed verbatim at
//!     `packaging/cli-manifest.json` and consumed by the NixOS module for its
//!     unsafe-verb assertion.
//!
//! The unsafe verbs come from `src/core/safety.zig` so the refusal matrix has
//! one owner. Visibility is data (`visible`), not a second list: operator-
//! facing commands are shown by plain `help`, everything is documented by
//! `help --all` grouped by area.

const std = @import("std");
const safety = @import("../core/safety.zig");

pub const manifest_schema = "xsprof/cli-manifest/v1";
pub const manifest_path = "packaging/cli-manifest.json";
pub const manifest_max_bytes = 64 * 1024;

const Writer = std.Io.Writer;

pub const Group = enum {
    console,
    capture,
    recorder,
    analysis,
    host_safety,

    /// Human-facing help heading.
    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .console => "CONSOLE",
            .capture => "CAPTURE",
            .recorder => "RECORDER",
            .analysis => "ANALYSIS",
            .host_safety => "HOST / SAFETY",
        };
    }

    /// Stable identifier used in the JSON manifest.
    pub fn id(self: Group) []const u8 {
        return switch (self) {
            .console => "console",
            .capture => "capture",
            .recorder => "recorder",
            .analysis => "analysis",
            .host_safety => "host_safety",
        };
    }
};

pub const groups = [_]Group{ .console, .capture, .recorder, .analysis, .host_safety };

/// Identifier the dispatch switch in `root.zig` matches on. Adding a command
/// without handling its handler is a compile error.
pub const Handler = enum {
    advise,
    bpf_gate,
    capabilities,
    capture,
    cgroup,
    compare,
    completions,
    daemon,
    demo,
    doctor,
    help,
    history,
    incident,
    metrics,
    preflight,
    pressure,
    record,
    snapshot,
    timeline,
    top,
    ui,
    unsafe,
    validate,
    verify,
    version,
    watch,
    why,
};

pub const Command = struct {
    name: []const u8,
    /// Alternate spellings resolved by `find` (for example `report`).
    aliases: []const []const u8 = &.{},
    group: Group,
    /// Plain `help` lists visible commands; `help --all` lists every command.
    visible: bool,
    summary: []const u8,
    usage: []const u8,
    handler: Handler,
    /// True for mutating verbs the read-only host refuses before dispatch.
    unsafe: bool = false,
};

/// The command table. Ordered by help group for presentation; the manifest
/// sorts by name to stay canonical.
pub const commands = [_]Command{
    // CONSOLE
    .{
        .name = "ui",
        .group = .console,
        .visible = true,
        .summary = "Native console (bare xsprof default)",
        .usage =
        \\xsprof [ui] [--replay FILE] [--recorder-dir DIR] [--view NAME]
        \\  [--theme NAME] [--smoke]
        \\Open one native console window. Bare xsprof does this when stdout is a
        \\terminal and a display is available; use XSPROF_NO_UI=1 for scripts.
        \\
        ,
        .handler = .ui,
    },
    .{
        .name = "demo",
        .group = .console,
        .visible = true,
        .summary = "Bundled capture in the native console",
        .usage =
        \\xsprof demo [--view NAME] [--theme NAME] [--smoke]
        \\Open the bundled capture in the native console. Native-only: it fails
        \\with an explicit reason when no display is available. Headless output
        \\uses `xsprof snapshot` / `xsprof ui --smoke`.
        \\
        ,
        .handler = .demo,
    },
    .{
        .name = "snapshot",
        .group = .console,
        .visible = true,
        .summary = "Headless PNG of the console",
        .usage =
        \\xsprof snapshot [--replay FILE | --demo-model FILE] [--view NAME]
        \\  [--theme NAME] [--width N] [--height N] [--out FILE] [--a11y FILE]
        \\Render one deterministic CPU frame to PNG without a window.
        \\
        ,
        .handler = .snapshot,
    },
    .{
        .name = "help",
        .group = .console,
        .visible = true,
        .summary = "This help, command help, or the CLI manifest",
        .usage =
        \\xsprof help [command | --all | --json --all [--check]]
        \\Print the operator help, one command's usage, the grouped full command
        \\list, or the canonical `xsprof/cli-manifest/v1` document. `--check`
        \\compares that document byte-for-byte with packaging/cli-manifest.json.
        \\
        ,
        .handler = .help,
    },
    .{
        .name = "version",
        .group = .console,
        .visible = true,
        .summary = "Print the xsprof version",
        .usage =
        \\xsprof version
        \\Print the canonical version line (`xsprof <semver>`).
        \\
        ,
        .handler = .version,
    },
    // CAPTURE
    .{
        .name = "record",
        .group = .capture,
        .visible = true,
        .summary = "One bounded capture (default file)",
        .usage =
        \\xsprof record [--duration 1s] [--output FILE|-] [--preset NAME] [--force]
        \\Capture scheduler tracepoints read-only. Default output is
        \\session-<timestamp>.ndjson; use '-' for stdout.
        \\
        ,
        .handler = .record,
    },
    .{
        .name = "top",
        .group = .capture,
        .visible = true,
        .summary = "Live ranked scheduler view (no daemon)",
        .usage =
        \\xsprof top [--duration 5s] [--interval 500ms]
        \\  [--preset scheduler|memory|deep] [--top N] [--json] [--once]
        \\Open one read-only perf capture and print a ranked terminal view.
        \\Exits 1 with a SKIP/REFUSE reason when perf is unavailable.
        \\
        ,
        .handler = .top,
    },
    // RECORDER
    .{
        .name = "daemon",
        .group = .recorder,
        .visible = false,
        .summary = "Foreground compact-segment flight recorder",
        .usage =
        \\xsprof daemon --foreground [--dir DIR] [--retain 10m] [--max-bytes 2G]
        \\  [--history-interval 60s] [--history-retain 24h] [--duration MS]
        \\Foreground read-only flight recorder writing compact .xsraw segments.
        \\
        ,
        .handler = .daemon,
    },
    .{
        .name = "capture",
        .group = .recorder,
        .visible = false,
        .summary = "Stream a recorder window (canonical NDJSON)",
        .usage =
        \\xsprof capture --last 5m [--dir DIR] [--out FILE|-] [--force]
        \\  [--markers-only] [--max-events N] [--max-window-bytes N]
        \\Stream a recorder window to canonical NDJSON. Compact .xsraw segments
        \\are decoded; loss/truncation is always an explicit marker.
        \\
        ,
        .handler = .capture,
    },
    .{
        .name = "incident",
        .aliases = &.{"report"},
        .group = .recorder,
        .visible = true,
        .summary = "Offline incident bundle (alias: report)",
        .usage =
        \\xsprof incident|report --last 10m [--dir DIR] [--out DIR] [--force]
        \\  [--max-window-bytes N]
        \\Write window.ndjson, summary.json, report.html, and trace.json.
        \\Default output is ./xsprof-incident-<timestamp>/.
        \\
        ,
        .handler = .incident,
    },
    .{
        .name = "history",
        .group = .recorder,
        .visible = false,
        .summary = "Sidecar history beyond raw retention",
        .usage =
        \\xsprof history --last 10m [--dir DIR] [--json|--md]
        \\Aggregate sidecar buckets that survive raw retention.
        \\
        ,
        .handler = .history,
    },
    .{
        .name = "watch",
        .group = .recorder,
        .visible = false,
        .summary = "Bounded ANSI recorder view",
        .usage =
        \\xsprof watch [--dir DIR] [--window 30s] [--duration MS] [--once]
        \\Bounded ANSI recorder view over .xsraw or legacy segments.
        \\
        ,
        .handler = .watch,
    },
    .{
        .name = "verify",
        .group = .recorder,
        .visible = false,
        .summary = "Read-only segment/state verification",
        .usage =
        \\xsprof verify [--dir DIR] [--json]
        \\Decode every segment and report clean/dirty/corrupt/missing state.
        \\Exit 0 only when the state directory verifies READY.
        \\
        ,
        .handler = .verify,
    },
    // ANALYSIS
    .{
        .name = "advise",
        .group = .analysis,
        .visible = false,
        .summary = "Seven-rule advisor (--json|--md)",
        .usage =
        \\xsprof advise [--input FILE] [--md]
        \\Run the seven-rule read-only advisor; host facts are used when no
        \\journal is supplied. Recommendations are suggestions and never applied.
        \\
        ,
        .handler = .advise,
    },
    .{
        .name = "why",
        .group = .analysis,
        .visible = true,
        .summary = "Explain a journal or recorder window",
        .usage =
        \\xsprof why [--input FILE | --last 10m --dir DIR]
        \\  [--json] [--pid N] [--comm NAME]
        \\Stream a journal or recorder window and explain the dominant waits,
        \\wakeup chains, faults, and advisor findings.
        \\
        ,
        .handler = .why,
    },
    .{
        .name = "metrics",
        .group = .analysis,
        .visible = false,
        .summary = "Canonical scheduler metrics",
        .usage =
        \\xsprof metrics --input FILE [--json]
        \\Print the canonical 21-field scheduler metric set for one journal.
        \\
        ,
        .handler = .metrics,
    },
    .{
        .name = "compare",
        .group = .analysis,
        .visible = false,
        .summary = "Baseline/candidate regression report",
        .usage =
        \\xsprof compare --base FILE [--base FILE ...] --candidate FILE [--candidate FILE ...]
        \\  [--min-runs K] [--fail-on METRIC=THRESHOLD ...] [--json|--md|--html FILE]
        \\Compare scheduler captures (1..8 per side; repeated runs establish a
        \\run-to-run noise floor). --fail-on exits 3 only when the named metric
        \\regresses beyond its threshold and the observed noise (reportable
        \\regression, not a crash).
        \\
        ,
        .handler = .compare,
    },
    .{
        .name = "timeline",
        .group = .analysis,
        .visible = false,
        .summary = "Chrome Trace export",
        .usage =
        \\xsprof timeline --input FILE [--output FILE] [--window START:END]
        \\  [--chunk-size N]
        \\Export one canonical journal as Chrome Trace JSON.
        \\
        ,
        .handler = .timeline,
    },
    // HOST / SAFETY
    .{
        .name = "preflight",
        .group = .host_safety,
        .visible = false,
        .summary = "Host facts and capability probes",
        .usage =
        \\xsprof preflight --json
        \\Emit host facts and capability states as canonical read-only JSON.
        \\
        ,
        .handler = .preflight,
    },
    .{
        .name = "capabilities",
        .group = .host_safety,
        .visible = false,
        .summary = "perf/tracepoint/BPF/PMU/sched_ext states",
        .usage =
        \\xsprof capabilities --json
        \\Emit READY/DEGRADED/SKIP/REFUSE capability states with reasons.
        \\
        ,
        .handler = .capabilities,
    },
    .{
        .name = "pressure",
        .group = .host_safety,
        .visible = false,
        .summary = "PSI CPU/memory/IO stalls",
        .usage =
        \\xsprof pressure --json
        \\Emit the PSI CPU/memory/IO stall snapshot; absent signals stay SKIP.
        \\
        ,
        .handler = .pressure,
    },
    .{
        .name = "cgroup",
        .group = .host_safety,
        .visible = false,
        .summary = "Read-only cgroup task attribution",
        .usage =
        \\xsprof cgroup --json
        \\Emit read-only cgroup task attribution; never writes cgroup files.
        \\
        ,
        .handler = .cgroup,
    },
    .{
        .name = "bpf-gate",
        .group = .host_safety,
        .visible = false,
        .summary = "VM-marker-gated no-op BPF gate",
        .usage =
        \\xsprof bpf-gate --json
        \\Report the VM-marker-gated no-op BPF gate; the host REFUSEs by design.
        \\
        ,
        .handler = .bpf_gate,
    },
    .{
        .name = "doctor",
        .group = .host_safety,
        .visible = true,
        .summary = "Check what this host can collect",
        .usage =
        \\xsprof doctor [--json]
        \\Report kernel, perf, tracefs, cgroup, PSI, and libbpf readiness.
        \\Never executes a fix or suggests privilege escalation.
        \\
        ,
        .handler = .doctor,
    },
    .{
        .name = "validate",
        .group = .host_safety,
        .visible = false,
        .summary = "Validate wire documents against schemas",
        .usage =
        \\xsprof validate --schema NAME|PATH --file PATH [--json] [--ndjson]
        \\Validate one canonical wire document (or every non-empty NDJSON line)
        \\against the committed JSON schema. Exit 0 only when all documents pass.
        \\
        ,
        .handler = .validate,
    },
    .{
        .name = "completions",
        .group = .host_safety,
        .visible = false,
        .summary = "Static bash/zsh/fish completions",
        .usage =
        \\xsprof completions bash|zsh|fish [--all]
        \\Print static shell completions generated from the command table.
        \\
        ,
        .handler = .completions,
    },
};

/// Refused verbs, generated from the single unsafe-verb list in `safety.zig`.
/// They are table entries so `help`, completions, and the manifest can see them,
/// but dispatch refuses before any handler runs.
const unsafe_commands: [safety.unsafe_verbs.len]Command = blk: {
    var list: [safety.unsafe_verbs.len]Command = undefined;
    for (safety.unsafe_verbs, 0..) |verb, index| {
        list[index] = .{
            .name = verb,
            .group = .host_safety,
            .visible = false,
            .summary = "REFUSED: unsafe/mutating verb",
            .usage =
            \\xsprof <unsafe verb> ...
            \\REFUSED: unsafe/mutating verbs are disabled in the read-only host
            \\operator. xsprof refuses before dispatch and never elevates.
            \\
            ,
            .handler = .unsafe,
            .unsafe = true,
        };
    }
    break :blk list;
};

pub const all_commands: [commands.len + unsafe_commands.len]Command = commands ++ unsafe_commands;

/// Finds a command by name or alias. Returns null for unknown/removed verbs.
pub fn find(name: []const u8) ?*const Command {
    var index: usize = 0;
    while (index < all_commands.len) : (index += 1) {
        const command = &all_commands[index];
        if (std.mem.eql(u8, command.name, name)) return command;
        for (command.aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return command;
        }
    }
    return null;
}

pub fn isUnsafe(name: []const u8) bool {
    const command = find(name) orelse return false;
    return command.unsafe;
}

/// Verbs removed from the product. They fail closed with an explicit reason
/// instead of silently becoming an unknown verb, so scripts see why they
/// stopped working.
pub const removed_commands = [_][]const u8{"serve"};

pub fn isRemoved(name: []const u8) bool {
    for (removed_commands) |removed| {
        if (std.mem.eql(u8, removed, name)) return true;
    }
    return false;
}

/// Names of the visible commands in table order (plain help, primary shell
/// completions). Derived from the table; never hand-maintained.
pub fn visibleNames(buffer: [][]const u8) []const []const u8 {
    var count: usize = 0;
    for (commands) |command| {
        if (command.visible) count += 1;
    }
    std.debug.assert(count <= buffer.len);
    var index: usize = 0;
    for (commands) |command| {
        if (!command.visible) continue;
        buffer[index] = command.name;
        index += 1;
    }
    return buffer[0..index];
}

/// Writes the canonical `xsprof/cli-manifest/v1` document: compact separators,
/// keys ascending, one trailing newline, commands sorted by name.
pub fn writeManifest(w: *Writer) Writer.Error!void {
    var order: [all_commands.len]*const Command = undefined;
    for (all_commands, 0..) |_, index| order[index] = &all_commands[index];
    std.mem.sort(*const Command, &order, {}, manifestLessThan);

    try w.writeAll("{\"commands\":[");
    for (order, 0..) |command, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"aliases\":[");
        for (command.aliases, 0..) |alias, alias_index| {
            if (alias_index != 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{alias});
        }
        try w.print(
            "],\"group\":\"{s}\",\"name\":\"{s}\",\"unsafe\":{s},\"visible\":{s}}}",
            .{ command.group.id(), command.name, boolText(command.unsafe), boolText(command.visible) },
        );
    }
    try w.writeAll("],\"host_mutation\":false,\"schema\":\"" ++ manifest_schema ++ "\"}\n");
}

fn manifestLessThan(_: void, a: *const Command, b: *const Command) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// `help --json --all --check`: compares the generated manifest with the
/// committed file, byte for byte. Returns ok on match, refuse otherwise.
pub fn checkManifest(io: std.Io, allocator: std.mem.Allocator, out: *Writer, err: *Writer) !@import("exit.zig").Exit {
    var generated_buffer: [manifest_max_bytes]u8 = undefined;
    var generated_writer = Writer.fixed(&generated_buffer);
    try writeManifest(&generated_writer);
    const generated = generated_writer.buffered();

    const committed = std.Io.Dir.cwd().readFileAlloc(
        io,
        manifest_path,
        allocator,
        .limited(manifest_max_bytes),
    ) catch |read_error| {
        try err.print("cli-manifest: {s}: {s}\n", .{ manifest_path, @errorName(read_error) });
        return .refuse;
    };
    defer allocator.free(committed);

    if (!std.mem.eql(u8, committed, generated)) {
        try err.print(
            "cli-manifest: FAIL {s} is stale ({d} committed bytes, {d} generated)\n",
            .{ manifest_path, committed.len, generated.len },
        );
        return .refuse;
    }
    try out.print("cli-manifest: PASS ({d} commands, {s})\n", .{ all_commands.len, manifest_schema });
    return .ok;
}

test "command table has unique names, valid aliases, and sorted manifest" {
    for (all_commands, 0..) |command, index| {
        try std.testing.expect(command.name.len != 0);
        try std.testing.expect(commands.len + unsafe_commands.len == all_commands.len);
        var other: usize = index + 1;
        while (other < all_commands.len) : (other += 1) {
            try std.testing.expect(!std.mem.eql(u8, command.name, all_commands[other].name));
        }
        for (command.aliases) |alias| {
            try std.testing.expect(!std.mem.eql(u8, alias, command.name));
        }
    }
}

test "manifest is canonical and sorted by name" {
    var buffer: [manifest_max_bytes]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeManifest(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"commands\":["));
    try std.testing.expect(std.mem.endsWith(u8, text, "\"host_mutation\":false,\"schema\":\"xsprof/cli-manifest/v1\"}\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"advise\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"serve\"") == null);
    // Unsafe verbs come from safety.zig and are present in the manifest.
    for (safety.unsafe_verbs) |verb| {
        try std.testing.expect(std.mem.indexOf(u8, text, verb) != null);
    }
    // Sorted order: the first command name after `commands` must be "advise".
    const name_index = std.mem.indexOf(u8, text, "\"name\":\"").?;
    try std.testing.expect(std.mem.startsWith(u8, text[name_index..], "\"name\":\"advise\""));
}

test "manifest matches the committed packaging/cli-manifest.json" {
    // @embedFile cannot leave the module path in Zig 0.17, so the committed
    // manifest is read from the repository root at test time (the same
    // cwd-relative convention the golden fixtures use).
    var buffer: [manifest_max_bytes]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeManifest(&writer);
    const committed = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        manifest_path,
        std.testing.allocator,
        .limited(manifest_max_bytes),
    ) catch |read_error| {
        std.debug.print("cli manifest read failed: {s}: {s}\n", .{ manifest_path, @errorName(read_error) });
        return error.TestUnexpectedResult;
    };
    defer std.testing.allocator.free(committed);
    try std.testing.expectEqualStrings(committed, writer.buffered());
}
