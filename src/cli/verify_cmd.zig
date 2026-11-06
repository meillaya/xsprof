//! xsprof verify: read-only recorder state verification. Hidden automation
//! verb (not part of the primary UI-first surface).

const std = @import("std");
const verify = @import("../recorder/verify.zig");

const Writer = std.Io.Writer;

pub fn cmdVerify(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !u8 {
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
            return 2;
        }
    }
    const resolved = dir orelse try defaultDir(allocator);
    const report = verify.run(io, allocator, .{ .dir = resolved }) catch |run_error| {
        try err.print("verify: {s}: {s}\n", .{ resolved, @errorName(run_error) });
        return 1;
    };
    if (as_json) {
        try verify.writeJson(out, report);
        try out.writeByte('\n');
    } else {
        try verify.writeText(out, report);
    }
    return if (std.mem.eql(u8, report.state, "READY")) 0 else 1;
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

// Checks unknown flags are usage errors, not silent no-ops.
test "verify rejects unknown options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [256]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    try std.testing.expectEqual(
        @as(u8, 2),
        try cmdVerify(std.testing.io, arena.allocator(), &.{"--nope"}, &out, &err),
    );
}
