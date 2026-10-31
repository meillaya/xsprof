//! Read-only Linux pressure-stall information (`/proc/pressure/*`). Values are
//! parsed exactly into basis points so the canonical JSON never contains a
//! float or a locale-dependent decimal.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("../../core/json.zig");

const Writer = std.Io.Writer;

pub const Sample = struct {
    avg10_bp: u32 = 0,
    avg60_bp: u32 = 0,
    avg300_bp: u32 = 0,
    total_us: u64 = 0,
};

pub const Resource = struct {
    some: ?Sample = null,
    full: ?Sample = null,
};

pub const Snapshot = struct {
    available: bool = false,
    state: []const u8 = "SKIP",
    reason: []const u8 = "",
    source: []const u8 = "proc_pressure",
    cpu: ?Resource = null,
    memory: ?Resource = null,
    io: ?Resource = null,
};

pub const Error = error{ InvalidPressure, OutOfMemory };

fn parseBp(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const whole = std.fmt.parseInt(u64, text[0..dot], 10) catch return null;
    var frac: u64 = 0;
    var scale: u64 = 100;
    if (dot < text.len) {
        const digits = text[dot + 1 ..];
        if (digits.len > 2) return null;
        frac = std.fmt.parseInt(u64, digits, 10) catch return null;
        if (digits.len == 1) frac *= 10;
        scale = 1;
    }
    return std.math.cast(u32, whole * 100 + frac * scale) orelse null;
}

fn parseSample(text: []const u8) Error!Sample {
    var sample = Sample{};
    var seen_avg10 = false;
    var seen_avg60 = false;
    var seen_avg300 = false;
    var seen_total = false;
    var fields = std.mem.tokenizeAny(u8, text, " \t");
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidPressure;
        const key = field[0..eq];
        const value = field[eq + 1 ..];
        if (std.mem.eql(u8, key, "avg10")) {
            sample.avg10_bp = parseBp(value) orelse return error.InvalidPressure;
            seen_avg10 = true;
        } else if (std.mem.eql(u8, key, "avg60")) {
            sample.avg60_bp = parseBp(value) orelse return error.InvalidPressure;
            seen_avg60 = true;
        } else if (std.mem.eql(u8, key, "avg300")) {
            sample.avg300_bp = parseBp(value) orelse return error.InvalidPressure;
            seen_avg300 = true;
        } else if (std.mem.eql(u8, key, "total")) {
            sample.total_us = std.fmt.parseInt(u64, value, 10) catch return error.InvalidPressure;
            seen_total = true;
        }
    }
    if (!seen_avg10 or !seen_avg60 or !seen_avg300 or !seen_total) {
        return error.InvalidPressure;
    }
    return sample;
}

pub fn parseResource(text: []const u8) Error!Resource {
    var resource = Resource{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "some ")) {
            resource.some = try parseSample(line["some ".len..]);
        } else if (std.mem.startsWith(u8, line, "full ")) {
            resource.full = try parseSample(line["full ".len..]);
        }
    }
    if (resource.some == null and resource.full == null) return error.InvalidPressure;
    return resource;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch null;
}

pub fn collect(io: std.Io, allocator: std.mem.Allocator) Snapshot {
    if (builtin.os.tag != .linux) {
        return .{
            .available = false,
            .state = "SKIP",
            .reason = "non-Linux host: /proc/pressure unavailable",
        };
    }
    var snapshot = Snapshot{};
    if (readFile(io, allocator, "/proc/pressure/cpu")) |text| {
        snapshot.cpu = parseResource(text) catch null;
    }
    if (readFile(io, allocator, "/proc/pressure/memory")) |text| {
        snapshot.memory = parseResource(text) catch null;
    }
    if (readFile(io, allocator, "/proc/pressure/io")) |text| {
        snapshot.io = parseResource(text) catch null;
    }
    if (snapshot.cpu == null and snapshot.memory == null and snapshot.io == null) {
        snapshot.reason = "/proc/pressure files unreadable";
        return snapshot;
    }
    snapshot.available = true;
    snapshot.state = "READY";
    return snapshot;
}

fn writeSample(w: *Writer, sample: Sample) Writer.Error!void {
    try json.write(w, .{ .object = &.{
        .{ .key = "avg10_bp", .value = .{ .unsigned = sample.avg10_bp } },
        .{ .key = "avg300_bp", .value = .{ .unsigned = sample.avg300_bp } },
        .{ .key = "avg60_bp", .value = .{ .unsigned = sample.avg60_bp } },
        .{ .key = "total_us", .value = .{ .unsigned = sample.total_us } },
    } });
}

fn writeResource(w: *Writer, resource: Resource) Writer.Error!void {
    try w.writeByte('{');
    if (resource.full) |full| {
        try w.writeAll("\"full\":");
        try writeSample(w, full);
        try w.writeByte(',');
    }
    try w.writeAll("\"some\":");
    try writeSample(w, resource.some.?);
    try w.writeByte('}');
}

pub fn writeJson(w: *Writer, snapshot: Snapshot) Writer.Error!void {
    try w.writeAll("{\"available\":");
    try json.write(w, .{ .boolean = snapshot.available });
    try w.writeAll(",\"cpu\":");
    if (snapshot.cpu) |cpu| try writeResource(w, cpu) else try w.writeAll("null");
    try w.writeAll(",\"host_mutation\":false,\"io\":");
    if (snapshot.io) |item| try writeResource(w, item) else try w.writeAll("null");
    try w.writeAll(",\"memory\":");
    if (snapshot.memory) |item| try writeResource(w, item) else try w.writeAll("null");
    try w.writeAll(",\"reason\":");
    try json.write(w, .{ .string = snapshot.reason });
    try w.writeAll(",\"schema\":\"xsprof/pressure/v1\",\"source\":");
    try json.write(w, .{ .string = snapshot.source });
    try w.writeAll(",\"state\":");
    try json.write(w, .{ .string = snapshot.state });
    try w.writeByte('}');
}

test "parses exact pressure basis points" {
    const text =
        "some avg10=1.23 avg60=4.56 avg300=7.89 total=123456\n" ++
        "full avg10=0.25 avg60=0.50 avg300=0.75 total=9000\n";
    const resource = try parseResource(text);
    try std.testing.expectEqual(@as(u32, 123), resource.some.?.avg10_bp);
    try std.testing.expectEqual(@as(u32, 456), resource.some.?.avg60_bp);
    try std.testing.expectEqual(@as(u32, 789), resource.some.?.avg300_bp);
    try std.testing.expectEqual(@as(u64, 123456), resource.some.?.total_us);
    try std.testing.expectEqual(@as(u32, 25), resource.full.?.avg10_bp);
    try std.testing.expectError(error.InvalidPressure, parseResource("some avg10=1.23\n"));
    try std.testing.expectError(error.InvalidPressure, parseResource("garbage\n"));
}

test "pressure JSON is canonical and read-only" {
    const snapshot = Snapshot{
        .available = true,
        .state = "READY",
        .cpu = .{ .some = .{ .avg10_bp = 100, .avg60_bp = 200, .avg300_bp = 300, .total_us = 42 } },
    };
    var buffer: [1024]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try writeJson(&writer, snapshot);
    try std.testing.expectEqualStrings(
        "{\"available\":true,\"cpu\":{\"some\":{\"avg10_bp\":100,\"avg300_bp\":300," ++
            "\"avg60_bp\":200,\"total_us\":42}},\"host_mutation\":false,\"io\":null," ++
            "\"memory\":null,\"reason\":\"\",\"schema\":\"xsprof/pressure/v1\"," ++
            "\"source\":\"proc_pressure\",\"state\":\"READY\"}",
        writer.buffered(),
    );
}
