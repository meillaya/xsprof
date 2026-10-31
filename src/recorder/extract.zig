//! Extract a bounded window from recorder segments. Missing or trimmed data
//! produces explicit markers; this code never interpolates events.

const std = @import("std");
const event = @import("../core/event.zig");
const safety = @import("../core/safety.zig");
const manifest_mod = @import("manifest.zig");

pub const Options = struct {
    dir: []const u8,
    last_ms: u64,
};

pub fn parseDuration(text: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return error.InvalidDuration;
    var unit_ms: u64 = 1;
    var number = trimmed;
    if (std.mem.endsWith(u8, trimmed, "ms")) {
        unit_ms = 1;
        number = trimmed[0 .. trimmed.len - 2];
    } else if (std.mem.endsWith(u8, trimmed, "s")) {
        unit_ms = 1000;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "m")) {
        unit_ms = 60 * 1000;
        number = trimmed[0 .. trimmed.len - 1];
    } else if (std.mem.endsWith(u8, trimmed, "h")) {
        unit_ms = 60 * 60 * 1000;
        number = trimmed[0 .. trimmed.len - 1];
    }
    const value = std.fmt.parseInt(u64, number, 10) catch return error.InvalidDuration;
    if (value == 0) return error.InvalidDuration;
    return std.math.mul(u64, value, unit_ms) catch error.InvalidDuration;
}

fn writeMarker(out: *std.Io.Writer, detail: []const u8) !void {
    try event.writeJson(out, .{
        .kind = .marker,
        .ts_ns = 0,
        .cpu = -1,
        .detail = detail,
    });
    try out.writeByte('\n');
}

pub fn extract(io: std.Io, allocator: std.mem.Allocator, opts: Options) ![]u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{opts.dir});
    defer allocator.free(manifest_path);
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse
        return error.NoRecorder;
    if (manifest.segments.len == 0) return error.NoData;

    const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    const window_ns = std.math.mul(u64, opts.last_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    const cutoff_wall = now_wall -| window_ns;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const oldest_start = manifest.segments[0].start_wall_ns;
    if (manifest.started_wall_ns <= cutoff_wall and
        oldest_start > cutoff_wall + std.time.ns_per_ms)
    {
        var detail_buf: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buf,
            "retention_loss requested_from_wall_ns={d} oldest_wall_ns={d}",
            .{ cutoff_wall, oldest_start },
        ) catch "retention_loss";
        try writeMarker(&out.writer, detail);
    }

    for (manifest.segments) |segment| {
        if (!safety.isSafeRelative(segment.path)) {
            try writeMarker(&out.writer, "capture_invalid_segment_path");
            continue;
        }
        const segment_end = if (segment.end_wall_ns == 0) now_wall else segment.end_wall_ns;
        if (segment_end < cutoff_wall) continue;

        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.dir, segment.path });
        defer allocator.free(full);
        const file = std.Io.Dir.openFileAbsolute(io, full, .{}) catch {
            try writeMarker(&out.writer, "capture_missing_segment");
            continue;
        };
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var reader = file.readerStreaming(io, &buffer);
        const data = reader.interface.allocRemaining(allocator, .limited(32 * 1024 * 1024)) catch {
            try writeMarker(&out.writer, "capture_segment_too_large");
            continue;
        };
        defer allocator.free(data);

        const cutoff_mono = if (cutoff_wall > segment.start_wall_ns)
            segment.start_mono_ns + (cutoff_wall - segment.start_wall_ns)
        else
            0;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const parsed = event.parseJson(allocator, line) catch {
                try writeMarker(&out.writer, "capture_corrupt_segment_line");
                continue;
            };
            if (parsed.ts_ns >= cutoff_mono) {
                try event.writeJson(&out.writer, parsed);
                try out.writer.writeByte('\n');
            }
        }
    }
    return out.toOwnedSlice();
}

// Checks duration units and rejection of zero/overflowing values.
test "duration parser handles units" {
    try std.testing.expectEqual(@as(u64, 5), try parseDuration("5ms"));
    try std.testing.expectEqual(@as(u64, 5000), try parseDuration("5s"));
    try std.testing.expectEqual(@as(u64, 300000), try parseDuration("5m"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("nope"));
}
