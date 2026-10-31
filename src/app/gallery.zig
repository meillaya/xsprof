//! Layout-driven profiler shell. P3 replaces the fixture numbers with the
//! EventStore and adds interaction; the visual grammar stays.

const std = @import("std");
const xsui = @import("xsui");
const draw = xsui.draw;
const layout = xsui.layout;
const widgets = xsui.widgets;
const frame_mod = xsui.frame;

pub fn build(ui: *layout.Ui) !void {
    const th = ui.theme;
    const root = try ui.column(.{ .bg = th.bg });

    const header = try ui.row(.{
        .height = 46,
        .padding = .{ .left = 12, .right = 12 },
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{ .text = "xsprof", .size = 16, .color = th.live, .weight = .bold });
    try ui.text(.{
        .text = "  read-only scheduler & memory profiler",
        .size = 10,
        .color = th.muted,
    });
    const spacer = try ui.column(.{ .flex = 1 });
    spacer.end();
    const live_chip = try widgets.chip(ui, "LIVE", th.live);
    live_chip.end();
    const ro_chip = try widgets.chip(ui, "READ-ONLY", th.pass);
    ro_chip.end();
    const mut_chip = try widgets.chip(ui, "host_mutation=false", th.muted);
    mut_chip.end();
    header.end();

    const body = try ui.row(.{
        .flex = 1,
        .padding = layout.Edges.all(12),
        .gap = 12,
    });

    const left = try ui.column(.{ .flex = 1.55, .gap = 12 });
    const stats = try ui.row(.{ .height = 58, .gap = 12 });
    const c1 = try widgets.statCard(ui, "CPU BUSY", "72%", th.live);
    c1.end();
    const c2 = try widgets.statCard(ui, "RUNQUEUE", "4.1", th.pending);
    c2.end();
    const c3 = try widgets.statCard(ui, "MIGRATIONS", "182", th.skip);
    c3.end();
    const c4 = try widgets.statCard(ui, "PAGE FAULTS", "9.4k", th.refuse);
    c4.end();
    stats.end();

    const cpu_panel = try widgets.panel(ui, "PER-CPU UTILIZATION", .{ .flex = 1 });
    try ui.custom(.{ .style = .{ .flex = 1 }, .paint = paintCpu });
    cpu_panel.end();

    const advisor = try widgets.panel(ui, "ADVISOR", .{ .height = 158 });
    try advisorRow(ui, "poor-numa-placement", "warning", th.skip);
    try advisorRow(ui, "excessive-locking", "warning", th.skip);
    try advisorRow(ui, "false-sharing", "critical", th.refuse);
    try ui.text(.{
        .text = "Recommendations are suggestions only - never applied.",
        .size = 9,
        .color = th.muted,
    });
    advisor.end();
    left.end();

    const right = try ui.column(.{ .flex = 1, .gap = 12 });
    const timeline = try widgets.panel(ui, "TIMELINE / WAKEUP FLOW", .{ .flex = 1 });
    try ui.custom(.{ .style = .{ .flex = 1 }, .paint = paintTimeline });
    timeline.end();

    const events = try widgets.panel(ui, "EVENT LEDGER", .{ .height = 178 });
    try ui.custom(.{ .style = .{ .flex = 1 }, .paint = paintEvents });
    events.end();
    right.end();

    body.end();

    const footer = try ui.row(.{
        .height = 26,
        .padding = .{ .left = 12, .right = 12 },
        .gap = 12,
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{
        .text = "1 Overview  2 Timeline  3 Advisor  4 Events  5 Capture    ? help    q quit",
        .size = 9,
        .color = th.muted,
    });
    const footer_spacer = try ui.column(.{ .flex = 1 });
    footer_spacer.end();
    try ui.text(.{ .text = "SKIP: uncollected", .size = 9, .color = th.skip });
    footer.end();
    root.end();
}

fn advisorRow(ui: *layout.Ui, id: []const u8, severity: []const u8, color: draw.Color) !void {
    const row = try ui.row(.{ .height = 20, .gap = 10, .align_items = .center });
    try ui.text(.{ .text = id, .size = 11, .color = ui.theme.text });
    const spacer = try ui.column(.{ .flex = 1 });
    spacer.end();
    try ui.text(.{ .text = severity, .size = 10, .color = color, .weight = .bold });
    row.end();
}

fn paintCpu(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    _ = user;
    const th = frame.theme;
    var lane: usize = 0;
    while (lane < 12) : (lane += 1) {
        const y = rect.y + @as(f32, @floatFromInt(lane)) * 17;
        if (y + 12 > rect.y + rect.h) break;
        const frac: f32 = 0.18 + @as(f32, @floatFromInt((lane * 37) % 78)) / 100.0;
        try frame.list.rect(rect.x, y + 3, rect.w - 34, 9, th.raised, clip);
        try frame.list.rect(
            rect.x,
            y + 3,
            (rect.w - 34) * frac,
            9,
            if (frac > 0.78) th.refuse else th.live,
            clip,
        );
        _ = try frame.list.text(0, &frame.regular, 9, rect.x + rect.w - 28, y, "CPU", th.muted, clip);
    }
}

fn paintTimeline(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    _ = user;
    const th = frame.theme;
    _ = try frame.list.text(0, &frame.regular, 12, rect.x, rect.y, "0ms", th.muted, clip);
    _ = try frame.list.text(0, &frame.regular, 12, rect.x + rect.w - 40, rect.y, "250ms", th.muted, clip);
    try frame.list.rect(rect.x, rect.y + 14, rect.w, 1, th.hairline, clip);
    var lane: usize = 0;
    while (lane < 10) : (lane += 1) {
        const y = rect.y + 22 + @as(f32, @floatFromInt(lane)) * 21;
        if (y + 16 > rect.y + rect.h) break;
        try frame.list.rect(rect.x, y, rect.w, 16, th.raised, clip);
        var slice: usize = 0;
        while (slice < 6) : (slice += 1) {
            const x = rect.x + (@as(f32, @floatFromInt((lane * 17 + slice * 29) % 100)) / 100.0) * rect.w;
            const sw = 18 + @as(f32, @floatFromInt((lane * 11 + slice * 13) % 60));
            const color = if (slice % 3 == 0) th.live else if (slice % 3 == 1) th.pass else th.vm;
            try frame.list.rect(x, y + 2, @min(sw, rect.x + rect.w - x), 12, color, clip);
        }
    }
}

fn paintEvents(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    _ = user;
    const th = frame.theme;
    const rows = [_]struct { ts: []const u8, kind: []const u8, status: []const u8, color: draw.Color }{
        .{ .ts = "12.004s", .kind = "sched_switch", .status = "host_mutation=false", .color = th.text },
        .{ .ts = "12.011s", .kind = "sched_wakeup", .status = "host_mutation=false", .color = th.text },
        .{ .ts = "12.019s", .kind = "page_fault", .status = "host_mutation=false", .color = th.text },
        .{ .ts = "12.026s", .kind = "sample_loss", .status = "unsafe / explicit", .color = th.refuse },
        .{ .ts = "12.031s", .kind = "capability", .status = "SKIP: perf_event_paranoid", .color = th.skip },
    };
    for (rows, 0..) |row, index| {
        const y = rect.y + @as(f32, @floatFromInt(index)) * 24;
        if (y + 18 > rect.y + rect.h) break;
        _ = try frame.list.text(0, &frame.regular, 10, rect.x, y, row.ts, th.muted, clip);
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 58, y, row.kind, row.color, clip);
        _ = try frame.list.text(0, &frame.regular, 9, rect.x + 178, y + 1, row.status, th.muted, clip);
    }
}

fn fnv(pixels: []const u8) u64 {
    var hash: u64 = 1469598103934665603;
    for (pixels) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return hash;
}

test "gallery layout renders deterministically" {
    var frame: frame_mod.Frame = undefined;
    try frame.init(std.testing.allocator, 960, 540, .{});
    defer frame.deinit();
    var ui = layout.Ui.init(&frame);
    defer ui.deinit();
    try build(&ui);
    try ui.finish();
    const pixels = try frame.render();
    defer std.testing.allocator.free(pixels);
    const first = fnv(pixels);
    const again = fnv(pixels);
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(u64, 0x2546c17f173084b4), first);
}
