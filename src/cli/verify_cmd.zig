//! xsprof verify: read-only recorder state verification (automation verb,
//! documented by `xsprof help --all`).

const std = @import("std");
const verify = @import("../recorder/verify.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;
const state_paths = @import("../platform/state_paths.zig");

pub fn cmdVerify(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    var dir: ?[]const u8 = null;
    var as_json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            dir = args[i];
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else {
            try err.print("verify: unknown option {s}\n", .{arg});
            return .usage;
        }
    }
    const resolved = dir orelse try state_paths.stateDirWith(env, allocator);
    const report = verify.run(io, allocator, .{ .dir = resolved }) catch |run_error| {
        try err.print("verify: {s}: {s}\n", .{ resolved, @errorName(run_error) });
        return .refuse;
    };
    if (as_json) {
        try verify.writeJson(out, report);
        try out.writeByte('\n');
    } else {
        try verify.writeText(out, report);
    }
    return if (std.mem.eql(u8, report.state, "READY")) .ok else .refuse;
}

// Checks unknown flags are usage errors, not silent no-ops.
test "verify rejects unknown options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        Exit.usage,
        try cmdVerify(std.testing.io, arena.allocator(), state_paths.Env.process(), &.{"--nope"}, &out, &err),
    );
}
