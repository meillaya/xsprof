//! `xsprof why`: one streaming pass over a journal or recorder window, then a
//! concise ranked explanation with explicit caveats.

const std = @import("std");
const analyze_file = @import("../incident/analyze.zig");
const advisor = @import("../analyze/advisor.zig");
const rules = @import("../analyze/rules.zig");
const why_mod = @import("../analyze/why.zig");
const extract = @import("../recorder/extract.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

const Options = struct {
    input: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    last_text: []const u8 = "10m",
    json: bool = false,
    pid: ?i32 = null,
    comm: ?[]const u8 = null,
    help: bool = false,
};

fn parseArgs(args: []const []const u8, err: *Writer) !?Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input")) {
            if (i + 1 >= args.len) {
                try err.writeAll("why: --input requires a path\n");
                return null;
            }
            i += 1;
            options.input = args[i];
        } else if (std.mem.eql(u8, arg, "--dir")) {
            if (i + 1 >= args.len) {
                try err.writeAll("why: --dir requires a path\n");
                return null;
            }
            i += 1;
            options.dir = args[i];
        } else if (std.mem.eql(u8, arg, "--last")) {
            if (i + 1 >= args.len) {
                try err.writeAll("why: --last requires a duration\n");
                return null;
            }
            i += 1;
            options.last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--pid")) {
            if (i + 1 >= args.len) {
                try err.writeAll("why: --pid requires a number\n");
                return null;
            }
            i += 1;
            options.pid = std.fmt.parseInt(i32, args[i], 10) catch {
                try err.writeAll("why: invalid --pid\n");
                return null;
            };
        } else if (std.mem.eql(u8, arg, "--comm")) {
            if (i + 1 >= args.len) {
                try err.writeAll("why: --comm requires a value\n");
                return null;
            }
            i += 1;
            options.comm = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else {
            try err.print("why: unknown option {s}\n", .{arg});
            return null;
        }
    }
    return options;
}

fn tempPath(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const now = std.Io.Clock.now(.real, io).nanoseconds;
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-why-{d}.ndjson", .{now});
}

fn explain(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    options: Options,
    out: *Writer,
    err: *Writer,
) !Exit {
    var temp: ?[]const u8 = null;
    defer if (temp) |path| std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    var source: []const u8 = "";
    const input_path: []const u8 = if (options.input) |path| blk: {
        source = path;
        break :blk path;
    } else blk: {
        const last_ms = extract.parseDuration(options.last_text) catch {
            try err.writeAll("why: invalid --last duration\n");
            return .usage;
        };
        const dir = options.dir orelse try state_paths.stateDirWith(env, allocator);
        const path = try tempPath(allocator, io);
        temp = path;
        source = try std.fmt.allocPrint(allocator, "recorder:{s}", .{dir});
        const file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |open_error| {
            try err.print("why: cannot create temporary window: {s}\n", .{@errorName(open_error)});
            return .refuse;
        };
        {
            defer file.close(io);
            var buffer: [64 * 1024]u8 = undefined;
            var writer = file.writer(io, &buffer);
            extract.writeTo(io, allocator, .{ .dir = dir, .last_ms = last_ms }, &writer.interface) catch |extract_error| {
                try err.print("why: cannot extract window: {s}\n", .{@errorName(extract_error)});
                return .refuse;
            };
            try writer.interface.flush();
        }
        break :blk path;
    };

    const analyzed = analyze_file.analyzeFile(io, allocator, input_path, .{
        .max_trace_events = 0,
    }) catch |analyze_error| {
        try err.print("why: cannot analyze {s}: {s}\n", .{ source, @errorName(analyze_error) });
        return .refuse;
    };
    const session = analyzed.session;
    const agg = session.aggregate();
    const findings = advisor.analyze(allocator, agg, .{}) catch |advisor_error| {
        try err.print("why: advisor failed: {s}\n", .{@errorName(advisor_error)});
        return .refuse;
    };
    const rule_reports = rules.reports(allocator, agg, findings) catch |rules_error| {
        try err.print("why: rule reports failed: {s}\n", .{@errorName(rules_error)});
        return .refuse;
    };
    const window_ms = if (session.last_us > session.first_us)
        (session.last_us - session.first_us) / 1000
    else
        0;
    const report: why_mod.Report = .{
        .source = source,
        .window_ms = window_ms,
        .events = analyzed.event_count,
        .malformed = analyzed.malformed,
        .lost = session.metrics.lost,
        .out_of_order = session.metrics.out_of_order,
        .metrics = session.metrics,
        .findings = findings,
        .rule_reports = rule_reports,
        .pid_filter = options.pid,
        .comm_filter = options.comm,
    };
    if (options.json) {
        try why_mod.writeJson(out, &report);
    } else {
        try why_mod.writeText(out, &report);
    }
    return .ok;
}

pub fn cmdWhy(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    const options = (parseArgs(args, err) catch null) orelse return .usage;
    if (options.help) {
        try out.writeAll(
            \\xsprof why [--input FILE | --last 10m --dir DIR] [--json]
            \\  [--pid N] [--comm NAME]
            \\Explain the dominant scheduler waits and wakeup chains in a window.
            \\The input is streamed; no multi-GB journal is materialized.
            \\
        );
        return .ok;
    }
    return explain(io, allocator, env, options, out, err);
}

test "why defaults to the last ten minutes" {
    const args = [_][]const u8{};
    var err_buffer: [256]u8 = undefined;
    var err = Writer.fixed(&err_buffer);
    const options = (try parseArgs(&args, &err)).?;
    try std.testing.expectEqualStrings("10m", options.last_text);
    try std.testing.expect(!options.json);
}
