const std = @import("std");

pub fn section(writer: anytype, width: usize, left: []const u8, right: []const u8) !void {
    try row(writer, width, left, "", right);
}

pub fn row(writer: anytype, width: usize, left: []const u8, middle: []const u8, right: []const u8) !void {
    const columns = columnWidths(width);
    try writer.writeAll("│ ");
    try writeCell(writer, left, columns.left);
    try writer.writeAll(" │ ");
    try writeCell(writer, middle, columns.middle);
    try writer.writeAll(" │ ");
    try writeCell(writer, right, columns.right);
    try writer.writeAll(" │\n");
}

const RowColumns = struct {
    left: usize,
    middle: usize,
    right: usize,
};

fn columnWidths(width: usize) RowColumns {
    if (width < 90) return .{ .left = 30, .middle = 24, .right = width - 64 };
    return .{ .left = 34, .middle = 24, .right = width - 68 };
}

pub fn line(writer: anytype, width: usize, left: []const u8, fill: []const u8, right: []const u8) !void {
    try writer.writeAll(left);
    var col: usize = 2;
    while (col < width) : (col += 1) try writer.writeAll(fill);
    try writer.writeAll(right);
    try writer.writeByte('\n');
}

pub fn countRows(bytes: []const u8) usize {
    var rows: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') rows += 1;
    }
    return rows;
}

fn writeCell(writer: anytype, text: []const u8, width: usize) !void {
    const clipped = clipToCells(text, width);
    try writer.writeAll(clipped.text);
    var cells = clipped.cells;
    while (cells < width) : (cells += 1) try writer.writeByte(' ');
}

pub fn displayCells(text: []const u8) usize {
    const view = std.unicode.Utf8View.init(text) catch return text.len;
    var iterator = view.iterator();
    var cells: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        cells += codepointCells(codepoint);
    }
    return cells;
}

pub fn maxLineCells(bytes: []const u8) usize {
    var max_width: usize = 0;
    var start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte == '\n') {
            max_width = @max(max_width, displayCells(bytes[start..index]));
            start = index + 1;
        }
    }
    if (start < bytes.len) max_width = @max(max_width, displayCells(bytes[start..]));
    return max_width;
}

const ClippedText = struct {
    text: []const u8,
    cells: usize,
};

fn clipToCells(text: []const u8, width: usize) ClippedText {
    const view = std.unicode.Utf8View.init(text) catch return .{
        .text = if (text.len > width) text[0..width] else text,
        .cells = @min(text.len, width),
    };
    var iterator = view.iterator();
    var end: usize = 0;
    var cells: usize = 0;
    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = std.unicode.utf8Decode(slice) catch unreachable;
        const next_cells = codepointCells(codepoint);
        if (cells + next_cells > width) break;
        cells += next_cells;
        end += slice.len;
    }
    return .{ .text = text[0..end], .cells = cells };
}

fn codepointCells(codepoint: u21) usize {
    if (isZeroWidth(codepoint)) return 0;
    if (isWide(codepoint)) return 2;
    return 1;
}

fn isZeroWidth(codepoint: u21) bool {
    return (codepoint >= 0x0300 and codepoint <= 0x036F) or
        (codepoint >= 0x1AB0 and codepoint <= 0x1AFF) or
        (codepoint >= 0x1DC0 and codepoint <= 0x1DFF) or
        (codepoint >= 0x20D0 and codepoint <= 0x20FF) or
        (codepoint >= 0xFE00 and codepoint <= 0xFE0F);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115F) or
        (codepoint >= 0x2329 and codepoint <= 0x232A) or
        (codepoint >= 0x2E80 and codepoint <= 0xA4CF) or
        (codepoint >= 0xAC00 and codepoint <= 0xD7A3) or
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or
        (codepoint >= 0xFE10 and codepoint <= 0xFE19) or
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or
        (codepoint >= 0x1F300 and codepoint <= 0x1FAFF);
}
