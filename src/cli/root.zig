const std = @import("std");
const json = @import("../core/json.zig");
const version = @import("../core/version.zig");
const safety = @import("../core/safety.zig");
const proc = @import("../os/linux/proc.zig");

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
