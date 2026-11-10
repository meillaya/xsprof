//! `incident` writes one offline folder from the recorder's retained window.

const std = @import("std");
const json = @import("../core/json.zig");
const extract = @import("../recorder/extract.zig");
const bundle = @import("../incident/bundle.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

pub fn cmdIncident(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var last_text: []const u8 = "10m";
    var force = false;
    var max_window_bytes: u64 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --dir requires a path\n");
                return .usage;
            }
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --out requires a path\n");
                return .usage;
            }
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--last")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --last requires a duration\n");
                return .usage;
            }
            i += 1;
            last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--max-window-bytes")) {
            if (i + 1 >= args.len) {
                try err.writeAll("incident: --max-window-bytes requires a size\n");
                return .usage;
            }
            i += 1;
            max_window_bytes = parseSize(args[i]) catch {
                try err.writeAll("incident: invalid --max-window-bytes\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("incident: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const destination = out_dir orelse blk: {
        const now = std.Io.Clock.now(.real, io).nanoseconds;
        break :blk try std.fmt.allocPrint(allocator, "xsprof-incident-{d}", .{now});
    };
    var exists = false;
    if (std.Io.Dir.cwd().access(io, destination, .{})) |_| {
        exists = true;
    } else |access_error| switch (access_error) {
        error.FileNotFound => {},
        else => exists = true,
    }
    if (exists and !force) {
        try err.print("incident: {s} already exists (use --force)\n", .{destination});
        return .refuse;
    }
    const last_ms = extract.parseDuration(last_text) catch {
        try err.writeAll("incident: invalid --last duration\n");
        return .usage;
    };
    const source_dir = if (dir) |value| value else try state_paths.stateDirWith(env, allocator);

    const result = bundle.write(io, allocator, .{
        .dir = source_dir,
        .out = destination,
        .last_ms = last_ms,
        .max_window_bytes = max_window_bytes,
    }) catch |write_error| {
        switch (write_error) {
            error.NoWindow => try err.writeAll("incident: no events in the requested window\n"),
            error.NoRecorder => try err.print("incident: no recorder manifest in {s}\n", .{source_dir}),
            else => try err.print("incident: {s}\n", .{@errorName(write_error)}),
        }
        return .refuse;
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
    return .ok;
}

fn parseSize(text: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidSize;
    var unit: u64 = 1;
    var number = trimmed;
    if (std.mem.endsWith(u8, trimmed, "G")) {
        unit = 1024 * 1024 * 1024;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "M")) {
        unit = 1024 * 1024;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "K")) {
        unit = 1024;
        number = trimmed[0 .. trimmed.len - 1];
    }
    const value = std.fmt.parseInt(u64, number, 10) catch return error.InvalidSize;
    return std.math.mul(u64, value, unit) catch error.InvalidSize;
}

test "incident requires --out and a valid duration" {
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [512]u8 = undefined;
    var out: Writer = undefined;
    var err: Writer = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bad_args = [_][]const u8{ "--out", "/tmp/x", "--last", "nope" };
    out = Writer.fixed(&out_buffer);
    err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdIncident(std.testing.io, arena.allocator(), state_paths.Env.process(), &bad_args, &out, &err),
    );
}
