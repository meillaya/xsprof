//! Home: startup surface. Source selection (live/replay/recorder-window/demo),
//! requested time frame, first-run onboarding CTA, capability strip, recorder
//! strip, and bounded recents. All controls dispatch through hits.zig.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const common = @import("common.zig");
const hits = @import("hits.zig");
const source = @import("source.zig");
const recorder = @import("recorder.zig");

const Canvas = xsui.Canvas;
const Rect = xsui.Rect;
const Theme = xsui.Theme;
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
const labelWrapped = common.labelWrapped;
const borderLine = common.borderLine;
const panelHead = common.panelHead;

pub fn draw(model: *const Model, state: *const State, canvas: *Canvas, th: Theme, stage_x: f32, stage_top: f32, width: f32) !void {
    _ = model;
    const compact = width <= 780;
    const pad: f32 = if (compact) 14 else 24;
    const x = stage_x + pad;
    const y = stage_top + (if (compact) @as(f32, 14) else 16) - state.scroll_y;
    const w = width - stage_x - pad * 2;

    var eyebrow = style(text_105, th.dim, .regular);
    eyebrow.tracking = 1.47;
    try label(canvas, x, y, "START HERE  ·  PRODUCT SHELL  ·  READ-ONLY", eyebrow);
    var h1 = style(text_13, th.text, .bold);
    h1.size = if (compact) 18 else 20;
    h1.line_height = 1.1;
    h1.tracking = -0.4;
    try label(canvas, x, y + 18.75, "Home", h1);
    var note = style(text_11, th.muted, .regular);
    note.tracking = 0.21;
    try labelRight(canvas, x + w, y + 24.25, sourceTag(state), note);
    try borderLine(canvas, x, y + 53.75, w, th.line);

    var cy = y + 65.75;
    try drawOnboardingCta(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 54 });
    cy += 66;
    const cards_h: f32 = if (compact) 4 * 88 + 12 else 176;
    try drawSourceCards(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = cards_h }, compact);
    cy += cards_h + 12;
    try drawTimeFrame(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 92 });
    cy += 104;
    try drawRecorderStrip(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 116 });
    cy += 128;
    try drawCapabilities(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 236 });
    cy += 248;
    try drawRecents(state, canvas, th, .{ .x = x, .y = cy, .w = w, .h = 30 + 26 * @as(f32, @floatFromInt(@max(@as(usize, 1), state.settings.recents.len))) });
}

fn sourceTag(state: *const State) []const u8 {
    return if (state.source.kind) |kind| kind.tag() else "NO SOURCE";
}

fn drawOnboardingCta(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    if (state.onboarding.completed_version >= 2) {
        try canvas.rounded(rect, 5, th.panel, th.line, 1);
        try label(canvas, rect.x + 14, rect.y + 10, "ONBOARDING", style(text_95, th.faint, .regular));
        try label(canvas, rect.x + 14, rect.y + 26, "First-run walkthrough complete. Replay it from the palette (Show onboarding).", style(text_11, th.dim, .regular));
        return;
    }
    try canvas.rounded(rect, 5, th.tint_live, th.chip_source_border, 1);
    try label(canvas, rect.x + 14, rect.y + 10, "FIRST RUN", style(text_95, th.live, .regular));
    try label(canvas, rect.x + 14, rect.y + 26, "Four short steps: read-only rules, host capabilities, and how to choose a source.", style(text_11, th.text, .regular));
    const button = Rect{ .x = rect.x + rect.w - 128, .y = rect.y + 14, .w = 114, .h = 27 };
    try canvas.rounded(button, 4, th.raised, th.line_strong, 1);
    try label(canvas, button.x + 11, button.y + 6.5, "start tour", style(text_11, th.text, .regular));
    canvas.hit(hits.onboarding_next, button);
}

fn drawSourceCards(state: *const State, canvas: *Canvas, th: Theme, rect: Rect, compact: bool) !void {
    const kinds = [_]struct { kind: source.Kind, id: u32, glyph: []const u8, detail: []const u8 }{
        .{ .kind = .live, .id = hits.home_live, .glyph = "LIVE", .detail = "in-process read-only capture (Linux, READY gate)" },
        .{ .kind = .replay, .id = hits.home_replay, .glyph = "FILE", .detail = "load a sanitized .ndjson journal from disk" },
        .{ .kind = .recorder_window, .id = hits.home_recorder_window, .glyph = "WINDOW", .detail = "extract the last N minutes from a recorder state dir" },
        .{ .kind = .demo, .id = hits.home_demo, .glyph = "DEMO", .detail = "bundled real capture, replayed read-only" },
    };
    const cols: usize = if (compact) 1 else 2;
    const gap: f32 = 12;
    const cw = (rect.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const ch: f32 = 82;
    for (kinds, 0..) |item, index| {
        const col = index % cols;
        const row = index / cols;
        const card = Rect{
            .x = rect.x + @as(f32, @floatFromInt(col)) * (cw + gap),
            .y = rect.y + @as(f32, @floatFromInt(row)) * (ch + gap),
            .w = cw,
            .h = ch,
        };
        const selected = state.source.kind != null and state.source.kind.? == item.kind;
        try canvas.rounded(card, 5, if (selected) th.raised else th.panel, if (selected) th.live else th.line, 1);
        try label(canvas, card.x + 14, card.y + 10, item.glyph, style(text_95, if (selected) th.live else th.faint, .regular));
        try label(canvas, card.x + 14, card.y + 26, item.kind.label(), style(text_12, if (selected) th.text else th.muted, .regular));
        try labelWrapped(canvas, .{ .x = card.x + 14, .y = card.y + 45, .w = card.w - 28, .h = 32 }, style(text_10, th.dim, .regular), item.detail);
        canvas.hit(item.id, card);
    }
}

fn drawTimeFrame(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "01", "TIME FRAME", "applies to live / recorder windows");
    var cx = rect.x + 14;
    for (source.window_presets, 0..) |preset, index| {
        const active = state.source.window.preset == preset;
        const tw = 22 + measure(canvas, preset.label(), style(text_105, th.muted, .regular));
        const chip = Rect{ .x = cx, .y = rect.y + 45, .w = tw, .h = 26 };
        try canvas.rounded(chip, 3, if (active) th.tint_live else th.panel, if (active) th.live else th.line, 1);
        try label(canvas, chip.x + 9, chip.y + 6.5, preset.label(), style(text_105, if (active) th.live else th.muted, .regular));
        canvas.hit(hits.home_window_base + @as(u32, @intCast(index)), chip);
        cx += tw + 6;
    }
    var note_buf: [96]u8 = undefined;
    const note = std.fmt.bufPrint(&note_buf, "raw retention is bounded; extraction older than the retained window reports retention_loss", .{}) catch "retention";
    try label(canvas, rect.x + 14, rect.y + 74, note, style(text_10, th.faint, .regular));
}

fn drawRecorderStrip(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    const phase = state.recorder.phase;
    const color = switch (phase) {
        .running => th.pass,
        .starting, .stopping => th.skip,
        .refused, .failed => th.refuse,
        else => th.dim,
    };
    try panelHead(canvas, th, rect, "02", "RECORDER", phase.label());
    try label(canvas, rect.x + 14, rect.y + 45, phase.label(), style(text_12, color, .bold));
    var buf: [96]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "{d} events · {d} lost · {d}ms window", .{ state.recorder.events, state.recorder.lost, state.recorder.window_ms }) catch "";
    try label(canvas, rect.x + 120, rect.y + 45, detail, style(text_11, th.muted, .regular));
    if (state.recorder.reason_len > 0) {
        try label(canvas, rect.x + 14, rect.y + 68, state.recorder.reasonSlice(), style(text_10, th.refuse, .regular));
    }
    try label(canvas, rect.x + 14, rect.y + 90, "Open the Recorder screen (5) to start, stop, restart, extract or export.", style(text_10, th.dim, .regular));
    if (phase.isActive()) {
        const stop = Rect{ .x = rect.x + rect.w - 90, .y = rect.y + 78, .w = 76, .h = 26 };
        try canvas.rounded(stop, 4, th.raised, th.refuse, 1);
        try label(canvas, stop.x + 16, stop.y + 5.5, "stop", style(text_11, th.refuse, .regular));
        canvas.hit(hits.recorder_stop, stop);
    } else {
        const start = Rect{ .x = rect.x + rect.w - 90, .y = rect.y + 78, .w = 76, .h = 26 };
        try canvas.rounded(start, 4, th.raised, th.line_strong, 1);
        try label(canvas, start.x + 14, start.y + 5.5, "start", style(text_11, th.text, .regular));
        canvas.hit(hits.recorder_start, start);
    }
}

fn drawCapabilities(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    var meta_buf: [48]u8 = undefined;
    try panelHead(canvas, th, rect, "03", "CAPABILITIES", std.fmt.bufPrint(&meta_buf, "{d} probes", .{state.capability_count}) catch "probes");
    if (state.capability_count == 0) {
        try labelWrapped(canvas, .{ .x = rect.x + 14, .y = rect.y + 52, .w = rect.w - 28, .h = 44 }, style(text_11, th.dim, .regular), "Capabilities have not been probed on this surface yet. READY/DEGRADED/SKIP/REFUSE states appear here with their exact reason; a missing signal is never shown as success.");
        return;
    }
    var y = rect.y + 44;
    for (state.capabilitiesSlice(), 0..) |cap, index| {
        if (index != 0) try borderLine(canvas, rect.x + 1, y, rect.w - 2, th.line);
        const color = switch (cap.state) {
            .ready => th.pass,
            .degraded, .busy => th.skip,
            .skip => th.skip,
            .refuse => th.refuse,
        };
        try label(canvas, rect.x + 14, y + 8, cap.nameSlice(), style(text_11, th.text, .regular));
        try label(canvas, rect.x + 130, y + 8, cap.glyph(), style(text_11, color, .regular));
        try label(canvas, rect.x + 150, y + 8, cap.label(), style(text_95, color, .regular));
        if (cap.reason_len > 0) try label(canvas, rect.x + 220, y + 8, cap.reasonSlice(), style(text_10, th.dim, .regular));
        y += 24;
    }
}

fn drawRecents(state: *const State, canvas: *Canvas, th: Theme, rect: Rect) !void {
    try canvas.rounded(rect, 5, th.panel, th.line, 1);
    try panelHead(canvas, th, rect, "04", "RECENT SOURCES", "local only, never exported");
    const entries = state.settings.recents.slice();
    if (entries.len == 0) {
        try label(canvas, rect.x + 14, rect.y + 50, "No recent sources yet.", style(text_11, th.dim, .regular));
        return;
    }
    var y = rect.y + 38;
    for (entries, 0..) |entry, index| {
        const row = Rect{ .x = rect.x + 1, .y = y, .w = rect.w - 2, .h = 24 };
        if (index % 2 == 1) try canvas.fill(row, th.raised);
        try label(canvas, rect.x + 14, y + 6, entry.kind.tag(), style(text_95, th.faint, .regular));
        try label(canvas, rect.x + 76, y + 6, entry.baseName(), style(text_11, th.text, .regular));
        try labelRight(canvas, rect.x + rect.w - 14, y + 6, "open", style(text_10, th.live, .regular));
        canvas.hit(hits.recents_base + @as(u32, @intCast(index)), row);
        y += 26;
    }
}
