//! Per-segment metrics sidecars. The daemon derives one bounded metrics
//! document after a segment closes, so recent history remains queryable after
//! raw retention drops the segment.

const std = @import("std");
const journal = @import("../stream/journal.zig");
const metrics_mod = @import("../analyze/metrics.zig");

pub fn writeForSegment(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segment_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const full = try std.fmt.allocPrint(arena_allocator, "{s}/{s}", .{ dir, segment_path });
    const events = try journal.read(io, arena_allocator, full);
    var index = metrics_mod.Index.init(arena_allocator);
    defer index.deinit();
    try index.append(events);
    const metrics = try index.snapshot(arena_allocator);

    try writeMetrics(io, arena_allocator, dir, segment_path, metrics);
}

/// Write a sidecar from an already-computed metrics snapshot. The daemon uses
/// this after accumulating the segment while writing it, so rotation never
/// re-reads and re-parses the raw file while perf rings are filling.
pub fn writeMetrics(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segment_path: []const u8,
    metrics: metrics_mod.Metrics,
) !void {
    const base = if (std.mem.lastIndexOfScalar(u8, segment_path, '/')) |slash|
        segment_path[slash + 1 ..]
    else
        segment_path;
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    const out_path = try std.fmt.allocPrint(allocator, "{s}/metrics/{s}.json", .{ dir, stem });
    const file = try std.Io.Dir.createFileAbsolute(io, out_path, .{});
    defer file.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try metrics_mod.writeJson(&writer.interface, metrics, 64);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    try file.sync(io);
}

// Checks that a sidecar path is derived from the segment stem.
test "sidecar stem strips the directory and extension" {
    const path = "segments/1793-0.ndjson";
    const base = path[std.mem.lastIndexOfScalar(u8, path, '/').? + 1 ..];
    const stem = base[0..std.mem.lastIndexOfScalar(u8, base, '.').?];
    try std.testing.expectEqualStrings("1793-0", stem);
}
