//! Temporary P2 demo frame. P3 replaces it with the profiler screens.

const std = @import("std");
const xsui = @import("xsui");
const ui = xsui.frame;
const draw = xsui.draw;

pub fn build(frame: *ui.Frame) !void {
    const theme = frame.theme;
    const full = frame.clip();
    const w: f32 = @floatFromInt(frame.width);
    const h: f32 = @floatFromInt(frame.height);
    const pad: f32 = 12;
    const header_h: f32 = 46;

    try frame.list.rect(0, 0, w, h, theme.bg, full);
    try frame.list.rect(0, 0, w, header_h, theme.raised, full);
    try frame.list.rect(0, header_h, w, 1, theme.hairline, full);
    _ = try frame.list.text(1, &frame.bold, 16, pad, 10, "xsprof", theme.live, full);
    _ = try frame.list.text(
        0,
        &frame.regular,
        10,
        pad + 64,
        16,
        "read-only scheduler & memory profiler",
        theme.muted,
        full,
    );
    var right = w - pad;
    const mutation = "host_mutation=false";
    const mutation_w: f32 = @floatFromInt(draw.DrawList.measure(&frame.regular, 10, mutation));
    right -= mutation_w;
    _ = try frame.list.text(0, &frame.regular, 10, right, 16, mutation, theme.muted, full);
    right -= 18;
    const readonly = "READ-ONLY";
    const readonly_w: f32 = @floatFromInt(draw.DrawList.measure(&frame.bold, 10, readonly));
    right -= readonly_w;
    _ = try frame.list.text(1, &frame.bold, 10, right, 16, readonly, theme.pass, full);
    right -= 18;
    const live = "LIVE";
    const live_w: f32 = @floatFromInt(draw.DrawList.measure(&frame.bold, 10, live));
    right -= live_w;
    _ = try frame.list.text(1, &frame.bold, 10, right, 16, live, theme.live, full);

    const top: f32 = header_h + 12;
    const left_w = (w - pad * 3) * 0.58;
    const right_x = pad * 2 + left_w;
    const right_w = w - right_x - pad;
    const bottom_h = 118;
    const main_h = h - top - bottom_h - pad * 3;

    try panel(frame, pad, top, left_w, main_h, "OVERVIEW");
    try panel(frame, right_x, top, right_w, main_h, "TIMELINE");
    try panel(frame, pad, top + main_h + pad, w - pad * 2, bottom_h, "ADVISOR / EVENTS");

    // Overview counters.
    const cards = [_]struct { label: []const u8, value: []const u8, color: draw.Color }{
        .{ .label = "CPU BUSY", .value = "72%", .color = theme.live },
        .{ .label = "RUNQUEUE", .value = "4.1", .color = theme.pending },
        .{ .label = "MIGRATIONS", .value = "182", .color = theme.skip },
        .{ .label = "PAGE FAULTS", .value = "9.4k", .color = theme.refuse },
    };
    var i: usize = 0;
    while (i < cards.len) : (i += 1) {
        const cw = (left_w - pad * 5) / 4;
        const cx = pad * 2 + @as(f32, @floatFromInt(i)) * (cw + pad);
        const cy = top + 34;
        try frame.list.roundedRect(cx, cy, cw, 58, 4, theme.raised, theme.hairline, 1, full);
        _ = try frame.list.text(0, &frame.regular, 10, cx + 8, cy + 8, cards[i].label, theme.muted, full);
        _ = try frame.list.text(1, &frame.bold, 16, cx + 8, cy + 24, cards[i].value, cards[i].color, full);
    }

    // Simple CPU bars.
    const bar_y = top + 118;
    const bar_w = left_w - pad * 3;
    _ = try frame.list.text(0, &frame.regular, 10, pad * 2, bar_y, "PER-CPU UTILIZATION", theme.muted, full);
    var cpu: usize = 0;
    while (cpu < 12) : (cpu += 1) {
        const frac: f32 = 0.2 + @as(f32, @floatFromInt((cpu * 37) % 80)) / 100.0;
        const y = bar_y + 18 + @as(f32, @floatFromInt(cpu)) * 14;
        try frame.list.rect(pad * 2, y, bar_w, 8, theme.raised, full);
        try frame.list.rect(pad * 2, y, bar_w * frac, 8, if (frac > 0.75) theme.refuse else theme.live, full);
        _ = try frame.list.text(0, &frame.regular, 10, pad * 2 + bar_w + 8, y - 2, "CPU", theme.muted, full);
    }

    // Timeline lanes.
    const lane_x = right_x + 12;
    const lane_w = right_w - 24;
    _ = try frame.list.text(0, &frame.regular, 10, lane_x, top + 32, "SCHED SWITCH / WAKEUP FLOW", theme.muted, full);
    var lane: usize = 0;
    while (lane < 10) : (lane += 1) {
        const y = top + 56 + @as(f32, @floatFromInt(lane)) * 22;
        try frame.list.rect(lane_x, y, lane_w, 16, theme.raised, full);
        var slice: usize = 0;
        while (slice < 6) : (slice += 1) {
            const x = lane_x + (@as(f32, @floatFromInt((lane * 17 + slice * 29) % 100)) / 100.0) * lane_w;
            const sw = 18 + @as(f32, @floatFromInt((lane * 11 + slice * 13) % 60));
            const color = if (slice % 3 == 0) theme.live else if (slice % 3 == 1) theme.pass else theme.vm;
            try frame.list.rect(x, y + 2, @min(sw, lane_x + lane_w - x), 12, color, full);
        }
    }

    // Advisor rows.
    const row_y = top + main_h + pad + 30;
    const rows = [_]struct { id: []const u8, sev: []const u8, color: draw.Color }{
        .{ .id = "poor-numa-placement", .sev = "warning", .color = theme.skip },
        .{ .id = "excessive-locking", .sev = "warning", .color = theme.skip },
        .{ .id = "false-sharing", .sev = "critical", .color = theme.refuse },
    };
    for (rows, 0..) |row, index| {
        const y = row_y + @as(f32, @floatFromInt(index)) * 22;
        _ = try frame.list.text(0, &frame.regular, 11, pad * 2, y, row.id, theme.text, full);
        _ = try frame.list.text(0, &frame.regular, 10, pad * 2 + 220, y, row.sev, row.color, full);
        _ = try frame.list.text(
            0,
            &frame.regular,
            10,
            pad * 2 + 300,
            y,
            "suggestions only - never applied",
            theme.muted,
            full,
        );
    }
    _ = try frame.list.text(
        0,
        &frame.regular,
        9,
        pad * 2,
        h - 18,
        "1 Overview  2 Timeline  3 Advisor  4 Events  5 Capture   ? help",
        theme.muted,
        full,
    );
}

fn panel(frame: *ui.Frame, x: f32, y: f32, w: f32, h: f32, title: []const u8) !void {
    const theme = frame.theme;
    const full = frame.clip();
    try frame.list.roundedRect(x, y, w, h, 4, theme.panel, theme.hairline, 1, full);
    try frame.list.rect(x + 1, y + 26, w - 2, 1, theme.hairline, full);
    _ = try frame.list.text(0, &frame.bold, 10, x + 10, y + 8, title, theme.muted, full);
}

test "demo builds and rasterizes" {
    var frame: ui.Frame = undefined;
    try frame.init(std.testing.allocator, 480, 300, .{});
    defer frame.deinit();
    try build(&frame);
    const pixels = try frame.render();
    defer std.testing.allocator.free(pixels);
    try std.testing.expect(pixels.len == 480 * 300 * 4);
}
