//! Event ledger view and painter. Filters are combined by `filter.Filter`; the
//! ledger only materializes the rows that fit on screen.

const std = @import("std");
const xsui = @import("xsui");
const app_state = @import("app_state.zig");
const filter_mod = @import("filter.zig");
const app_util = @import("app_util.zig");
const frame_mod = xsui.frame;
const layout = xsui.layout;
const widgets = xsui.widgets;

const row_height = 22.0;

pub fn view(state: *app_state.EventsState, ui: *layout.Ui) !void {
    var panel = try widgets.panel(ui, "EVENT LEDGER / APPEND-ONLY", .{ .flex = 1 });
    try ui.custom(.{
        .style = .{ .flex = 1 },
        .user = state,
        .paint = paint,
    });
    panel.end();
}

fn paint(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    const state: *app_state.EventsState = @ptrCast(@alignCast(user.?));
    const session = state.session;
    const filter = state.filter.*;
    const th = frame.theme;
    const visible: usize = @intFromFloat(@max(0, rect.h) / row_height);
    if (visible == 0) return;
    state.rect = rect;
    state.visible = @min(visible, app_state.max_visible_events);

    var total: usize = 0;
    if (filter.active()) {
        for (session.events) |entry| {
            if (filter.matchesEvent(entry)) total += 1;
        }
    } else {
        total = session.events.len;
    }
    state.match_total = total;
    const max_scroll = total -| state.visible;
    state.scroll = @min(state.scroll, max_scroll);

    var skipped: usize = 0;
    var count: usize = 0;
    var index = session.events.len;
    while (index > 0 and count < state.visible) {
        index -= 1;
        const entry = session.events[index];
        if (filter.active() and !filter.matchesEvent(entry)) continue;
        if (skipped < state.scroll) {
            skipped += 1;
            continue;
        }
        state.visible_indices[count] = index;
        count += 1;
    }
    state.visible_count = count;
    state.start = if (count == 0) session.events.len else state.visible_indices[count - 1];

    var row: usize = 0;
    while (row < count) : (row += 1) {
        const entry = session.events[state.visible_indices[row]];
        const y = rect.y + @as(f32, @floatFromInt(row)) * row_height;
        if (frame.input.inside(rect.x, y, rect.w, row_height)) {
            try frame.list.rect(rect.x, y, rect.w, row_height - 1, th.raised, clip);
        }
        const is_loss = filter_mod.Filter.isLoss(entry);
        const color = if (is_loss) th.refuse else th.text;
        _ = try frame.list.text(0, &frame.regular, 12, rect.x, y, try app_util.formatTime(frame.allocator, entry.ts_ns / 1000), th.muted, clip);
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 76, y, @tagName(entry.kind), color, clip);
        var meta: [64]u8 = undefined;
        const meta_text = std.fmt.bufPrint(&meta, "cpu={d} pid={d}", .{ entry.cpu, entry.pid }) catch "";
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 192, y, meta_text, th.muted, clip);
        const detail = if (is_loss) "explicit sample loss - unsafe" else entry.detail;
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 300, y, detail, if (is_loss) th.refuse else th.muted, clip);
    }
}
