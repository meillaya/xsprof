const std = @import("std");
const scenario = @import("../app/lab/scenario.zig");

const Writer = std.Io.Writer;

pub fn cmdLab(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
    var scenario_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var json_output = false;
    var width: u32 = 1280;
    var height: u32 = 720;
    var list = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--scenario") and i + 1 < args.len) {
            i += 1;
            scenario_path = args[i];
        } else if (std.mem.eql(u8, arg, "--out") and i + 1 < args.len) {
            i += 1;
            out_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--width") and i + 1 < args.len) {
            i += 1;
            width = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("lab: invalid --width\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--height") and i + 1 < args.len) {
            i += 1;
            height = std.fmt.parseInt(u32, args[i], 10) catch {
                try err.writeAll("lab: invalid --height\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--list")) {
            list = true;
        } else {
            try err.print("lab: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    if (width < 320 or height < 240 or width > 4096 or height > 4096) {
        try err.writeAll("lab: width/height out of range\n");
        return 2;
    }
    if (list) {
        var dir = std.Io.Dir.cwd().openDir(io, "scenarios", .{ .iterate = true }) catch {
            try err.writeAll("lab: scenarios/ is not available\n");
            return 1;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try out.print("scenarios/{s}\n", .{entry.name});
        }
        return 0;
    }
    const path = scenario_path orelse {
        try err.writeAll("lab: --scenario <file> or --list is required\n");
        return 2;
    };
    const result = scenario.run(io, allocator, path, .{
        .width = width,
        .height = height,
        .out_dir = out_dir,
    }) catch |run_error| {
        try err.print("lab: {s}\n", .{@errorName(run_error)});
        return 1;
    };
    if (json_output) {
        try scenario.writeJson(out, result);
        try out.writeByte('\n');
    } else {
        try out.print("scenario {s}: {s}\n", .{
            result.id,
            if (result.passed) "PASS" else "FAIL",
        });
        try out.print("steps={d} events={d} lost={d} snapshots={d}\n", .{
            result.steps,
            result.events,
            result.lost,
            result.snapshots.len,
        });
        for (result.assertions) |assertion| {
            try out.print("{s} {s} {s}: actual={s} {s}\n", .{
                assertion.metric,
                assertion.op,
                assertion.expected,
                assertion.actual,
                if (assertion.passed) "PASS" else "FAIL",
            });
        }
    }
    return if (result.passed) 0 else 1;
}
