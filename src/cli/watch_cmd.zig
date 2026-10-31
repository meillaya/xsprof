const std = @import("std");
const watch = @import("../tui/watch.zig");
const extract = @import("../recorder/extract.zig");

pub fn cmdWatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    var options: watch.Options = .{ .dir = "" };
    var dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--window") and i + 1 < args.len) {
            i += 1;
            options.window_ms = extract.parseDuration(args[i]) catch {
                try err.writeAll("watch: invalid --window\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            options.duration_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                try err.writeAll("watch: invalid --duration\n");
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else {
            try err.print("watch: unknown option {s}\n", .{arg});
            return 2;
        }
    }
    const resolved = dir orelse try defaultDir(allocator);
    options.dir = resolved;
    watch.run(io, allocator, options, out) catch |run_error| {
        try err.print("watch: {s}\n", .{@errorName(run_error)});
        return 1;
    };
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
