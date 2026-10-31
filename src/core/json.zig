//! Canonical, deterministic JSON writer.
//!
//! Object keys are written in the caller-supplied order and must be strictly
//! ascending. This is deliberate: the wire format is byte-stable, matching the
//! archived profiler's sorted-key output. Parsing is handled by std.json at the
//! boundary, not here.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Value = union(enum) {
    nul,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    array: []const Value,
    object: []const Entry,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub fn write(w: *Writer, value: Value) Writer.Error!void {
    switch (value) {
        .nul => try w.writeAll("null"),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .integer => |v| try w.print("{d}", .{v}),
        .unsigned => |v| try w.print("{d}", .{v}),
        .float => |v| {
            if (std.math.isNan(v) or std.math.isInf(v)) {
                try w.writeAll("null");
            } else {
                // P1 will pin this to the archived wire formatting; Zig's
                // shortest round-trip form is the safe default for now.
                try w.print("{d}", .{v});
            }
        },
        .string => |v| try writeString(w, v),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try write(w, item);
            }
            try w.writeByte(']');
        },
        .object => |entries| {
            try w.writeByte('{');
            var previous: ?[]const u8 = null;
            for (entries, 0..) |entry, i| {
                if (previous) |prev| {
                    std.debug.assert(std.mem.order(u8, prev, entry.key) == .lt);
                }
                previous = entry.key;
                if (i != 0) try w.writeByte(',');
                try writeString(w, entry.key);
                try w.writeByte(':');
                try write(w, entry.value);
            }
            try w.writeByte('}');
        },
    }
}

pub fn writeString(w: *Writer, value: []const u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.writeAll(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] });
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "canonical object is byte-stable" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try write(&w, .{
        .object = &.{
            .{ .key = "event", .value = .{ .string = "refusal" } },
            .{ .key = "host_mutation", .value = .{ .boolean = false } },
            .{ .key = "seq", .value = .{ .unsigned = 7 } },
        },
    });
    try std.testing.expectEqualStrings(
        "{\"event\":\"refusal\",\"host_mutation\":false,\"seq\":7}",
        w.buffered(),
    );
}

test "array, null, float, and escaping" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try write(&w, .{
        .array = &.{
            .nul,
            .{ .integer = -3 },
            .{ .float = 1.5 },
            .{ .string = "a\nb\u{1}c\"d" },
        },
    });
    try std.testing.expectEqualStrings(
        "[null,-3,1.5,\"a\\nb\\u0001c\\\"d\"]",
        w.buffered(),
    );
}

test "non-finite floats serialize as null" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try write(&w, .{ .array = &.{
        .{ .float = std.math.nan(f64) },
        .{ .float = std.math.inf(f64) },
    } });
    try std.testing.expectEqualStrings("[null,null]", w.buffered());
}
