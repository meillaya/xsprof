//! `incident` writes one offline folder from the recorder's retained window.

const std = @import("std");
const json = @import("../core/json.zig");
const extract = @import("../recorder/extract.zig");
const bundle = @import("../incident/bundle.zig");

const Writer = std.Io.Writer;

pub fn cmdIncident(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var last_text: []const u8 = "10m";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --dir requires a path\n");
                return 2;
            }
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --out requires a path\n");
                return 2;
            }
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--last")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --last requires a duration\n");
                return 2;
            }
            i += 1;
            last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("incident: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const destination = out_dir orelse {
        try err.writeAll("incident: --out <dir> is required\n");
        return 2;
    };
    const last_ms = extract.parseDuration(last_text) catch {
        try err.writeAll("incident: invalid --last duration\n");
        return 2;
    };
    const source_dir = if (dir) |value| value else try defaultDir(allocator);

    const result = bundle.write(io, allocator, .{
        .dir = source_dir,
        .out = destination,
        .last_ms = last_ms,
    }) catch |write_error| {
        switch (write_error) {
            error.NoWindow => try err.writeAll("incident: no events in the requested window\n"),
            error.NoRecorder => try err.print("incident: no recorder manifest in {s}\n", .{source_dir}),
            else => try err.print("incident: {s}\n", .{@errorName(write_error)}),
        }
        return 1;
    };

    try json.write(out, .{ .object = &.{
        .{ .key = "artifacts", .value = .{ .object = &.{
            .{ .key = "report", .value = .{ .string = result.report_path } },
            .{ .key = "summary", .value = .{ .string = result.summary_path } },
            .{ .key = "trace", .value = .{ .string = result.trace_path } },
            .{ .key = "window", .value = .{ .string = result.window_path } },
        } } },
        .{ .key = "clears", .value = .{ .unsigned = result.clears } },
        .{ .key = "findings", .value = .{ .unsigned = result.findings } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "schema", .value = .{ .string = "xsprof/incident-result/v1" } },
        .{ .key = "skips", .value = .{ .unsigned = result.skips } },
        .{ .key = "trace_events", .value = .{ .unsigned = result.trace_events } },
        .{ .key = "trace_truncated", .value = .{ .boolean = result.trace_truncated } },
        .{ .key = "window_events", .value = .{ .unsigned = result.events } },
    } });
    try out.writeByte('\n');
    return 0;
}

fn defaultDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/xsprof", .{std.mem.span(value)});
    }
    if (std.c.getenv("HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/xsprof", .{std.mem.span(value)});
    }
    return error.NoStateDirectory;
}

test "incident requires --out and a valid duration" {
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_args = [_][]const u8{"incident"};
    out = Writer.fixed(&out_buffer);
    err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        @as(u8, 2),
        try cmdIncident(std.testing.io, arena.allocator(), out_args[1..], &out, &err),
    );
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "--out") != null);

    var bad_args = [_][]const u8{ "--out", "/tmp/x", "--last", "nope" };
    out = Writer.fixed(&out_buffer);
    err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        @as(u8, 2),
        try cmdIncident(std.testing.io, arena.allocator(), &bad_args, &out, &err),
    );
}
