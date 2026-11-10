//! `history` reads per-segment sidecars that survive raw retention.

const std = @import("std");
const extract = @import("../recorder/extract.zig");
const history = @import("../recorder/history.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

pub fn cmdHistory(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var dir: ?[]const u8 = null;
    var last_text: []const u8 = "10m";
    var markdown = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir")) {
            if (i + 1 >= args.len) {
                try err.writeAll("history: --dir requires a path\n");
                return .usage;
            }
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--last")) {
            if (i + 1 >= args.len) {
                try err.writeAll("history: --last requires a duration\n");
                return .usage;
            }
            i += 1;
            last_text = args[i];
        } else if (std.mem.eql(u8, arg, "--md")) {
            markdown = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            continue;
        } else {
            try err.print("history: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const last_ms = extract.parseDuration(last_text) catch {
        try err.writeAll("history: invalid --last duration\n");
        return .usage;
    };
    const source_dir = if (dir) |value| value else try state_paths.stateDirWith(env, allocator);
    const report = history.scan(io, allocator, source_dir, last_ms) catch |scan_error| {
        try err.print("history: {s}\n", .{@errorName(scan_error)});
        return .refuse;
    };
    if (markdown) {
        try history.writeMarkdown(out, report);
    } else {
        try history.writeJson(out, report);
    }
    return .ok;
}

test "history requires a valid duration" {
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "--last", "nope" };
    try std.testing.expectEqual(
        Exit.usage,
        try cmdHistory(std.testing.io, arena.allocator(), state_paths.Env.process(), &args, &out, &err),
    );
}
