//! Small formatting and palette helpers shared by the app painters.

const std = @import("std");
const draw = @import("../ui/draw.zig");

pub fn formatTime(allocator: std.mem.Allocator, us: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d:0>3}s", .{ us / 1_000_000, (us / 1000) % 1000 });
}

pub fn palette(th: draw.Theme, comm: []const u8) draw.Color {
    var h: u32 = 2166136261;
    for (comm) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return switch (h % 5) {
        0 => th.live,
        1 => th.pass,
        2 => th.vm,
        3 => th.skip,
        else => th.pending,
    };
}
