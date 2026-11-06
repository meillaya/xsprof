const std = @import("std");
const json = @import("../core/json.zig");
const event = @import("../core/event.zig");
const version = @import("../core/version.zig");
const safety = @import("../core/safety.zig");
const proc = @import("../os/linux/proc.zig");
const journal = @import("../stream/journal.zig");
const chrome_trace = @import("../viz/chrome_trace.zig");
const render_cmd = @import("render.zig");
const serve_cmd = @import("serve_cmd.zig");
const advise_cmd = @import("advise_cmd.zig");
const incident_cmd = @import("incident_cmd.zig");
const history_cmd = @import("history_cmd.zig");
const bpf_cmd = @import("bpf_cmd.zig");
const recorder_cmd = @import("recorder_cmd.zig");
const record_cmd = @import("record_cmd.zig");
const top_cmd = @import("top_cmd.zig");
const why_cmd = @import("why_cmd.zig");
const completions_cmd = @import("completions_cmd.zig");
const doctor_cmd = @import("doctor_cmd.zig");
const watch_cmd = @import("watch_cmd.zig");
const analysis_cmd = @import("analysis_cmd.zig");
const observe_cmd = @import("observe_cmd.zig");
const lab_cmd = @import("lab_cmd.zig");
const help = @import("help.zig");

const Writer = std.Io.Writer;

pub const unsafe_verbs = safety.unsafe_verbs;

const known_commands = [_][]const u8{
    "preflight",
    "capabilities",
    "advise",
    "incident",
    "history",
    "timeline",
    "record",
    "serve",
    "snapshot",
    "ui",
    "bpf-gate",
    "daemon",
    "capture",
    "doctor",
    "demo",
    "watch",
    "top",
    "why",
    "report",
    "completions",
    "metrics",
    "compare",
    "pressure",
    "cgroup",
    "lab",
};

const refusal_reason =
    "unsafe verb is disabled in the host operator (fail-closed); " ++
    "mutation is VM-lab-only with audit-id + rollback-id + lab marker";

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

pub fn runWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    if (args.len < 2) {
        // The signed app bundle launches the binary directly and asks for the
        // native UI through LSEnvironment instead of a shell wrapper.
        if (std.c.getenv("XSPROF_APP_MODE") != null) {
            return render_cmd.cmdUi(io, allocator, &.{}, out, err);
        }
        try help.writeQuickstart(out);
        return 0;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help")) {
        if (args.len > 2) try help.writeCommand(out, args[2]) else try help.writeHelp(out);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try help.writeHelp(out);
        return 0;
    }
    if (args.len > 2 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h"))) {
        try help.writeCommand(out, cmd);
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
        return advise_cmd.cmdAdvise(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "incident") or std.mem.eql(u8, cmd, "report")) {
        return incident_cmd.cmdIncident(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "history")) {
        return history_cmd.cmdHistory(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "timeline")) {
        return cmdTimeline(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "snapshot")) {
        return render_cmd.cmdSnapshot(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        return serve_cmd.cmdServe(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "record")) {
        return record_cmd.cmdRecord(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "top")) {
        return top_cmd.cmdTop(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "why")) {
        return why_cmd.cmdWhy(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "completions")) {
        return completions_cmd.cmdCompletions(args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "ui")) {
        return render_cmd.cmdUi(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "bpf-gate")) {
        return bpf_cmd.cmdBpf(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        return recorder_cmd.cmdDaemon(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "capture")) {
        return recorder_cmd.cmdCapture(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "doctor")) {
        return doctor_cmd.cmdDoctor(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "demo")) {
        return serve_cmd.cmdServe(io, allocator, &.{"--demo"}, out, err);
    }
    if (std.mem.eql(u8, cmd, "watch")) {
        return watch_cmd.cmdWatch(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "metrics")) {
        return analysis_cmd.cmdMetrics(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "compare")) {
        return analysis_cmd.cmdCompare(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "pressure")) {
        return observe_cmd.cmdPressure(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "cgroup")) {
        return observe_cmd.cmdCgroup(io, allocator, args[2..], out, err);
    }
    if (std.mem.eql(u8, cmd, "lab")) {
        return lab_cmd.cmdLab(io, allocator, args[2..], out, err);
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
    try std.testing.expectEqualStrings("xsprof 0.3.0\n", out.buffered());
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
