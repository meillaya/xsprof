//! The operator-console shell and screens. This file currently owns the shell
//! and Overview; the remaining screens are added beside it as they are built.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const icons = @import("icons.zig");
const common = @import("common.zig");
const overview = @import("overview.zig");
const timeline = @import("timeline.zig");
const advisor = @import("advisor.zig");
const events = @import("events.zig");
const capture = @import("capture.zig");
const home = @import("home.zig");
const audit_view = @import("audit_view.zig");
const settings_view = @import("settings_view.zig");
const overlays = @import("overlays.zig");
const ui_spec = @import("ui_spec.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Color = xsui.Color;
const Theme = xsui.Theme;
const TextStyle = xsui.TextStyle;
const FontWeight = xsui.FontWeight;
const Model = model_mod.Model;
const State = state_mod.State;
const text_10 = common.text_10;
const text_95 = common.text_95;
const text_105 = common.text_105;
const text_11 = common.text_11;
const text_12 = common.text_12;
const text_13 = common.text_13;
const style = common.style;
const measure = common.measure;
const label = common.label;
const labelRight = common.labelRight;
const borderLine = common.borderLine;

pub const shell_top: f32 = ui_spec.shell_top;
pub const shell_bottom: f32 = ui_spec.shell_bottom;
pub const rail_width: f32 = ui_spec.rail_width;

pub fn view(model: *const Model, state: *const State, canvas: *Canvas) !void {
    const th = canvas.frame.theme;
    const width: f32 = @floatFromInt(canvas.frame.width);
    const height: f32 = @floatFromInt(canvas.frame.height);
    const bottom_rail = width <= 1024;
    const active_rail: f32 = if (bottom_rail) 0 else rail_width;
    const active_keybar: f32 = if (bottom_rail) 0 else shell_bottom;
    try canvas.fill(.{ .x = 0, .y = 0, .w = width, .h = height }, th.bg);
    try drawTopbar(model, state, canvas, th, width);
    if (!bottom_rail) try drawRail(model, state, canvas, th, height);
    canvas.pushClip(.{ .x = active_rail, .y = shell_top, .w = width - active_rail, .h = height - shell_top - active_keybar });
    // One semantic group per route: native AX exposes the screen as a group
    // (wire role `tabpanel`) and every control painted inside it nests under it.
    canvas.pushGroup(.{
        .id = 1,
        .rect = .{ .x = active_rail, .y = shell_top, .w = width - active_rail, .h = height - shell_top - active_keybar },
        .role = .group,
        .label = state_mod.screenName(state.screen),
    });
    switch (state.screen) {
        .overview => try overview.draw(model, state, canvas, th, active_rail, shell_top, width),
        .timeline => try timeline.draw(model, state, canvas, th, active_rail, shell_top, width),
        .advisor => try advisor.draw(model, state, canvas, th, active_rail, shell_top, width),
        .events => try events.draw(model, state, canvas, th, active_rail, shell_top, width),
        .capture => try capture.draw(model, state, canvas, th, active_rail, shell_top, width),
        .home => try home.draw(model, state, canvas, th, active_rail, shell_top, width),
        .audit => try audit_view.draw(model, state, canvas, th, active_rail, shell_top, width),
        .settings => try settings_view.draw(model, state, canvas, th, active_rail, shell_top, width),
    }
    canvas.popGroup();
    canvas.popClip();
    if (bottom_rail) {
        try drawBottomRail(model, state, canvas, th, width, height);
    } else {
        try drawKeybar(model, canvas, th, width, height);
    }
    try overlays.draw(state, canvas, th, width, height);
    try overlays.drawToast(state, canvas, th, width, height);
    if (state.focus_visible) {
        if (state.focus_id) |id| {
            if (canvas.hitRect(id)) |hit| {
                try canvas.stroke(.{ .x = hit.x - 2, .y = hit.y - 2, .w = hit.w + 4, .h = hit.h + 4 }, 4, th.focus, 2);
            }
        }
    }
}

fn drawTopbar(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, width: f32) !void {
    try canvas.fill(.{ .x = 0, .y = 0, .w = width, .h = shell_top }, th.panel);
    try borderLine(canvas, 0, shell_top - 1, width, th.line_strong);

    try icons.brandMark(canvas, .{ .x = 12, .y = 13.5, .w = 24, .h = 24 });
    const wordmark = style(text_13, th.text, .bold);
    var wo = wordmark;
    wo.size = 14;
    wo.line_height = 1;
    wo.tracking = -0.14;
    try label(canvas, 45, 18.5, "xsprof", wo);
    var sub = style(text_105, th.dim, .regular);
    sub.tracking = 0.21;
    const sub_text = "read-only scheduler & memory profiler";
    const show_sub = width > 1140;
    if (show_sub) try label(canvas, 103.56, 17.63, sub_text, sub);
    const brand_end: f32 = if (show_sub) 103.56 + measure(canvas, sub_text, sub) else 94.56;

    var bar = style(text_12, th.text, .regular);
    bar.tracking = 0.0;
    const compact_top = width <= 780;
    const phone = width <= 420;
    const bar_x = brand_end + (if (width <= 1140) @as(f32, 10) else 16);
    try canvas.fill(.{ .x = bar_x, .y = 14.5, .w = 1, .h = 22 }, th.line);
    try label(canvas, bar_x + 16, 14.5, "/", style(text_12, th.faint, .regular));
    try label(canvas, bar_x + 16 + 7 + measure(canvas, "/", style(text_12, th.faint, .regular)), 14.5, state_mod.screenName(state.screen), bar);
    const bar_end = bar_x + 16 + 7 + measure(canvas, "/", style(text_12, th.faint, .regular)) + measure(canvas, state_mod.screenName(state.screen), bar);
    const meta_x = bar_end + 24;

    // Right-aligned cluster geometry comes first: safety/loss/source and the
    // palette/theme/help buttons are measured before the session identity, so
    // the identity has a hard right boundary and can never draw beneath a chip.
    const right: f32 = width - 16;
    const help_rect = Rect{ .x = right - 28, .y = 11.5, .w = 28, .h = 28 };
    const theme_rect = Rect{ .x = help_rect.x - 8 - 31, .y = 11.5, .w = 31, .h = 28 };
    const palette_key_style = style(text_95, th.muted, .regular);
    const palette_key_w = measure(canvas, "⌘K", palette_key_style) + 8 + 2;
    const palette_w: f32 = if (compact_top) 30 else 16 + 14 + 6 + palette_key_w;
    const palette_rect = Rect{ .x = theme_rect.x - 8 - palette_w, .y = 11.5, .w = palette_w, .h = 28 };
    var x_right = palette_rect.x - 8;

    const safety = "READ-ONLY · HOST_MUTATION=FALSE";
    var chip_font = style(text_105, th.muted, .regular);
    chip_font.tracking = 0.84;
    chip_font.line_height = 1.2;
    const safety_w: f32 = if (compact_top) 25 else 8 + 11 + 5 + measure(canvas, safety, chip_font) + 8;
    const safety_rect = Rect{ .x = x_right - safety_w, .y = 15.2, .w = safety_w, .h = 20.59 };
    x_right = safety_rect.x - 8;

    var loss_buf: [32]u8 = undefined;
    const loss_text = if (phone)
        std.fmt.bufPrint(&loss_buf, "■ {d}", .{model.summary.lost}) catch "■"
    else
        std.fmt.bufPrint(&loss_buf, "■ LOSS {d}", .{model.summary.lost}) catch "■ LOSS";
    var loss_font = style(text_105, th.refuse, .regular);
    loss_font.tracking = 0.84;
    loss_font.line_height = 1.2;
    const loss_w = 8 + measure(canvas, loss_text, loss_font) + 8;
    const loss_rect = Rect{ .x = x_right - loss_w, .y = 15.2, .w = loss_w, .h = 20.59 };
    x_right = loss_rect.x - 8;

    var source_font = style(text_105, th.live, .regular);
    source_font.tracking = 0.84;
    source_font.line_height = 1.2;
    var source_rect: ?Rect = null;
    if (!phone) {
        const source_w = 8 + measure(canvas, model.meta.source, source_font) + 8;
        source_rect = Rect{ .x = x_right - source_w, .y = 15.2, .w = source_w, .h = 20.59 };
        x_right = source_rect.?.x - 8;
    }

    // The identity only occupies what is left: 16px of breathing room before
    // the leftmost chip, and a deterministic trailing ellipsis when it overflows.
    const identity_gap: f32 = 16;
    if (width > 780) try drawSessionIdentity(canvas, model, th, meta_x, x_right - identity_gap);

    try iconButton(canvas, help_rect, th);
    try label(canvas, help_rect.x + 10.5, 19.5, "?", style(text_11, th.muted, .regular));
    try iconButton(canvas, theme_rect, th);
    try icons.draw(canvas, .sun, .{ .x = theme_rect.x + 8, .y = theme_rect.y + 6.5, .w = 15, .h = 15 }, th.muted);
    try iconButton(canvas, palette_rect, th);
    try icons.draw(canvas, .menu, .{ .x = palette_rect.x + 8, .y = palette_rect.y + 7, .w = 14, .h = 14 }, th.muted);
    if (!compact_top) {
        const pcap = Rect{ .x = palette_rect.x + 8 + 14 + 6, .y = palette_rect.y + 5.875, .w = palette_key_w, .h = 16.25 };
        try canvas.rounded(pcap, 3, th.raised, th.line, 1);
        try canvas.fill(.{ .x = pcap.x + 1, .y = pcap.y + pcap.h - 2, .w = pcap.w - 2, .h = 1 }, th.line_strong);
        _ = try canvas.textIn(.{ .x = pcap.x + 5, .y = pcap.y + 1, .w = pcap.w - 8, .h = pcap.h - 2 }, palette_key_style, "⌘K");
    }
    _ = canvas.button(200, palette_rect, "Command palette");
    _ = canvas.button(201, theme_rect, "Appearance");
    _ = canvas.button(202, help_rect, "Keyboard help");

    try canvas.rounded(safety_rect, 3, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line_strong, 1);
    try icons.draw(canvas, .lock, .{ .x = safety_rect.x + (if (compact_top) @as(f32, 6) else 8), .y = 19, .w = 11, .h = 11 }, th.pass);
    if (!compact_top) try label(canvas, safety_rect.x + 8 + 11 + 5, 18.2, safety, chip_font);

    try canvas.rounded(loss_rect, 3, th.tint_refuse, th.chip_loss_border, 1);
    try label(canvas, loss_rect.x + 8, 18.2, loss_text, loss_font);

    if (source_rect) |rect| {
        try canvas.rounded(rect, 3, th.tint_live, th.chip_source_border, 1);
        try label(canvas, rect.x + 8, 18.2, model.meta.source, source_font);
    }
}

const identity_sep = "·";
const identity_ellipsis = "…";

const Fit = struct {
    /// Widest UTF-8 prefix that fits the width budget.
    prefix: []const u8,
    /// The whole text fits; nothing is elided.
    complete: bool,
    /// The caller draws `identity_ellipsis` after `prefix`.
    elided: bool,
};

/// Deterministic, codepoint-safe width clamp for the topbar session identity.
/// `complete` means the whole text fits its budget; otherwise `prefix` is the
/// widest prefix whose width plus the measured trailing ellipsis still fits.
/// When not even the ellipsis fits, the result has an empty prefix and both
/// flags false: the caller draws nothing and no budget underflows. Pure layout
/// measurement (canvas text atlas only): no clock, random, or host state.
fn truncateToWidth(canvas: *Canvas, text: []const u8, base: TextStyle, max_w: f32) Fit {
    if (text.len == 0) return .{ .prefix = text, .complete = true, .elided = false };
    if (measure(canvas, text, base) <= max_w) return .{ .prefix = text, .complete = true, .elided = false };
    const ellipsis_w = measure(canvas, identity_ellipsis, base);
    if (max_w < ellipsis_w) return .{ .prefix = text[0..0], .complete = false, .elided = false };
    var end: usize = 0;
    var best: usize = 0;
    while (end < text.len) {
        const codepoint_len: usize = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        end = @min(end + codepoint_len, text.len);
        if (measure(canvas, text[0..end], base) + ellipsis_w > max_w) break;
        best = end;
    }
    return .{ .prefix = text[0..best], .complete = false, .elided = true };
}

/// Draws `host · kernel · arch` starting at `start_x` and never past
/// `hard_right`. Empty fields are omitted; the first field that does not fit is
/// cut on a codepoint boundary and followed by a measured `…` in the same text
/// style. Separators keep the faint token color and are only drawn between
/// fields that are actually rendered.
fn drawSessionIdentity(canvas: *Canvas, model: *const Model, th: Theme, start_x: f32, hard_right: f32) !void {
    const parts = [_]struct { text: []const u8, color: Color }{
        .{ .text = model.meta.host, .color = th.muted },
        .{ .text = model.meta.kernel, .color = th.muted },
        .{ .text = model.meta.arch, .color = th.muted },
    };
    var meta = style(text_11, th.dim, .regular);
    const sep_style = style(text_11, th.faint, .regular);
    const sep_cost: f32 = 7 + measure(canvas, identity_sep, sep_style) + 7;
    const ellipsis_w = measure(canvas, identity_ellipsis, meta);
    const y: f32 = 17.25;
    var mx = start_x;
    var first = true;
    for (parts) |part| {
        if (part.text.len == 0) continue;
        const gap: f32 = if (first) 0 else sep_cost;
        if (mx + gap >= hard_right) break;
        const fit = truncateToWidth(canvas, part.text, meta, hard_right - mx - gap);
        if (fit.complete) {
            if (!first) {
                try label(canvas, mx + 7, y, identity_sep, sep_style);
                mx += gap;
            }
            meta.color = part.color;
            try label(canvas, mx, y, part.text, meta);
            mx += measure(canvas, part.text, meta);
            first = false;
            continue;
        }
        if (fit.elided) {
            if (!first) {
                try label(canvas, mx + 7, y, identity_sep, sep_style);
                mx += gap;
            }
            meta.color = part.color;
            try label(canvas, mx, y, fit.prefix, meta);
            if (fit.prefix.len != 0) mx += measure(canvas, fit.prefix, meta);
            try label(canvas, mx, y, identity_ellipsis, meta);
            return;
        }
        // Not even the ellipsis fits after the separator: elide directly after
        // the last rendered field instead of leaving a dangling "·".
        if (ellipsis_w <= hard_right - mx) try label(canvas, mx, y, identity_ellipsis, meta);
        return;
    }
}

fn iconButton(canvas: *Canvas, rect: Rect, th: Theme) !void {
    try canvas.rounded(rect, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line, 1);
}

fn drawRail(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, height: f32) !void {
    try canvas.fill(.{ .x = 0, .y = shell_top, .w = rail_width, .h = height - shell_top - shell_bottom }, th.panel);
    try borderLine(canvas, rail_width - 1, shell_top, 1, th.line);
    const screens = [_]struct { screen: state_mod.Screen, icon: icons.Kind, key: []const u8 }{
        .{ .screen = .home, .icon = .home, .key = "0" },
        .{ .screen = .overview, .icon = .overview, .key = "1" },
        .{ .screen = .timeline, .icon = .timeline, .key = "2" },
        .{ .screen = .advisor, .icon = .advisor, .key = "3" },
        .{ .screen = .events, .icon = .events, .key = "4" },
        .{ .screen = .capture, .icon = .capture, .key = "5" },
        .{ .screen = .audit, .icon = .audit, .key = "6" },
        .{ .screen = .settings, .icon = .settings, .key = "7" },
    };
    var y: f32 = shell_top;
    for (screens, 0..) |item, index| {
        const active = state.screen == item.screen;
        const rect = Rect{ .x = 0, .y = y, .w = rail_width - 1, .h = 63.75 };
        if (active) try canvas.fill(rect, th.raised);
        if (active) try canvas.fill(.{ .x = 0, .y = y, .w = 2, .h = rect.h }, th.live);
        try labelRight(canvas, rail_width - 9, y + 9, item.key, style(text_95, th.faint, .regular));
        try icons.draw(canvas, item.icon, .{ .x = 15, .y = y + 13, .w = 17, .h = 17 }, if (active) th.live else th.dim);
        try label(canvas, 15, y + 36, state_mod.screenName(item.screen), style(text_105, if (active) th.text else th.muted, .regular));
        _ = canvas.tabItem(@as(u32, @backingInt(item.screen)) + 100, rect, state_mod.screenName(item.screen), active);
        y += 63.75;
        _ = index;
    }
    try borderLine(canvas, 0, height - shell_bottom - 1, rail_width - 1, th.line);
    try canvas.circle(15, height - shell_bottom - 22, 2.5, th.live);
    var foot = style(text_95, th.dim, .regular);
    foot.tracking = 0.95;
    var source_buf: [32]u8 = undefined;
    const source_text = std.fmt.bufPrint(&source_buf, "{s}", .{model.meta.source}) catch "REPLAY";
    try label(canvas, 25, height - shell_bottom - 30, source_text, foot);
}

fn drawBottomRail(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, width: f32, height: f32) !void {
    const bar_h: f32 = 57;
    const y = height - bar_h;
    try canvas.fill(.{ .x = 0, .y = y, .w = width, .h = bar_h }, th.panel);
    try borderLine(canvas, 0, y, width, th.line_strong);
    const screens = [_]struct { screen: state_mod.Screen, icon: icons.Kind, label: []const u8 }{
        .{ .screen = .home, .icon = .home, .label = "Home" },
        .{ .screen = .overview, .icon = .overview, .label = "Overview" },
        .{ .screen = .timeline, .icon = .timeline, .label = "Timeline" },
        .{ .screen = .advisor, .icon = .advisor, .label = "Advisor" },
        .{ .screen = .events, .icon = .events, .label = "Events" },
        .{ .screen = .capture, .icon = .capture, .label = "Recorder" },
        .{ .screen = .audit, .icon = .audit, .label = "Audit" },
        .{ .screen = .settings, .icon = .settings, .label = "Settings" },
    };
    const item_w = width / 8;
    for (screens, 0..) |item, index| {
        const active = state.screen == item.screen;
        const x = @as(f32, @floatFromInt(index)) * item_w;
        if (active) try canvas.fill(.{ .x = x, .y = y + 1, .w = 2, .h = 0 }, th.live);
        if (active) try canvas.fill(.{ .x = x, .y = y + 1, .w = item_w, .h = 2 }, th.live);
        const ix = x + item_w * 0.5 - 8.5;
        try icons.draw(canvas, item.icon, .{ .x = ix, .y = y + 11.5, .w = 17, .h = 17 }, if (active) th.live else th.dim);
        var lbl = style(text_105, if (active) th.text else th.muted, .regular);
        lbl.text_align = .center;
        _ = try canvas.textIn(.{ .x = x, .y = y + 31.5, .w = item_w, .h = 16 }, lbl, item.label);
        _ = canvas.tabItem(@as(u32, @backingInt(item.screen)) + 100, .{ .x = x, .y = y, .w = item_w, .h = bar_h }, item.label, active);
    }
    _ = model;
}

fn drawKeybar(model: *const Model, canvas: *Canvas, th: Theme, width: f32, height: f32) !void {
    const y = height - shell_bottom;
    try canvas.fill(.{ .x = 0, .y = y, .w = width, .h = shell_bottom }, th.panel);
    try borderLine(canvas, 0, y, width, th.line);
    const keys = [_][2][]const u8{
        .{ "0–7", "routes" },
        .{ "/", "filter" },
        .{ "space", "playhead" },
        .{ "f", "fit" },
        .{ "+ −", "zoom" },
        .{ "w", "theme" },
        .{ "⌘K", "palette" },
        .{ "?", "help" },
    };
    var x: f32 = 16;
    const key_style = style(text_95, th.muted, .regular);
    const label_style = style(text_10, th.muted, .regular);
    for (keys) |item| {
        const kw = measure(canvas, item[0], key_style);
        const cap_w = kw + 8 + 2;
        const cap = Rect{ .x = x, .y = y + 7.375, .w = cap_w, .h = 16.25 };
        try canvas.rounded(cap, 3, th.raised, th.line, 1);
        try canvas.fill(.{ .x = cap.x + 1, .y = cap.y + cap.h - 2, .w = cap.w - 2, .h = 1 }, th.line_strong);
        _ = try canvas.textIn(.{ .x = cap.x + 5, .y = cap.y + 0.75, .w = cap.w - 8, .h = cap.h - 1.5 }, key_style, item[0]);
        try label(canvas, x + cap_w + 4, y + 7.5, item[1], label_style);
        x += cap_w + 4 + measure(canvas, item[1], label_style) + 13;
    }
    var status = style(text_10, th.dim, .regular);
    status.tracking = 0.0;
    var switch_buf: [48]u8 = undefined;
    var lost_buf: [32]u8 = undefined;
    const switch_text = std.fmt.bufPrint(&switch_buf, "{d} switches", .{model.summary.switches}) catch "";
    const lost_text = std.fmt.bufPrint(&lost_buf, "{d} lost", .{model.summary.lost}) catch "";
    var source_lower: [32]u8 = undefined;
    const source_len = @min(model.meta.source.len, source_lower.len);
    for (model.meta.source[0..source_len], 0..) |c, index| source_lower[index] = std.ascii.toLower(c);
    const parts = [_][]const u8{ "▚", source_lower[0..source_len], "·", model.meta.fixture, "·", switch_text, "·", lost_text, "·", "host_mutation=false" };
    var total: f32 = 0;
    var i: usize = 0;
    while (i < parts.len) : (i += 1) {
        total += measure(canvas, parts[i], status);
        if (i + 1 < parts.len) total += 6;
    }
    var sx = width - 16 - total;
    i = 0;
    while (i < parts.len) : (i += 1) {
        const color = if (i == 1) th.muted else if (i == 7) th.refuse else th.dim;
        try label(canvas, sx, y + 7.5, parts[i], style(text_10, color, .regular));
        sx += measure(canvas, parts[i], status) + 6;
    }
}

test "renders all screens, themes, and reference viewports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    const screens = [_]state_mod.Screen{ .home, .overview, .timeline, .advisor, .events, .capture, .audit, .settings };
    const viewports = [_]struct { w: u32, h: u32 }{ .{ .w = 1440, .h = 900 }, .{ .w = 1280, .h = 720 }, .{ .w = 320, .h = 200 } };
    for (viewports) |viewport| {
        var frame: xsui.frame.Frame = undefined;
        try frame.init(std.testing.allocator, viewport.w, viewport.h, xsui.themes.paper);
        defer frame.deinit();
        for (screens) |screen| {
            var state = state_mod.State{ .screen = screen, .theme_index = 1 };
            frame.list.clear();
            var canvas = xsui.Canvas.init(&frame);
            defer canvas.deinit();
            try view(&model, &state, &canvas);
            try std.testing.expect(frame.list.items.items.len > 0);
        }
    }
}

test "switching palette changes the recorded frame colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, xsui.themes.presets[0].theme);
    defer frame.deinit();
    var state = state_mod.State{ .theme_index = 0 };
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    try view(&model, &state, &canvas);
    const dark_color = frame.list.items.items[0].color;
    frame.list.clear();
    state.theme_index = 5;
    frame.theme = xsui.themes.presets[5].theme;
    canvas.resetHits();
    try view(&model, &state, &canvas);
    try std.testing.expect(frame.list.items.items[0].color != dark_color);
}

test "topbar identity truncation is deterministic and UTF-8 safe" {
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1280, 720, xsui.themes.paper);
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    const st = style(text_11, frame.theme.dim, .regular);
    const ellipsis_w = measure(&canvas, identity_ellipsis, st);
    try std.testing.expect(ellipsis_w > 0);
    try std.testing.expectEqual(@as(usize, 3), identity_ellipsis.len);

    // Exact fit keeps the whole string with no ellipsis.
    const full = "localhost.localdomain";
    const full_w = measure(&canvas, full, st);
    const exact = truncateToWidth(&canvas, full, st, full_w);
    try std.testing.expect(exact.complete);
    try std.testing.expect(!exact.elided);
    try std.testing.expectEqualStrings(full, exact.prefix);

    // One unit too long drops codepoints, stays inside the budget, and would
    // not fit if one more codepoint were kept.
    const limit = full_w - 1;
    const tight = truncateToWidth(&canvas, full, st, limit);
    try std.testing.expect(!tight.complete);
    try std.testing.expect(tight.elided);
    try std.testing.expect(tight.prefix.len > 0 and tight.prefix.len < full.len);
    try std.testing.expect(measure(&canvas, tight.prefix, st) + ellipsis_w <= limit);
    const next = full[0 .. tight.prefix.len + 1];
    try std.testing.expect(measure(&canvas, next, st) + ellipsis_w > limit);

    // Empty input is complete and never elided.
    const empty = truncateToWidth(&canvas, "", st, 100);
    try std.testing.expect(empty.complete and !empty.elided and empty.prefix.len == 0);

    // Multibyte text: the "·" separator is two bytes and "…" is three, so a
    // byte-wise cut would break UTF-8. Every clamp must be a codepoint boundary.
    const multibyte = "host · kernel · arch";
    var budget: f32 = 40;
    while (budget < 200) : (budget += 7) {
        const fit = truncateToWidth(&canvas, multibyte, st, budget);
        if (fit.complete) {
            try std.testing.expectEqualStrings(multibyte, fit.prefix);
            try std.testing.expect(!fit.elided);
        } else {
            try std.testing.expect(fit.elided);
            try std.testing.expect(std.unicode.utf8ValidateSlice(fit.prefix));
            try std.testing.expect(measure(&canvas, fit.prefix, st) + ellipsis_w <= budget);
        }
    }

    // Tiny limits never underflow: below the ellipsis width nothing is drawn.
    for ([_]f32{ ellipsis_w - 0.5, 0, -10 }) |tiny| {
        const fit = truncateToWidth(&canvas, multibyte, st, tiny);
        try std.testing.expect(!fit.complete and !fit.elided);
        try std.testing.expectEqual(@as(usize, 0), fit.prefix.len);
    }

    // No wall clock or hidden state: repeated calls are identical.
    const again = truncateToWidth(&canvas, full, st, limit);
    try std.testing.expectEqualStrings(tight.prefix, again.prefix);
    try std.testing.expectEqual(tight.elided, again.elided);
    try std.testing.expectEqual(tight.complete, again.complete);
}
