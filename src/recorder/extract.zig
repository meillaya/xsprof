//! Extract a bounded window from recorder segments. Missing or trimmed data
//! produces explicit markers; this code never interpolates events.

const std = @import("std");
const event = @import("../core/event.zig");
const session_meta = @import("../core/session_meta.zig");
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
            // Session metadata is a header, not a sampled event: keep it even
            // when its capture-start timestamp is older than the window.
            if (parsed.ts_ns >= cutoff_mono or session_meta.isMetadata(parsed)) {
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

test "metadata survives a cutoff that drops surrounding events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(
        allocator,
        "/tmp/xsprof-extract-{d}",
        .{std.testing.random_seed},
    );
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};

    const segment_path = try std.fmt.allocPrint(allocator, "{s}/segments/0-0.ndjson", .{root});
    const body =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":0,\"cpu\":-1,\"pid\":7,\"tid\":7,\"comm\":\"xsprof\",\"detail\":\"capture_owner\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_switch\",\"ts_ns\":0,\"cpu\":0,\"pid\":1,\"tid\":1,\"a\":1,\"b\":0,\"c\":0,\"comm\":\"worker\",\"host_mutation\":false}\n";
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, segment_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, body);
    }

    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, std.testing.io).nanoseconds)));
    const start = now - 120 * std.time.ns_per_s;
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    try manifest_mod.writeAtomic(std.testing.io, allocator, manifest_path, .{
        .session_id = "extract-test",
        .state = .stopped,
        .started_wall_ns = start,
        .started_mono_ns = 0,
        .segments = &.{.{
            .path = "segments/0-0.ndjson",
            .start_wall_ns = start,
            .start_mono_ns = 0,
            .end_wall_ns = now,
            .end_mono_ns = 60 * std.time.ns_per_s,
            .bytes = body.len,
            .events = 2,
            .closed = true,
        }},
    });

    const data = try extract(std.testing.io, allocator, .{ .dir = root, .last_ms = 60_000 });
    try std.testing.expect(std.mem.indexOf(u8, data, "capture_owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "sched_switch") == null);

    std.Io.Dir.deleteFileAbsolute(std.testing.io, segment_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, manifest_path) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}
