//! Events screen: searchable append-only ledger, type filters, and the
//! sanitized field detail pane.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const format = @import("format.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Color = xsui.Color;
const Theme = xsui.Theme;
const Model = model_mod.Model;
const State = state_mod.State;
const style = common.style;
const measure = common.measure;
const label = common.label;
const labelRight = common.labelRight;
const borderLine = common.borderLine;

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const w = width - stage_x - pad * 2;
    var eyebrow = style(common.text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    try label(canvas, x, y, "APPEND-ONLY LEDGER  ·  SANITIZED", eyebrow);
    var h1 = style(common.text_13, th.text, .bold);
    h1.size = if (width <= 780) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Events", h1);
    try drawFilterField(canvas, th, .{ .x = x + w - 296.61, .y = y + 8.75, .w = 296.61, .h = 32 }, state.events_query);
    try borderLine(canvas, x, y + 53.75, w, th.line);
    try drawTypes(model, state, canvas, th, x, y + 65.75);

    const body_y = y + 99.75;
    if (width <= 1140) {
        try drawLedger(model, state, canvas, th, .{ .x = x, .y = body_y, .w = w, .h = 573.5 });
        try drawDetail(model, state, canvas, th, .{ .x = x, .y = body_y + 585.5, .w = w, .h = 260 });
        return;
    }
    const ledger_w = w - 316;
    try drawLedger(model, state, canvas, th, .{ .x = x, .y = body_y, .w = ledger_w, .h = 573.5 });
    try drawDetail(model, state, canvas, th, .{ .x = x + ledger_w + 12, .y = body_y, .w = 304, .h = 260 });
}

fn drawFilterField(canvas: *Canvas, th: Theme, rect: Rect, query: []const u8) !void {
    try canvas.rounded(rect, 4, th.field, th.line, 1);
    var fl = style(common.text_95, th.faint, .regular);
    fl.tracking = 0.95;
    try label(canvas, rect.x + 9, rect.y + 5.5, "FILTER", fl);
    try label(canvas, rect.x + 57, rect.y + 8, if (query.len > 0) query else "comm, pid, type…", style(common.text_11, if (query.len > 0) th.text else th.faint, .regular));
    try canvas.rounded(.{ .x = rect.x + rect.w - 21.5, .y = rect.y + 9.75, .w = 14.5, .h = 14.5 }, 3, th.raised, th.line, 1);
    try label(canvas, rect.x + rect.w - 18.5, rect.y + 11, "/", style(common.text_10, th.muted, .regular));
    _ = canvas.textField(520, rect, "Filter events", query);
    try borderLine(canvas, rect.x, rect.y + rect.h, rect.w, th.line);
}

fn drawTypes(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, x: f32, y: f32) !void {
    var buf: [32]u8 = undefined;
    var cx = x;
    const all = std.fmt.bufPrint(&buf, "All {d}", .{model.summary.events}) catch "All";
    try typeChip(canvas, th, &cx, y, all, std.mem.eql(u8, state.events_type, "all"), false, 600);
    const order = [_][]const u8{ "sched_switch", "sched_wakeup", "sched_migrate", "page_fault", "cache_miss", "loss" };
    for (order, 0..) |kind, kind_index| {
        const count = countFor(model, kind);
        if (count == 0) continue;
        var count_buf: [32]u8 = undefined;
        var label_buf: [64]u8 = undefined;
        const label_text = std.fmt.bufPrint(&label_buf, "{s} {s}", .{ typeLabel(kind), format.int(&count_buf, count) }) catch typeLabel(kind);
        try typeChip(canvas, th, &cx, y, label_text, std.mem.eql(u8, state.events_type, kind), std.mem.eql(u8, kind, "loss"), 601 + @as(u32, @intCast(kind_index)));
    }
    var total_buf: [64]u8 = undefined;
    var total_count_buf: [32]u8 = undefined;
    const total_text = std.fmt.bufPrint(&total_buf, "{s} events · showing {d}", .{ format.int(&total_count_buf, model.summary.events), @min(model.events.len, 80) }) catch "";
    try labelRight(canvas, x + 1300, y + 4, total_text, style(common.text_10, th.dim, .regular));
}

fn countFor(model: *const Model, kind: []const u8) u32 {
    for (model.typeCounts) |item| {
        if (std.mem.eql(u8, item.kind, kind)) return item.count;
    }
    return 0;
}

fn typeChip(canvas: *Canvas, th: Theme, x: *f32, y: f32, text_value: []const u8, active: bool, loss: bool, hit_id: u32) !void {
    const tw = 18 + measure(canvas, text_value, style(common.text_105, th.muted, .regular));
    const color = if (loss) th.refuse else if (active) th.live else th.line;
    try canvas.rounded(.{ .x = x.*, .y = y, .w = tw, .h = 26 }, 3, if (active) th.tint_live else th.panel, color, 1);
    try label(canvas, x.* + 9, y + 6.5, text_value, style(common.text_105, if (active) th.live else if (loss) th.refuse else th.muted, .regular));
    _ = canvas.choice(hit_id, .{ .x = x.*, .y = y, .w = tw, .h = 26 }, text_value, active);
    x.* += tw + 6;
}

fn drawLedger(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    if (rect.w < 800) {
        try drawLedgerCompact(model, state, canvas, th, rect);
        return;
    }
    try canvas.fill(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = 31 }, th.raised);
    try borderLine(canvas, rect.x + 1, rect.y + 32, rect.w - 2, th.line);
    var head = style(common.text_95, th.faint, .regular);
    head.tracking = 0.76;
    const cols = [_]struct { x: f32, text: []const u8, right: bool }{
        .{ .x = 14, .text = "TIME", .right = false },
        .{ .x = 100, .text = "TYPE", .right = false },
        .{ .x = 224, .text = "CPU", .right = false },
        .{ .x = 270, .text = "COMM / PID", .right = false },
        .{ .x = 560, .text = "DETAIL", .right = false },
    };
    try label(canvas, rect.x + cols[0].x, rect.y + 8, cols[0].text, head);
    try label(canvas, rect.x + cols[1].x, rect.y + 8, cols[1].text, head);
    try label(canvas, rect.x + cols[2].x, rect.y + 8, cols[2].text, head);
    try label(canvas, rect.x + cols[3].x, rect.y + 8, cols[3].text, head);
    try label(canvas, rect.x + cols[4].x, rect.y + 8, cols[4].text, head);

    canvas.pushClip(.{ .x = rect.x + 1, .y = rect.y + 32, .w = rect.w - 2, .h = rect.h - 33 });
    var row_y = rect.y + 32;
    const max_rows: usize = 18;
    var matched: usize = 0;
    var shown: usize = 0;
    for (model.events) |event| {
        if (!eventMatches(event, state)) continue;
        matched += 1;
        if (shown >= max_rows) continue;
        const i = shown;
        shown += 1;
        if (i % 2 == 1) try canvas.fill(.{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 27 }, th.panel);
        if (event.loss) try canvas.fill(.{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 27 }, th.tint_refuse);
        var tb: [32]u8 = undefined;
        try label(canvas, rect.x + cols[0].x, row_y + 5, format.secs(&tb, event.ts, 3), style(common.text_11, th.dim, .regular));
        const type_color = eventColor(th, event.type);
        try label(canvas, rect.x + cols[1].x, row_y + 5.5, fullTypeLabel(event.type), style(common.text_10, type_color, .regular));
        var cb: [16]u8 = undefined;
        try label(canvas, rect.x + cols[2].x, row_y + 5, std.fmt.bufPrint(&cb, "c{d}", .{event.cpu}) catch "", style(common.text_11, th.dim, .regular));
        var pb: [48]u8 = undefined;
        const comm_pid = std.fmt.bufPrint(&pb, "{s} {d}", .{ event.comm, event.pid }) catch event.comm;
        try label(canvas, rect.x + cols[3].x, row_y + 5, comm_pid, style(common.text_11, th.text, .regular));
        try label(canvas, rect.x + cols[4].x, row_y + 5, event.detail, style(common.text_11, th.muted, .regular));
        try borderLine(canvas, rect.x + 1, row_y + 27, rect.w - 2, th.line);
        var row_buf: [96]u8 = undefined;
        const row_label = std.fmt.bufPrint(&row_buf, "{s} {s} pid {d} cpu {d}", .{
            fullTypeLabel(event.type), event.comm, event.pid, event.cpu,
        }) catch event.comm;
        _ = canvas.listItem(500 + @as(u32, @intCast(i)), .{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 27 }, row_label, false);
        row_y += 27;
    }
    canvas.popClip();
    try borderLine(canvas, rect.x + 1, rect.y + rect.h - 28, rect.w - 2, th.line);
    var footer_buf: [128]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "Showing first {d} of {d} matches. Refine the filter or pick an event type to narrow the ledger.", .{ @min(shown, 80), matched }) catch "";
    try label(canvas, rect.x + 14, rect.y + rect.h - 21, footer, style(common.text_10, th.faint, .regular));
}

fn drawLedgerCompact(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    canvas.pushClip(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 35 });
    var row_y = rect.y + 1;
    const max_rows: usize = 8;
    var matched: usize = 0;
    var shown: usize = 0;
    for (model.events) |event| {
        if (!eventMatches(event, state)) continue;
        matched += 1;
        if (shown >= max_rows) continue;
        const i = shown;
        shown += 1;
        if (i % 2 == 1) try canvas.fill(.{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 60 }, th.panel);
        if (event.loss) try canvas.fill(.{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 60 }, th.tint_refuse);
        var tb: [32]u8 = undefined;
        try label(canvas, rect.x + 12, row_y + 7, format.secs(&tb, event.ts, 3), style(common.text_11, th.dim, .regular));
        const type_color = eventColor(th, event.type);
        try label(canvas, rect.x + 64, row_y + 7.5, fullTypeLabel(event.type), style(common.text_10, type_color, .regular));
        var cb: [16]u8 = undefined;
        const cpu_text = std.fmt.bufPrint(&cb, "c{d}", .{event.cpu}) catch "";
        try labelRight(canvas, rect.x + rect.w - 12, row_y + 7, cpu_text, style(common.text_11, th.dim, .regular));
        var pb: [48]u8 = undefined;
        const comm_pid = std.fmt.bufPrint(&pb, "{s} {d}", .{ event.comm, event.pid }) catch event.comm;
        try label(canvas, rect.x + 12, row_y + 24, comm_pid, style(common.text_12, th.text, .regular));
        try label(canvas, rect.x + 12, row_y + 42, event.detail, style(common.text_105, th.muted, .regular));
        try borderLine(canvas, rect.x + 1, row_y + 60, rect.w - 2, th.line);
        var row_buf: [96]u8 = undefined;
        const row_label = std.fmt.bufPrint(&row_buf, "{s} {s} pid {d} cpu {d}", .{
            fullTypeLabel(event.type), event.comm, event.pid, event.cpu,
        }) catch event.comm;
        _ = canvas.listItem(500 + @as(u32, @intCast(i)), .{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 60 }, row_label, false);
        row_y += 60;
    }
    canvas.popClip();
    try borderLine(canvas, rect.x + 1, rect.y + rect.h - 28, rect.w - 2, th.line);
    var footer_buf: [128]u8 = undefined;
    const footer = std.fmt.bufPrint(&footer_buf, "{d} matches · {d} shown", .{ matched, shown }) catch "";
    try label(canvas, rect.x + 12, rect.y + rect.h - 21, footer, style(common.text_10, th.faint, .regular));
}

fn drawDetail(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    if (state.events_selected) |index| {
        if (index < model.events.len) {
            const event = model.events[index];
            var hb: [128]u8 = undefined;
            try label(canvas, rect.x + 14, rect.y + 9, std.fmt.bufPrint(&hb, "EVENT {d}", .{event.id}) catch "EVENT", style(common.text_95, th.dim, .regular));
            try borderLine(canvas, rect.x + 1, rect.y + 36, rect.w - 2, th.line);
            try label(canvas, rect.x + 14, rect.y + 49, typeLabel(event.type), style(common.text_13, th.text, .bold));
            var y = rect.y + 76;
            for (event.fields) |field| {
                if (field.len < 2) continue;
                try label(canvas, rect.x + 14, y, field[0], style(common.text_10, th.dim, .regular));
                try label(canvas, rect.x + 100, y, field[1], style(common.text_10, th.muted, .regular));
                y += 20;
            }
            const actions_y = rect.y + rect.h - 42;
            const timeline_btn = Rect{ .x = rect.x + 14, .y = actions_y, .w = 88, .h = 28 };
            const filter_btn = Rect{ .x = rect.x + 110, .y = actions_y, .w = 106, .h = 28 };
            try canvas.rounded(timeline_btn, 4, th.raised, th.line_strong, 1);
            try label(canvas, timeline_btn.x + 9, actions_y + 5.5, "Timeline", style(common.text_11, th.text, .regular));
            try canvas.rounded(filter_btn, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line_strong, 1);
            try label(canvas, filter_btn.x + 9, actions_y + 5.5, "Filter task", style(common.text_11, th.muted, .regular));
            _ = canvas.button(610, timeline_btn, "Open event in timeline");
            _ = canvas.button(611, filter_btn, "Filter by task");
            return;
        }
    }
    var body = style(common.text_11, th.dim, .regular);
    body.line_height = 1.6;
    body.wrap = true;
    _ = try canvas.textIn(.{ .x = rect.x + 14, .y = rect.y + 12, .w = rect.w - 28, .h = 80 }, body, "Select a ledger row to read its fields.");
    _ = try canvas.textIn(.{ .x = rect.x + 14, .y = rect.y + 96, .w = rect.w - 28, .h = 90 }, body, "Sanitized: runtime samples never include argv, environ, paths, or raw comm bytes.");
}

pub fn typeLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "sched_switch")) return "switch";
    if (std.mem.eql(u8, kind, "sched_wakeup")) return "wakeup";
    if (std.mem.eql(u8, kind, "sched_migrate")) return "migrate";
    if (std.mem.eql(u8, kind, "page_fault")) return "page fault";
    if (std.mem.eql(u8, kind, "cache_miss")) return "cache miss";
    if (std.mem.eql(u8, kind, "loss")) return "loss";
    return kind;
}

pub fn eventColor(th: Theme, kind: []const u8) Color {
    if (std.mem.eql(u8, kind, "sched_switch")) return th.live;
    if (std.mem.eql(u8, kind, "sched_wakeup")) return th.pass;
    if (std.mem.eql(u8, kind, "sched_migrate")) return th.vm;
    if (std.mem.eql(u8, kind, "page_fault")) return th.skip;
    if (std.mem.eql(u8, kind, "cache_miss")) return th.pending;
    if (std.mem.eql(u8, kind, "loss")) return th.refuse;
    return th.muted;
}

fn eventMatches(event: model_mod.Event, state: *const State) bool {
    if (!std.mem.eql(u8, state.events_type, "all") and !std.mem.eql(u8, state.events_type, event.type)) return false;
    const query = state.events_query;
    if (query.len == 0) return true;
    var q: [128]u8 = undefined;
    const qn = @min(query.len, q.len);
    for (query[0..qn], 0..) |c, i| q[i] = std.ascii.toLower(c);
    const lower_q = q[0..qn];
    var hay: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&hay, "{s} {s} {s}", .{ event.type, event.comm, event.detail }) catch event.comm;
    var lowered: [256]u8 = undefined;
    const hn = @min(text.len, lowered.len);
    for (text[0..hn], 0..) |c, i| lowered[i] = std.ascii.toLower(c);
    return std.mem.indexOf(u8, lowered[0..hn], lower_q) != null;
}

pub fn fullTypeLabel(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "sched_switch")) return "sched_switch";
    if (std.mem.eql(u8, kind, "sched_wakeup")) return "sched_wakeup";
    if (std.mem.eql(u8, kind, "sched_migrate")) return "sched_migrate";
    if (std.mem.eql(u8, kind, "page_fault")) return "page_fault";
    if (std.mem.eql(u8, kind, "cache_miss")) return "cache_miss";
    if (std.mem.eql(u8, kind, "loss")) return "loss";
    return kind;
}
