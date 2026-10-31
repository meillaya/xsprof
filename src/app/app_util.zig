//! Small formatting and palette helpers shared by the app painters.

const std = @import("std");
const draw = @import("../ui/draw.zig");
const session_mod = @import("../stream/session.zig");
const metrics_mod = @import("../analyze/metrics.zig");

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

pub fn paintHover(
    frame: *@import("../ui/frame.zig").Frame,
    plot_x: f32,
    top_y: f32,
    plot_w: f32,
    lane_h: f32,
    lanes: usize,
    start_us: u64,
    end_us: u64,
    clip: [4]f32,
) !void {
    const color = frame.theme.text;
    if (!frame.input.inside(plot_x, top_y, plot_w, lane_h * @as(f32, @floatFromInt(lanes)))) return;
    const fraction = (frame.input.pointer_x - plot_x) / @max(1.0, plot_w);
    const hover_us = start_us + @as(u64, @intFromFloat(fraction * @as(f32, @floatFromInt(end_us - start_us))));
    const hover_x = plot_x + plot_w * fraction;
    try frame.list.rect(hover_x, top_y, 1, lane_h * @as(f32, @floatFromInt(lanes)), color, clip);
    _ = try frame.list.text(
        0,
        &frame.regular,
        10,
        @min(hover_x + 4, plot_x + plot_w - 90),
        top_y,
        try formatTime(frame.allocator, hover_us),
        color,
        clip,
    );
}

pub fn selectedMetric(
    session: *const session_mod.Session,
    pid: i32,
    comm: []const u8,
) ?metrics_mod.TaskMetric {
    for (session.metrics.tasks) |task| {
        if (task.pid == pid and std.mem.eql(u8, task.comm, comm)) return task;
    }
    return null;
}
