//! Profiler screens over a replay Session. P3 renders these headlessly and in
//! the browser; later phases add live sources and interactions.

const std = @import("std");
const draw = @import("../ui/draw.zig");
const frame_mod = @import("../ui/frame.zig");
const layout = @import("../ui/layout.zig");
const widgets = @import("../ui/widgets.zig");
const session_mod = @import("../stream/session.zig");
const input_mod = @import("../ui/input.zig");
const app_util = @import("app_util.zig");
const advisor = @import("../analyze/advisor.zig");

pub const Screen = enum { overview, timeline, advisor, events, capture };

pub fn screenName(screen: Screen) []const u8 {
    return switch (screen) {
        .overview => "Overview",
        .timeline => "Timeline",
        .advisor => "Advisor",
        .events => "Events",
        .capture => "Capture",
    };
}

pub fn parseScreen(name: []const u8) ?Screen {
    inline for (@typeInfo(Screen).@"enum".field_names) |field| {
        if (std.ascii.eqlIgnoreCase(name, field)) return @field(Screen, field);
    }
    return null;
}

pub const Window = struct {
    start_us: u64,
    end_us: u64,
};

pub const Selection = struct {
    pid: i32,
    comm: []const u8,
};

pub const TimelineGeometry = struct {
    plot: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    start_us: u64 = 0,
    end_us: u64 = 0,
    lane_h: f32 = 0,
    cpu_count: u8 = 0,
    valid: bool = false,
};

pub const State = struct {
    session: *const session_mod.Session,
    screen: Screen = .overview,
    window: ?Window = null,
    selection: ?Selection = null,
    timeline: TimelineGeometry = .{},
    live_paused: bool = false,
    live_follow: bool = true,
    event_scroll: usize = 0,
    events_rect: layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    events_visible: usize = 0,
    events_start: usize = 0,
};

pub fn view(state: *State, ui: *layout.Ui) !void {
    handleTimelineInput(state, &ui.frame.input);
    var root = try ui.column(.{ .bg = ui.theme.bg });
    try header(state, ui);
    var body = try ui.row(.{
        .flex = 1,
        .padding = layout.Edges.all(12),
        .gap = 12,
    });
    switch (state.screen) {
        .overview => try overview(state, ui),
        .timeline => try timeline(state, ui),
        .advisor => try advisorView(state, ui),
        .events => try eventsView(state, ui),
        .capture => try captureView(state, ui),
    }
    body.end();
    try footer(ui);
    root.end();
}

fn handleTimelineInput(state: *State, input: *input_mod.Input) void {
    if (state.screen == .events and state.events_visible != 0 and
        input.scroll_y != 0 and
        input.inside(state.events_rect.x, state.events_rect.y, state.events_rect.w, state.events_rect.h))
    {
        const max_scroll = state.session.events.len -| state.events_visible;
        const step: usize = if (input.scroll_y > 0) 3 else 0;
        state.event_scroll = @min(max_scroll, state.event_scroll + step);
        if (input.scroll_y < 0) state.event_scroll -|= 3;
        input.scroll_y = 0;
    }
    if (state.screen == .events and input.clicked and
        input.inside(state.events_rect.x, state.events_rect.y, state.events_rect.w, state.events_rect.h) and
        state.events_visible != 0)
    {
        const row_offset = input.pointer_y - state.events_rect.y;
        if (row_offset >= 0) {
            const row: usize = @intFromFloat(@floor(row_offset / 22.0));
            const index = state.events_start + row;
            if (index < state.session.events.len) {
                const entry = state.session.events[index];
                const event_us = entry.ts_ns / 1000;
                const full_start = state.session.first_us;
                const full_end = @max(state.session.last_us, full_start + 1);
                var start = event_us -| 500_000;
                var end = event_us +| 500_000;
                if (start < full_start) start = full_start;
                if (end > full_end) end = full_end;
                if (end <= start) {
                    start = full_start;
                    end = full_end;
                }
                state.window = .{ .start_us = start, .end_us = end };
                state.screen = .timeline;
                input.clicked = false;
            }
        }
    }
    if (input.key == .zero) {
        state.window = null;
        state.selection = null;
        input.key = .none;
        return;
    }
    if (input.key == .escape) {
        state.selection = null;
        input.key = .none;
        return;
    }
    const geometry = state.timeline;
    if (!geometry.valid or !input.inside(geometry.plot.x, geometry.plot.y, geometry.plot.w, geometry.plot.h)) {
        return;
    }
    const full_start = state.session.first_us;
    const full_end = @max(state.session.last_us, full_start + 1);
    var window = state.window orelse Window{ .start_us = full_start, .end_us = full_end };
    if (input.scroll_y != 0) {
        const span = window.end_us - window.start_us;
        const factor: f64 = if (input.scroll_y > 0) 0.8 else 1.25;
        const next_span: u64 = @intFromFloat(@max(
            1000.0,
            @min(@as(f64, @floatFromInt(full_end - full_start)), @as(f64, @floatFromInt(span)) * factor),
        ));
        const fraction = (input.pointer_x - geometry.plot.x) / @max(1.0, geometry.plot.w);
        const focus = window.start_us + @as(u64, @intFromFloat(fraction * @as(f32, @floatFromInt(span))));
        var start = focus -| @as(u64, @intFromFloat(@as(f64, @floatFromInt(next_span)) * fraction));
        if (start < full_start) start = full_start;
        var end = start + next_span;
        if (end > full_end) {
            end = full_end;
            start = end -| next_span;
        }
        window = .{ .start_us = start, .end_us = end };
        state.window = window;
        input.scroll_y = 0;
    }
    if (input.clicked) {
        const lane_offset = input.pointer_y - (geometry.plot.y + 20);
        if (lane_offset < 0) return;
        const lane_index: usize = @intFromFloat(@floor(lane_offset / @max(1.0, geometry.lane_h)));
        if (lane_index >= geometry.cpu_count) return;
        const fraction = (input.pointer_x - geometry.plot.x) / @max(1.0, geometry.plot.w);
        const when = window.start_us + @as(u64, @intFromFloat(fraction * @as(f32, @floatFromInt(window.end_us - window.start_us))));
        for (state.session.slices) |slice| {
            if (slice.cpu != lane_index) continue;
            if (when < slice.start_us or when > slice.end_us) continue;
            state.selection = .{ .pid = slice.pid, .comm = slice.comm };
            break;
        }
        input.clicked = false;
    }
}

fn selectedMetric(state: *const State) ?@import("../analyze/metrics.zig").TaskMetric {
    const selection = state.selection orelse return null;
    for (state.session.metrics.tasks) |task| {
        if (task.pid == selection.pid and std.mem.eql(u8, task.comm, selection.comm)) return task;
    }
    return null;
}

fn header(state: *State, ui: *layout.Ui) !void {
    const th = ui.theme;
    var bar = try ui.row(.{
        .height = 46,
        .padding = .{ .left = 12, .right = 12 },
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{ .text = "xsprof", .size = 16, .color = th.live, .weight = .bold });
    try ui.text(.{ .text = "  read-only profiler", .size = 10, .color = th.muted });
    var spacer = try ui.column(.{ .flex = 1 });
    spacer.end();
    var i: usize = 0;
    const screens = [_]Screen{ .overview, .timeline, .advisor, .events, .capture };
    while (i < screens.len) : (i += 1) {
        const active = state.screen == screens[i];
        var box = try ui.row(.{
            .height = 22,
            .padding = .{ .left = 8, .right = 8 },
            .align_items = .center,
            .bg = if (active) th.raised else null,
        });
        try ui.text(.{
            .text = screenName(screens[i]),
            .size = 10,
            .color = if (active) th.live else th.muted,
            .weight = .bold,
        });
        box.end();
    }
    const live = std.mem.startsWith(u8, state.session.source, "live");
    var source = try widgets.chip(ui, if (live) "LIVE" else "REPLAY", if (live) th.live else th.pending);
    source.end();
    if (state.live_paused) {
        var paused = try widgets.chip(ui, "PAUSED", th.skip);
        paused.end();
    } else if (live and !state.live_follow) {
        var hold = try widgets.chip(ui, "HOLD", th.skip);
        hold.end();
    }
    var ro = try widgets.chip(ui, "READ-ONLY", th.pass);
    ro.end();
    var mut = try widgets.chip(ui, "host_mutation=false", th.muted);
    mut.end();
    if (state.session.lost != 0) {
        var lost = try widgets.chip(ui, "LOSS", th.refuse);
        lost.end();
    }
    bar.end();
}

fn footer(ui: *layout.Ui) !void {
    const th = ui.theme;
    var bar = try ui.row(.{
        .height = 26,
        .padding = .{ .left = 12, .right = 12 },
        .gap = 12,
        .align_items = .center,
        .bg = th.raised,
    });
    try ui.text(.{
        .text = "1-5 screens   / filter   space pause   f fit   ? help   q quit",
        .size = 9,
        .color = th.muted,
    });
    var spacer = try ui.column(.{ .flex = 1 });
    spacer.end();
    try ui.text(.{
        .text = if (ui.theme.pass.r == 0x72) "READY is a gate result, not release" else "read-only",
        .size = 9,
        .color = th.muted,
    });
    bar.end();
}

fn overview(state: *State, ui: *layout.Ui) !void {
    const th = ui.theme;
    var left = try ui.column(.{ .flex = 1.55, .gap = 12 });
    var stats = try ui.row(.{ .height = 58, .gap = 12 });
    try stat(ui, "EVENTS", state.session.events.len, th.text);
    try stat(ui, "CPUS", state.session.cpu_count, th.live);
    try stat(ui, "SWITCHES", state.session.switches, th.pending);
    try stat(ui, "MIGRATIONS", state.session.migrations, th.skip);
    try stat(ui, "FAULTS", state.session.faults, th.refuse);
    stats.end();

    var caps = try widgets.panel(ui, "CAPABILITIES", .{ .flex = 1 });
    if (state.session.capabilities.len == 0) {
        try emptyNote(ui, "No capability rows in this session.");
    } else {
        for (state.session.capabilities) |cap| {
            var row = try ui.row(.{ .height = 22, .gap = 10, .align_items = .center });
            try ui.text(.{ .text = cap.name, .size = 11, .color = th.text });
            const color = stateColor(th, cap.state);
            try ui.text(.{ .text = cap.state, .size = 10, .color = color, .weight = .bold });
            try ui.text(.{ .text = cap.reason, .size = 9, .color = th.muted });
            row.end();
        }
    }
    caps.end();
    left.end();

    var right = try ui.column(.{ .flex = 1, .gap = 12 });
    var comms = try widgets.panel(ui, "TOP TASKS BY P95 WAIT", .{ .flex = 1 });
    if (state.session.metrics.tasks.len != 0) {
        var shown: [8][]const u8 = undefined;
        var shown_count: usize = 0;
        for (state.session.metrics.tasks) |task| {
            var duplicate = false;
            for (shown[0..shown_count]) |name| {
                if (std.mem.eql(u8, name, task.comm)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            if (shown_count == shown.len) break;
            shown[shown_count] = task.comm;
            shown_count += 1;
            var row = try ui.row(.{ .height = 22, .gap = 10, .align_items = .center });
            try ui.text(.{ .text = task.comm, .size = 11, .color = th.text });
            var spacer = try ui.column(.{ .flex = 1 });
            spacer.end();
            const value = try std.fmt.allocPrint(
                ui.allocator,
                "{d}ms / {d}",
                .{ task.wait_p95_us / 1000, task.switches },
            );
            try ui.text(.{ .text = value, .size = 11, .color = th.live });
            row.end();
        }
    } else {
        for (state.session.top_comms[0..@min(state.session.top_comms.len, 8)]) |comm| {
            var row = try ui.row(.{ .height = 22, .gap = 10, .align_items = .center });
            try ui.text(.{ .text = comm.comm, .size = 11, .color = th.text });
            var spacer = try ui.column(.{ .flex = 1 });
            spacer.end();
            const value = try std.fmt.allocPrint(ui.allocator, "{d}", .{comm.count});
            try ui.text(.{ .text = value, .size = 11, .color = th.live });
            row.end();
        }
    }
    comms.end();

    var range = try widgets.panel(ui, "SESSION", .{ .height = 120 });
    const first = try app_util.formatTime(ui.allocator, state.session.first_us);
    const last = try app_util.formatTime(ui.allocator, state.session.last_us);
    try kv(ui, "source", state.session.source);
    try kv(ui, "window", try std.fmt.allocPrint(ui.allocator, "{s} -> {s}", .{ first, last }));
    try kv(
        ui,
        "lost / refusals",
        try std.fmt.allocPrint(ui.allocator, "{d} / {d}", .{
            state.session.lost,
            state.session.refusals,
        }),
    );
    range.end();
    right.end();
}

fn stat(ui: *layout.Ui, label: []const u8, value: anytype, color: draw.Color) !void {
    const text = try std.fmt.allocPrint(ui.allocator, "{d}", .{value});
    var card = try widgets.statCard(ui, label, text, color);
    card.end();
}

fn kv(ui: *layout.Ui, key: []const u8, value: []const u8) !void {
    var row = try ui.row(.{ .height = 21, .gap = 8 });
    try ui.text(.{ .text = key, .size = 10, .color = ui.theme.muted });
    try ui.text(.{ .text = value, .size = 14, .color = ui.theme.text });
    row.end();
}

fn emptyNote(ui: *layout.Ui, note: []const u8) !void {
    try ui.text(.{ .text = note, .size = 10, .color = ui.theme.skip });
}

fn stateColor(th: draw.Theme, state: []const u8) draw.Color {
    if (std.mem.eql(u8, state, "READY")) return th.pass;
    if (std.mem.eql(u8, state, "DEGRADED")) return th.pending;
    if (std.mem.eql(u8, state, "REFUSE")) return th.refuse;
    return th.skip;
}

fn timeline(state: *State, ui: *layout.Ui) !void {
    var panel = try widgets.panel(ui, "TIMELINE / CPU LANES", .{ .flex = 1 });
    try ui.custom(.{
        .style = .{ .flex = 1 },
        .user = state,
        .paint = paintTimeline,
    });
    if (state.selection) |selection| {
        var row = try ui.row(.{ .height = 30, .gap = 10, .align_items = .center });
        try ui.text(.{
            .text = try std.fmt.allocPrint(ui.allocator, "selected {s} pid={d}", .{ selection.comm, selection.pid }),
            .size = 11,
            .color = ui.theme.live,
        });
        if (selectedMetric(state)) |task| {
            try ui.text(.{
                .text = try std.fmt.allocPrint(
                    ui.allocator,
                    "p95={d}ms offcpu={d}ms switches={d}",
                    .{ task.wait_p95_us / 1000, task.offcpu_p95_us / 1000, task.switches },
                ),
                .size = 11,
                .color = ui.theme.text,
            });
        }
        row.end();
    } else {
        try ui.text(.{ .text = "click a slice to inspect; wheel zooms; 0 resets", .size = 10, .color = ui.theme.muted });
    }
    panel.end();
}

fn advisorView(state: *State, ui: *layout.Ui) !void {
    const th = ui.theme;
    const findings = try advisor.analyze(ui.allocator, state.session.aggregate(), .{});
    defer advisor.freeFindings(ui.allocator, findings);
    var panel = try widgets.panel(ui, "PERFORMANCE ADVISOR", .{ .flex = 1 });
    if (findings.len == 0) {
        try ui.text(.{ .text = "No findings", .size = 16, .color = th.pass, .weight = .bold });
        try ui.text(.{
            .text = "Either the workload is healthy or the signals needed for detection " ++
                "were not collected. Uncollected signals are never treated as zero.",
            .size = 10,
            .color = th.muted,
        });
    } else {
        for (findings) |finding| {
            var row = try ui.row(.{ .height = 24, .gap = 10, .align_items = .center });
            try ui.text(.{ .text = finding.id, .size = 11, .color = th.text });
            try ui.text(.{
                .text = advisor.severityName(finding.severity),
                .size = 10,
                .color = if (finding.severity == .critical) th.refuse else th.skip,
                .weight = .bold,
            });
            row.end();
        }
    }
    try widgets.rule(ui);
    try ui.text(.{
        .text = "Rules: poor-numa-placement, cpu-affinity-churn, unnecessary-wakeups, " ++
            "excessive-locking, false-sharing, allocator-fragmentation, priority-inversion",
        .size = 9,
        .color = th.muted,
    });
    try ui.text(.{
        .text = "PMU HITM: uncollected in this replay. Recommendations are suggestions only.",
        .size = 9,
        .color = th.skip,
    });
    panel.end();
}

fn eventsView(state: *State, ui: *layout.Ui) !void {
    var panel = try widgets.panel(ui, "EVENT LEDGER / APPEND-ONLY", .{ .flex = 1 });
    try ui.custom(.{
        .style = .{ .flex = 1 },
        .user = state,
        .paint = paintEvents,
    });
    panel.end();
}

fn captureView(state: *State, ui: *layout.Ui) !void {
    const th = ui.theme;
    var panel = try widgets.panel(ui, "CAPTURE / READ-ONLY", .{ .flex = 1 });
    try ui.text(.{ .text = "Capture is started outside the UI.", .size = 14, .color = th.text, .weight = .bold });
    try ui.text(.{
        .text = "xsprof record --duration 2000 --output session.ndjson",
        .size = 11,
        .color = th.live,
    });
    try ui.text(.{
        .text = "xsprof serve --journal session.ndjson",
        .size = 11,
        .color = th.live,
    });
    try widgets.rule(ui);
    try ui.text(.{
        .text = "No UI control mutates the host. Every record carries host_mutation=false. " ++
            "Unsafe verbs (load, attach, enable, mutate, apply, setaffinity, setpriority, bind) refuse.",
        .size = 10,
        .color = th.muted,
    });
    try ui.text(.{
        .text = "BPF is VM-marker-gated and refuses on the host; without BTF/libbpf it reports SKIP.",
        .size = 10,
        .color = th.skip,
    });
    if (state.session.capabilities.len != 0) {
        try widgets.rule(ui);
        for (state.session.capabilities) |cap| {
            var row = try ui.row(.{ .height = 20, .gap = 8, .align_items = .center });
            try ui.text(.{ .text = cap.name, .size = 10, .color = th.text });
            try ui.text(.{ .text = cap.state, .size = 9, .color = stateColor(th, cap.state), .weight = .bold });
            try ui.text(.{ .text = cap.reason, .size = 9, .color = th.muted });
            row.end();
        }
    }
    panel.end();
}

fn paintTimeline(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    const state: *State = @ptrCast(@alignCast(user.?));
    const session = state.session;
    const th = frame.theme;
    const full_start = session.first_us;
    const full_end = @max(session.last_us, full_start + 1);
    const window = state.window orelse Window{ .start_us = full_start, .end_us = full_end };
    const start = window.start_us;
    const end = @max(window.end_us, start + 1);
    const left = 34.0;
    const plot_x = rect.x + left;
    const plot_w = rect.w - left;
    if (plot_w <= 0 or session.slices.len == 0) {
        _ = try frame.list.text(0, &frame.regular, 10, rect.x, rect.y, "no scheduler slices in this replay", th.skip, clip);
        return;
    }
    var tick: usize = 0;
    while (tick <= 4) : (tick += 1) {
        const t = start + (end - start) * tick / 4;
        const x = plot_x + plot_w * @as(f32, @floatFromInt(tick)) / 4.0;
        try frame.list.rect(x, rect.y + 14, 1, rect.h - 14, th.hairline, clip);
        const label = try app_util.formatTime(frame.allocator, t);
        _ = try frame.list.text(0, &frame.regular, 12, x + 2, rect.y, label, th.muted, clip);
    }
    const lanes = @max(1, session.cpu_count);
    const lane_h = @min(28.0, (rect.h - 24) / @as(f32, @floatFromInt(lanes)));
    state.timeline = .{
        .plot = .{ .x = plot_x, .y = rect.y, .w = plot_w, .h = lane_h * @as(f32, @floatFromInt(lanes)) },
        .start_us = start,
        .end_us = end,
        .lane_h = lane_h,
        .cpu_count = @intCast(@min(lanes, 255)),
        .valid = true,
    };
    var cpu: usize = 0;
    while (cpu < lanes) : (cpu += 1) {
        const y = rect.y + 20 + @as(f32, @floatFromInt(cpu)) * lane_h;
        try frame.list.rect(plot_x, y, plot_w, lane_h - 3, th.raised, clip);
        var label_buf: [16]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "CPU{d}", .{cpu}) catch "CPU";
        _ = try frame.list.text(0, &frame.regular, 10, rect.x, y + 2, label, th.muted, clip);
    }
    const span = @as(f32, @floatFromInt(end - start));
    for (session.slices) |slice| {
        if (slice.cpu >= lanes) continue;
        const slice_start = @max(slice.start_us, start);
        const slice_end = @min(slice.end_us, end);
        if (slice_end <= slice_start) continue;
        const x0 = plot_x + plot_w * @as(f32, @floatFromInt(slice_start - start)) / span;
        const x1 = plot_x + plot_w * @as(f32, @floatFromInt(slice_end - start)) / span;
        const y = rect.y + 20 + @as(f32, @floatFromInt(slice.cpu)) * lane_h;
        const color = app_util.palette(th, slice.comm);
        try frame.list.rect(x0, y + 2, @max(1, x1 - x0), @max(1, lane_h - 6), color, clip);
        if (state.selection) |selection| {
            if (slice.pid == selection.pid and std.mem.eql(u8, slice.comm, selection.comm)) {
                try frame.list.rect(x0, y + 2, @max(1, x1 - x0), 2, th.text, clip);
            }
        }
    }
    try app_util.paintHover(frame, plot_x, rect.y + 20, plot_w, lane_h, lanes, start, end, clip);
    if (session.lost != 0) {
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "LOSS x{d}", .{session.lost}) catch "LOSS";
        _ = try frame.list.text(1, &frame.bold, 10, rect.x + rect.w - 70, rect.y, label, th.refuse, clip);
    }
}

fn paintEvents(user: ?*anyopaque, frame: *frame_mod.Frame, rect: layout.Rect, clip: [4]f32) !void {
    const state: *State = @ptrCast(@alignCast(user.?));
    const session = state.session;
    const th = frame.theme;
    const row_h = 22.0;
    const visible: usize = @intFromFloat(@max(0, rect.h) / row_h);
    if (visible == 0) return;
    state.events_rect = rect;
    state.events_visible = visible;
    const total = session.events.len;
    const max_scroll = total -| visible;
    state.event_scroll = @min(state.event_scroll, max_scroll);
    const first = total -| (visible + state.event_scroll);
    const start = first;
    state.events_start = first;
    var row: usize = 0;
    var index = total - state.event_scroll;
    while (index > start) {
        index -= 1;
        const e = session.events[index];
        const y = rect.y + @as(f32, @floatFromInt(row)) * row_h;
        if (frame.input.inside(rect.x, y, rect.w, row_h)) {
            try frame.list.rect(rect.x, y, rect.w, row_h - 1, th.raised, clip);
        }
        row += 1;
        const is_loss = e.kind == .marker and
            (std.mem.indexOf(u8, e.detail, "sample_loss") != null or
                std.mem.indexOf(u8, e.detail, "lost") != null);
        const color = if (is_loss) th.refuse else th.text;
        _ = try frame.list.text(0, &frame.regular, 12, rect.x, y, try app_util.formatTime(frame.allocator, e.ts_ns / 1000), th.muted, clip);
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 76, y, @tagName(e.kind), color, clip);
        var meta: [64]u8 = undefined;
        const meta_text = std.fmt.bufPrint(&meta, "cpu={d} pid={d}", .{ e.cpu, e.pid }) catch "";
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 192, y, meta_text, th.muted, clip);
        const detail = if (is_loss) "explicit sample loss - unsafe" else e.detail;
        _ = try frame.list.text(0, &frame.regular, 10, rect.x + 300, y, detail, if (is_loss) th.refuse else th.muted, clip);
    }
}
