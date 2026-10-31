//! Modal overlays: command palette, appearance, keyboard help, and toast.

const std = @import("std");
const xsui = @import("xsui");
const state_mod = @import("state.zig");
const commands = @import("commands.zig");
const common = @import("common.zig");
const icons = @import("icons.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Theme = xsui.Theme;
const State = state_mod.State;
const style = common.style;
const measure = common.measure;
const label = common.label;
const labelRight = common.labelRight;
const labelWrapped = common.labelWrapped;
const borderLine = common.borderLine;

pub fn draw(state: *const State, canvas: *Canvas, th: Theme, width: f32, height: f32) !void {
    if (state.dialog == .none) return;
    try canvas.fill(.{ .x = 0, .y = 0, .w = width, .h = height }, .{ .r = th.bg.r, .g = th.bg.g, .b = th.bg.b, .a = 210 });
    switch (state.dialog) {
        .palette => try palette(state, canvas, th, width),
        .appearance => try appearance(state, canvas, th, width),
        .help => try help(state, canvas, th, width),
        .none => {},
    }
}

fn modalFrame(canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 6, th.panel, th.line_strong, 1);
}

fn closeButton(canvas: *Canvas, th: Theme, x: f32, y: f32) !void {
    try canvas.rounded(.{ .x = x, .y = y, .w = 26, .h = 26 }, 4, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, th.line, 1);
    try icons.draw(canvas, .close, .{ .x = x + 4, .y = y + 4, .w = 13, .h = 13 }, th.dim);
}

fn palette(state: *const State, canvas: *Canvas, th: Theme, width: f32) !void {
    const rect = Rect{ .x = (width - 560) * 0.5, .y = 126, .w = 560, .h = 495.75 };
    try modalFrame(canvas, th, rect);
    try canvas.fill(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = 45.5 }, th.field);
    try borderLine(canvas, rect.x + 1, rect.y + 46.5, rect.w - 2, th.line);
    try label(canvas, rect.x + 16, rect.y + 13, "›", style(common.text_13, th.live, .bold));
    const query = state.paletteQuery();
    const prompt = if (query.len > 0) query else "Jump to screen, switch theme, open journal…";
    try label(canvas, rect.x + 34, rect.y + 13, prompt, style(common.text_12, if (query.len > 0) th.text else th.faint, .regular));
    try canvas.rounded(.{ .x = rect.x + rect.w - 40, .y = rect.y + 13, .w = 27, .h = 20 }, 3, th.raised, th.line, 1);
    try label(canvas, rect.x + rect.w - 33, rect.y + 15.5, "esc", style(common.text_95, th.muted, .regular));

    canvas.pushClip(.{ .x = rect.x + 1, .y = rect.y + 47.5, .w = rect.w - 2, .h = 414 });
    var shown: usize = 0;
    var row_y = rect.y + 47.5;
    for (commands.all) |command| {
        if (!commands.matches(command, query)) continue;
        const selected = shown == state.palette_index;
        if (selected) try canvas.fill(.{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 35 }, th.tint_live);
        var group = style(common.text_10, th.faint, .regular);
        group.tracking = 0.8;
        try label(canvas, rect.x + 16, row_y + 10, command.group, group);
        try label(canvas, rect.x + 74, row_y + 10, command.label, style(common.text_11, if (selected) th.text else th.muted, .regular));
        if (command.key.len > 0) {
            try canvas.rounded(.{ .x = rect.x + rect.w - 34, .y = row_y + 8, .w = 18, .h = 18 }, 3, th.raised, th.line, 1);
            try label(canvas, rect.x + rect.w - 29, row_y + 10, command.key, style(common.text_10, th.muted, .regular));
        }
        canvas.hit(700 + @as(u32, @intCast(shown)), .{ .x = rect.x + 1, .y = row_y, .w = rect.w - 2, .h = 35 });
        row_y += 35;
        shown += 1;
    }
    canvas.popClip();
    try canvas.fill(.{ .x = rect.x + 1, .y = rect.y + rect.h - 34, .w = rect.w - 2, .h = 33 }, th.field);
    try borderLine(canvas, rect.x + 1, rect.y + rect.h - 34, rect.w - 2, th.line);
    try label(canvas, rect.x + 16, rect.y + rect.h - 26, "↑ ↓", style(common.text_10, th.dim, .regular));
    try label(canvas, rect.x + 52, rect.y + rect.h - 26, "move", style(common.text_10, th.dim, .regular));
    try label(canvas, rect.x + 90, rect.y + rect.h - 26, "enter", style(common.text_10, th.dim, .regular));
    try label(canvas, rect.x + 126, rect.y + rect.h - 26, "run", style(common.text_10, th.dim, .regular));
}

fn appearance(state: *const State, canvas: *Canvas, th: Theme, width: f32) !void {
    const rect = Rect{ .x = (width - 620) * 0.5, .y = 54, .w = 620, .h = 356 };
    try modalFrame(canvas, th, rect);
    try label(canvas, rect.x + 16, rect.y + 16, "APPEARANCE", style(common.text_12, th.text, .bold));
    try closeButton(canvas, th, rect.x + rect.w - 42, rect.y + 12);
    try labelWrapped(canvas, .{ .x = rect.x + 16, .y = rect.y + 53, .w = rect.w - 32, .h = 36 }, style(common.text_11, th.muted, .regular), "Graphite and Paper are the console defaults. Catppuccin flavours remap the same semantic tokens — state is still carried by labels, not colour alone.");
    try label(canvas, rect.x + 16, rect.y + 92, "CORE", style(common.text_95, th.faint, .regular));
    try themeOption(canvas, th, state, .{ .x = rect.x + 16, .y = rect.y + 114, .w = 289.5, .h = 48.25 }, 0, "Graphite");
    try themeOption(canvas, th, state, .{ .x = rect.x + 312.5, .y = rect.y + 114, .w = 289.5, .h = 48.25 }, 1, "Paper");
    try label(canvas, rect.x + 16, rect.y + 172, "CATPPUCCIN", style(common.text_95, th.faint, .regular));
    try themeOption(canvas, th, state, .{ .x = rect.x + 16, .y = rect.y + 197.59, .w = 289.5, .h = 48.25 }, 2, "Latte");
    try themeOption(canvas, th, state, .{ .x = rect.x + 312.5, .y = rect.y + 197.59, .w = 289.5, .h = 48.25 }, 3, "Frappe");
    try themeOption(canvas, th, state, .{ .x = rect.x + 16, .y = rect.y + 252.84, .w = 289.5, .h = 48.25 }, 4, "Macchiato");
    try themeOption(canvas, th, state, .{ .x = rect.x + 312.5, .y = rect.y + 252.84, .w = 289.5, .h = 48.25 }, 5, "Mocha");
    try canvas.fill(.{ .x = rect.x + 1, .y = rect.y + rect.h - 35, .w = rect.w - 2, .h = 34 }, th.field);
    try borderLine(canvas, rect.x + 1, rect.y + rect.h - 35, rect.w - 2, th.line);
    try label(canvas, rect.x + 16, rect.y + rect.h - 26, "esc", style(common.text_10, th.dim, .regular));
    try label(canvas, rect.x + 42, rect.y + rect.h - 26, "close · selection applies immediately", style(common.text_10, th.dim, .regular));
}

fn themeOption(canvas: *Canvas, th: Theme, state: *const State, rect: Rect, index: usize, name: []const u8) !void {
    const preset = xsui.themes.presets[index];
    const active = state.theme_index == index;
    try canvas.rounded(rect, 5, if (active) th.raised2 else th.panel, if (active) th.live else th.line, 1);
    var sx = rect.x + 10;
    inline for ([_]usize{ 0, 1, 2 }) |si| {
        const swatch = switch (si) {
            0 => preset.theme.bg,
            1 => preset.theme.panel,
            else => preset.theme.live,
        };
        try canvas.rounded(.{ .x = sx, .y = rect.y + 8, .w = 12, .h = 31 }, 1, swatch, null, 0);
        sx += 6;
    }
    try label(canvas, rect.x + 66, rect.y + 8, name, style(common.text_12, th.text, .regular));
    try label(canvas, rect.x + 66, rect.y + 25, if (std.mem.eql(u8, preset.kind, "dark")) "dark" else "light", style(common.text_95, th.dim, .regular));
    if (active) try labelRight(canvas, rect.x + rect.w - 12, rect.y + 16, "✓", style(common.text_11, th.live, .regular));
    canvas.hit(720 + @as(u32, @intCast(index)), rect);
}

fn help(state: *const State, canvas: *Canvas, th: Theme, width: f32) !void {
    _ = state;
    const rect = Rect{ .x = (width - 640) * 0.5, .y = 72, .w = 640, .h = 428.25 };
    try modalFrame(canvas, th, rect);
    try label(canvas, rect.x + 16, rect.y + 16, "Keyboard", style(common.text_12, th.text, .bold));
    try closeButton(canvas, th, rect.x + rect.w - 42, rect.y + 12);
    try borderLine(canvas, rect.x + 1, rect.y + 48, rect.w - 2, th.line);
    const rows = [_][2][]const u8{
        .{ "1 – 5", "Switch screen: Overview, Timeline, Advisor, Events, Capture" },
        .{ "/", "Filter events by task" },
        .{ "space", "Play or pause the timeline playhead" },
        .{ "f", "Fit the timeline to the full excerpt" },
        .{ "+ −", "Zoom the timeline around the playhead" },
        .{ "w", "Open the appearance menu" },
        .{ "⌘K / Ctrl K", "Open the command palette" },
        .{ "?", "This keyboard sheet" },
        .{ "esc", "Close a dialog, clear focus, or dismiss a toast" },
        .{ "drag", "Brush across timeline lanes to zoom" },
        .{ "click", "Inspect a slice or select a ledger row" },
        .{ "skip", "Tab to the skip link, Enter jumps to the screen" },
    };
    var y = rect.y + 64;
    for (rows) |row| {
        try label(canvas, rect.x + 16, y, row[0], style(common.text_11, th.text, .regular));
        try label(canvas, rect.x + 142, y, row[1], style(common.text_11, th.muted, .regular));
        try borderLine(canvas, rect.x + 1, y + 24, rect.w - 2, th.line);
        y += 27;
    }
    try label(canvas, rect.x + 16, rect.y + rect.h - 25, "esc", style(common.text_10, th.dim, .regular));
    try label(canvas, rect.x + 42, rect.y + rect.h - 25, "close", style(common.text_10, th.dim, .regular));
}

pub fn drawToast(state: *const State, canvas: *Canvas, th: Theme, width: f32, height: f32) !void {
    if (state.toast) |toast| {
        const tw = 24 + measure(canvas, toast, style(common.text_11, th.text, .regular));
        const rect = Rect{ .x = width - tw - 16, .y = height - 48 - 30, .w = tw, .h = 30 };
        try canvas.rounded(rect, 4, th.raised2, th.line_strong, 1);
        try label(canvas, rect.x + 12, rect.y + 6.5, toast, style(common.text_11, th.text, .regular));
    }
}
