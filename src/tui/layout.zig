const std = @import("std");

pub fn section(writer: anytype, width: usize, left: []const u8, right: []const u8) !void {
    try row(writer, width, left, "", right);
}

pub fn row(writer: anytype, width: usize, left: []const u8, middle: []const u8, right: []const u8) !void {
    try writer.writeAll("│ ");
    try writeCell(writer, left, 34);
    try writer.writeAll(" │ ");
    try writeCell(writer, middle, 24);
    try writer.writeAll(" │ ");
    const used: usize = 2 + 34 + 3 + 24 + 3;
    const right_width = if (width > used + 2) width - used - 2 else 12;
    try writeCell(writer, right, right_width);
    try writer.writeAll(" │\n");
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
    const clipped = if (text.len > width) text[0..width] else text;
    try writer.writeAll(clipped);
    var cells = displayCells(clipped);
    while (cells < width) : (cells += 1) try writer.writeByte(' ');
}

pub fn displayCells(text: []const u8) usize {
    var cells: usize = 0;
    for (text) |byte| {
        if ((byte & 0b1100_0000) != 0b1000_0000) cells += 1;
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
