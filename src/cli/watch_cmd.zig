const std = @import("std");
const watch = @import("../tui/watch.zig");
const extract = @import("../recorder/extract.zig");
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

pub fn cmdWatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !Exit {
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
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--duration") and i + 1 < args.len) {
            i += 1;
            options.duration_ms = std.fmt.parseInt(u64, args[i], 10) catch {
                try err.writeAll("watch: invalid --duration\n");
                return .usage;
            };
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else {
            try err.print("watch: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const resolved = dir orelse try state_paths.stateDirWith(env, allocator);
    options.dir = resolved;
    watch.run(io, allocator, options, out) catch |run_error| {
        try err.print("watch: {s}\n", .{@errorName(run_error)});
        return .refuse;
    };
    return .ok;
}
