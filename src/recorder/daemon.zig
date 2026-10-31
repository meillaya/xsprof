//! Foreground recorder daemon. One capture owner writes append-only segments,
//! keeps a durable manifest, and never mutates host policy.

const std = @import("std");
const builtin = @import("builtin");
const live = @import("../capture/live.zig");
const manifest_mod = @import("manifest.zig");
const segment_mod = @import("segment.zig");
const sidecar = @import("sidecar.zig");

const segment_bytes = 16 * 1024 * 1024;
const segment_age_ms = 30 * 1000;
const manifest_interval_ms = 1000;
const default_max_bytes = 2 * 1024 * 1024 * 1024;
const default_max_age_ms = 10 * 60 * 1000;
const max_seq = 999_999;
const poll_ms = 100;
const idle_sleep_ms = 5;

pub const Options = struct {
    dir: ?[]const u8 = null,
    max_bytes: u64 = default_max_bytes,
    max_age_ms: u64 = default_max_age_ms,
    duration_ms: ?u32 = null,
    live_options: live.Options = .{},
};

pub const Result = struct {
    state: live.State,
    reason: []const u8 = "",
    dir: []const u8 = "",
    session_id: []const u8 = "",
    events: u64 = 0,
    bytes: u64 = 0,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    if (builtin.os.tag != .linux) {
        return .{ .state = .SKIP, .reason = "recorder daemon is Linux-only" };
    }
    const probe = try live.probe(io, allocator);
    if (probe.state != .READY) return .{ .state = probe.state, .reason = probe.reason };

    const dir = try resolveDir(allocator, opts.dir);
    try ensureLayout(io, dir);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/lock", .{dir});
    defer allocator.free(lock_path);
    const lock_file = std.Io.Dir.createFileAbsolute(io, lock_path, .{}) catch |err| {
        return .{ .state = .SKIP, .reason = @errorName(err), .dir = dir };
    };
    defer lock_file.close(io);
    const lock_rc = std.os.linux.flock(lock_file.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (std.os.linux.errno(lock_rc) != .SUCCESS) {
        return .{ .state = .REFUSE, .reason = "another recorder holds the state lock", .dir = dir };
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(manifest_path);
    const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    const now_mono = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));

    var segments: std.ArrayList(manifest_mod.Segment) = .empty;
    defer segments.deinit(allocator);
    var previous_session: ?[]const u8 = null;
    if (try manifest_mod.read(io, allocator, manifest_path)) |existing| {
        if (existing.state == .recording) {
            previous_session = existing.session_id;
            try segments.appendSlice(allocator, existing.segments);
            if (segments.items.len != 0) {
                const last = &segments.items[segments.items.len - 1];
                last.closed = true;
                last.end_wall_ns = now_wall;
                last.end_mono_ns = now_mono;
            }
        }
    }

    var sequence: u32 = 0;
    var segment = try segment_mod.Writer.create(io, allocator, dir, sequence, now_wall, now_mono);
    defer segment.deinit();
    const segment_path = try allocator.dupe(u8, segment.path);
    try segments.append(allocator, .{
        .path = segment_path,
        .start_wall_ns = now_wall,
        .start_mono_ns = now_mono,
    });
    var current: usize = segments.items.len - 1;

    var manifest = manifest_mod.Manifest{
        .session_id = try newSessionId(io, allocator),
        .started_wall_ns = now_wall,
        .started_mono_ns = now_mono,
        .segments = segments.items,
        .max_bytes = opts.max_bytes,
        .max_age_ms = opts.max_age_ms,
    };
    try writeManifest(io, allocator, manifest_path, manifest);

    var capture = live.Capture.open(io, allocator, opts.live_options) catch |err| {
        try segment.close();
        manifest.state = .failed;
        manifest.updated_wall_ns = now_wall;
        manifest.segments = segments.items;
        try writeManifest(io, allocator, manifest_path, manifest);
        return .{ .state = .REFUSE, .reason = @errorName(err), .dir = dir, .session_id = manifest.session_id };
    };
    defer capture.deinit();

    if (previous_session) |session_id| {
        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buf,
            "capture_interrupted previous_session={s}",
            .{session_id},
        ) catch "capture_interrupted";
        try segment.writeEvent(.{
            .kind = .marker,
            .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
            .cpu = -1,
            .detail = detail,
        });
    }
    try segment.writeEvent(.{
        .kind = .marker,
        .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
        .cpu = -1,
        .detail = "capture_start",
    });

    var last_manifest = now_mono;
    var segment_started = now_mono;
    const deadline: i96 = if (opts.duration_ms) |duration|
        @as(i96, @intCast(now_mono)) + @as(i96, duration) * std.time.ns_per_ms
    else
        std.math.maxInt(i96);
    var total_events: u64 = 0;

    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline) {
        const poll_result = capture.poll(poll_ms) catch {
            break;
        };
        if (poll_result > 0) {
            var batch = try capture.take();
            defer batch.deinit();
            for (batch.events) |entry| {
                try segment.writeEvent(entry);
                total_events += 1;
            }
            if (batch.lost != 0) {
                var detail_buf: [96]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "sample_loss perf_ring lost={d}",
                    .{batch.lost},
                ) catch "sample_loss perf_ring";
                try segment.writeEvent(.{
                    .kind = .marker,
                    .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                    .cpu = -1,
                    .detail = detail,
                });
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(idle_sleep_ms), .awake) catch {};
        }

        const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
        const size = segment.sizeBytes();
        if (size >= segment_bytes or now - segment_started >= segment_age_ms * std.time.ns_per_ms) {
            try segment.close();
            sidecar.writeForSegment(io, allocator, dir, segments.items[current].path) catch {};
            segment.deinit();
            segments.items[current].end_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
            segments.items[current].end_mono_ns = now;
            segments.items[current].bytes = segment.stats.bytes;
            segments.items[current].events = segment.stats.events;
            segments.items[current].closed = true;

            sequence += 1;
            if (sequence > max_seq) sequence = 0;
            const wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
            segment = try segment_mod.Writer.create(io, allocator, dir, sequence, wall, now);
            try segments.append(allocator, .{
                .path = try allocator.dupe(u8, segment.path),
                .start_wall_ns = wall,
                .start_mono_ns = now,
            });
            current = segments.items.len - 1;
            segment_started = now;
            const dropped = try enforceRetention(
                io,
                allocator,
                dir,
                &segments,
                &current,
                opts.max_bytes,
                opts.max_age_ms,
                @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds))),
            );
            if (dropped != 0) {
                var detail_buf: [64]u8 = undefined;
                const detail = std.fmt.bufPrint(
                    &detail_buf,
                    "retention_loss dropped_segments={d}",
                    .{dropped},
                ) catch "retention_loss";
                try segment.writeEvent(.{
                    .kind = .marker,
                    .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                    .cpu = -1,
                    .detail = detail,
                });
            }
            manifest.segments = segments.items;
            try writeManifest(io, allocator, manifest_path, manifest);
        }

        if (now - last_manifest >= manifest_interval_ms * std.time.ns_per_ms) {
            manifest.updated_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
            manifest.segments = segments.items;
            segments.items[current].bytes = segment.stats.bytes;
            segments.items[current].events = segment.stats.events;
            try writeManifest(io, allocator, manifest_path, manifest);
            last_manifest = now;
        }
    }

    try segment.writeEvent(.{
        .kind = .marker,
        .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
        .cpu = -1,
        .detail = "capture_stop",
    });
    try segment.close();
    sidecar.writeForSegment(io, allocator, dir, segments.items[current].path) catch {};
    segments.items[current].end_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    segments.items[current].end_mono_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
    segments.items[current].bytes = segment.stats.bytes;
    segments.items[current].events = segment.stats.events;
    segments.items[current].closed = true;
    manifest.state = .stopped;
    manifest.updated_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    manifest.segments = segments.items;
    try writeManifest(io, allocator, manifest_path, manifest);

    return .{
        .state = .READY,
        .reason = "recording stopped",
        .dir = dir,
        .session_id = manifest.session_id,
        .events = total_events,
        .bytes = totalBytes(segments.items),
    };
}

fn totalBytes(segments: []const manifest_mod.Segment) u64 {
    var total: u64 = 0;
    for (segments) |segment| total += segment.bytes;
    return total;
}

fn enforceRetention(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segments: *std.ArrayList(manifest_mod.Segment),
    current: *usize,
    max_bytes: u64,
    max_age_ms: u64,
    now_wall: u64,
) !usize {
    var dropped: usize = 0;
    const max_age_ns = std.math.mul(u64, max_age_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    while (segments.items.len > 1) {
        const oldest = segments.items[0];
        if (!oldest.closed) break;
        const too_old = oldest.end_wall_ns != 0 and now_wall > oldest.end_wall_ns +| max_age_ns;
        const over_budget = totalBytes(segments.items) > max_bytes;
        if (!too_old and !over_budget) break;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, oldest.path });
        defer allocator.free(full);
        std.Io.Dir.deleteFileAbsolute(io, full) catch break;
        _ = segments.orderedRemove(0);
        if (current.* > 0) current.* -= 1;
        dropped += 1;
    }
    return dropped;
}

fn resolveDir(allocator: std.mem.Allocator, explicit: ?[]const u8) ![]const u8 {
    if (explicit) |dir| return allocator.dupe(u8, dir);
    if (std.c.getenv("XDG_STATE_HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/xsprof", .{std.mem.span(value)});
    }
    if (std.c.getenv("HOME")) |value| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/xsprof", .{std.mem.span(value)});
    }
    return error.NoStateDirectory;
}

fn ensureLayout(io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const segments = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/segments", .{dir});
    defer std.heap.smp_allocator.free(segments);
    try std.Io.Dir.cwd().createDirPath(io, segments);
    const metrics = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}/metrics", .{dir});
    defer std.heap.smp_allocator.free(metrics);
    try std.Io.Dir.cwd().createDirPath(io, metrics);
}

fn newSessionId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var bytes: [8]u8 = undefined;
    std.Io.randomSecure(io, &bytes) catch {
        @memset(&bytes, 0);
    };
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = hex[byte >> 4];
        out[index * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

fn writeManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: manifest_mod.Manifest,
) !void {
    try manifest_mod.writeAtomic(io, allocator, path, manifest);
}

// Checks that the daemon fails closed off Linux with a reason.
test "daemon skips off Linux" {
    if (builtin.os.tag != .linux) {
        const result = try run(std.testing.io, std.testing.allocator, .{});
        try std.testing.expectEqual(live.State.SKIP, result.state);
    }
}
