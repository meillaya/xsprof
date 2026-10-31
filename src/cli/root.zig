const std = @import("std");
const json = @import("../core/json.zig");
const event = @import("../core/event.zig");
const version = @import("../core/version.zig");
const safety = @import("../core/safety.zig");
const proc = @import("../os/linux/proc.zig");
const aggregates = @import("../analyze/aggregates.zig");
const advisor = @import("../analyze/advisor.zig");
const journal = @import("../stream/journal.zig");
const chrome_trace = @import("../viz/chrome_trace.zig");
const ui_frame = @import("../ui/frame.zig");
const gallery = @import("../app/gallery.zig");
const app = @import("../app/app.zig");
const session_mod = @import("../stream/session.zig");
const server = @import("../serve/server.zig");
const live = @import("../capture/live.zig");
const ui_layout = @import("../ui/layout.zig");

const Writer = std.Io.Writer;

pub const unsafe_verbs = safety.unsafe_verbs;

const known_commands = [_][]const u8{
    "preflight",
    "capabilities",
    "advise",
    "timeline",
    "record",
    "serve",
    "snapshot",
    "ui",
};

const refusal_reason =
    "unsafe verb is disabled in the host operator (fail-closed); " ++
    "mutation is VM-lab-only with audit-id + rollback-id + lab marker";

fn writeHelp(w: *Writer) Writer.Error!void {
    try w.writeAll(
        \\xsprof — read-only Linux scheduler & memory profiler
        \\
        \\USAGE:
        \\  xsprof <command> [options]
        \\
        \\COMMANDS (read-only, fail-closed):
        \\  preflight --json        Read-only host facts + capability probes
        \\  capabilities --json     Probe perf/tracepoint/BPF/PMU/sched_ext
        \\  advise --json|--md      Performance Advisor report
        \\  timeline --input <f> [--window start:end] [--chunk-size N]
        \\                          Chrome Trace timeline from a JSONL journal
        \\  record --duration <ms> [--output <f>]
        \\                          Live read-only perf capture (SKIP if unprivileged)
        \\  serve [--journal <f>]   Read-only local web frontend
        \\  snapshot [--replay <f>] Headless PNG snapshot of the profiler UI
        \\  ui [--replay <f>]       Native profiler UI
        \\  version                 Print version
        \\  help                    Print this help
        \\
        \\REFUSED (unsafe verbs; non-zero exit on host by design):
        \\  load attach enable mutate apply sched-ext-attach setaffinity setpriority bind
        \\
        \\SAFETY:
        \\  Observation is read-only. Every record carries host_mutation=false.
        \\  Runtime samples never expose argv, environment, secrets, or tokens.
        \\
    );
}

fn writeRefusal(w: *Writer, verb: []const u8) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "event", .value = .{ .string = "refusal" } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "reason", .value = .{ .string = refusal_reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/event/v1" } },
        .{ .key = "status", .value = .{ .string = "refused" } },
        .{ .key = "verb", .value = .{ .string = verb } },
    } });
    try w.writeByte('\n');
}

fn isKnownCommand(cmd: []const u8) bool {
    for (known_commands) |known| {
        if (std.mem.eql(u8, cmd, known)) return true;
    }
    return false;
}

pub fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buffer: [4096]u8 = undefined;
    var out_file: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
    var err_buffer: [4096]u8 = undefined;
    var err_file: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);

    const code = try runWith(init.io, arena, args, &out_file.interface, &err_file.interface);
    try out_file.interface.flush();
    try err_file.interface.flush();
    return code;
}

fn hasJson(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}

fn cmdPreflight(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (!hasJson(args)) {
        try err.writeAll("preflight expects --json and remains read-only\n");
        return 2;
    }
    const capabilities = try proc.probeCapabilities(io, allocator);
    const facts = try proc.collectFacts(io, allocator);
    try proc.writePreflight(out, capabilities, facts);
    return 0;
}

fn cmdCapabilities(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (!hasJson(args)) {
        try err.writeAll("capabilities expects --json and remains read-only\n");
        return 2;
    }
    const capabilities = try proc.probeCapabilities(io, allocator);
    try proc.writeCapabilities(out, capabilities);
    try out.writeByte('\n');
    return 0;
}

fn cmdAdvise(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
) !u8 {
    var markdown = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--md")) markdown = true;
    }
    const facts = try proc.collectFacts(io, allocator);
    const agg = aggregates.fromFacts(facts);
    if (markdown) {
        try advisor.writeReportMarkdown(out, allocator, agg, .{});
    } else {
        try advisor.writeReportJson(out, allocator, agg, .{});
    }
    return 0;
}

fn cmdTimeline(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var window_text: ?[]const u8 = null;
    var chunk_size: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --input requires a path\n");
                return 2;
            }
            i += 1;
            input = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --output requires a path\n");
                return 2;
            }
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--window")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --window requires start:end\n");
                return 2;
            }
            i += 1;
            window_text = args[i];
        } else if (std.mem.eql(u8, arg, "--chunk-size")) {
            if (i + 1 >= args.len) {
                try err.writeAll("timeline: --chunk-size requires a number\n");
                return 2;
            }
            i += 1;
            const parsed = std.fmt.parseInt(usize, args[i], 10) catch {
                try err.writeAll("timeline: invalid --chunk-size\n");
                return 2;
            };
            chunk_size = if (parsed == 0) null else parsed;
        }
    }
    const input_path = input orelse {
        try err.writeAll("timeline requires --input <journal.jsonl>\n");
        return 2;
    };
    const window = if (window_text) |text| chrome_trace.parseWindow(text) orelse {
        try err.writeAll("timeline: invalid --window (expected start:end in microseconds)\n");
        return 2;
    } else null;

    const events = journal.read(io, allocator, input_path) catch |read_error| {
        try err.print("timeline: cannot read {s}: {s}\n", .{ input_path, @errorName(read_error) });
        return 1;
    };

    if (output) |path| {
        const file = if (path.len != 0 and path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
                try err.print("timeline: cannot open output {s}\n", .{path});
                return 1;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, .{}) catch {
                try err.print("timeline: cannot open output {s}\n", .{path});
                return 1;
            };
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try chrome_trace.writeTimeline(&file_writer.interface, allocator, events, window, chunk_size);
        try file_writer.interface.flush();
    } else {
        try chrome_trace.writeTimeline(out, allocator, events, window, chunk_size);
    }
    if (chunk_size != null) {
        try err.print("{{\"journal_rows\":{d}}}\n", .{events.len});
    }
    return 0;
}

fn themeFromName(name: []const u8) @import("../ui/draw.zig").Theme {
    if (std.mem.eql(u8, name, "light")) {
        return .{
            .bg = .{ .r = 0xf3, .g = 0xea, .b = 0xd7 },
            .panel = .{ .r = 0xff, .g = 0xf8, .b = 0xeb },
            .raised = .{ .r = 0xe9, .g = 0xdf, .b = 0xcb },
            .text = .{ .r = 0x1a, .g = 0x17, .b = 0x12 },
            .muted = .{ .r = 0x6b, .g = 0x5f, .b = 0x51 },
            .hairline = .{ .r = 0xc9, .g = 0xba, .b = 0xa2 },
        };
    }
    return .{};
}

fn cmdSnapshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var path: []const u8 = "xsprof-snapshot.png";
    var width: u32 = 1280;
    var height: u32 = 720;
    var theme_name: []const u8 = "warm-dark";
    var replay: ?[]const u8 = null;
    var screen_name: []const u8 = "overview";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            path = args[i];
        } else if (std.mem.eql(u8, arg, "--width") and i + 1 < args.len) {
            i += 1;
            width = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --width\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
            i += 1;
            height = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("snapshot: invalid --height\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--theme") and i + 1 < args.len) {
            i += 1;
            theme_name = args[i];
        } else if (std.mem.eql(u8, arg, "--replay") and i + 1 < args.len) {
            i += 1;
            replay = args[i];
        } else if (std.mem.eql(u8, arg, "--view") and i + 1 < args.len) {
            i += 1;
            screen_name = args[i];
        }
    }
    if (width < 64 or height < 64 or width > 4096 or height > 4096) {
        try err.writeAll("snapshot: width/height must be 64..4096\n");
        return 2;
    }
    var frame: ui_frame.Frame = undefined;
    frame.init(allocator, width, height, themeFromName(theme_name)) catch {
        try err.writeAll("snapshot: cannot initialize UI frame\n");
        return 1;
    };
    defer frame.deinit();
    var ui = ui_layout.Ui.init(&frame);
    defer ui.deinit();
    if (replay) |journal_path| {
        const screen = app.parseScreen(screen_name) orelse {
            try err.print("snapshot: unknown view {s}\n", .{screen_name});
            return 2;
        };
        const session = session_mod.Session.load(io, allocator, journal_path) catch |load_error| {
            try err.print("snapshot: cannot load {s}: {s}\n", .{ journal_path, @errorName(load_error) });
            return 1;
        };
        var state = app.State{ .session = &session, .screen = screen };
        app.view(&state, &ui) catch {
            try err.writeAll("snapshot: cannot build profiler view\n");
            return 1;
        };
    } else {
        gallery.build(&ui) catch {
            try err.writeAll("snapshot: cannot build gallery frame\n");
            return 1;
        };
    }
    ui.finish() catch {
        try err.writeAll("snapshot: cannot finish layout\n");
        return 1;
    };
    frame.savePng(io, path) catch |save_error| {
        try err.print("snapshot: cannot write {s}: {s}\n", .{ path, @errorName(save_error) });
        return 1;
    };
    try out.print("{s}\n", .{path});
    return 0;
}

fn cmdServe(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var port: u16 = 8787;
    var journal_path: []const u8 = "fixtures/ui/healthy.ndjson";
    var assets_dir: []const u8 = "zig-out/web";
    var addr: []const u8 = "127.0.0.1";
    var live_capture = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                try err.writeAll("serve: invalid --port\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--journal") and i + 1 < args.len) {
            i += 1;
            journal_path = args[i];
        } else if (std.mem.eql(u8, arg, "--assets-dir") and i + 1 < args.len) {
            i += 1;
            assets_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--addr") and i + 1 < args.len) {
            i += 1;
            addr = args[i];
        } else if (std.mem.eql(u8, arg, "--live")) {
            live_capture = true;
        }
    }
    if (!std.mem.eql(u8, addr, "127.0.0.1") and !std.mem.eql(u8, addr, "::1")) {
        try err.writeAll("serve: refusing non-loopback address\n");
        return 2;
    }
    var raw: [16]u8 = undefined;
    std.Io.randomSecure(io, &raw) catch {
        try err.writeAll("serve: entropy unavailable\n");
        return 1;
    };
    var token: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        token[index * 2] = hex[byte >> 4];
        token[index * 2 + 1] = hex[byte & 0x0f];
    }
    try out.print("http://{s}:{d}/?token={s}\n", .{ addr, port, token[0..] });
    try out.flush();
    server.run(io, allocator, .{
        .addr = addr,
        .port = port,
        .journal_path = journal_path,
        .assets_dir = assets_dir,
        .token = token[0..],
        .live = live_capture,
    }) catch |serve_error| {
        try err.print("serve: {s}\n", .{@errorName(serve_error)});
        return 1;
    };
    return 0;
}

fn stateName(state: live.State) []const u8 {
    return switch (state) {
        .READY => "READY",
        .DEGRADED => "DEGRADED",
        .SKIP => "SKIP",
        .REFUSE => "REFUSE",
    };
}

fn writeCapabilityEvent(
    out: *Writer,
    name: []const u8,
    state: []const u8,
    reason: []const u8,
) !void {
    try json.write(out, .{ .object = &.{
        .{ .key = "event", .value = .{ .string = "capability" } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "name", .value = .{ .string = name } },
        .{ .key = "reason", .value = .{ .string = reason } },
        .{ .key = "schema", .value = .{ .string = "xsprof/event/v1" } },
        .{ .key = "state", .value = .{ .string = state } },
    } });
    try out.writeByte('\n');
}

fn cmdRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var duration_ms: u32 = 1000;
    var output: ?[]const u8 = null;
    var bpf = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            duration_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("record: invalid --duration\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (std.mem.eql(u8, arg, "--bpf")) {
            bpf = true;
        }
    }
    if (bpf) {
        try writeCapabilityEvent(out, "bpf_capture", "SKIP", "BPF lane is VM-marker-gated and lands in P7");
        return 1;
    }
    const result = live.record(io, allocator, duration_ms) catch |record_error| {
        try writeCapabilityEvent(out, "live_capture", "SKIP", @errorName(record_error));
        return 1;
    };
    if (result.state != .READY) {
        try writeCapabilityEvent(out, "live_capture", stateName(result.state), result.reason);
        return 1;
    }

    var switches: u64 = 0;
    var wakeups: u64 = 0;
    var migrations: u64 = 0;
    var faults: u64 = 0;
    for (result.events) |e| {
        switch (e.kind) {
            .sched_switch => switches += 1,
            .sched_wakeup => wakeups += 1,
            .sched_migrate => migrations += 1,
            .page_fault => faults += 1,
            else => {},
        }
    }

    if (output) |path| {
        const file = if (path.len != 0 and path[0] == '/')
            std.Io.Dir.createFileAbsolute(io, path, .{}) catch {
                try err.print("record: cannot open output {s}\n", .{path});
                return 1;
            }
        else
            std.Io.Dir.cwd().createFile(io, path, .{}) catch {
                try err.print("record: cannot open output {s}\n", .{path});
                return 1;
            };
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        for (result.events) |e| {
            try event.writeJson(&writer.interface, e);
            try writer.interface.writeByte('\n');
        }
        try writer.interface.flush();
    } else {
        for (result.events) |e| {
            try event.writeJson(out, e);
            try out.writeByte('\n');
        }
    }

    try err.writeAll("{\"capability\":\"READY\",\"duration_ms\":");
    try err.print("{d}", .{duration_ms});
    try err.print(",\"events_captured\":{d},\"host_mutation\":false,", .{result.events.len});
    try err.print("\"page_faults\":{d},\"sched_migrations\":{d},\"sched_switches\":{d},", .{ faults, migrations, switches });
    try err.print("\"sched_wakeups\":{d},\"schema\":\"xsprof/capture-summary/v1\",", .{wakeups});
    try err.writeAll("\"source\":\"perf_tracepoint\"}\n");
    return 0;
}

pub fn runWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (args.len < 2) {
        try writeHelp(out);
        return 0;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h"))
    {
        try writeHelp(out);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try out.writeAll(version.line());
        return 0;
    }
    if (safety.isUnsafeVerb(cmd)) {
        try writeRefusal(out, cmd);
        return 1;
    }
    if (std.mem.eql(u8, cmd, "preflight")) {
        return cmdPreflight(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "capabilities")) {
        return cmdCapabilities(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "advise")) {
        return cmdAdvise(io, allocator, args[2..], out);
    }
    if (std.mem.eql(u8, cmd, "timeline")) {
        return cmdTimeline(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "snapshot")) {
        return cmdSnapshot(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        return cmdServe(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "record")) {
        return cmdRecord(io, allocator, args[2..], out, err);
    }
    if (isKnownCommand(cmd)) {
        try err.print("xsprof: {s} is not implemented in this build yet\n", .{cmd});
        return 2;
    }

    try writeRefusal(out, cmd);
    return 1;
}

fn testRun(
    args: []const []const u8,
    out_buffer: []u8,
    err_buffer: []u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    out.* = Writer.fixed(out_buffer);
    err.* = Writer.fixed(err_buffer);
    return runWith(std.testing.io, arena.allocator(), args, out, err);
}

test "help exits zero and names the tool" {
    var out_buffer: [4096]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "help" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "xsprof") != null);
}

test "version is stable" {
    var out_buffer: [128]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "version" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expectEqualStrings("xsprof 0.2.0\n", out.buffered());
}

test "unsafe verbs refuse with canonical json" {
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    for (unsafe_verbs) |verb| {
        var out: Writer = undefined;
        var err: Writer = undefined;
        const args = [_][]const u8{ "xsprof", verb };
        try std.testing.expectEqual(
            @as(u8, 1),
            try testRun(&args, &out_buffer, &err_buffer, &out, &err),
        );
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"event\":\"refusal\",\"host_mutation\":false," ++
                "\"reason\":\"unsafe verb is disabled in the host operator (fail-closed); " ++
                "mutation is VM-lab-only with audit-id + rollback-id + lab marker\"," ++
                "\"schema\":\"xsprof/event/v1\",\"status\":\"refused\"," ++
                "\"verb\":\"{s}\"}}\n",
            .{verb},
        );
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, out.buffered());
    }
}

test "unknown verbs fail closed" {
    var out_buffer: [1024]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "no-such-verb" };
    try std.testing.expectEqual(
        @as(u8, 1),
        try testRun(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"verb\":\"no-such-verb\"") != null);
}

test "preflight requires --json and emits a read-only document" {
    var out_buffer: [16384]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;

    const no_json = [_][]const u8{ "xsprof", "preflight" };
    try std.testing.expectEqual(
        @as(u8, 2),
        try testRun(&no_json, &out_buffer, &err_buffer, &out, &err),
    );

    const with_json = [_][]const u8{ "xsprof", "preflight", "--json" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&with_json, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"schema\":\"xsprof/preflight/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"capabilities\":[") != null);
}

test "capabilities requires --json and is an array" {
    var out_buffer: [8192]u8 = undefined;
    var err_buffer: [64]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    const args = [_][]const u8{ "xsprof", "capabilities", "--json" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.startsWith(u8, out.buffered(), "[{\"host_mutation\":false"));
}

test "advise json and markdown stay read-only" {
    var out_buffer: [16384]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;

    const json_args = [_][]const u8{ "xsprof", "advise", "--json" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&json_args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"schema\":\"xsprof/advisor-report/v1\"") != null);

    const md_args = [_][]const u8{ "xsprof", "advise", "--md" };
    try std.testing.expectEqual(
        @as(u8, 0),
        try testRun(&md_args, &out_buffer, &err_buffer, &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Performance Advisor Report") != null);
}
