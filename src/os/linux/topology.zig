//! Read-only CPU cache-topology probe. LLC groups come from the last-level
//! cache's `shared_cpu_list`; when it is unavailable the caller must treat
//! topology as uncollected rather than inferring it from CPU count.

const std = @import("std");
const builtin = @import("builtin");

pub const max_cpus = 256;

pub const Map = struct {
    llc: [max_cpus]i16 = @splat(-1),
    count: u16 = 0,
};

/// Parses the first CPU in a sysfs cpu list (`0-3`, `0,2-3`, `5`).
pub fn parseFirstCpu(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const first = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, ',') orelse trimmed.len];
    const dash = std.mem.indexOfScalar(u8, first, '-') orelse first.len;
    const number = first[0..dash];
    if (number.len == 0) return null;
    return std.fmt.parseInt(u16, number, 10) catch null;
}

fn readCpuList(
    io: std.Io,
    allocator: std.mem.Allocator,
    cpu: u32,
) ![]u8 {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "/sys/devices/system/cpu/cpu{d}/cache/index3/shared_cpu_list",
        .{cpu},
    );
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buffer: [128]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(128));
}

pub fn collect(io: std.Io, allocator: std.mem.Allocator, cpu_count: u32) Map {
    if (comptime builtin.os.tag != .linux) return .{};
    return collectLinux(io, allocator, cpu_count);
}

fn collectLinux(io: std.Io, allocator: std.mem.Allocator, cpu_count: u32) Map {
    var map: Map = .{};
    const count = @min(cpu_count, max_cpus);
    var cpu: u32 = 0;
    while (cpu < count) : (cpu += 1) {
        const text = readCpuList(io, allocator, cpu) catch continue;
        defer allocator.free(text);
        const group = parseFirstCpu(text) orelse continue;
        const index: usize = @intCast(cpu);
        if (map.llc[index] < 0) map.count +|= 1;
        map.llc[index] = @intCast(group);
    }
    return map;
}

test "cpu list parser takes the first group" {
    try std.testing.expectEqual(@as(u16, 0), parseFirstCpu("0-3\n").?);
    try std.testing.expectEqual(@as(u16, 2), parseFirstCpu("2,4-5").?);
    try std.testing.expectEqual(@as(u16, 7), parseFirstCpu("7").?);
    try std.testing.expect(parseFirstCpu("") == null);
    try std.testing.expect(parseFirstCpu("nope") == null);
}
