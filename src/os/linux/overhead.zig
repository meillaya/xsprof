//! A small overhead meter for the recorder. It reads only this process's
//! scheduler runtime and RSS, then reports events/bytes per wall second and
//! profiler CPU time as basis points of one CPU.

const std = @import("std");
const builtin = @import("builtin");

pub const SelfSample = struct {
    available: bool = false,
    cpu_us: u64 = 0,
    rss_kb: u64 = 0,
};

pub const Report = struct {
    available: bool = false,
    wall_ms: u64 = 0,
    cpu_ms: u64 = 0,
    rss_kb: u64 = 0,
    events: u64 = 0,
    bytes: u64 = 0,
    events_per_sec: u64 = 0,
    bytes_per_sec: u64 = 0,
    /// One basis point is 0.01% of one CPU. 10000 = one full CPU.
    overhead_bp: u64 = 0,
};

pub fn parseSchedstat(text: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const runtime_ns = fields.next() orelse return null;
    return std.fmt.parseInt(u64, runtime_ns, 10) catch null;
}

pub fn parseVmRss(status: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["VmRSS:".len..], " \t");
        const value = fields.next() orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

pub fn report(
    start_cpu_us: u64,
    start_wall_us: u64,
    end_cpu_us: u64,
    end_wall_us: u64,
    rss_kb: u64,
    events: u64,
    bytes: u64,
) Report {
    const wall_us = end_wall_us -| start_wall_us;
    const cpu_us = end_cpu_us -| start_cpu_us;
    return .{
        .available = true,
        .wall_ms = wall_us / 1000,
        .cpu_ms = cpu_us / 1000,
        .rss_kb = rss_kb,
        .events = events,
        .bytes = bytes,
        .events_per_sec = if (wall_us == 0) 0 else events *| 1_000_000 / wall_us,
        .bytes_per_sec = if (wall_us == 0) 0 else bytes *| 1_000_000 / wall_us,
        .overhead_bp = if (wall_us == 0) 0 else cpu_us *| 10_000 / wall_us,
    };
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch null;
}

pub fn readSelf(io: std.Io, allocator: std.mem.Allocator) SelfSample {
    if (builtin.os.tag != .linux) return .{};
    const schedstat = readFile(io, allocator, "/proc/self/schedstat") orelse return .{};
    const runtime_ns = parseSchedstat(schedstat) orelse return .{};
    const status = readFile(io, allocator, "/proc/self/status") orelse return .{};
    const rss_kb = parseVmRss(status) orelse 0;
    return .{
        .available = true,
        .cpu_us = runtime_ns / 1000,
        .rss_kb = rss_kb,
    };
}

pub const Meter = struct {
    start_cpu_us: u64 = 0,
    start_wall_us: u64 = 0,
    available: bool = false,

    pub fn start(io: std.Io, allocator: std.mem.Allocator) Meter {
        const sample = readSelf(io, allocator);
        return .{
            .start_cpu_us = sample.cpu_us,
            .start_wall_us = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds))) / 1000,
            .available = sample.available,
        };
    }

    pub fn finish(self: Meter, io: std.Io, allocator: std.mem.Allocator, events: u64, bytes: u64) Report {
        if (!self.available) return .{ .events = events, .bytes = bytes };
        const sample = readSelf(io, allocator);
        if (!sample.available) return .{ .events = events, .bytes = bytes };
        const end_wall_us = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds))) / 1000;
        return report(
            self.start_cpu_us,
            self.start_wall_us,
            sample.cpu_us,
            end_wall_us,
            sample.rss_kb,
            events,
            bytes,
        );
    }
};

test "parses scheduler runtime and RSS" {
    try std.testing.expectEqual(@as(u64, 12345), parseSchedstat("12345 678 9\n").?);
    try std.testing.expect(parseSchedstat("nope") == null);
    try std.testing.expectEqual(@as(u64, 2048), parseVmRss("Name:\txsprof\nVmRSS:\t   2048 kB\n").?);
    try std.testing.expect(parseVmRss("Name:\txsprof\n") == null);
}

test "overhead math is bounded and fail-closed at zero wall time" {
    const sample = report(1_000, 10_000, 51_000, 1_010_000, 4096, 5000, 100_000);
    try std.testing.expectEqual(@as(u64, 1000), sample.wall_ms);
    try std.testing.expectEqual(@as(u64, 50), sample.cpu_ms);
    try std.testing.expectEqual(@as(u64, 500), sample.overhead_bp);
    try std.testing.expectEqual(@as(u64, 5000), sample.events_per_sec);
    try std.testing.expectEqual(@as(u64, 0), report(0, 5, 1, 5, 0, 0, 0).overhead_bp);
}
