//! Extract a bounded window from recorder segments. Missing or trimmed data
//! produces explicit markers; this code never interpolates events. Compact
//! .xsraw segments stream through segment_reader; legacy .ndjson lines remain
//! readable so an upgraded binary reads an existing state directory.

const std = @import("std");
const event = @import("../core/event.zig");
const session_meta = @import("../core/session_meta.zig");
const safety = @import("../core/safety.zig");
const manifest_mod = @import("manifest.zig");
const reader_mod = @import("segment_reader.zig");

const Writer = std.Io.Writer;

pub const Stats = struct {
    emitted_events: u64 = 0,
    emitted_bytes: u64 = 0,
    decoded_events: u64 = 0,
    segments: u32 = 0,
    legacy_segments: u32 = 0,
    sample_loss: u64 = 0,
    truncated: bool = false,
};

pub const Options = struct {
    dir: []const u8,
    last_ms: u64,
    /// Emit only marker rows; bounded loss audits use this.
    markers_only: bool = false,
    /// Stop after this many emitted events (0 = unlimited).
    max_events: u64 = 0,
    /// Stop after this many canonical output bytes (0 = unlimited).
    max_bytes: u64 = 0,
    /// Optional counters filled by writeTo.
    stats: ?*Stats = null,
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

fn writeMarker(out: *Writer, detail: []const u8) !void {
    try event.writeJson(out, .{
        .kind = .marker,
        .ts_ns = 0,
        .cpu = -1,
        .detail = detail,
    });
    try out.writeByte('\n');
}

const Emit = struct {
    out: *Writer,
    opts: Options,
    stats: *Stats,
    line_buffer: [event.max_line_bytes]u8 = undefined,
    stop: bool = false,

    fn append(self: *Emit, parsed: event.RawEvent) !void {
        if (self.stop) return;
        if (self.opts.markers_only and parsed.kind != .marker) return;
        var line = Writer.fixed(&self.line_buffer);
        try event.writeJson(&line, parsed);
        try line.writeByte('\n');
        const bytes = line.buffered();
        if (self.opts.max_events != 0 and self.stats.emitted_events >= self.opts.max_events) {
            self.stats.truncated = true;
            self.stop = true;
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "capture_truncated reason=max_events limit={d} dropped=1",
                .{self.opts.max_events},
            ) catch "capture_truncated reason=max_events dropped=1";
            try writeMarker(self.out, detail);
            return;
        }
        if (self.opts.max_bytes != 0 and self.stats.emitted_bytes + bytes.len > self.opts.max_bytes) {
            self.stats.truncated = true;
            self.stop = true;
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "capture_truncated reason=max_bytes limit={d} dropped=1",
                .{self.opts.max_bytes},
            ) catch "capture_truncated reason=max_bytes dropped=1";
            try writeMarker(self.out, detail);
            return;
        }
        try self.out.writeAll(bytes);
        self.stats.emitted_events += 1;
        self.stats.emitted_bytes += bytes.len;
        if (parsed.kind == .marker) {
            const magnitude = event.lossMagnitude(parsed.detail);
            if (std.mem.indexOf(u8, parsed.detail, "loss") != null) {
                self.stats.sample_loss += magnitude;
            }
        }
    }
};

pub fn extract(io: std.Io, allocator: std.mem.Allocator, opts: Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeTo(io, allocator, opts, &out.writer);
    return out.toOwnedSlice();
}

/// Stream the extracted window to a writer. Segment data is released after
/// each segment; compact records are decoded block by block.
pub fn writeTo(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: Options,
    w: *Writer,
) !void {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{opts.dir});
    defer allocator.free(manifest_path);
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse
        return error.NoRecorder;
    if (manifest.segments.len == 0) return error.NoData;

    var stats: Stats = .{};
    var emit = Emit{ .out = w, .opts = opts, .stats = &stats };
    defer {
        if (opts.stats) |pointer| pointer.* = stats;
    }

    const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    const window_ns = std.math.mul(u64, opts.last_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    const cutoff_wall = now_wall -| window_ns;

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
        try writeMarker(w, detail);
    }

    for (manifest.segments) |segment| {
        if (emit.stop) break;
        if (!safety.isSafeRelative(segment.path)) {
            try writeMarker(w, "capture_invalid_segment_path");
            continue;
        }
        const segment_end = if (segment.end_wall_ns == 0) now_wall else segment.end_wall_ns;
        if (segment_end < cutoff_wall) continue;

        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.dir, segment.path });
        defer allocator.free(full);
        const cutoff_mono = if (cutoff_wall > segment.start_wall_ns)
            segment.start_mono_ns + (cutoff_wall - segment.start_wall_ns)
        else
            0;

        const codec = reader_mod.codecForPath(segment.path);
        switch (codec) {
            .compact_v1 => {
                stats.segments += 1;
                try writeCompactSegment(io, allocator, full, cutoff_mono, &emit);
            },
            .ndjson => {
                stats.segments += 1;
                stats.legacy_segments += 1;
                try writeLegacySegment(io, allocator, full, cutoff_mono, &emit);
            },
            .unknown => try writeMarker(w, "capture_unknown_segment_codec"),
        }
    }
}

fn writeCompactSegment(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    cutoff_mono: u64,
    emit: *Emit,
) !void {
    var reader = reader_mod.Reader.open(io, path) catch |open_error| switch (open_error) {
        error.FileNotFound => {
            try writeMarker(emit.out, "capture_missing_segment");
            return;
        },
        error.UnsupportedVersion => {
            try writeMarker(emit.out, "capture_unsupported_segment version=0 dropped=1");
            return;
        },
        error.InvalidSegment => {
            try writeMarker(emit.out, "capture_corrupt_segment offset=0 dropped=1");
            return;
        },
        else => {
            try writeMarker(emit.out, "capture_segment_unreadable");
            return;
        },
    };
    defer reader.deinit();
    _ = allocator;
    while (true) {
        const decoded = reader.next() catch break;
        const parsed = decoded orelse break;
        emit.stats.decoded_events += 1;
        if (parsed.ts_ns >= cutoff_mono or session_meta.isMetadata(parsed)) {
            try emit.append(parsed);
            if (emit.stop) break;
        }
    }
    switch (reader.status) {
        .dirty => {
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "capture_truncated_tail missing_footer=1 offset={d} dropped=1",
                .{reader.err_offset},
            ) catch "capture_truncated_tail missing_footer=1 dropped=1";
            try writeMarker(emit.out, detail);
        },
        .corrupt => {
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "capture_corrupt_segment offset={d} dropped=1",
                .{reader.err_offset},
            ) catch "capture_corrupt_segment dropped=1";
            try writeMarker(emit.out, detail);
        },
        .unsupported => try writeMarker(emit.out, "capture_unsupported_segment dropped=1"),
        .clean => {},
    }
}

fn writeLegacySegment(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    cutoff_mono: u64,
    emit: *Emit,
) !void {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
            try writeMarker(emit.out, "capture_missing_segment");
            return;
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            try writeMarker(emit.out, "capture_missing_segment");
            return;
        };
    defer file.close(io);
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = reader.interface.allocRemaining(allocator, .limited(32 * 1024 * 1024)) catch {
        try writeMarker(emit.out, "capture_segment_too_large");
        return;
    };
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        if (emit.stop) return;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        _ = line_arena.reset(.retain_capacity);
        const parsed = event.parseJson(line_arena.allocator(), line) catch {
            try writeMarker(emit.out, "capture_corrupt_segment_line");
            continue;
        };
        emit.stats.decoded_events += 1;
        if (parsed.ts_ns >= cutoff_mono or session_meta.isMetadata(parsed)) {
            try emit.append(parsed);
        }
    }
}

// Checks duration units and rejection of zero/overflowing values.
test "duration parser handles units" {
    try std.testing.expectEqual(@as(u64, 5), try parseDuration("5ms"));
    try std.testing.expectEqual(@as(u64, 5000), try parseDuration("5s"));
    try std.testing.expectEqual(@as(u64, 300000), try parseDuration("5m"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("nope"));
}

const segment_mod = @import("segment.zig");

fn testRoot(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-extract2-{s}-{d}", .{ tag, std.testing.random_seed });
}

fn makeDirs(allocator: std.mem.Allocator, root: []const u8) !void {
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};
}

fn cleanup(allocator: std.mem.Allocator, root: []const u8) void {
    const segments = std.fmt.allocPrint(allocator, "{s}/segments", .{root}) catch return;
    defer allocator.free(segments);
    var dir = std.Io.Dir.openDirAbsolute(std.testing.io, segments, .{ .iterate = true }) catch {
        std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
        return;
    };
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (it.next(std.testing.io) catch null) |item| {
        dir.deleteFile(std.testing.io, item.name) catch {};
    }
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}

fn nowWall(io: std.Io) u64 {
    return @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
}

fn writeManifest(io: std.Io, allocator: std.mem.Allocator, root: []const u8, segments: []const manifest_mod.Segment, started: u64) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(path);
    try manifest_mod.writeAtomic(io, allocator, path, .{
        .session_id = "extract-test",
        .state = .stopped,
        .started_wall_ns = started,
        .started_mono_ns = 0,
        .segments = segments,
    });
}

// Checks a compact segment extracts canonical NDJSON and mixed manifests keep
// the legacy line path working next to it.
test "compact and legacy segments extract together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, "mixed");
    defer allocator.free(root);
    defer cleanup(allocator, root);
    try makeDirs(allocator, root);
    const started = nowWall(std.testing.io) - 120 * std.time.ns_per_s;

    var writer = try segment_mod.Writer.create(std.testing.io, allocator, root, 0, started, 0);
    defer writer.deinit();
    try writer.writeEvent(.{ .kind = .marker, .ts_ns = 0, .cpu = -1, .pid = 7, .tid = 7, .comm = "xsprof", .detail = "capture_owner" });
    try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 61 * std.time.ns_per_s, .cpu = 0, .pid = 7, .tid = 7, .a = 9, .b = 0, .comm = "worker" });
    try writer.writeEvent(.{ .kind = .page_fault, .ts_ns = 62 * std.time.ns_per_s, .cpu = 1, .pid = 7, .tid = 7, .a = 1, .b = 1, .comm = "worker" });
    try writer.close();
    const compact_path = try allocator.dupe(u8, writer.path);

    const legacy_name = "segments/legacy-0.ndjson";
    const legacy_body =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_wakeup\",\"ts_ns\":63000000000,\"cpu\":0,\"pid\":7,\"tid\":7,\"a\":9,\"comm\":\"worker\",\"host_mutation\":false}\n";
    const legacy_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, legacy_name });
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, legacy_full, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, legacy_body);
    }
    try writeManifest(std.testing.io, allocator, root, &.{
        .{ .path = compact_path, .start_wall_ns = started, .start_mono_ns = 0, .end_wall_ns = nowWall(std.testing.io), .end_mono_ns = 70 * std.time.ns_per_s, .bytes = writer.stats.bytes, .events = 3, .closed = true },
        .{ .path = legacy_name, .start_wall_ns = started, .start_mono_ns = 0, .end_wall_ns = nowWall(std.testing.io), .end_mono_ns = 70 * std.time.ns_per_s, .bytes = legacy_body.len, .events = 1, .closed = true },
    }, started);

    var stats: Stats = .{};
    const data = try extract(std.testing.io, allocator, .{ .dir = root, .last_ms = 60_000, .stats = &stats });
    try std.testing.expect(std.mem.indexOf(u8, data, "capture_owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"sched_switch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"page_fault\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"sched_wakeup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "capture_corrupt") == null);
    try std.testing.expectEqual(@as(u32, 2), stats.segments);
    try std.testing.expectEqual(@as(u32, 1), stats.legacy_segments);
}

// Checks a torn compact tail produces one explicit marker and keeps the prefix.
test "torn compact tail is an explicit gap marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, "torn");
    defer allocator.free(root);
    defer cleanup(allocator, root);
    try makeDirs(allocator, root);
    const started = nowWall(std.testing.io) - 120 * std.time.ns_per_s;
    const mono = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, std.testing.io).nanoseconds)));
    var writer = try segment_mod.Writer.create(std.testing.io, allocator, root, 0, started, mono - 120 * std.time.ns_per_s);
    defer writer.deinit();
    var index: u64 = 0;
    while (index < 4000) : (index += 1) {
        try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = mono + index * 250, .cpu = 0, .pid = 7, .tid = 7, .a = index, .comm = "worker" });
    }
    try writer.close();
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(full);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    {
        const file = try std.Io.Dir.createFileAbsolute(std.testing.io, full, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, bytes[0 .. bytes.len - 5]);
    }
    try writeManifest(std.testing.io, allocator, root, &.{
        .{ .path = writer.path, .start_wall_ns = started, .start_mono_ns = 0, .end_wall_ns = nowWall(std.testing.io), .end_mono_ns = 70 * std.time.ns_per_s, .bytes = bytes.len, .events = 4000, .closed = true },
    }, started);
    var stats: Stats = .{};
    const data = try extract(std.testing.io, allocator, .{ .dir = root, .last_ms = 120_000, .stats = &stats });
    try std.testing.expect(std.mem.indexOf(u8, data, "capture_truncated_tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"event\":\"sched_switch\"") != null);
    try std.testing.expect(stats.truncated == false);
}

// Checks markers-only and max_events bounds on the same state.
test "markers only and max events are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator, "bounds");
    defer allocator.free(root);
    defer cleanup(allocator, root);
    try makeDirs(allocator, root);
    const started = nowWall(std.testing.io) - 120 * std.time.ns_per_s;
    var writer = try segment_mod.Writer.create(std.testing.io, allocator, root, 0, started, 0);
    defer writer.deinit();
    try writer.writeEvent(.{ .kind = .marker, .ts_ns = 0, .detail = "capture_owner", .comm = "xsprof", .pid = 7, .tid = 7 });
    try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 1_000_000, .cpu = 0, .pid = 7, .tid = 7, .a = 1, .comm = "worker" });
    try writer.writeEvent(.{ .kind = .marker, .ts_ns = 2_000_000, .detail = "sample_loss dropped=5" });
    try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 3_000_000, .cpu = 0, .pid = 7, .tid = 7, .a = 1, .comm = "worker" });
    try writer.close();
    try writeManifest(std.testing.io, allocator, root, &.{
        .{ .path = writer.path, .start_wall_ns = started, .start_mono_ns = 0, .end_wall_ns = nowWall(std.testing.io), .end_mono_ns = 70 * std.time.ns_per_s, .bytes = writer.stats.bytes, .events = 4, .closed = true },
    }, started);

    var stats: Stats = .{};
    const markers = try extract(std.testing.io, allocator, .{ .dir = root, .last_ms = 120_000, .markers_only = true, .stats = &stats });
    try std.testing.expect(std.mem.indexOf(u8, markers, "\"event\":\"sched_switch\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, markers, "sample_loss") != null);
    try std.testing.expectEqual(@as(u64, 5), stats.sample_loss);

    var limited_stats: Stats = .{};
    const limited = try extract(std.testing.io, allocator, .{ .dir = root, .last_ms = 120_000, .max_events = 1, .stats = &limited_stats });
    try std.testing.expect(std.mem.indexOf(u8, limited, "capture_truncated reason=max_events") != null);
    try std.testing.expect(limited_stats.truncated);
    try std.testing.expectEqual(@as(u64, 1), limited_stats.emitted_events);
}
