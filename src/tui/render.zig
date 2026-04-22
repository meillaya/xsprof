const std = @import("std");
const analysis = @import("analysis_root");
const scheduler = @import("zig_scheduler");

pub const Report = analysis.model.Report;
pub const TraceEntry = analysis.model.TraceEntry;
pub const TaskMetrics = analysis.model.TaskMetrics;
pub const PolicyKind = scheduler.PolicyKind;
pub const ObservabilitySummary = scheduler.observability.ObservabilitySummary;
pub const ComparisonSummary = scheduler.observability_comparison.ComparisonSummary;

pub const View = enum {
    picker,
    explorer,
    drawer,
    diff,
    observability_summary,
    observability_comparison,
    help,
};

pub const DomainMode = enum {
    simulator,
    observability_summary,
    observability_comparison,
};

pub const PaneFocus = enum {
    gantt,
    tasks,
    events,
    tick,
};

pub const ThemeKind = enum {
    dark,
    light,
};

pub const OutputMode = enum {
    interactive,
    snapshot,
};

pub const LayoutTier = enum(u8) {
    too_small,
    compact,
    medium,
    large,
};

pub const HelpMode = enum {
    disabled,
    fullscreen,
    overlay,
};

pub const FocusVisibility = struct {
    gantt: bool = false,
    tasks: bool = false,
    events: bool = false,
    tick: bool = false,
};

pub const ViewLayoutContract = struct {
    tier: LayoutTier,
    visible: FocusVisibility = .{},
    focus_order: [4]PaneFocus = .{ .gantt, .tasks, .events, .tick },
    focus_len: usize = 0,
    default_focus: ?PaneFocus = null,
    can_enter_drawer: bool = false,
    can_open_diff: bool = false,
    help_mode: HelpMode = .fullscreen,
    show_aggregate_pane: bool = true,
    dense_task_table: bool = false,
};

pub const PickerEntry = struct {
    scenario_key: []const u8,
    scenario_label: []const u8,
    pack: []const u8,
    policy: PolicyKind,
    policy_label: []const u8,
    description: []const u8,
    theme_label: ?[]const u8 = null,
    explanation_doc: ?[]const u8 = null,
    m21_start_here_rank: ?u8 = null,
    cores: u32,
    tasks: u32,
    ticks: u32,
};

pub const AppView = struct {
    domain_mode: DomainMode,
    theme: ThemeKind,
    view: View,
    focus: PaneFocus,
    cursor: u32,
    selected_task_index: ?usize,
    picker_index: usize,
    playing: bool,
    report: ?*const Report,
    compare_report: ?*const Report,
    observability_summary: ?*const ObservabilitySummary,
    observability_comparison: ?*const ComparisonSummary,
    picker_entries: []const PickerEntry,
    history: []const []const u8,
};

fn teachingPolicyLabel(policy: scheduler.PolicyKind) []const u8 {
    return switch (policy) {
        .fcfs => "fcfs",
        .round_robin => "round-robin",
        .cfs_like => "cfs-like",
        .deadline => "deadline",
    };
}

fn axisTier(value: usize, large_min: usize, medium_min: usize, compact_min: usize) LayoutTier {
    if (value >= large_min) return .large;
    if (value >= medium_min) return .medium;
    if (value >= compact_min) return .compact;
    return .too_small;
}

fn lowerTier(a: LayoutTier, b: LayoutTier) LayoutTier {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

pub fn classifyLayout(width: usize, height: usize) LayoutTier {
    return lowerTier(axisTier(width, 100, 90, 80), axisTier(height, 30, 26, 24));
}

pub fn focusVisible(contract: ViewLayoutContract, focus: PaneFocus) bool {
    return switch (focus) {
        .gantt => contract.visible.gantt,
        .tasks => contract.visible.tasks,
        .events => contract.visible.events,
        .tick => contract.visible.tick,
    };
}

pub fn normalizedFocus(current: PaneFocus, contract: ViewLayoutContract) ?PaneFocus {
    if (focusVisible(contract, current)) return current;
    return contract.default_focus;
}

pub fn nextFocus(current: PaneFocus, contract: ViewLayoutContract, reverse: bool) ?PaneFocus {
    if (contract.focus_len == 0) return null;

    var current_index: usize = 0;
    var found = false;
    for (contract.focus_order[0..contract.focus_len], 0..) |focus, idx| {
        if (focus == current) {
            current_index = idx;
            found = true;
            break;
        }
    }

    if (!found) return contract.default_focus;
    if (reverse) {
        return contract.focus_order[(current_index + contract.focus_len - 1) % contract.focus_len];
    }
    return contract.focus_order[(current_index + 1) % contract.focus_len];
}

pub fn viewContract(view: View, width: usize, height: usize, has_compare: bool) ViewLayoutContract {
    const tier = classifyLayout(width, height);

    return switch (view) {
        .explorer => switch (tier) {
            .large => .{
                .tier = .large,
                .visible = .{ .gantt = true, .tasks = true, .events = true, .tick = true },
                .focus_len = 4,
                .default_focus = .gantt,
                .can_enter_drawer = true,
                .can_open_diff = has_compare,
                .help_mode = .overlay,
                .show_aggregate_pane = true,
            },
            .medium => .{
                .tier = .medium,
                .visible = .{ .gantt = true, .tasks = true, .events = true, .tick = true },
                .focus_len = 4,
                .default_focus = .gantt,
                .can_enter_drawer = true,
                .can_open_diff = has_compare,
                .help_mode = .overlay,
                .show_aggregate_pane = true,
                .dense_task_table = true,
            },
            .compact => .{
                .tier = .compact,
                .visible = .{ .gantt = true, .tasks = true, .events = false, .tick = true },
                .focus_order = .{ .gantt, .tasks, .tick, .events },
                .focus_len = 3,
                .default_focus = .gantt,
                .can_enter_drawer = true,
                .can_open_diff = true,
                .help_mode = .fullscreen,
                .show_aggregate_pane = false,
                .dense_task_table = true,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
        },
        .drawer => switch (tier) {
            .compact => .{
                .tier = .compact,
                .help_mode = .fullscreen,
                .can_open_diff = has_compare,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
            else => .{
                .tier = tier,
                .help_mode = .overlay,
                .can_open_diff = has_compare,
            },
        },
        .diff => switch (tier) {
            .compact => .{
                .tier = .compact,
                .help_mode = .fullscreen,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
            else => .{
                .tier = tier,
                .help_mode = .overlay,
            },
        },
        .picker => switch (tier) {
            .compact => .{
                .tier = .compact,
                .help_mode = .fullscreen,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
            else => .{
                .tier = tier,
                .help_mode = .overlay,
            },
        },
        .help => switch (tier) {
            .compact => .{
                .tier = .compact,
                .help_mode = .fullscreen,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
            else => .{
                .tier = tier,
                .help_mode = .overlay,
            },
        },
        .observability_summary, .observability_comparison => switch (tier) {
            .compact => .{
                .tier = .compact,
                .help_mode = .fullscreen,
            },
            .too_small => .{
                .tier = .too_small,
                .help_mode = .disabled,
            },
            else => .{
                .tier = tier,
                .help_mode = .overlay,
            },
        },
    };
}

const Slot = enum(u8) {
    bg,
    bg_alt,
    bg_inv,
    fg,
    fg_dim,
    fg_faint,
    fg_inv,
    rule,
    running,
    dispatch,
    preempt,
    complete,
    block,
    deadline,
};

const Rgb = struct { r: u8, g: u8, b: u8 };

const Theme = struct {
    bg: Rgb,
    bg_alt: Rgb,
    bg_inv: Rgb,
    fg: Rgb,
    fg_dim: Rgb,
    fg_faint: Rgb,
    fg_inv: Rgb,
    rule: Rgb,
    running: Rgb,
    dispatch: Rgb,
    preempt: Rgb,
    complete: Rgb,
    block: Rgb,
    deadline: Rgb,

    fn color(self: Theme, slot: Slot) Rgb {
        return switch (slot) {
            .bg => self.bg,
            .bg_alt => self.bg_alt,
            .bg_inv => self.bg_inv,
            .fg => self.fg,
            .fg_dim => self.fg_dim,
            .fg_faint => self.fg_faint,
            .fg_inv => self.fg_inv,
            .rule => self.rule,
            .running => self.running,
            .dispatch => self.dispatch,
            .preempt => self.preempt,
            .complete => self.complete,
            .block => self.block,
            .deadline => self.deadline,
        };
    }
};

const dark_theme = Theme{
    .bg = .{ .r = 0x0e, .g = 0x0d, .b = 0x0c },
    .bg_alt = .{ .r = 0x17, .g = 0x15, .b = 0x0f },
    .bg_inv = .{ .r = 0xf5, .g = 0xf1, .b = 0xe8 },
    .fg = .{ .r = 0xe8, .g = 0xe3, .b = 0xd6 },
    .fg_dim = .{ .r = 0x8a, .g = 0x83, .b = 0x72 },
    .fg_faint = .{ .r = 0x55, .g = 0x50, .b = 0x4a },
    .fg_inv = .{ .r = 0x0e, .g = 0x0d, .b = 0x0c },
    .rule = .{ .r = 0x2a, .g = 0x26, .b = 0x22 },
    .running = .{ .r = 0xeb, .g = 0xc7, .b = 0x67 },
    .dispatch = .{ .r = 0x6b, .g = 0xc9, .b = 0xe4 },
    .preempt = .{ .r = 0xd4, .g = 0x70, .b = 0xb5 },
    .complete = .{ .r = 0x72, .g = 0xd0, .b = 0x93 },
    .block = .{ .r = 0x9a, .g = 0x81, .b = 0x63 },
    .deadline = .{ .r = 0xe1, .g = 0x73, .b = 0x4e },
};

const light_theme = Theme{
    .bg = .{ .r = 0xf5, .g = 0xf1, .b = 0xe8 },
    .bg_alt = .{ .r = 0xec, .g = 0xe6, .b = 0xd6 },
    .bg_inv = .{ .r = 0x0e, .g = 0x0d, .b = 0x0c },
    .fg = .{ .r = 0x1a, .g = 0x18, .b = 0x14 },
    .fg_dim = .{ .r = 0x6a, .g = 0x63, .b = 0x57 },
    .fg_faint = .{ .r = 0xb5, .g = 0xad, .b = 0x9c },
    .fg_inv = .{ .r = 0xf5, .g = 0xf1, .b = 0xe8 },
    .rule = .{ .r = 0xd6, .g = 0xcf, .b = 0xbc },
    .running = .{ .r = 0xb3, .g = 0x7a, .b = 0x12 },
    .dispatch = .{ .r = 0x0d, .g = 0x89, .b = 0xb5 },
    .preempt = .{ .r = 0xba, .g = 0x37, .b = 0x89 },
    .complete = .{ .r = 0x1f, .g = 0x96, .b = 0x54 },
    .block = .{ .r = 0x83, .g = 0x70, .b = 0x5a },
    .deadline = .{ .r = 0xc0, .g = 0x4a, .b = 0x2a },
};

const Style = struct {
    fg: Slot = .fg,
    bg: Slot = .bg,
    bold: bool = false,
};

const Cell = struct {
    ch: u21 = ' ',
    style: Style = .{},
};

const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

const Canvas = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []Cell,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize, style: Style) !Canvas {
        const cells = try allocator.alloc(Cell, width * height);
        var canvas = Canvas{ .allocator = allocator, .width = width, .height = height, .cells = cells };
        canvas.clear(style);
        return canvas;
    }

    fn deinit(self: *Canvas) void {
        self.allocator.free(self.cells);
    }

    fn clear(self: *Canvas, style: Style) void {
        for (self.cells) |*cell| cell.* = .{ .ch = ' ', .style = style };
    }

    fn set(self: *Canvas, x: usize, y: usize, ch: u21, style: Style) void {
        if (x >= self.width or y >= self.height) return;
        self.cells[y * self.width + x] = .{ .ch = ch, .style = style };
    }

    fn fillRect(self: *Canvas, rect: Rect, style: Style) void {
        var yy: usize = 0;
        while (yy < rect.h) : (yy += 1) {
            var xx: usize = 0;
            while (xx < rect.w) : (xx += 1) self.set(rect.x + xx, rect.y + yy, ' ', style);
        }
    }

    fn drawText(self: *Canvas, x: usize, y: usize, text: []const u8, style: Style) void {
        if (y >= self.height) return;
        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        var xx = x;
        while (it.nextCodepoint()) |cp| : (xx += 1) {
            if (xx >= self.width) break;
            self.set(xx, y, cp, style);
        }
    }

    fn drawTextClipped(self: *Canvas, x: usize, y: usize, width: usize, text: []const u8, style: Style) void {
        if (width == 0) return;
        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        var xx = x;
        var remaining = width;
        while (it.nextCodepoint()) |cp| {
            if (remaining == 0 or xx >= self.width) break;
            self.set(xx, y, cp, style);
            xx += 1;
            remaining -= 1;
        }
    }

    fn drawHLine(self: *Canvas, x: usize, y: usize, width: usize, ch: u21, style: Style) void {
        if (y >= self.height) return;
        var xx: usize = 0;
        while (xx < width) : (xx += 1) self.set(x + xx, y, ch, style);
    }

    fn drawVLine(self: *Canvas, x: usize, y: usize, height: usize, ch: u21, style: Style) void {
        if (x >= self.width) return;
        var yy: usize = 0;
        while (yy < height) : (yy += 1) self.set(x, y + yy, ch, style);
    }

    fn drawBox(self: *Canvas, rect: Rect, style: Style) void {
        if (rect.w < 2 or rect.h < 2) return;
        self.drawHLine(rect.x + 1, rect.y, rect.w - 2, '─', style);
        self.drawHLine(rect.x + 1, rect.y + rect.h - 1, rect.w - 2, '─', style);
        self.drawVLine(rect.x, rect.y + 1, rect.h - 2, '│', style);
        self.drawVLine(rect.x + rect.w - 1, rect.y + 1, rect.h - 2, '│', style);
        self.set(rect.x, rect.y, '┌', style);
        self.set(rect.x + rect.w - 1, rect.y, '┐', style);
        self.set(rect.x, rect.y + rect.h - 1, '└', style);
        self.set(rect.x + rect.w - 1, rect.y + rect.h - 1, '┘', style);
    }

    fn renderAnsi(self: *Canvas, allocator: std.mem.Allocator, theme: Theme) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var writer = out.writer(allocator);

        var current = Style{ .fg = .fg, .bg = .bg, .bold = false };
        try applyStyle(&writer, theme, current);

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const cell = self.cells[y * self.width + x];
                if (!styleEq(current, cell.style)) {
                    current = cell.style;
                    try applyStyle(&writer, theme, current);
                }
                try writeCodepoint(&writer, cell.ch);
            }
            if (y + 1 < self.height) try writer.writeAll("\x1b[0m\r\n");
            current = .{ .fg = .fg, .bg = .bg, .bold = false };
            if (y + 1 < self.height) try applyStyle(&writer, theme, current);
        }
        try writer.writeAll("\x1b[0m");
        return try out.toOwnedSlice(allocator);
    }

    fn renderPlain(self: *Canvas, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var writer = out.writer(allocator);

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const cell = self.cells[y * self.width + x];
                try writeCodepoint(&writer, cell.ch);
            }
            if (y + 1 < self.height) try writer.writeAll("\n");
        }

        return try out.toOwnedSlice(allocator);
    }
};

pub fn renderFrame(allocator: std.mem.Allocator, width: usize, height: usize, app: AppView) ![]u8 {
    return renderFrameWithMode(allocator, width, height, app, .interactive);
}

pub fn renderSnapshotFrame(allocator: std.mem.Allocator, width: usize, height: usize, app: AppView) ![]u8 {
    return renderFrameWithMode(allocator, width, height, app, .snapshot);
}

fn renderFrameWithMode(allocator: std.mem.Allocator, width: usize, height: usize, app: AppView, output_mode: OutputMode) ![]u8 {
    const theme = switch (app.theme) {
        .dark => dark_theme,
        .light => light_theme,
    };

    var canvas = try Canvas.init(allocator, width, height, .{ .fg = .fg, .bg = .bg });
    defer canvas.deinit();

    const contract = viewContract(app.view, width, height, app.compare_report != null);
    if (contract.tier == .too_small) {
        renderTooSmall(&canvas, theme, width, height);
        return switch (output_mode) {
            .interactive => try canvas.renderAnsi(allocator, theme),
            .snapshot => try canvas.renderPlain(allocator),
        };
    }

    switch (app.view) {
        .picker => renderPicker(&canvas, app, theme, output_mode),
        .explorer => renderExplorer(&canvas, app, theme, output_mode),
        .drawer => renderDrawer(&canvas, app, theme, output_mode),
        .diff => renderDiff(&canvas, app, theme, output_mode),
        .observability_summary => renderObservabilitySummary(&canvas, app, theme, output_mode),
        .observability_comparison => renderObservabilityComparison(&canvas, app, theme, output_mode),
        .help => renderHelp(&canvas, app, theme, output_mode),
    }

    return switch (output_mode) {
        .interactive => try canvas.renderAnsi(allocator, theme),
        .snapshot => try canvas.renderPlain(allocator),
    };
}

fn renderTooSmall(canvas: *Canvas, _: Theme, width: usize, height: usize) void {
    canvas.fillRect(.{ .x = 0, .y = 0, .w = width, .h = height }, .{ .fg = .fg, .bg = .bg });
    const lines = [_][]const u8{
        "zig-scheduler · local TUI surface",
        "Resize the terminal to at least 80 columns × 24 rows.",
        "Compact layouts exist now, but this size is below the supported floor.",
    };
    var y: usize = if (height > 4) height / 2 - 2 else 0;
    for (lines) |line| {
        const x = if (width > line.len) (width - line.len) / 2 else 0;
        canvas.drawText(x, y, line, .{ .fg = .fg, .bg = .bg, .bold = true });
        y += 2;
    }
}

fn renderHeader(canvas: *Canvas, rect: Rect, report: *const Report, _: Theme, live: bool, custom_label: ?[]const u8) void {
    canvas.fillRect(rect, .{ .fg = .fg, .bg = .bg });
    const tier = classifyLayout(canvas.width, canvas.height);

    if (tier == .compact) {
        canvas.drawText(1, rect.y, "▚ zig-scheduler", .{ .fg = .dispatch, .bg = .bg, .bold = true });
        if (custom_label) |label| {
            canvas.drawTextClipped(18, rect.y, satSub(rect.w, 22), label, .{ .fg = .fg, .bg = .bg, .bold = true });
        } else {
            var title_buf: [96]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buf, "{s} [{s}]", .{ report.scenario.name, report.policy.display_name }) catch report.scenario.name;
            canvas.drawTextClipped(18, rect.y, satSub(rect.w, 28), title, .{ .fg = .fg, .bg = .bg, .bold = true });
        }
        var info_buf: [96]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "cores {d} · tasks {d} · ticks {d}", .{ report.core_count, report.tasks.len, lastTick(report) + 1 }) catch "";
        canvas.drawText(1, rect.y + 1, info, .{ .fg = .fg_dim, .bg = .bg });
        canvas.drawTextClipped(1 + info.len + 2, rect.y + 1, satSub(rect.w, info.len + 14), report.source.value, .{ .fg = .fg_dim, .bg = .bg });
        const replay = if (live) "● LIVE" else "● REPLAY";
        canvas.drawText(rect.x + rect.w - replay.len - 2, rect.y, replay, .{ .fg = .fg_dim, .bg = .bg, .bold = true });
        canvas.drawHLine(rect.x, rect.y + rect.h - 1, rect.w, '─', .{ .fg = .fg_faint, .bg = .bg });
        return;
    }

    var x: usize = 1;
    canvas.drawText(x, rect.y, "▚ zig-scheduler", .{ .fg = .dispatch, .bg = .bg, .bold = true });
    x += 16;
    canvas.drawText(x, rect.y, "│", .{ .fg = .fg_dim, .bg = .bg });
    x += 3;
    if (custom_label) |label| {
        canvas.drawTextClipped(x, rect.y, rect.w / 2, label, .{ .fg = .fg, .bg = .bg, .bold = true });
    } else {
        canvas.drawText(x, rect.y, "scenario", .{ .fg = .fg_dim, .bg = .bg });
        x += 10;
        canvas.drawTextClipped(x, rect.y, 28, report.scenario.name, .{ .fg = .fg, .bg = .bg, .bold = true });
        x += 30;
        canvas.drawText(x, rect.y, "│", .{ .fg = .fg_dim, .bg = .bg });
        x += 3;
        canvas.drawText(x, rect.y, "policy", .{ .fg = .fg_dim, .bg = .bg });
        x += 8;
        var policy_buf: [64]u8 = undefined;
        const policy = std.fmt.bufPrint(&policy_buf, "[{s}]", .{report.policy.display_name}) catch report.policy.display_name;
        canvas.drawTextClipped(x, rect.y, 22, policy, .{ .fg = .running, .bg = .bg, .bold = true });
        x += 24;
    }

    const replay = if (live) "● LIVE" else "● REPLAY";
    var counts_buf: [128]u8 = undefined;
    const counts = std.fmt.bufPrint(&counts_buf, "cores {d} · tasks {d} · ticks {d}", .{ report.core_count, report.tasks.len, lastTick(report) + 1 }) catch "";
    const counts_on_top = x + 2 + counts.len + replay.len + 4 < rect.w;
    if (counts_on_top) {
        canvas.drawText(rect.x + rect.w - counts.len - replay.len - 6, rect.y, counts, .{ .fg = .fg_dim, .bg = .bg });
    } else if (counts.len + 2 < rect.w / 2) {
        canvas.drawText(rect.x + 1, rect.y + 1, counts, .{ .fg = .fg_dim, .bg = .bg });
    }

    var source_buf: [196]u8 = undefined;
    const source = std.fmt.bufPrint(&source_buf, "{s}: {s}", .{ @tagName(report.source.kind), report.source.value }) catch "";
    if (source.len + 8 < rect.w) canvas.drawText(rect.x + rect.w - source.len - 8, rect.y + 1, source, .{ .fg = .fg_dim, .bg = .bg });

    const replay_style = if (live) Style{ .fg = .complete, .bg = .bg, .bold = true } else Style{ .fg = .fg_dim, .bg = .bg, .bold = true };
    canvas.drawText(rect.x + rect.w - replay.len - 2, rect.y, replay, replay_style);
    canvas.drawHLine(rect.x, rect.y + rect.h - 1, rect.w, '─', .{ .fg = .fg_faint, .bg = .bg });
}

fn renderStatusBar(canvas: *Canvas, rect: Rect, app: AppView, _: Theme, mode_label: []const u8, output_mode: OutputMode) void {
    const contract = viewContract(app.view, canvas.width, canvas.height, app.compare_report != null);
    canvas.fillRect(rect, .{ .fg = .fg_inv, .bg = .bg_inv });
    canvas.drawText(rect.x + 1, rect.y, mode_label, .{ .fg = .fg_inv, .bg = .bg_inv, .bold = true });
    var info_buf: [196]u8 = undefined;
    const info = switch (app.domain_mode) {
        .simulator => blk: {
            if (app.report) |report| {
                const selected = selectedTask(report, app.selected_task_index);
                break :blk if (contract.tier == .compact)
                    if (selected) |task|
                        std.fmt.bufPrint(&info_buf, "t={d} {s}", .{ app.cursor, task.id }) catch ""
                    else
                        std.fmt.bufPrint(&info_buf, "t={d}", .{app.cursor}) catch ""
                else if (selected) |task|
                    std.fmt.bufPrint(&info_buf, "{s}·{s} │ t={d} │ task={s}", .{ report.scenario.name, @tagName(report.policy.kind), app.cursor, task.id }) catch ""
                else
                    std.fmt.bufPrint(&info_buf, "{s}·{s} │ t={d}", .{ report.scenario.name, @tagName(report.policy.kind), app.cursor }) catch "";
            }
            break :blk "";
        },
        .observability_summary => if (app.observability_summary) |summary|
            std.fmt.bufPrint(&info_buf, "{s} │ events={d} │ cpus={d} │ pids={d}", .{ summary.family, summary.event_count, summary.cpu_ids.len, summary.pid_ids.len }) catch ""
        else
            "",
        .observability_comparison => if (app.observability_comparison) |comparison|
            std.fmt.bufPrint(&info_buf, "{s} │ metrics={d} │ sim={s}", .{ comparison.pairing_id, comparison.metric_rows.len, comparison.simulator_source.policy }) catch ""
        else
            "",
    };
    if (info.len != 0) {
        canvas.drawTextClipped(rect.x + 10, rect.y, rect.w / 2 - 12, info, .{ .fg = .fg_inv, .bg = .bg_inv });
    }

    const hints = switch (output_mode) {
        .interactive => switch (app.view) {
            .explorer => if (contract.tier == .too_small)
                "resize to at least 80x24 · q quit"
            else if (contract.tier == .compact)
                "tab enter d ? q"
            else
                "← → scrub  j k task  tab pane  space play  d diff  s open  ? help  q quit",
            .picker => "↑ ↓ select  ↵ open  p policy  m m19  c m20  w theme  ? help  q quit",
            .drawer => if (contract.tier == .compact) "esc back  d diff  ? help  q quit" else "esc back  ← → scrub  j k task  d diff  s open  ? help  q quit",
            .diff => if (contract.tier == .compact) "d exit diff  ? help  q quit" else "d exit diff  ← → scrub  w theme  s open  ? help  q quit",
            .observability_summary => "w theme  ? help  q quit",
            .observability_comparison => "w theme  ? help  q quit",
            .help => if (contract.tier == .compact) "esc close help  q quit" else "? or esc close  q quit",
        },
        .snapshot => "snapshot · non-interactive render · rerun without --snapshot for controls",
    };
    canvas.drawTextClipped(rect.x + rect.w / 2, rect.y, rect.w / 2 - 2, hints, .{ .fg = .fg_inv, .bg = .bg_inv, .bold = false });
}

fn renderPane(canvas: *Canvas, rect: Rect, title: []const u8, badge: ?[]const u8, subtitle: ?[]const u8, active: bool, _: Theme) Rect {
    const border_style: Style = .{ .fg = if (active) .fg else .fg_faint, .bg = .bg };
    canvas.fillRect(rect, .{ .fg = .fg, .bg = .bg });
    canvas.drawBox(rect, border_style);

    var title_buf: [128]u8 = undefined;
    const title_text = if (badge) |badge_text|
        std.fmt.bufPrint(&title_buf, " {s} {s} ", .{ title, badge_text }) catch title
    else
        std.fmt.bufPrint(&title_buf, " {s} ", .{title}) catch title;
    canvas.drawText(rect.x + 2, rect.y, title_text, .{ .fg = if (active) .fg else .fg_dim, .bg = .bg, .bold = true });
    if (subtitle) |sub| canvas.drawTextClipped(rect.x + 2, rect.y + 1, rect.w - 4, sub, .{ .fg = .fg_dim, .bg = .bg });
    const subtitle_rows: usize = if (subtitle != null) 2 else 1;
    const footer_rows: usize = if (subtitle != null) 3 else 2;
    return .{
        .x = rect.x + 1,
        .y = rect.y + @min(subtitle_rows, rect.h),
        .w = satSub(rect.w, 2),
        .h = satSub(rect.h, footer_rows),
    };
}

fn renderBannerHeader(canvas: *Canvas, rect: Rect, title: []const u8, subtitle: []const u8, lane_label: []const u8) void {
    canvas.fillRect(rect, .{ .fg = .fg, .bg = .bg });
    canvas.drawText(1, rect.y, "▚ zig-scheduler", .{ .fg = .dispatch, .bg = .bg, .bold = true });
    canvas.drawTextClipped(18, rect.y, satSub(rect.w, lane_label.len + 22), title, .{ .fg = .fg, .bg = .bg, .bold = true });
    canvas.drawTextClipped(1, rect.y + 1, satSub(rect.w, lane_label.len + 6), subtitle, .{ .fg = .fg_dim, .bg = .bg });
    canvas.drawText(rect.x + rect.w - lane_label.len - 2, rect.y, lane_label, .{ .fg = .fg_dim, .bg = .bg, .bold = true });
    canvas.drawHLine(rect.x, rect.y + rect.h - 1, rect.w, '─', .{ .fg = .fg_faint, .bg = .bg });
}

fn renderTextRows(canvas: *Canvas, rect: Rect, lines: []const []const u8) void {
    var y = rect.y;
    for (lines) |line| {
        if (y >= rect.y + rect.h) break;
        canvas.drawTextClipped(rect.x, y, rect.w, line, .{ .fg = .fg, .bg = .bg });
        y += 1;
    }
}

fn formatNumericValue(buf: []u8, value: scheduler.observability_comparison.Numeric) []const u8 {
    return switch (value) {
        .int => |int_value| std.fmt.bufPrint(buf, "{d}", .{int_value}) catch "",
        .float => |float_value| std.fmt.bufPrint(buf, "{d:.3}", .{float_value}) catch "",
    };
}

fn renderObservabilitySummary(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const summary = app.observability_summary orelse {
        canvas.fillRect(.{ .x = 0, .y = 0, .w = canvas.width, .h = canvas.height }, .{ .fg = .fg, .bg = .bg });
        return;
    };
    const contract = viewContract(.observability_summary, canvas.width, canvas.height, false);
    renderBannerHeader(
        canvas,
        .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 },
        "linux observability summary",
        "m19 · observability-only offline fixture summary · not replay or Linux-performance evidence",
        if (output_mode == .snapshot) "SNAPSHOT" else "M19",
    );

    const top: usize = 3;
    const gap: usize = 1;
    const body_h = canvas.height - top - 1;

    if (contract.tier == .compact) {
        const meta_h = @max(@as(usize, 7), body_h / 3);
        const counts_h = @max(@as(usize, 6), body_h / 4);
        const meta_rect = Rect{ .x = 1, .y = top, .w = canvas.width - 2, .h = meta_h };
        const counts_rect = Rect{ .x = 1, .y = meta_rect.y + meta_rect.h + gap, .w = canvas.width - 2, .h = counts_h };
        const boundary_rect = Rect{ .x = 1, .y = counts_rect.y + counts_rect.h + gap, .w = canvas.width - 2, .h = canvas.height - 1 - (counts_rect.y + counts_rect.h + gap) };
        const meta_inner = renderPane(canvas, meta_rect, "fixture + tuple", null, null, true, theme);
        const counts_inner = renderPane(canvas, counts_rect, "event counts", null, null, false, theme);
        const boundary_inner = renderPane(canvas, boundary_rect, "boundary", null, null, false, theme);
        var row_buf: [8][128]u8 = undefined;
        const meta_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "fixture `{s}`", .{summary.fixture_name}) catch "",
            std.fmt.bufPrint(&row_buf[1], "family `{s}`", .{summary.family}) catch "",
            std.fmt.bufPrint(&row_buf[2], "kernel `{s}`", .{summary.kernel_release}) catch "",
            std.fmt.bufPrint(&row_buf[3], "format `{s}`", .{summary.snapshot_format_version}) catch "",
            std.fmt.bufPrint(&row_buf[4], "scrub `{s}`", .{summary.scrub_policy_version}) catch "",
            std.fmt.bufPrint(&row_buf[5], "source {s}", .{summary.source_class}) catch "",
        };
        renderTextRows(canvas, meta_inner, &meta_rows);
        const count_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "events {d}  span {d:.6}..{d:.6}", .{ summary.event_count, summary.first_timestamp, summary.last_timestamp }) catch "",
            std.fmt.bufPrint(&row_buf[1], "cpus {d}  pids {d}", .{ summary.cpu_ids.len, summary.pid_ids.len }) catch "",
            std.fmt.bufPrint(&row_buf[2], "switch {d}  wakeup {d}", .{ summary.counts.sched_switch, summary.counts.sched_wakeup }) catch "",
            std.fmt.bufPrint(&row_buf[3], "wakeup_new {d}  fork {d}", .{ summary.counts.sched_wakeup_new, summary.counts.sched_process_fork }) catch "",
            std.fmt.bufPrint(&row_buf[4], "exit {d}", .{summary.counts.sched_process_exit}) catch "",
        };
        renderTextRows(canvas, counts_inner, &count_rows);
        const boundary_rows = [_][]const u8{
            "observability-only · bounded offline fixture lane",
            "not replay authority · not calibration authority",
            "not Linux-performance evidence",
        };
        renderTextRows(canvas, boundary_inner, &boundary_rows);
    } else {
        const left_w = (canvas.width - 4) / 2;
        const left_rect = Rect{ .x = 1, .y = top, .w = left_w, .h = body_h };
        const right_rect = Rect{ .x = left_rect.x + left_rect.w + gap, .y = top, .w = canvas.width - left_rect.w - 3, .h = body_h };
        const tuple_rect = Rect{ .x = left_rect.x, .y = left_rect.y, .w = left_rect.w, .h = left_rect.h / 2 };
        const scope_rect = Rect{ .x = left_rect.x, .y = tuple_rect.y + tuple_rect.h + gap, .w = left_rect.w, .h = left_rect.h - tuple_rect.h - gap };
        const counts_rect = Rect{ .x = right_rect.x, .y = right_rect.y, .w = right_rect.w, .h = right_rect.h / 2 };
        const boundary_rect = Rect{ .x = right_rect.x, .y = counts_rect.y + counts_rect.h + gap, .w = right_rect.w, .h = right_rect.h - counts_rect.h - gap };
        const tuple_inner = renderPane(canvas, tuple_rect, "fixture + tuple", null, null, true, theme);
        const scope_inner = renderPane(canvas, scope_rect, "scope", null, null, false, theme);
        const counts_inner = renderPane(canvas, counts_rect, "event counts", null, null, false, theme);
        const boundary_inner = renderPane(canvas, boundary_rect, "boundary", null, null, false, theme);
        var row_buf: [12][160]u8 = undefined;
        const tuple_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "fixture: `{s}`", .{summary.fixture_name}) catch "",
            std.fmt.bufPrint(&row_buf[1], "family: `{s}`", .{summary.family}) catch "",
            std.fmt.bufPrint(&row_buf[2], "kernel: `{s}`", .{summary.kernel_release}) catch "",
            std.fmt.bufPrint(&row_buf[3], "snapshot format: `{s}`", .{summary.snapshot_format_version}) catch "",
            std.fmt.bufPrint(&row_buf[4], "scrub policy: `{s}`", .{summary.scrub_policy_version}) catch "",
            std.fmt.bufPrint(&row_buf[5], "redistribution: {s}", .{summary.redistribution_basis}) catch "",
        };
        renderTextRows(canvas, tuple_inner, &tuple_rows);
        const scope_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[6], "source class: {s}", .{summary.source_class}) catch "",
            std.fmt.bufPrint(&row_buf[7], "timestamp span: {d:.6} -> {d:.6}", .{ summary.first_timestamp, summary.last_timestamp }) catch "",
            std.fmt.bufPrint(&row_buf[8], "cpu ids seen: {d}", .{summary.cpu_ids.len}) catch "",
            std.fmt.bufPrint(&row_buf[9], "pid ids seen: {d}", .{summary.pid_ids.len}) catch "",
        };
        renderTextRows(canvas, scope_inner, &scope_rows);
        const count_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "sched_switch: {d}", .{summary.counts.sched_switch}) catch "",
            std.fmt.bufPrint(&row_buf[1], "sched_wakeup: {d}", .{summary.counts.sched_wakeup}) catch "",
            std.fmt.bufPrint(&row_buf[2], "sched_wakeup_new: {d}", .{summary.counts.sched_wakeup_new}) catch "",
            std.fmt.bufPrint(&row_buf[3], "sched_process_fork: {d}", .{summary.counts.sched_process_fork}) catch "",
            std.fmt.bufPrint(&row_buf[4], "sched_process_exit: {d}", .{summary.counts.sched_process_exit}) catch "",
        };
        renderTextRows(canvas, counts_inner, &count_rows);
        const boundary_rows = [_][]const u8{
            "observability-only surface based on a committed offline fixture",
            "bounded M19 lane · approved tuple only",
            "not replay authority · not calibration authority",
            "not Linux-performance evidence",
        };
        renderTextRows(canvas, boundary_inner, &boundary_rows);
    }

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "M19", output_mode);
}

fn renderObservabilityComparison(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const comparison = app.observability_comparison orelse {
        canvas.fillRect(.{ .x = 0, .y = 0, .w = canvas.width, .h = canvas.height }, .{ .fg = .fg, .bg = .bg });
        return;
    };
    const contract = viewContract(.observability_comparison, canvas.width, canvas.height, false);
    renderBannerHeader(
        canvas,
        .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 },
        "simulator-to-trace comparison",
        "m20 · bounded observability-only comparison lane · not replay or fidelity evidence",
        if (output_mode == .snapshot) "SNAPSHOT" else "M20",
    );

    const top: usize = 3;
    const gap: usize = 1;
    const body_h = canvas.height - top - 1;

    if (contract.tier == .compact) {
        const meta_h = @max(@as(usize, 6), body_h / 4);
        const family_h = @max(@as(usize, 4), body_h / 5);
        const metric_h = @max(@as(usize, 7), body_h / 3);
        const meta_rect = Rect{ .x = 1, .y = top, .w = canvas.width - 2, .h = meta_h };
        const family_rect = Rect{ .x = 1, .y = meta_rect.y + meta_rect.h + gap, .w = canvas.width - 2, .h = family_h };
        const metric_rect = Rect{ .x = 1, .y = family_rect.y + family_rect.h + gap, .w = canvas.width - 2, .h = metric_h };
        const caveat_rect = Rect{ .x = 1, .y = metric_rect.y + metric_rect.h + gap, .w = canvas.width - 2, .h = canvas.height - 1 - (metric_rect.y + metric_rect.h + gap) };
        const meta_inner = renderPane(canvas, meta_rect, "pairing", null, null, true, theme);
        const family_inner = renderPane(canvas, family_rect, "normalized families", null, null, false, theme);
        const metric_inner = renderPane(canvas, metric_rect, "metric rows", null, null, false, theme);
        const caveat_inner = renderPane(canvas, caveat_rect, "caveats", null, null, false, theme);
        var row_buf: [12][160]u8 = undefined;
        const meta_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "pairing `{s}`", .{comparison.pairing_id}) catch "",
            std.fmt.bufPrint(&row_buf[1], "sim `{s}` with `{s}`", .{ comparison.simulator_source.scenario_path, comparison.simulator_source.policy }) catch "",
            std.fmt.bufPrint(&row_buf[2], "obs `{s}`", .{comparison.observability_fixture_manifest.manifest_path}) catch "",
        };
        renderTextRows(canvas, meta_inner, &meta_rows);
        const family_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[3], "sim: {s} -> {s} -> {s}", .{ comparison.normalized_order_summary.simulator_families[0], comparison.normalized_order_summary.simulator_families[1], comparison.normalized_order_summary.simulator_families[2] }) catch "",
            std.fmt.bufPrint(&row_buf[4], "obs: {s} -> {s} -> {s}", .{ comparison.normalized_order_summary.observability_families[0], comparison.normalized_order_summary.observability_families[1], comparison.normalized_order_summary.observability_families[2] }) catch "",
        };
        renderTextRows(canvas, family_inner, &family_rows);
        renderComparisonMetricRows(canvas, metric_inner, comparison.metric_rows, true);
        const caveat_rows = [_][]const u8{
            "observability-only · bounded comparison",
            "not replay authority · not fidelity scoring",
            "not Linux-performance evidence",
        };
        renderTextRows(canvas, caveat_inner, &caveat_rows);
    } else {
        const left_w = (canvas.width - 4) * 11 / 25;
        const right_w = canvas.width - left_w - 3;
        const left_rect = Rect{ .x = 1, .y = top, .w = left_w, .h = body_h };
        const right_rect = Rect{ .x = left_rect.x + left_rect.w + gap, .y = top, .w = right_w, .h = body_h };
        const meta_rect = Rect{ .x = left_rect.x, .y = left_rect.y, .w = left_rect.w, .h = left_rect.h / 2 };
        const family_rect = Rect{ .x = left_rect.x, .y = meta_rect.y + meta_rect.h + gap, .w = left_rect.w, .h = left_rect.h - meta_rect.h - gap };
        const metric_rect = Rect{ .x = right_rect.x, .y = right_rect.y, .w = right_rect.w, .h = right_rect.h * 3 / 5 };
        const caveat_rect = Rect{ .x = right_rect.x, .y = metric_rect.y + metric_rect.h + gap, .w = right_rect.w, .h = right_rect.h - metric_rect.h - gap };
        const meta_inner = renderPane(canvas, meta_rect, "pairing", null, null, true, theme);
        const family_inner = renderPane(canvas, family_rect, "normalized families", null, null, false, theme);
        const metric_inner = renderPane(canvas, metric_rect, "metric rows", null, null, false, theme);
        const caveat_inner = renderPane(canvas, caveat_rect, "caveats", null, null, false, theme);
        var row_buf: [12][180]u8 = undefined;
        const meta_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[0], "pairing id: `{s}`", .{comparison.pairing_id}) catch "",
            std.fmt.bufPrint(&row_buf[1], "simulator source: `{s}` with `{s}`", .{ comparison.simulator_source.scenario_path, comparison.simulator_source.policy }) catch "",
            std.fmt.bufPrint(&row_buf[2], "simulator export provenance: v{d}", .{comparison.simulator_source.report_version}) catch "",
            std.fmt.bufPrint(&row_buf[3], "observability manifest: `{s}`", .{comparison.observability_fixture_manifest.manifest_path}) catch "",
            std.fmt.bufPrint(&row_buf[4], "tuple: `{s}` / `{s}` / `{s}` / `{s}`", .{ comparison.observability_fixture_manifest.family, comparison.observability_fixture_manifest.kernel_release, comparison.observability_fixture_manifest.snapshot_format_version, comparison.observability_fixture_manifest.scrub_policy_version }) catch "",
        };
        renderTextRows(canvas, meta_inner, &meta_rows);
        const family_rows = [_][]const u8{
            std.fmt.bufPrint(&row_buf[5], "simulator order: {s} -> {s} -> {s}", .{ comparison.normalized_order_summary.simulator_families[0], comparison.normalized_order_summary.simulator_families[1], comparison.normalized_order_summary.simulator_families[2] }) catch "",
            std.fmt.bufPrint(&row_buf[6], "observability order: {s} -> {s} -> {s}", .{ comparison.normalized_order_summary.observability_families[0], comparison.normalized_order_summary.observability_families[1], comparison.normalized_order_summary.observability_families[2] }) catch "",
        };
        renderTextRows(canvas, family_inner, &family_rows);
        renderComparisonMetricRows(canvas, metric_inner, comparison.metric_rows, false);
        const caveat_rows = [_][]const u8{
            "observability-only comparison using committed inputs",
            comparison.caveats.observability_only,
            comparison.caveats.units_not_equivalent,
            comparison.caveats.identity_not_equivalent,
            comparison.caveats.not_fidelity,
        };
        renderTextRows(canvas, caveat_inner, &caveat_rows);
    }

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "M20", output_mode);
}

fn renderComparisonMetricRows(canvas: *Canvas, rect: Rect, metric_rows: []const scheduler.observability_comparison.MetricRow, compact: bool) void {
    var y = rect.y;
    for (metric_rows) |row| {
        if (y >= rect.y + rect.h) break;
        var sim_buf: [32]u8 = undefined;
        var obs_buf: [32]u8 = undefined;
        var delta_buf: [32]u8 = undefined;
        if (compact) {
            var line_buf: [192]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}: s={s} o={s} Δ={s}", .{
                row.metric_key,
                formatNumericValue(&sim_buf, row.simulator_value),
                formatNumericValue(&obs_buf, row.observability_value),
                formatNumericValue(&delta_buf, row.delta),
            }) catch "";
            canvas.drawTextClipped(rect.x, y, rect.w, line, .{ .fg = .fg, .bg = .bg });
            y += 1;
            if (y >= rect.y + rect.h) break;
            var caveat_buf: [96]u8 = undefined;
            const caveat_line = std.fmt.bufPrint(&caveat_buf, "  caveat `{s}`", .{row.caveat_key}) catch "";
            canvas.drawTextClipped(rect.x, y, rect.w, caveat_line, .{ .fg = .fg_dim, .bg = .bg });
            y += 1;
            continue;
        }

        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s:<26} sim={s:<8} obs={s:<8} delta={s:<8} `{s}`", .{
            row.metric_key,
            formatNumericValue(&sim_buf, row.simulator_value),
            formatNumericValue(&obs_buf, row.observability_value),
            formatNumericValue(&delta_buf, row.delta),
            row.caveat_key,
        }) catch "";
        canvas.drawTextClipped(rect.x, y, rect.w, line, .{ .fg = .fg, .bg = .bg });
        y += 1;
    }
}

fn renderExplorer(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const report = app.report orelse return renderPicker(canvas, app, theme, output_mode);
    const contract = viewContract(.explorer, canvas.width, canvas.height, app.compare_report != null);
    renderHeader(canvas, .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 }, report, theme, app.playing, null);

    const body_top: usize = 3;
    const body_height = canvas.height - body_top - 2;
    const gap: usize = 1;
    const task_badge = std.fmt.allocPrint(canvas.allocator, "{d}", .{report.tasks.len}) catch null;
    defer if (task_badge) |owned| canvas.allocator.free(owned);
    const event_badge = std.fmt.allocPrint(canvas.allocator, "{d} total", .{report.trace.len}) catch null;
    defer if (event_badge) |owned| canvas.allocator.free(owned);
    var tick_buf: [24]u8 = undefined;
    const tick_badge = std.fmt.bufPrint(&tick_buf, "t={d}", .{app.cursor}) catch "";

    if (contract.tier == .compact) {
        const gantt_h = @min(@as(usize, 7), @max(@as(usize, 6), body_height / 3));
        const bottom_y = body_top + gantt_h + gap;
        const bottom_h = body_top + body_height - bottom_y;
        const task_h = @max(@as(usize, 6), bottom_h / 2);
        const gantt_rect = Rect{ .x = 1, .y = body_top, .w = canvas.width - 2, .h = gantt_h };
        const tasks_rect = Rect{ .x = 1, .y = bottom_y, .w = canvas.width - 2, .h = task_h };
        const tick_rect = Rect{ .x = 1, .y = tasks_rect.y + tasks_rect.h + gap, .w = canvas.width - 2, .h = canvas.height - 1 - (tasks_rect.y + tasks_rect.h + gap) };

        const gantt_inner = renderPane(canvas, gantt_rect, "trace · cpu lanes", null, policySubtitle(report), app.focus == .gantt, theme);
        renderGantt(canvas, gantt_inner, report, app, theme, false);

        const tasks_inner = renderPane(canvas, tasks_rect, "tasks", task_badge, null, app.focus == .tasks, theme);
        renderTaskTable(canvas, tasks_inner, report, app, theme, true);

        const tick_inner = renderPane(canvas, tick_rect, "tick", tick_badge, null, app.focus == .tick, theme);
        renderCompactTickPane(canvas, tick_inner, report, app.cursor);
    } else {
        const gantt_h = if (contract.tier == .medium) @min(@as(usize, 12), body_height / 2 + 1) else @min(@as(usize, 16), body_height / 2 + 2);
        const gantt_rect = Rect{ .x = 1, .y = body_top, .w = canvas.width - 2, .h = gantt_h };
        const bottom_y = body_top + gantt_h + gap;
        const bottom_h = body_top + body_height - bottom_y;
        const left_w = (canvas.width - 4) * 12 / 30;
        const mid_w = (canvas.width - 4) * 9 / 30;
        const right_w = canvas.width - 4 - left_w - mid_w;
        const left_rect = Rect{ .x = 1, .y = bottom_y, .w = left_w, .h = bottom_h };
        const mid_rect = Rect{ .x = left_rect.x + left_rect.w + gap, .y = bottom_y, .w = mid_w, .h = bottom_h };
        const right_top_rect = Rect{ .x = mid_rect.x + mid_rect.w + gap, .y = bottom_y, .w = right_w, .h = bottom_h / 2 };
        const right_bottom_rect = Rect{ .x = right_top_rect.x, .y = right_top_rect.y + right_top_rect.h + gap, .w = right_w, .h = bottom_h - right_top_rect.h - gap };

        const gantt_inner = renderPane(canvas, gantt_rect, "trace · cpu lanes", null, policySubtitle(report), app.focus == .gantt, theme);
        renderGantt(canvas, gantt_inner, report, app, theme, contract.tier == .large);

        const tasks_inner = renderPane(canvas, left_rect, "tasks", task_badge, null, app.focus == .tasks, theme);
        renderTaskTable(canvas, tasks_inner, report, app, theme, contract.dense_task_table);

        const events_inner = renderPane(canvas, mid_rect, "events", event_badge, null, app.focus == .events, theme);
        renderEventLog(canvas, events_inner, report, app.cursor, theme);

        const tick_inner = renderPane(canvas, right_top_rect, "tick", tick_badge, null, app.focus == .tick, theme);
        renderTickDetail(canvas, tick_inner, report, app.cursor, theme);

        if (contract.show_aggregate_pane) {
            const agg_inner = renderPane(canvas, right_bottom_rect, "aggregate", null, null, false, theme);
            renderAggregate(canvas, agg_inner, report, theme);
        } else {
            renderAggregateCompact(canvas, tick_inner, report, app.cursor);
        }
    }

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "NORMAL", output_mode);
}

fn renderDrawer(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const report = app.report orelse return renderExplorer(canvas, app, theme, output_mode);
    const task = selectedTask(report, app.selected_task_index) orelse return renderExplorer(canvas, app, theme, output_mode);
    const contract = viewContract(.drawer, canvas.width, canvas.height, app.compare_report != null);
    renderHeader(canvas, .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 }, report, theme, false, null);

    if (contract.tier == .compact) {
        const gap: usize = 1;
        const top: usize = 3;
        const full_w = canvas.width - 2;
        const body_h = canvas.height - top - 1;
        const detail_h = @min(@as(usize, 8), @max(@as(usize, 6), body_h / 3));
        const side_h = @max(@as(usize, 3), (body_h - detail_h - 3 * gap) / 3);
        const detail_rect = Rect{ .x = 1, .y = top, .w = full_w, .h = detail_h };
        const waiting_rect = Rect{ .x = 1, .y = detail_rect.y + detail_rect.h + gap, .w = full_w, .h = side_h };
        const cores_rect = Rect{ .x = 1, .y = waiting_rect.y + waiting_rect.h + gap, .w = full_w, .h = side_h };
        const order_rect = Rect{ .x = 1, .y = cores_rect.y + cores_rect.h + gap, .w = full_w, .h = side_h };
        const events_rect = Rect{ .x = 1, .y = order_rect.y + order_rect.h + gap, .w = full_w, .h = canvas.height - 1 - (order_rect.y + order_rect.h + gap) };

        var badge_buf: [64]u8 = undefined;
        const badge = if (task.group_id) |group_id|
            std.fmt.bufPrint(&badge_buf, "group {s}", .{group_id}) catch ""
        else
            null;
        const detail_inner = renderPane(canvas, detail_rect, std.fmt.bufPrint(&badge_buf, "task · {s}", .{task.id}) catch "task", badge, null, true, theme);
        renderTaskDetail(canvas, detail_inner, report, task, app.cursor, theme);

        const wait_inner = renderPane(canvas, waiting_rect, "waiting profile", null, null, false, theme);
        renderWaitingProfile(canvas, wait_inner, task, theme);
        const cores_inner = renderPane(canvas, cores_rect, "cores used", null, null, false, theme);
        renderTaskCoreUsage(canvas, cores_inner, report, task, theme);
        const order_inner = renderPane(canvas, order_rect, "neighbors · completion order", null, null, false, theme);
        renderCompletionOrder(canvas, order_inner, report, task.id, theme);
        const events_inner = renderPane(canvas, events_rect, "events · this task", null, null, false, theme);
        renderTaskEventLog(canvas, events_inner, report, task.id, app.cursor, theme);

        renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "TASK", output_mode);
        return;
    }

    const gap: usize = 1;
    const top: usize = 3;
    const left_w = canvas.width - 40;
    const right_w = 38;
    const left_rect = Rect{ .x = 1, .y = top, .w = left_w - 1, .h = canvas.height - top - 2 };
    const right_rect = Rect{ .x = left_rect.x + left_rect.w + gap, .y = top, .w = right_w, .h = canvas.height - top - 2 };

    const top_left_h = 14;
    const detail_rect = Rect{ .x = left_rect.x, .y = left_rect.y, .w = left_rect.w, .h = top_left_h };
    const events_rect = Rect{ .x = left_rect.x, .y = left_rect.y + top_left_h + gap, .w = left_rect.w, .h = left_rect.h - top_left_h - gap };

    var badge_buf: [64]u8 = undefined;
    const badge = if (task.group_id) |group_id|
        std.fmt.bufPrint(&badge_buf, "group {s}", .{group_id}) catch ""
    else
        null;
    const detail_inner = renderPane(canvas, detail_rect, std.fmt.bufPrint(&badge_buf, "task · {s}", .{task.id}) catch "task", badge, null, true, theme);
    renderTaskDetail(canvas, detail_inner, report, task, app.cursor, theme);

    const task_events_inner = renderPane(canvas, events_rect, "events · this task", null, null, false, theme);
    renderTaskEventLog(canvas, task_events_inner, report, task.id, app.cursor, theme);

    const wait_rect = Rect{ .x = right_rect.x, .y = right_rect.y, .w = right_rect.w, .h = 8 };
    const cores_rect = Rect{ .x = right_rect.x, .y = right_rect.y + 9, .w = right_rect.w, .h = 8 };
    const neigh_rect = Rect{ .x = right_rect.x, .y = right_rect.y + 18, .w = right_rect.w, .h = right_rect.h - 18 };
    const wait_inner = renderPane(canvas, wait_rect, "waiting profile", null, null, false, theme);
    renderWaitingProfile(canvas, wait_inner, task, theme);
    const cores_inner = renderPane(canvas, cores_rect, "cores used", null, null, false, theme);
    renderTaskCoreUsage(canvas, cores_inner, report, task, theme);
    const neigh_inner = renderPane(canvas, neigh_rect, "neighbors · completion order", null, null, false, theme);
    renderCompletionOrder(canvas, neigh_inner, report, task.id, theme);

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "TASK", output_mode);
}

fn renderDiff(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const report_a = app.report orelse return renderExplorer(canvas, app, theme, output_mode);
    const report_b = app.compare_report orelse return renderExplorer(canvas, app, theme, output_mode);
    const contract = viewContract(.diff, canvas.width, canvas.height, app.compare_report != null);
    renderHeader(canvas, .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 }, report_a, theme, false, "diff");

    if (contract.tier == .compact) {
        const gap: usize = 1;
        const top: usize = 3;
        const full_w = canvas.width - 2;
        const body_h = canvas.height - top - 1;
        const gantt_h = @max(@as(usize, 5), (body_h - 3 * gap) / 4);
        const summary_h = @max(@as(usize, 4), (body_h - 2 * gantt_h - 3 * gap) / 2);
        const a_rect = Rect{ .x = 1, .y = top, .w = full_w, .h = gantt_h };
        const b_rect = Rect{ .x = 1, .y = a_rect.y + a_rect.h + gap, .w = full_w, .h = gantt_h };
        const delta_rect = Rect{ .x = 1, .y = b_rect.y + b_rect.h + gap, .w = full_w, .h = summary_h };
        const agg_rect = Rect{ .x = 1, .y = delta_rect.y + delta_rect.h + gap, .w = full_w, .h = canvas.height - 1 - (delta_rect.y + delta_rect.h + gap) };

        const a_inner = renderPane(canvas, a_rect, "A · current", report_a.policy.display_name, null, true, theme);
        renderGantt(canvas, a_inner, report_a, app, theme, false);
        const b_inner = renderPane(canvas, b_rect, "B · compare", report_b.policy.display_name, null, true, theme);
        renderGantt(canvas, b_inner, report_b, app, theme, false);
        const delta_inner = renderPane(canvas, delta_rect, "per-task deltas", null, null, false, theme);
        renderDiffTable(canvas, delta_inner, report_a, report_b, theme);
        const agg_inner = renderPane(canvas, agg_rect, "aggregate", null, null, false, theme);
        renderDiffAggregate(canvas, agg_inner, report_a, report_b, theme);

        renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "DIFF", output_mode);
        return;
    }

    const gap: usize = 1;
    const top: usize = 3;
    const half_w = (canvas.width - 3) / 2;
    const gantt_h: usize = 12;
    const pane_a = Rect{ .x = 1, .y = top, .w = half_w, .h = gantt_h };
    const pane_b = Rect{ .x = pane_a.x + pane_a.w + gap, .y = top, .w = canvas.width - pane_a.w - 3, .h = gantt_h };
    const bottom_top = top + gantt_h + gap;
    const bottom_h = canvas.height - bottom_top - 2;
    const deltas_rect = Rect{ .x = 1, .y = bottom_top, .w = half_w, .h = bottom_h };
    const agg_rect = Rect{ .x = deltas_rect.x + deltas_rect.w + gap, .y = bottom_top, .w = canvas.width - deltas_rect.w - 3, .h = bottom_h };

    const a_inner = renderPane(canvas, pane_a, "A · current", report_a.policy.display_name, null, true, theme);
    renderGantt(canvas, a_inner, report_a, app, theme, false);
    const b_inner = renderPane(canvas, pane_b, "B · compare", report_b.policy.display_name, null, true, theme);
    renderGantt(canvas, b_inner, report_b, app, theme, false);
    const delta_inner = renderPane(canvas, deltas_rect, "per-task deltas", null, null, false, theme);
    renderDiffTable(canvas, delta_inner, report_a, report_b, theme);
    const agg_inner = renderPane(canvas, agg_rect, "aggregate", null, null, false, theme);
    renderDiffAggregate(canvas, agg_inner, report_a, report_b, theme);

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "DIFF", output_mode);
}

fn renderPicker(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const fallback_report = app.report orelse blk: {
        canvas.fillRect(.{ .x = 0, .y = 0, .w = canvas.width, .h = canvas.height }, .{ .fg = .fg, .bg = .bg });
        break :blk null;
    };
    const contract = viewContract(.picker, canvas.width, canvas.height, app.compare_report != null);
    if (fallback_report) |report| renderHeader(canvas, .{ .x = 0, .y = 0, .w = canvas.width, .h = 3 }, report, theme, false, "trace explorer") else {
        canvas.fillRect(.{ .x = 0, .y = 0, .w = canvas.width, .h = 3 }, .{ .fg = .fg, .bg = .bg });
        canvas.drawText(1, 0, "▚ zig-scheduler · trace explorer", .{ .fg = .dispatch, .bg = .bg, .bold = true });
        canvas.drawText(1, 1, "m15 · load a scenario, pick a policy, replay the trace.", .{ .fg = .fg_dim, .bg = .bg });
        canvas.drawHLine(0, 2, canvas.width, '─', .{ .fg = .fg_faint, .bg = .bg });
    }

    const banner = [_][]const u8{
        "   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓",
        "   ┃  a deterministic cpu scheduling laboratory · phase 1 · simulator only   ┃",
        "   ┃  schema · zig-scheduler/report v1   ·   built-in packs + .zon fixtures  ┃",
        "   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛",
    };
    var y: usize = 4;
    for (banner) |line| {
        canvas.drawText(2, y, line, .{ .fg = .fg_dim, .bg = .bg });
        y += 1;
    }

    if (contract.tier == .compact) {
        const gap: usize = 1;
        const top: usize = 3;
        const body_h = canvas.height - top - 1;
        const list_h = @min(@as(usize, 9), @max(@as(usize, 6), body_h / 2));
        const list_rect = Rect{ .x = 1, .y = top, .w = canvas.width - 2, .h = list_h };
        const side_h = @max(@as(usize, 3), (body_h - list_h - 2 * gap) / 3);
        const sources_rect = Rect{ .x = 1, .y = list_rect.y + list_rect.h + gap, .w = canvas.width - 2, .h = side_h };
        const policies_rect = Rect{ .x = 1, .y = sources_rect.y + sources_rect.h + gap, .w = canvas.width - 2, .h = side_h };
        const recent_rect = Rect{ .x = 1, .y = policies_rect.y + policies_rect.h + gap, .w = canvas.width - 2, .h = canvas.height - 1 - (policies_rect.y + policies_rect.h + gap) };
        const scenarios_badge = std.fmt.allocPrint(canvas.allocator, "{d} available", .{app.picker_entries.len}) catch null;
        defer if (scenarios_badge) |owned| canvas.allocator.free(owned);
        const list_inner = renderPane(canvas, list_rect, "scenarios", scenarios_badge, null, true, theme);
        renderPickerList(canvas, list_inner, app, theme);
        const sources_inner = renderPane(canvas, sources_rect, "sources", null, null, false, theme);
        renderPickerSources(canvas, sources_inner, theme);
        const start_here_inner = renderPane(canvas, policies_rect, "start here", null, null, false, theme);
        renderPickerStartHere(canvas, start_here_inner, theme);
        const recent_inner = renderPane(canvas, recent_rect, "recent", null, null, false, theme);
        renderPickerRecent(canvas, recent_inner, app.history, theme);
        renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "OPEN", output_mode);
        return;
    }

    const gap: usize = 1;
    const list_rect = Rect{ .x = 1, .y = 9, .w = (canvas.width * 16 / 25), .h = canvas.height - 12 };
    const side_rect = Rect{ .x = list_rect.x + list_rect.w + gap, .y = 9, .w = canvas.width - list_rect.w - 3, .h = canvas.height - 12 };
    const scenarios_badge = std.fmt.allocPrint(canvas.allocator, "{d} available", .{app.picker_entries.len}) catch null;
    defer if (scenarios_badge) |owned| canvas.allocator.free(owned);
    const list_inner = renderPane(canvas, list_rect, "scenarios", scenarios_badge, null, true, theme);
    renderPickerList(canvas, list_inner, app, theme);

    const sources_rect = Rect{ .x = side_rect.x, .y = side_rect.y, .w = side_rect.w, .h = 8 };
    const policies_rect = Rect{ .x = side_rect.x, .y = side_rect.y + 9, .w = side_rect.w, .h = 8 };
    const recent_rect = Rect{ .x = side_rect.x, .y = side_rect.y + 18, .w = side_rect.w, .h = side_rect.h - 18 };
    const sources_inner = renderPane(canvas, sources_rect, "sources", null, null, false, theme);
    renderPickerSources(canvas, sources_inner, theme);
    const start_here_inner = renderPane(canvas, policies_rect, "start here", null, null, false, theme);
    renderPickerStartHere(canvas, start_here_inner, theme);
    const recent_inner = renderPane(canvas, recent_rect, "recent", null, null, false, theme);
    renderPickerRecent(canvas, recent_inner, app.history, theme);

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "OPEN", output_mode);
}

fn renderHelp(canvas: *Canvas, app: AppView, theme: Theme, output_mode: OutputMode) void {
    const contract = viewContract(.help, canvas.width, canvas.height, app.compare_report != null);
    if (contract.tier != .compact) {
        switch (app.domain_mode) {
            .simulator => renderExplorer(canvas, AppView{
                .domain_mode = .simulator,
                .view = .explorer,
                .theme = app.theme,
                .focus = app.focus,
                .cursor = app.cursor,
                .selected_task_index = app.selected_task_index,
                .picker_index = app.picker_index,
                .playing = app.playing,
                .report = app.report,
                .compare_report = app.compare_report,
                .observability_summary = app.observability_summary,
                .observability_comparison = app.observability_comparison,
                .picker_entries = app.picker_entries,
                .history = app.history,
            }, theme, output_mode),
            .observability_summary => renderObservabilitySummary(canvas, AppView{
                .domain_mode = .observability_summary,
                .view = .observability_summary,
                .theme = app.theme,
                .focus = app.focus,
                .cursor = app.cursor,
                .selected_task_index = app.selected_task_index,
                .picker_index = app.picker_index,
                .playing = false,
                .report = app.report,
                .compare_report = app.compare_report,
                .observability_summary = app.observability_summary,
                .observability_comparison = app.observability_comparison,
                .picker_entries = app.picker_entries,
                .history = app.history,
            }, theme, output_mode),
            .observability_comparison => renderObservabilityComparison(canvas, AppView{
                .domain_mode = .observability_comparison,
                .view = .observability_comparison,
                .theme = app.theme,
                .focus = app.focus,
                .cursor = app.cursor,
                .selected_task_index = app.selected_task_index,
                .picker_index = app.picker_index,
                .playing = false,
                .report = app.report,
                .compare_report = app.compare_report,
                .observability_summary = app.observability_summary,
                .observability_comparison = app.observability_comparison,
                .picker_entries = app.picker_entries,
                .history = app.history,
            }, theme, output_mode),
        }
    } else {
        canvas.fillRect(.{ .x = 0, .y = 0, .w = canvas.width, .h = canvas.height }, .{ .fg = .fg, .bg = .bg });
        canvas.drawText(1, 0, "KEY BINDINGS", .{ .fg = .dispatch, .bg = .bg, .bold = true });
        canvas.drawText(1, 1, "compact help · press ? or esc to close", .{ .fg = .fg_dim, .bg = .bg });
    }

    const width = if (contract.tier == .compact) canvas.width - 2 else @min(82, canvas.width - 8);
    const height = if (contract.tier == .compact) canvas.height - 4 else @min(22, canvas.height - 6);
    const x = if (contract.tier == .compact) 1 else (canvas.width - width) / 2;
    const y = if (contract.tier == .compact) 3 else (canvas.height - height) / 2;
    const rect = Rect{ .x = x, .y = y, .w = width, .h = height };
    canvas.fillRect(rect, .{ .fg = .fg, .bg = .bg });
    canvas.drawBox(rect, .{ .fg = .fg, .bg = .bg });
    canvas.drawText(rect.x + 3, rect.y, " KEY BINDINGS ", .{ .fg = .fg, .bg = .bg, .bold = true });
    if (rect.w > 28) canvas.drawText(rect.x + rect.w - 26, rect.y + 1, "press ? or esc to close", .{ .fg = .fg_dim, .bg = .bg });

    const HelpSection = struct { title: []const u8, rows: []const [2][]const u8 };
    const shortlist = scheduler.scenario_packs.listM21TeachingEntries();
    const simulator_sections = [_]HelpSection{
        .{ .title = "NAVIGATION", .rows = &.{ .{ "←  →", "scrub one tick" }, .{ "home / end", "first / last tick" }, .{ "space", "play / pause" } } },
        .{ .title = "START HERE", .rows = &.{
            .{ shortlist[0].key, teachingPolicyLabel(shortlist[0].recommended_policy.?) },
            .{ shortlist[1].key, teachingPolicyLabel(shortlist[1].recommended_policy.?) },
            .{ shortlist[2].key, teachingPolicyLabel(shortlist[2].recommended_policy.?) },
        } },
        .{ .title = "SELECTION", .rows = &.{ .{ "j  k", "select next / previous task" }, .{ "esc", "clear or close" }, .{ "enter", "open task detail drawer" } } },
        .{ .title = "PANES", .rows = &.{ .{ "tab", "cycle pane focus" }, .{ "w", "toggle dark / light" }, .{ "?", "open this help" } } },
        .{ .title = "VIEWS", .rows = &.{ .{ "d", "policy diff" }, .{ "s", "open scenario picker" }, .{ "m / c", "open M19 / M20 from picker" }, .{ "q", "quit" } } },
    };
    const observability_sections = [_]HelpSection{
        .{ .title = "NAVIGATION", .rows = &.{ .{ "esc", "close help" }, .{ "w", "toggle dark / light" }, .{ "?", "open this help" } } },
        .{ .title = "BOUNDARY", .rows = &.{ .{ "m19 / m20", "observability-only lane" }, .{ "no replay", "not fidelity evidence" }, .{ "q", "quit" } } },
    };
    const sections = switch (app.domain_mode) {
        .simulator => simulator_sections[0..],
        .observability_summary, .observability_comparison => observability_sections[0..],
    };

    var col: usize = 0;
    var sec_y = rect.y + 3;
    for (sections, 0..) |section, idx| {
        if (contract.tier != .compact and idx == 2) {
            col = width / 2;
            sec_y = rect.y + 3;
        }
        const sec_x = rect.x + 3 + col;
        canvas.drawText(sec_x, sec_y, section.title, .{ .fg = .dispatch, .bg = .bg, .bold = true });
        var row_y = sec_y + 2;
        for (section.rows) |row| {
            canvas.drawText(sec_x, row_y, row[0], .{ .fg = .fg, .bg = .bg, .bold = true });
            canvas.drawText(sec_x + 14, row_y, row[1], .{ .fg = .fg_dim, .bg = .bg });
            row_y += 2;
        }
        sec_y = row_y + 1;
    }

    renderStatusBar(canvas, .{ .x = 0, .y = canvas.height - 1, .w = canvas.width, .h = 1 }, app, theme, if (output_mode == .snapshot) "SNAPSHOT" else "HELP", output_mode);
}

fn satSub(lhs: usize, rhs: usize) usize {
    return if (lhs > rhs) lhs - rhs else 0;
}

fn renderGantt(canvas: *Canvas, rect: Rect, report: *const Report, app: AppView, theme: Theme, show_legend: bool) void {
    const ticks = lastTick(report) + 1;
    if (ticks == 0) return;
    const usable_width = satSub(rect.w, 8);
    const cell_w: usize = if (ticks <= usable_width / 4) 4 else if (ticks <= usable_width / 3) 3 else if (ticks <= usable_width / 2) 2 else 1;
    const left = rect.x + 2;
    const grid_x = left + 6;
    const lanes = buildLanes(canvas.allocator, report) catch return;
    defer freeLanes(canvas.allocator, lanes);

    var y = rect.y + 1;
    var t: u32 = 0;
    while (t < ticks and y < rect.y + rect.h - 2) : (t += 1) {
        var label_buf: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{d}", .{t}) catch "";
        const x = grid_x + @as(usize, t) * cell_w;
        canvas.drawText(x, y, label, .{ .fg = if (t == app.cursor) .fg else .fg_dim, .bg = .bg, .bold = t == app.cursor });
    }
    y += 1;

    const arrivals = arrivalLabels(canvas.allocator, report, ticks) catch return;
    defer {
        for (arrivals) |entry| canvas.allocator.free(entry);
        canvas.allocator.free(arrivals);
    }
    t = 0;
    while (t < ticks and y < rect.y + rect.h - 2) : (t += 1) {
        const x = grid_x + @as(usize, t) * cell_w;
        canvas.drawTextClipped(x, y, cell_w, arrivals[t], .{ .fg = .dispatch, .bg = .bg });
    }
    y += 1;

    for (lanes, 0..) |lane, cpu_index| {
        if (y >= rect.y + rect.h - 3) break;
        var cpu_buf: [16]u8 = undefined;
        const cpu_label = std.fmt.bufPrint(&cpu_buf, "cpu{d}", .{cpu_index}) catch "cpu";
        canvas.drawText(left, y, cpu_label, .{ .fg = .fg_dim, .bg = .bg });
        t = 0;
        while (t < ticks) : (t += 1) {
            const cell_x = grid_x + @as(usize, t) * cell_w;
            const selected_id = if (selectedTask(report, app.selected_task_index)) |task| task.id else null;
            drawLaneCell(canvas, cell_x, y, cell_w, lane[@intCast(t)], selected_id, t == app.cursor, report, theme);
        }
        y += 1;
    }

    y += 1;
    renderScrubBar(canvas, .{ .x = left, .y = y, .w = satSub(rect.w, 4), .h = 2 }, report, app.cursor, theme);
    if (show_legend and y + 2 < rect.y + rect.h) renderLegend(canvas, .{ .x = left, .y = y + 2, .w = satSub(rect.w, 4), .h = 1 }, report, theme);
}

fn drawLaneCell(canvas: *Canvas, x: usize, y: usize, cell_w: usize, cell_value: ?[]const u8, selected_id: ?[]const u8, is_cursor: bool, report: *const Report, _: Theme) void {
    var style: Style = .{ .fg = .fg, .bg = .bg_alt, .bold = false };
    var label: []const u8 = "·";
    if (cell_value) |task_id| {
        if (std.mem.eql(u8, task_id, "·")) {
            style = .{ .fg = .fg_faint, .bg = .bg, .bold = false };
            label = "·";
        } else {
            style = .{ .fg = .fg_inv, .bg = colorForTask(report, task_id), .bold = true };
            label = task_id;
            if (selected_id) |selected| {
                if (!std.mem.eql(u8, selected, task_id)) style = .{ .fg = .fg_dim, .bg = .bg_alt, .bold = false };
            }
        }
    }
    if (is_cursor) style = .{ .fg = .fg_inv, .bg = .bg_inv, .bold = true };
    canvas.fillRect(.{ .x = x, .y = y, .w = cell_w, .h = 1 }, style);
    canvas.drawTextClipped(x, y, cell_w, label, style);
}

fn renderScrubBar(canvas: *Canvas, rect: Rect, report: *const Report, cursor: u32, _: Theme) void {
    var buf: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "tick {d:0>2} / {d}", .{ cursor, lastTick(report) }) catch "tick";
    canvas.drawText(rect.x, rect.y, label, .{ .fg = .fg_dim, .bg = .bg });
    const start_x = rect.x + 16;
    const span = satSub(rect.w, 20);
    const ticks = lastTick(report) + 1;
    if (ticks == 0 or span == 0) return;
    var i: usize = 0;
    while (i < span) : (i += 1) {
        const tick = (@as(u32, @intCast(i)) * ticks) / @as(u32, @intCast(span));
        canvas.set(start_x + i, rect.y, '█', .{ .fg = if (tick <= cursor) .dispatch else .fg_faint, .bg = .bg, .bold = false });
    }
    if (rect.w > 12) canvas.drawText(rect.x + rect.w - 12, rect.y, "◀ ▶  SPC", .{ .fg = .fg_dim, .bg = .bg });
}

fn renderLegend(canvas: *Canvas, rect: Rect, report: *const Report, _: Theme) void {
    var x = rect.x;
    for (report.tasks) |task| {
        if (x + 10 >= rect.x + rect.w) break;
        const style = Style{ .fg = .fg_inv, .bg = colorForTask(report, task.id), .bold = true };
        canvas.fillRect(.{ .x = x, .y = rect.y, .w = 3, .h = 1 }, style);
        canvas.drawTextClipped(x, rect.y, 3, task.id, style);
        x += 4;
        var buf: [48]u8 = undefined;
        const suffix = if (task.deadline_tick) |deadline_tick|
            std.fmt.bufPrint(&buf, "{s} w={d} ⏱{d}", .{ task.id, task.weight, deadline_tick }) catch task.id
        else if (task.group_id) |group_id|
            std.fmt.bufPrint(&buf, "{s} [{s}]", .{ task.id, group_id }) catch task.id
        else
            std.fmt.bufPrint(&buf, "{s} w={d}", .{ task.id, task.weight }) catch task.id;
        canvas.drawTextClipped(x, rect.y, satSub(rect.x + rect.w, x), suffix, .{ .fg = .fg_dim, .bg = .bg });
        x += suffix.len + 2;
    }
    const tail = "✗ preempt · ✓ complete · ▼ arrival · · idle";
    if (tail.len + 2 < rect.w) canvas.drawText(rect.x + rect.w - tail.len, rect.y, tail, .{ .fg = .fg_dim, .bg = .bg });
}

fn renderAggregateCompact(canvas: *Canvas, rect: Rect, report: *const Report, cursor: u32) void {
    var event_count: usize = 0;
    for (report.trace) |event| {
        if (event.tick == cursor) event_count += 1;
    }
    const start_y = rect.y + @min(satSub(rect.h, 3), @as(usize, 2 + event_count));
    const rows = [_][]const u8{
        fmtStatic(canvas.allocator, "avg wait {d:.2}", .{report.aggregate.average_waiting_time}),
        fmtStatic(canvas.allocator, "avg resp {d:.2}", .{report.aggregate.average_response_time}),
        fmtStatic(canvas.allocator, "throughput {d:.2}", .{report.aggregate.throughput}),
    };
    defer for (rows) |row| canvas.allocator.free(row);
    for (rows, 0..) |row, idx| {
        const y = start_y + idx;
        if (y >= rect.y + rect.h) break;
        canvas.drawTextClipped(rect.x, y, rect.w, row, .{ .fg = .fg_dim, .bg = .bg });
    }
}

fn renderCompactTickPane(canvas: *Canvas, rect: Rect, report: *const Report, cursor: u32) void {
    var head_buf: [32]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "tick t={d}", .{cursor}) catch "tick";
    canvas.drawText(rect.x, rect.y, head, .{ .fg = .fg_dim, .bg = .bg });

    var y = rect.y + 1;
    const max_event_rows: usize = if (rect.h > 5) 2 else 1;
    var shown_events: usize = 0;
    for (report.trace) |ev| {
        if (ev.tick != cursor) continue;
        if (shown_events >= max_event_rows or y >= rect.y + rect.h) break;
        if (y >= rect.y + rect.h) break;
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "{s} {s}", .{ eventGlyph(ev.kind), ev.task_id orelse "—" }) catch ev.task_id orelse "—";
        canvas.drawTextClipped(rect.x, y, rect.w, line, .{ .fg = .fg, .bg = .bg });
        y += 1;
        shown_events += 1;
    }

    if (y < rect.y + rect.h) {
        const rows = [_][]const u8{
            fmtStatic(canvas.allocator, "avg wait {d:.1}", .{report.aggregate.average_waiting_time}),
            fmtStatic(canvas.allocator, "throughput {d:.1}", .{report.aggregate.throughput}),
        };
        defer for (rows) |row| canvas.allocator.free(row);
        for (rows) |row| {
            if (y >= rect.y + rect.h) break;
            canvas.drawTextClipped(rect.x, y, rect.w, row, .{ .fg = .fg_dim, .bg = .bg });
            y += 1;
        }
    }
}

fn renderTaskTable(canvas: *Canvas, rect: Rect, report: *const Report, app: AppView, _: Theme, dense: bool) void {
    if (dense) {
        const headers = [_][]const u8{ "task", "arr", "burst", "end", "wait", "resp" };
        const widths = [_]usize{ 6, 4, 5, 4, 4, 4 };
        var x = rect.x;
        for (headers, widths) |header, width| {
            canvas.drawTextClipped(x, rect.y, width, header, .{ .fg = .fg_dim, .bg = .bg, .bold = true });
            x += width + 1;
        }
        canvas.drawHLine(rect.x, rect.y + 1, rect.w, '─', .{ .fg = .rule, .bg = .bg });

        const rows = rect.h - 2;
        const start = selectionStart(report.tasks.len, rows, app.selected_task_index);
        var row: usize = 0;
        while (row < rows and start + row < report.tasks.len) : (row += 1) {
            const task = report.tasks[start + row];
            const selected = app.selected_task_index != null and start + row == app.selected_task_index.?;
            const style = if (selected) Style{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else Style{ .fg = .fg, .bg = .bg, .bold = false };
            canvas.fillRect(.{ .x = rect.x, .y = rect.y + 2 + row, .w = rect.w, .h = 1 }, style);
            drawTaskRowDense(canvas, rect.x, rect.y + 2 + row, widths, task, selected, style);
        }
        return;
    }

    const headers = [_][]const u8{ "task", "arr", "burst", "w", "group", "dL", "disp", "end", "wait", "resp", "turn" };
    const widths = [_]usize{ 6, 4, 5, 5, 8, 4, 4, 4, 4, 4, 4 };
    var x = rect.x;
    for (headers, widths) |header, width| {
        canvas.drawTextClipped(x, rect.y, width, header, .{ .fg = .fg_dim, .bg = .bg, .bold = true });
        x += width + 1;
    }
    canvas.drawHLine(rect.x, rect.y + 1, rect.w, '─', .{ .fg = .rule, .bg = .bg });

    const rows = rect.h - 2;
    const start = selectionStart(report.tasks.len, rows, app.selected_task_index);
    var row: usize = 0;
    while (row < rows and start + row < report.tasks.len) : (row += 1) {
        const task = report.tasks[start + row];
        const selected = app.selected_task_index != null and start + row == app.selected_task_index.?;
        const style = if (selected) Style{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else Style{ .fg = .fg, .bg = .bg, .bold = false };
        canvas.fillRect(.{ .x = rect.x, .y = rect.y + 2 + row, .w = rect.w, .h = 1 }, style);
        drawTaskRow(canvas, rect.x, rect.y + 2 + row, widths, task, selected, style);
    }
}

fn drawTaskRow(canvas: *Canvas, x0: usize, y: usize, widths: [11]usize, task: TaskMetrics, selected: bool, style: Style) void {
    var x = x0;
    var id_buf: [16]u8 = undefined;
    const id_text = if (selected)
        std.fmt.bufPrint(&id_buf, "▶ {s}", .{task.id}) catch task.id
    else
        std.fmt.bufPrint(&id_buf, "  {s}", .{task.id}) catch task.id;
    canvas.drawTextClipped(x, y, widths[0], id_text, style);
    x += widths[0] + 1;
    drawValue(canvas, x, y, widths[1], task.arrival_tick, style);
    x += widths[1] + 1;
    drawValue(canvas, x, y, widths[2], task.burst_ticks, style);
    x += widths[2] + 1;
    drawValue(canvas, x, y, widths[3], task.weight, style);
    x += widths[3] + 1;
    canvas.drawTextClipped(x, y, widths[4], task.group_id orelse "·", style);
    x += widths[4] + 1;
    if (task.deadline_tick) |deadline_tick| drawValue(canvas, x, y, widths[5], deadline_tick, style) else canvas.drawTextClipped(x, y, widths[5], "·", style);
    x += widths[5] + 1;
    drawValue(canvas, x, y, widths[6], task.first_dispatch_tick, style);
    x += widths[6] + 1;
    drawValue(canvas, x, y, widths[7], task.completion_time, style);
    x += widths[7] + 1;
    drawValue(canvas, x, y, widths[8], task.waiting_time, style);
    x += widths[8] + 1;
    drawValue(canvas, x, y, widths[9], task.response_time, style);
    x += widths[9] + 1;
    drawValue(canvas, x, y, widths[10], task.turnaround_time, style);
}

fn drawTaskRowDense(canvas: *Canvas, x0: usize, y: usize, widths: [6]usize, task: TaskMetrics, selected: bool, style: Style) void {
    var x = x0;
    var id_buf: [16]u8 = undefined;
    const id_text = if (selected)
        std.fmt.bufPrint(&id_buf, "▶ {s}", .{task.id}) catch task.id
    else
        std.fmt.bufPrint(&id_buf, "  {s}", .{task.id}) catch task.id;
    canvas.drawTextClipped(x, y, widths[0], id_text, style);
    x += widths[0] + 1;
    drawValue(canvas, x, y, widths[1], task.arrival_tick, style);
    x += widths[1] + 1;
    drawValue(canvas, x, y, widths[2], task.burst_ticks, style);
    x += widths[2] + 1;
    drawValue(canvas, x, y, widths[3], task.completion_time, style);
    x += widths[3] + 1;
    drawValue(canvas, x, y, widths[4], task.waiting_time, style);
    x += widths[4] + 1;
    drawValue(canvas, x, y, widths[5], task.response_time, style);
}

fn drawValue(canvas: *Canvas, x: usize, y: usize, width: usize, value: anytype, style: Style) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "";
    canvas.drawTextClipped(x, y, width, text, style);
}

fn renderEventLog(canvas: *Canvas, rect: Rect, report: *const Report, cursor: u32, _: Theme) void {
    const rows = rect.h;
    const target_index = nearestEventIndex(report, cursor);
    const start = selectionStart(report.trace.len, rows, target_index);
    var row: usize = 0;
    while (row < rows and start + row < report.trace.len) : (row += 1) {
        const event = report.trace[start + row];
        const active = event.tick == cursor;
        const style = if (active) Style{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else Style{ .fg = .fg, .bg = .bg, .bold = false };
        canvas.fillRect(.{ .x = rect.x, .y = rect.y + row, .w = rect.w, .h = 1 }, style);
        drawEventRow(canvas, rect.x, rect.y + row, rect.w, event, style);
    }
}

fn drawEventRow(canvas: *Canvas, x: usize, y: usize, width: usize, event: TraceEntry, style: Style) void {
    var tick_buf: [16]u8 = undefined;
    const tick_text = std.fmt.bufPrint(&tick_buf, "t={d:0>2}", .{event.tick}) catch "";
    canvas.drawTextClipped(x, y, 5, tick_text, .{ .fg = if (style.bg == .bg_inv) .fg_inv else .fg_dim, .bg = style.bg, .bold = style.bold });
    canvas.drawText(x + 6, y, eventGlyph(event.kind), .{ .fg = if (style.bg == .bg_inv) .fg_inv else eventColor(event.kind), .bg = style.bg, .bold = true });
    canvas.drawTextClipped(x + 8, y, 9, @tagName(event.kind), .{ .fg = if (style.bg == .bg_inv) .fg_inv else .fg_dim, .bg = style.bg });
    canvas.drawTextClipped(x + 18, y, satSub(width, 28), event.task_id orelse "—", .{ .fg = if (style.bg == .bg_inv) .fg_inv else .fg, .bg = style.bg, .bold = true });
    var cpu_buf: [32]u8 = undefined;
    const cpu_text = if (event.core_id) |core_id|
        if (event.domain_id) |domain_id|
            std.fmt.bufPrint(&cpu_buf, "cpu{d} d{s}", .{ core_id, domain_id }) catch "cpu"
        else
            std.fmt.bufPrint(&cpu_buf, "cpu{d}", .{core_id}) catch "cpu"
    else
        "cpu·";
    if (cpu_text.len + 1 < width) canvas.drawTextClipped(x + width - cpu_text.len - 1, y, cpu_text.len, cpu_text, .{ .fg = if (style.bg == .bg_inv) .fg_inv else .fg_dim, .bg = style.bg });
}

fn renderTickDetail(canvas: *Canvas, rect: Rect, report: *const Report, cursor: u32, _: Theme) void {
    const evs = eventsAt(canvas.allocator, report, cursor) catch return;
    defer canvas.allocator.free(evs);
    if (evs.len == 0) {
        var buf: [48]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "no events at t={d}", .{cursor}) catch "no events";
        canvas.drawText(rect.x, rect.y, text, .{ .fg = .fg_dim, .bg = .bg });
        return;
    }
    var head_buf: [48]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "tick t={d} · {d} event{s}", .{ cursor, evs.len, if (evs.len == 1) "" else "s" }) catch "tick";
    canvas.drawText(rect.x, rect.y, head, .{ .fg = .fg_dim, .bg = .bg });
    for (evs, 0..) |ev, idx| {
        if (rect.y + idx + 1 >= rect.y + rect.h) break;
        canvas.drawText(rect.x, rect.y + idx + 1, eventGlyph(ev.kind), .{ .fg = eventColor(ev.kind), .bg = .bg, .bold = true });
        canvas.drawTextClipped(rect.x + 2, rect.y + idx + 1, 10, @tagName(ev.kind), .{ .fg = .fg_dim, .bg = .bg });
        canvas.drawTextClipped(rect.x + 14, rect.y + idx + 1, satSub(rect.w, 18), ev.task_id orelse "—", .{ .fg = .fg, .bg = .bg, .bold = true });
    }
}

fn renderAggregate(canvas: *Canvas, rect: Rect, report: *const Report, _: Theme) void {
    const rows = [_]struct { label: []const u8, value: f64, int_value: ?u32 = null }{
        .{ .label = "avg wait", .value = report.aggregate.average_waiting_time },
        .{ .label = "avg response", .value = report.aggregate.average_response_time },
        .{ .label = "throughput", .value = report.aggregate.throughput },
        .{ .label = "max wait", .value = 0, .int_value = report.aggregate.max_waiting_time },
        .{ .label = "max response", .value = 0, .int_value = report.aggregate.max_response_time },
        .{ .label = "wait spread", .value = 0, .int_value = report.aggregate.waiting_time_spread },
        .{ .label = "resp spread", .value = 0, .int_value = report.aggregate.response_time_spread },
    };
    for (rows, 0..) |row, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        canvas.drawText(rect.x, rect.y + idx, row.label, .{ .fg = .fg_dim, .bg = .bg });
        var buf: [64]u8 = undefined;
        const text = if (row.int_value) |value|
            std.fmt.bufPrint(&buf, "{d}", .{value}) catch ""
        else if (std.mem.eql(u8, row.label, "throughput"))
            std.fmt.bufPrint(&buf, "{d:.3} ({d}/{d})", .{ row.value, report.aggregate.throughput_numerator, report.aggregate.throughput_denominator }) catch ""
        else
            std.fmt.bufPrint(&buf, "{d:.3}", .{row.value}) catch "";
        canvas.drawTextClipped(rect.x + rect.w / 2, rect.y + idx, rect.w / 2 - 1, text, .{ .fg = .fg, .bg = .bg, .bold = true });
    }
}

fn renderTaskDetail(canvas: *Canvas, rect: Rect, report: *const Report, task: TaskMetrics, cursor: u32, _: Theme) void {
    const metrics = [_]struct { label: []const u8, value: []const u8 }{};
    _ = metrics;
    const kv = [_]struct { label: []const u8, text: []const u8 }{
        .{ .label = "arrival", .text = fmtStatic(canvas.allocator, "{d}", .{task.arrival_tick}) },
        .{ .label = "burst", .text = fmtStatic(canvas.allocator, "{d}", .{task.burst_ticks}) },
        .{ .label = "weight", .text = fmtStatic(canvas.allocator, "{d}", .{task.weight}) },
        .{ .label = "deadline", .text = if (task.deadline_tick) |deadline_tick| fmtStatic(canvas.allocator, "{d}", .{deadline_tick}) else fmtStatic(canvas.allocator, "—", .{}) },
        .{ .label = "first dispatch", .text = fmtStatic(canvas.allocator, "{d}", .{task.first_dispatch_tick}) },
        .{ .label = "completion", .text = fmtStatic(canvas.allocator, "{d}", .{task.completion_time}) },
        .{ .label = "turnaround", .text = fmtStatic(canvas.allocator, "{d}", .{task.turnaround_time}) },
        .{ .label = "phases", .text = fmtStatic(canvas.allocator, "{d}", .{task.phase_count}) },
        .{ .label = "waiting", .text = fmtStatic(canvas.allocator, "{d}", .{task.waiting_time}) },
        .{ .label = "blocked", .text = fmtStatic(canvas.allocator, "{d}", .{task.blocked_time}) },
        .{ .label = "response", .text = fmtStatic(canvas.allocator, "{d}", .{task.response_time}) },
        .{ .label = "executed", .text = fmtStatic(canvas.allocator, "{d}", .{task.total_executed}) },
    };
    defer for (kv) |entry| canvas.allocator.free(entry.text);

    for (kv, 0..) |entry, idx| {
        const col = idx % 4;
        const row = idx / 4;
        const x = rect.x + col * (rect.w / 4);
        const y = rect.y + row;
        canvas.drawText(x, y, entry.label, .{ .fg = .fg_dim, .bg = .bg });
        canvas.drawTextClipped(x + 14, y, satSub(rect.w / 4, 14), entry.text, .{ .fg = .fg, .bg = .bg, .bold = true });
    }

    canvas.drawText(rect.x, rect.y + 4, "state per tick", .{ .fg = .fg_dim, .bg = .bg, .bold = true });
    const ticks = lastTick(report) + 1;
    var i: u32 = 0;
    while (i < ticks and rect.x + @as(usize, i) * 2 < rect.x + rect.w - 1) : (i += 1) {
        const state = taskStateAt(report, task.id, i);
        const style = Style{ .fg = .fg_inv, .bg = stateColor(state), .bold = true };
        const x = rect.x + @as(usize, i) * 2;
        canvas.fillRect(.{ .x = x, .y = rect.y + 6, .w = 2, .h = 1 }, style);
        canvas.drawTextClipped(x, rect.y + 6, 2, stateGlyph(state), style);
        if (i == cursor) canvas.drawTextClipped(x, rect.y + 7, 2, "▔▔", .{ .fg = .fg, .bg = .bg });
    }

    canvas.drawText(rect.x, rect.y + 9, "▶ dispatch  █ running  ✗ preempt  ■ blocked  ✓ complete  ░ waiting", .{ .fg = .fg_dim, .bg = .bg });
}

fn renderTaskEventLog(canvas: *Canvas, rect: Rect, report: *const Report, task_id: []const u8, cursor: u32, _: Theme) void {
    var filtered: std.ArrayList(TraceEntry) = .empty;
    defer filtered.deinit(canvas.allocator);
    for (report.trace) |event| {
        if (event.task_id) |id| {
            if (std.mem.eql(u8, id, task_id)) filtered.append(canvas.allocator, event) catch return;
        }
    }
    const rows = rect.h;
    const target_index = nearestEventIndexSlice(filtered.items, cursor);
    const start = selectionStart(filtered.items.len, rows, target_index);
    for (0..rows) |row| {
        if (start + row >= filtered.items.len) break;
        const event = filtered.items[start + row];
        const active = event.tick == cursor;
        drawEventRow(canvas, rect.x, rect.y + row, rect.w, event, if (active) .{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else .{ .fg = .fg, .bg = .bg, .bold = false });
    }
}

fn renderWaitingProfile(canvas: *Canvas, rect: Rect, task: TaskMetrics, _: Theme) void {
    const entries = [_][]const u8{
        fmtStatic(canvas.allocator, "arrived        t={d}", .{task.arrival_tick}),
        fmtStatic(canvas.allocator, "first run      t={d} (+{d})", .{ task.first_dispatch_tick, task.response_time }),
        fmtStatic(canvas.allocator, "completed      t={d}", .{task.completion_time}),
        fmtStatic(canvas.allocator, "cpu time       {d} / {d}", .{ task.total_executed, task.burst_ticks }),
        fmtStatic(canvas.allocator, "time in queue  {d}", .{task.waiting_time}),
        if (task.deadline_tick) |deadline_tick| fmtStatic(canvas.allocator, "deadline slack {d}", .{@as(i32, @intCast(deadline_tick)) - @as(i32, @intCast(task.completion_time))}) else fmtStatic(canvas.allocator, "deadline slack —", .{}),
    };
    defer for (entries) |text| canvas.allocator.free(text);
    for (entries, 0..) |text, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        canvas.drawTextClipped(rect.x, rect.y + idx, rect.w, text, .{ .fg = .fg, .bg = .bg });
    }
}

fn renderTaskCoreUsage(canvas: *Canvas, rect: Rect, report: *const Report, task: TaskMetrics, _: Theme) void {
    var y = rect.y;
    for (0..report.core_count) |cpu_index| {
        if (y >= rect.y + rect.h) break;
        const count = executionCountOnCpu(report, task.id, @intCast(cpu_index));
        var cpu_buf: [16]u8 = undefined;
        const cpu_label = std.fmt.bufPrint(&cpu_buf, "cpu{d}", .{cpu_index}) catch "cpu";
        canvas.drawText(rect.x, y, cpu_label, .{ .fg = .fg_dim, .bg = .bg });
        const bar_x = rect.x + 6;
        const bar_w = satSub(rect.w, 12);
        canvas.drawHLine(bar_x, y, bar_w, '░', .{ .fg = .fg_faint, .bg = .bg });
        const filled = if (task.total_executed == 0) 0 else (count * bar_w) / task.total_executed;
        canvas.drawHLine(bar_x, y, filled, '█', .{ .fg = .dispatch, .bg = .bg });
        var count_buf: [8]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch "";
        canvas.drawTextClipped(rect.x + rect.w - 3, y, 3, count_text, .{ .fg = .fg, .bg = .bg });
        y += 2;
    }
}

fn renderCompletionOrder(canvas: *Canvas, rect: Rect, report: *const Report, selected_id: []const u8, _: Theme) void {
    var x = rect.x;
    var y = rect.y;
    for (report.completion_order, 0..) |task_id, idx| {
        const style = if (std.mem.eql(u8, task_id, selected_id)) Style{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else Style{ .fg = .fg, .bg = .bg, .bold = true };
        const w = task_id.len + 2;
        if (x + w + 2 >= rect.x + rect.w) {
            x = rect.x;
            y += 2;
            if (y >= rect.y + rect.h) break;
        }
        canvas.fillRect(.{ .x = x, .y = y, .w = w, .h = 1 }, style);
        canvas.drawText(x + 1, y, task_id, style);
        x += w;
        if (idx + 1 < report.completion_order.len and x + 2 < rect.x + rect.w) {
            canvas.drawText(x, y, "→", .{ .fg = .fg_dim, .bg = .bg });
            x += 2;
        }
    }
}

fn renderDiffTable(canvas: *Canvas, rect: Rect, report_a: *const Report, report_b: *const Report, _: Theme) void {
    canvas.drawText(rect.x, rect.y, "task   wait      response   turnaround   Δwait", .{ .fg = .fg_dim, .bg = .bg, .bold = true });
    canvas.drawHLine(rect.x, rect.y + 1, rect.w, '─', .{ .fg = .rule, .bg = .bg });
    for (report_a.tasks, 0..) |task_a, idx| {
        if (rect.y + idx + 2 >= rect.y + rect.h) break;
        const task_b = findTask(report_b, task_a.id) orelse task_a;
        const delta_wait = @as(i32, @intCast(task_b.waiting_time)) - @as(i32, @intCast(task_a.waiting_time));
        var buf: [128]u8 = undefined;
        const row = std.fmt.bufPrint(&buf, "{s} {d}->{d}  {d}->{d}  {d}->{d}  {d}", .{ task_a.id, task_a.waiting_time, task_b.waiting_time, task_a.response_time, task_b.response_time, task_a.turnaround_time, task_b.turnaround_time, delta_wait }) catch "";
        canvas.drawTextClipped(rect.x, rect.y + idx + 2, rect.w, row, .{ .fg = .fg, .bg = .bg });
    }
}

fn renderDiffAggregate(canvas: *Canvas, rect: Rect, report_a: *const Report, report_b: *const Report, _: Theme) void {
    const lines = [_][]const u8{
        fmtStatic(canvas.allocator, "average waiting   {d:.3} → {d:.3}", .{ report_a.aggregate.average_waiting_time, report_b.aggregate.average_waiting_time }),
        fmtStatic(canvas.allocator, "average response  {d:.3} → {d:.3}", .{ report_a.aggregate.average_response_time, report_b.aggregate.average_response_time }),
        fmtStatic(canvas.allocator, "throughput        {d:.3} → {d:.3}", .{ report_a.aggregate.throughput, report_b.aggregate.throughput }),
        fmtStatic(canvas.allocator, "max waiting       {d} → {d}", .{ report_a.aggregate.max_waiting_time, report_b.aggregate.max_waiting_time }),
        fmtStatic(canvas.allocator, "max response      {d} → {d}", .{ report_a.aggregate.max_response_time, report_b.aggregate.max_response_time }),
        fmtStatic(canvas.allocator, "wait spread       {d} → {d}", .{ report_a.aggregate.waiting_time_spread, report_b.aggregate.waiting_time_spread }),
        fmtStatic(canvas.allocator, "resp spread       {d} → {d}", .{ report_a.aggregate.response_time_spread, report_b.aggregate.response_time_spread }),
        fmtStatic(canvas.allocator, "rr spreads wait more evenly; fcfs finishes sooner in this teaching diff.", .{}),
    };
    defer for (lines) |line| canvas.allocator.free(line);
    for (lines, 0..) |line, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        canvas.drawTextClipped(rect.x, rect.y + idx, rect.w, line, .{ .fg = if (idx == lines.len - 1) .fg_dim else .fg, .bg = .bg });
    }
}

fn renderPickerList(canvas: *Canvas, rect: Rect, app: AppView, _: Theme) void {
    canvas.drawText(rect.x, rect.y, "scenario                 policy          cores  tasks  ticks", .{ .fg = .fg_dim, .bg = .bg, .bold = true });
    canvas.drawHLine(rect.x, rect.y + 1, rect.w, '─', .{ .fg = .rule, .bg = .bg });
    const rows = rect.h - 2;
    const start = selectionStart(app.picker_entries.len, rows, app.picker_index);
    for (0..rows) |row| {
        if (start + row >= app.picker_entries.len) break;
        const entry = app.picker_entries[start + row];
        const selected = start + row == app.picker_index;
        const style = if (selected) Style{ .fg = .fg_inv, .bg = .bg_inv, .bold = true } else Style{ .fg = .fg, .bg = .bg, .bold = false };
        canvas.fillRect(.{ .x = rect.x, .y = rect.y + 2 + row, .w = rect.w, .h = 1 }, style);
        var buf: [160]u8 = undefined;
        const row_text = std.fmt.bufPrint(&buf, "{s}{s:<22} {s:<14} {d:>3}    {d:>3}    {d:>3}", .{
            if (entry.m21_start_here_rank != null) "★ " else "  ",
            entry.scenario_label,
            entry.policy_label,
            entry.cores,
            entry.tasks,
            entry.ticks,
        }) catch "";
        canvas.drawTextClipped(rect.x, rect.y + 2 + row, rect.w, if (selected) row_text else row_text, style);
        if (selected and rect.y + 3 + row < rect.y + rect.h) {
            var desc_buf: [256]u8 = undefined;
            const desc = if (entry.m21_start_here_rank) |rank|
                std.fmt.bufPrint(&desc_buf, "  START HERE {d} · {s} · {s} · {s} · {s}", .{
                    rank,
                    entry.theme_label orelse "simulator path",
                    entry.policy_label,
                    entry.description,
                    entry.explanation_doc orelse "docs/m17-scenario-corpus.md",
                }) catch entry.description
            else
                std.fmt.bufPrint(&desc_buf, "  {s} · {s}", .{ entry.pack, entry.description }) catch entry.description;
            canvas.drawTextClipped(rect.x + 2, rect.y + 3 + row, rect.w - 2, desc, .{ .fg = if (selected) .fg_inv else .fg_dim, .bg = style.bg });
        }
    }
}

fn renderPickerSources(canvas: *Canvas, rect: Rect, _: Theme) void {
    const shortlist = scheduler.scenario_packs.listM21TeachingEntries();
    var line_buf: [3][96]u8 = undefined;
    const lines = [_][]const u8{
        "start here path:",
        std.fmt.bufPrint(&line_buf[0], "1. {s} · {s}", .{ shortlist[0].key, teachingPolicyLabel(shortlist[0].recommended_policy.?) }) catch "",
        std.fmt.bufPrint(&line_buf[1], "2. {s} · {s}", .{ shortlist[1].key, teachingPolicyLabel(shortlist[1].recommended_policy.?) }) catch "",
        std.fmt.bufPrint(&line_buf[2], "3. {s} · {s}", .{ shortlist[2].key, teachingPolicyLabel(shortlist[2].recommended_policy.?) }) catch "",
        "",
        "picker shortcuts:",
        "m/c         observability side lane",
        "",
        "load any exported report:",
        "zig build sim -- --scenario-file <path> --format json | zig-out/bin/zig-scheduler --stdin --snapshot",
    };
    for (lines, 0..) |line, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        const style = if (idx < 4)
            Style{ .fg = .dispatch, .bg = .bg, .bold = idx == 0 }
        else if (idx >= 7)
            Style{ .fg = .running, .bg = .bg, .bold = false }
        else
            Style{ .fg = .fg, .bg = .bg, .bold = false };
        canvas.drawTextClipped(rect.x, rect.y + idx, rect.w, line, style);
    }
}

fn renderPickerStartHere(canvas: *Canvas, rect: Rect, _: Theme) void {
    const shortlist = scheduler.scenario_packs.listM21TeachingEntries();
    for (shortlist, 0..) |entry, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        canvas.drawText(rect.x, rect.y + idx, scheduler.scenario_packs.curriculumThemeLabel(entry.theme.?), .{ .fg = switch (idx) {
            0 => .running,
            1 => .dispatch,
            else => .preempt,
        }, .bg = .bg, .bold = true });
        canvas.drawTextClipped(rect.x + 14, rect.y + idx, satSub(rect.w, 14), entry.explanation_doc.?, .{ .fg = .fg_dim, .bg = .bg });
    }
    if (rect.y + shortlist.len < rect.y + rect.h) {
        canvas.drawText(rect.x, rect.y + shortlist.len, "side lane", .{ .fg = .fg_dim, .bg = .bg, .bold = true });
        canvas.drawTextClipped(rect.x + 14, rect.y + shortlist.len, satSub(rect.w, 14), "m/c keep M19/M20 reachable but secondary", .{ .fg = .fg_dim, .bg = .bg });
    }
}

fn renderPickerRecent(canvas: *Canvas, rect: Rect, history: []const []const u8, _: Theme) void {
    if (history.len == 0) {
        canvas.drawText(rect.x, rect.y, "· no recent scenarios in this session", .{ .fg = .fg_dim, .bg = .bg });
        return;
    }
    for (history, 0..) |entry, idx| {
        if (rect.y + idx >= rect.y + rect.h) break;
        canvas.drawTextClipped(rect.x, rect.y + idx, rect.w, entry, .{ .fg = .fg_dim, .bg = .bg });
    }
}

fn fmtStatic(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "";
}

fn lastTick(report: *const Report) u32 {
    var max_tick: u32 = 0;
    for (report.trace) |event| max_tick = @max(max_tick, event.tick);
    return max_tick;
}

fn buildLanes(allocator: std.mem.Allocator, report: *const Report) ![][]?[]const u8 {
    const ticks = lastTick(report) + 1;
    const lanes = try allocator.alloc([]?[]const u8, report.core_count);
    errdefer allocator.free(lanes);
    for (0..report.core_count) |cpu_index| {
        lanes[cpu_index] = try allocator.alloc(?[]const u8, ticks);
        for (lanes[cpu_index]) |*entry| entry.* = "·";
    }
    for (report.trace) |event| {
        const core_id = event.core_id orelse continue;
        if (core_id >= report.core_count) continue;
        switch (event.kind) {
            .tick => lanes[core_id][event.tick] = event.task_id,
            .idle => lanes[core_id][event.tick] = "·",
            else => {},
        }
    }
    return lanes;
}

fn freeLanes(allocator: std.mem.Allocator, lanes: [][]?[]const u8) void {
    for (lanes) |lane| allocator.free(lane);
    allocator.free(lanes);
}

fn arrivalLabels(allocator: std.mem.Allocator, report: *const Report, ticks: u32) ![]const []const u8 {
    const labels = try allocator.alloc([]const u8, ticks);
    errdefer allocator.free(labels);
    var builders = try allocator.alloc(std.ArrayList(u8), ticks);
    defer allocator.free(builders);
    for (builders) |*list| list.* = .empty;
    defer for (builders) |*list| list.deinit(allocator);

    for (report.trace) |event| {
        if (event.kind != .arrival) continue;
        const index: usize = @intCast(event.tick);
        if (builders[index].items.len == 0) {
            try builders[index].appendSlice(allocator, "▼");
        }
        if (event.task_id) |task_id| try builders[index].appendSlice(allocator, task_id);
    }
    for (builders, 0..) |*list, idx| labels[idx] = if (list.items.len == 0) try allocator.dupe(u8, "") else try allocator.dupe(u8, list.items);
    return labels;
}

fn selectedTask(report: *const Report, index: ?usize) ?TaskMetrics {
    if (index) |task_index| {
        if (task_index < report.tasks.len) return report.tasks[task_index];
    }
    return null;
}

fn selectionStart(total: usize, visible: usize, selected: ?usize) usize {
    if (total <= visible) return 0;
    const index = selected orelse 0;
    if (index <= visible / 2) return 0;
    if (index + visible / 2 >= total) return total - visible;
    return index - visible / 2;
}

fn nearestEventIndex(report: *const Report, cursor: u32) usize {
    return nearestEventIndexSlice(report.trace, cursor);
}

fn nearestEventIndexSlice(events: []const TraceEntry, cursor: u32) usize {
    var idx: usize = 0;
    while (idx < events.len) : (idx += 1) {
        if (events[idx].tick >= cursor) return idx;
    }
    return if (events.len == 0) 0 else events.len - 1;
}

fn eventsAt(allocator: std.mem.Allocator, report: *const Report, cursor: u32) ![]TraceEntry {
    var list: std.ArrayList(TraceEntry) = .empty;
    defer list.deinit(allocator);
    for (report.trace) |event| if (event.tick == cursor) try list.append(allocator, event);
    return try list.toOwnedSlice(allocator);
}

fn eventGlyph(kind: anytype) []const u8 {
    return switch (kind) {
        .arrival => "→",
        .dispatch => "▶",
        .tick => "·",
        .preempt => "✗",
        .block => "■",
        .wakeup => "↺",
        .complete => "✓",
        .idle => "○",
    };
}

fn eventColor(kind: anytype) Slot {
    return switch (kind) {
        .arrival, .dispatch => .dispatch,
        .tick => .fg_dim,
        .preempt => .preempt,
        .block => .block,
        .wakeup, .complete => .complete,
        .idle => .fg_faint,
    };
}

fn policySubtitle(report: *const Report) []const u8 {
    return switch (report.policy.kind) {
        .fcfs => "fcfs replay shows first-come, first-served dispatch on the current workload",
        .round_robin => "round robin replay surfaces fixed-quantum preemption across the same deterministic trace",
        .cfs_like => "cfs-inspired replay highlights weighted fairness, blocked time, and group behavior",
        .deadline => "deadline-inspired replay highlights slack, urgency ordering, and missed-deadline pressure",
    };
}

fn colorForTask(report: *const Report, task_id: []const u8) Slot {
    for (report.tasks) |task| {
        if (std.mem.eql(u8, task.id, task_id)) {
            return switch (task.input_order % 6) {
                0 => .running,
                1 => .dispatch,
                2 => .preempt,
                3 => .complete,
                4 => .deadline,
                else => .block,
            };
        }
    }
    return .running;
}

const TaskState = enum { nil, wait, disp, run, prmt, blk, wake, done, end };

fn taskStateAt(report: *const Report, task_id: []const u8, tick: u32) TaskState {
    const task = findTask(report, task_id) orelse return .nil;
    if (tick < task.arrival_tick) return .nil;
    if (tick > task.completion_time) return .end;
    var state: TaskState = .wait;
    for (report.trace) |event| {
        if (event.tick != tick) continue;
        if (event.task_id) |id| {
            if (!std.mem.eql(u8, id, task_id)) continue;
            state = switch (event.kind) {
                .dispatch => .disp,
                .tick => .run,
                .preempt => .prmt,
                .block => .blk,
                .wakeup => .wake,
                .complete => .done,
                else => state,
            };
        }
    }
    return state;
}

fn stateGlyph(state: TaskState) []const u8 {
    return switch (state) {
        .nil, .end => " ",
        .wait => "░",
        .disp => "▶",
        .run => "█",
        .prmt => "✗",
        .blk => "■",
        .wake => "↺",
        .done => "✓",
    };
}

fn stateColor(state: TaskState) Slot {
    return switch (state) {
        .nil, .end => .bg,
        .wait => .fg_faint,
        .disp => .dispatch,
        .run => .running,
        .prmt => .preempt,
        .blk => .block,
        .wake => .complete,
        .done => .complete,
    };
}

fn executionCountOnCpu(report: *const Report, task_id: []const u8, cpu_index: u32) usize {
    var count: usize = 0;
    for (report.trace) |event| {
        if (event.kind != .tick) continue;
        if (event.core_id != cpu_index) continue;
        if (event.task_id) |id| {
            if (std.mem.eql(u8, id, task_id)) count += 1;
        }
    }
    return count;
}

fn findTask(report: *const Report, task_id: []const u8) ?TaskMetrics {
    for (report.tasks) |task| if (std.mem.eql(u8, task.id, task_id)) return task;
    return null;
}

test "too-small renderer handles tiny heights without underflow" {
    const app: AppView = .{
        .domain_mode = .simulator,
        .theme = .dark,
        .view = .picker,
        .focus = .gantt,
        .cursor = 0,
        .selected_task_index = null,
        .picker_index = 0,
        .playing = false,
        .report = null,
        .compare_report = null,
        .observability_summary = null,
        .observability_comparison = null,
        .picker_entries = &.{},
        .history = &.{},
    };

    const allocator = std.testing.allocator;
    inline for ([_]usize{ 0, 1, 2, 3, 4, 5 }) |height| {
        const frame = try renderSnapshotFrame(allocator, 20, height, app);
        defer allocator.free(frame);
    }
}

fn styleEq(a: Style, b: Style) bool {
    return a.fg == b.fg and a.bg == b.bg and a.bold == b.bold;
}

fn applyStyle(writer: anytype, theme: Theme, style: Style) !void {
    const fg = theme.color(style.fg);
    const bg = theme.color(style.bg);
    const weight: u8 = if (style.bold) 1 else 22;
    try writer.print("\x1b[{d};38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ weight, fg.r, fg.g, fg.b, bg.r, bg.g, bg.b });
}

fn writeCodepoint(writer: anytype, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    try writer.writeAll(buf[0..len]);
}
