const layout = @import("layout.zig");
const actions = @import("actions.zig");

pub const LayoutTier = enum { narrow, standard, wide };
pub const Style = enum { normal, accent, warning, success, muted };

pub const Theme = struct {
    brand: []const u8 = "▚ zig-scheduler",
    mode: []const u8 = "NORMAL",
    accent: []const u8 = "cyan",
    warning: []const u8 = "yellow",
    success: []const u8 = "green",
};

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
    _ = action_status;
    const theme = Theme{};
    try writer.writeAll("│ ");
    try writer.writeAll(theme.mode);
    try writer.writeAll("     ");
    const status_cells = try actions.writeFooter(writer, width);
    try writer.writeAll("     FAIL-CLOSED");
    var cells = layout.displayCells(theme.mode) + layout.displayCells("     ") + status_cells + layout.displayCells("     FAIL-CLOSED");
    while (cells + 4 < width) : (cells += 1) try writer.writeByte(' ');
    try writer.writeAll(" │\n");
}
