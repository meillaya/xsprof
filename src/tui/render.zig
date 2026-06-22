//! SIZE_OK: ANSI rendering keeps theme palettes, semantic tokens, and escape emission in
//! one small renderer so snapshot coloring cannot drift between split modules after the
//! verified live-VM visual contract was established.
const layout = @import("layout.zig");
const actions = @import("actions.zig");

const std = @import("std");

pub const LayoutTier = enum { narrow, standard, wide };
pub const Style = enum { normal, accent, warning, success, danger, muted, border };

pub const ThemeId = enum {
    black,
    cool_dark,
    paper,
    catppuccin_mocha,
    catppuccin_latte,
};

pub const AnsiPalette = struct {
    /// DESIGN.md: warm terminal surface, not pure black.
    surface: []const u8 = "\x1b[48;5;235m",
    neutral: []const u8 = "\x1b[38;5;245m",
    muted: []const u8 = "\x1b[38;5;240m",
    border: []const u8 = "\x1b[38;5;94m",
    accent: []const u8 = "\x1b[38;5;45m",
    warning: []const u8 = "\x1b[38;5;220m",
    success: []const u8 = "\x1b[38;5;114m",
    danger: []const u8 = "\x1b[38;5;205m",
    reset: []const u8 = "\x1b[0m",
};

pub const Theme = struct {
    brand: []const u8 = "▚ zig-scheduler",
    mode: []const u8 = "NORMAL",
    accent: []const u8 = "cyan",
    warning: []const u8 = "yellow",
    success: []const u8 = "green",
    palette: AnsiPalette = .{},
};

pub fn nextTheme(id: ThemeId) ThemeId {
    return switch (id) {
        .black => .cool_dark,
        .cool_dark => .paper,
        .paper => .catppuccin_mocha,
        .catppuccin_mocha => .catppuccin_latte,
        .catppuccin_latte => .black,
    };
}

pub fn themeHeaderLabel(id: ThemeId) []const u8 {
    return switch (id) {
        .black => "theme black ▸ w",
        .cool_dark => "theme cool dark ▸ w",
        .paper => "theme paper ▸ w",
        .catppuccin_mocha => "theme catppuccin mocha ▸ w",
        .catppuccin_latte => "theme catppuccin latte ▸ w",
    };
}

pub fn themeFor(id: ThemeId) Theme {
    return switch (id) {
        .black => .{
            .accent = "cyan",
            .warning = "amber",
            .success = "green",
            .palette = .{
                .surface = "\x1b[48;5;16m",
                .neutral = "\x1b[38;5;255m",
                .muted = "\x1b[38;5;242m",
                .border = "\x1b[38;5;238m",
                .accent = "\x1b[38;5;45m",
                .warning = "\x1b[38;5;220m",
                .success = "\x1b[38;5;114m",
                .danger = "\x1b[38;5;205m",
            },
        },
        .cool_dark => .{
            .accent = "cyan",
            .warning = "yellow",
            .success = "green",
            .palette = .{
                .surface = "\x1b[48;5;17m",
                .neutral = "\x1b[38;5;252m",
                .muted = "\x1b[38;5;244m",
                .border = "\x1b[38;5;60m",
                .accent = "\x1b[38;5;81m",
                .warning = "\x1b[38;5;221m",
                .success = "\x1b[38;5;115m",
                .danger = "\x1b[38;5;211m",
            },
        },
        .paper => .{
            .accent = "cyan",
            .warning = "ochre",
            .success = "green",
            .palette = .{
                .surface = "\x1b[48;5;255m",
                .neutral = "\x1b[38;5;235m",
                .muted = "\x1b[38;5;245m",
                .border = "\x1b[38;5;250m",
                .accent = "\x1b[38;5;31m",
                .warning = "\x1b[38;5;136m",
                .success = "\x1b[38;5;28m",
                .danger = "\x1b[38;5;162m",
            },
        },
        .catppuccin_mocha => .{
            .accent = "sapphire",
            .warning = "peach",
            .success = "green",
            .palette = .{
                .surface = "\x1b[48;5;235m",
                .neutral = "\x1b[38;5;189m",
                .muted = "\x1b[38;5;103m",
                .border = "\x1b[38;5;60m",
                .accent = "\x1b[38;5;111m",
                .warning = "\x1b[38;5;216m",
                .success = "\x1b[38;5;151m",
                .danger = "\x1b[38;5;212m",
            },
        },
        .catppuccin_latte => .{
            .accent = "sapphire",
            .warning = "peach",
            .success = "green",
            .palette = .{
                .surface = "\x1b[48;5;230m",
                .neutral = "\x1b[38;5;237m",
                .muted = "\x1b[38;5;246m",
                .border = "\x1b[38;5;188m",
                .accent = "\x1b[38;5;32m",
                .warning = "\x1b[38;5;209m",
                .success = "\x1b[38;5;71m",
                .danger = "\x1b[38;5;204m",
            },
        },
    };
}

pub const Cell = struct {
    text: []const u8,
    style: Style = .normal,
};

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const Canvas = struct {
    width: usize,
    height: usize,
    theme: Theme = .{},
};

pub fn layoutTier(width: usize) LayoutTier {
    if (width < 100) return .narrow;
    if (width < 140) return .standard;
    return .wide;
}

pub fn renderHeader(writer: anytype, width: usize, title: []const u8, mode: []const u8) !void {
    const theme = Theme{};
    try layout.row(writer, width, theme.brand, title, mode);
}

pub fn renderPane(writer: anytype, width: usize, title: []const u8, left: []const u8, right: []const u8) !void {
    try layout.row(writer, width, title, left, right);
}

pub fn renderStatusBar(writer: anytype, width: usize, action_status: []const u8) !void {
    const mode = footerMode(action_status);
    try writer.writeAll("│ ");
    try writer.writeAll(mode);
    try writer.writeAll("     ");
    const status_cells = try actions.writeFooter(writer, width);
    try writer.writeAll("     FAIL-CLOSED");
    var cells = layout.displayCells(mode) + layout.displayCells("     ") + status_cells + layout.displayCells("     FAIL-CLOSED");
    while (cells + 4 < width) : (cells += 1) try writer.writeByte(' ');
    try writer.writeAll(" │\n");
}

fn footerMode(action_status: []const u8) []const u8 {
    if (std.mem.indexOf(u8, action_status, "INCIDENT") != null or std.mem.indexOf(u8, action_status, "incident") != null) return "INCIDENT";
    if (std.mem.indexOf(u8, action_status, "ROLLBACK") != null or std.mem.indexOf(u8, action_status, "rollback") != null) return "ROLLBACK";
    if (std.mem.indexOf(u8, action_status, "CLEANUP") != null or std.mem.indexOf(u8, action_status, "cleanup") != null) return "CLEANUP";
    if (std.mem.indexOf(u8, action_status, "SAFE") != null or std.mem.indexOf(u8, action_status, "validated") != null or std.mem.indexOf(u8, action_status, "QUIT") != null) return "SAFE";
    if (std.mem.indexOf(u8, action_status, "RUNNING") != null or std.mem.indexOf(u8, action_status, "active") != null or std.mem.indexOf(u8, action_status, "queued") != null) return "RUNNING";
    return themeDefaultMode();
}

fn themeDefaultMode() []const u8 {
    const theme = Theme{};
    return theme.mode;
}

const SemanticToken = struct {
    text: []const u8,
    style: Style,
};

const semantic_tokens = [_]SemanticToken{
    .{ .text = "host unchanged", .style = .muted },
    .{ .text = "host_mutation=false", .style = .muted },
    .{ .text = "VM-only path", .style = .muted },

    .{ .text = "cleanup receipt PASS", .style = .success },
    .{ .text = "rollback ready/completed", .style = .success },
    .{ .text = "rollback_done", .style = .success },
    .{ .text = "verifier-ready", .style = .success },
    .{ .text = "fallback-fired", .style = .success },
    .{ .text = "PASS", .style = .success },
    .{ .text = "completed", .style = .success },
    .{ .text = "ready", .style = .success },
    .{ .text = "none after rollback", .style = .success },

    .{ .text = "unsafe_to_assume", .style = .danger },
    .{ .text = "verifier queued/refused host-safe", .style = .danger },
    .{ .text = "partial attach queued/refused host-safe", .style = .danger },
    .{ .text = "live microvm queued/refused host-safe", .style = .danger },
    .{ .text = "daemon refused host-safe", .style = .danger },
    .{ .text = "failed-boot", .style = .danger },
    .{ .text = "closed_stale_bundle", .style = .danger },
    .{ .text = "REJECTED", .style = .danger },
    .{ .text = "rejected", .style = .danger },
    .{ .text = "incident", .style = .danger },
    .{ .text = "refused", .style = .danger },
    .{ .text = "FAIL-CLOSED", .style = .danger },

    .{ .text = "pending signed proof", .style = .warning },
    .{ .text = "partial switch required", .style = .warning },
    .{ .text = "rollback required", .style = .warning },
    .{ .text = "not-started", .style = .warning },
    .{ .text = "required", .style = .warning },
    .{ .text = "pending", .style = .warning },
    .{ .text = "missing", .style = .warning },
    .{ .text = "closed", .style = .warning },
    .{ .text = "read-only", .style = .warning },
    .{ .text = "FIXTURE", .style = .warning },

    .{ .text = "▚ zig-scheduler", .style = .accent },
    .{ .text = "live microVM lab", .style = .accent },
    .{ .text = "vm-live", .style = .accent },
    .{ .text = "runtime samples", .style = .accent },
    .{ .text = "lifecycle", .style = .accent },
    .{ .text = "sched_ext", .style = .accent },
    .{ .text = "zigsched_minimal", .style = .accent },
    .{ .text = "NORMAL", .style = .accent },
    .{ .text = "RUNNING", .style = .accent },
    .{ .text = "ROLLBACK", .style = .warning },
    .{ .text = "CLEANUP", .style = .warning },
    .{ .text = "SAFE", .style = .success },
    .{ .text = "REFUSED", .style = .danger },
    .{ .text = "INCIDENT", .style = .danger },
    .{ .text = "↵", .style = .accent },
};

pub fn renderInteractiveAnsi(allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
    return renderInteractiveAnsiWithTheme(allocator, plain, .black);
}

pub fn renderInteractiveAnsiWithTheme(allocator: std.mem.Allocator, plain: []const u8, theme_id: ThemeId) ![]u8 {
    const theme = themeFor(theme_id);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);

    var index: usize = 0;
    var at_line_start = true;
    while (index < plain.len) {
        if (at_line_start) {
            try writer.writer.writeAll(theme.palette.surface);
            try writer.writer.writeAll(theme.palette.neutral);
            at_line_start = false;
        }

        if (plain[index] == '\n') {
            try writer.writer.writeAll(theme.palette.reset);
            try writer.writer.writeByte('\n');
            index += 1;
            at_line_start = true;
            continue;
        }

        if (semanticTokenAt(plain[index..])) |token| {
            try writer.writer.writeAll(ansiForStyle(theme.palette, token.style));
            try writer.writer.writeAll(token.text);
            try writer.writer.writeAll(theme.palette.neutral);
            index += token.text.len;
            continue;
        }

        try writer.writer.writeByte(plain[index]);
        index += 1;
    }
    if (!at_line_start) try writer.writer.writeAll(theme.palette.reset);
    out = writer.toArrayList();
    return out.toOwnedSlice(allocator);
}

fn semanticTokenAt(text: []const u8) ?SemanticToken {
    for (semantic_tokens) |token| {
        if (std.mem.startsWith(u8, text, token.text)) return token;
    }
    return null;
}

fn ansiForStyle(palette: AnsiPalette, style: Style) []const u8 {
    return switch (style) {
        .normal => palette.neutral,
        .accent => palette.accent,
        .warning => palette.warning,
        .success => palette.success,
        .danger => palette.danger,
        .muted => palette.muted,
        .border => palette.border,
    };
}
