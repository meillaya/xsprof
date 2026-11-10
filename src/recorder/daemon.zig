//! Foreground recorder daemon. One capture owner writes append-only segments,
//! keeps a durable manifest, and never mutates host policy.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const live = @import("../capture/live.zig");
const capture_meta = @import("../capture/session_meta.zig");
const compact = @import("compact.zig");
const manifest_mod = @import("manifest.zig");
const segment_mod = @import("segment.zig");
const reader_mod = @import("segment_reader.zig");
const retention_mod = @import("retention.zig");
const sidecar = @import("sidecar.zig");
const metrics_mod = @import("../analyze/metrics.zig");
const overhead = @import("../os/linux/overhead.zig");
const signal = @import("signal.zig");

const segment_bytes = 16 * 1024 * 1024;
const segment_age_ms = 30 * 1000;
const manifest_interval_ms = 1000;
const default_max_bytes = 2 * 1024 * 1024 * 1024;
const default_max_age_ms = 10 * 60 * 1000;
const default_history_interval_ms = 60 * 1000;
const default_history_retain_ms = 24 * 60 * 60 * 1000;
const max_seq = 999_999;
const poll_ms = 100;
const idle_sleep_ms = 5;

pub const Options = struct {
    dir: ?[]const u8 = null,
    max_bytes: u64 = default_max_bytes,
    max_age_ms: u64 = default_max_age_ms,
    history_interval_ms: u64 = default_history_interval_ms,
    history_retain_ms: u64 = default_history_retain_ms,
    duration_ms: ?u32 = null,
    /// Optional cooperative stop owned by an in-process UI worker. When set,
    /// the daemon does not install process signal handlers.
    stop: ?*std.atomic.Value(bool) = null,
    live_options: live.Options = .{},
};

pub const Result = struct {
    state: live.State,
    reason: []const u8 = "",
    dir: []const u8 = "",
    session_id: []const u8 = "",
    events: u64 = 0,
    bytes: u64 = 0,
    history_sidecars: u64 = 0,
    history_dropped: u64 = 0,
    sidecar_errors: u64 = 0,
    /// Orphan `.xsraw` segments adopted into the manifest on this start.
    recovered_orphans: u64 = 0,
    overhead: overhead.Report = .{},
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    if (builtin.os.tag != .linux) {
        return .{ .state = .SKIP, .reason = "recorder daemon is Linux-only" };
    }
    const meter = overhead.Meter.start(io, allocator);
    var signal_guard: ?signal.Guard = null;
    if (opts.stop == null) signal_guard = signal.install();
    defer if (signal_guard) |*guard| guard.deinit();
    const stopped = struct {
        fn requested(opts_in: Options) bool {
            if (signal.requested()) return true;
            if (opts_in.stop) |flag| return flag.load(.acquire);
            return false;
        }
    };
    // The daemon is long-lived: capture batches and sidecars must return
    // memory to a freeing allocator, not the CLI's per-process arena.
    const runtime_allocator = std.heap.smp_allocator;
    var meta_arena = std.heap.ArenaAllocator.init(runtime_allocator);
    defer meta_arena.deinit();
    const meta_events = capture_meta.collect(io, meta_arena.allocator()) catch &.{};
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
    var previous_tail: ?reader_mod.Status = null;
    if (try manifest_mod.read(io, allocator, manifest_path)) |existing| {
        if (existing.state == .recording) {
            previous_session = existing.session_id;
            try segments.appendSlice(allocator, existing.segments);
            if (segments.items.len != 0) {
                const last = &segments.items[segments.items.len - 1];
                last.closed = true;
                last.end_wall_ns = now_wall;
                last.end_mono_ns = now_mono;
                previous_tail = tailStatusFor(io, allocator, dir, last.*) catch .dirty;
            }
        }
    }

    // A crash between segment creation and the manifest rename leaves a
    // `.xsraw` file the manifest never learned about. Adopt those files into
    // the durable index before this session starts, so extract/verify see them
    // and retention can eventually age them out. Unknown files are left alone.
    const recovery = try reconcileSegments(io, allocator, dir, &segments, now_wall);

    var sequence: u32 = 0;
    var segment = try segment_mod.Writer.create(io, runtime_allocator, dir, sequence, now_wall, now_mono);
    defer segment.deinit();
    var segment_arena = std.heap.ArenaAllocator.init(runtime_allocator);
    var segment_metrics = metrics_mod.Index.init(segment_arena.allocator());
    defer {
        segment_metrics.deinit();
        segment_arena.deinit();
    }
    const segment_path = try allocator.dupe(u8, segment.path);
    try segments.append(allocator, .{
        .path = segment_path,
        .start_wall_ns = now_wall,
        .start_mono_ns = now_mono,
        .codec = "compact_v1",
    });
    var current: usize = segments.items.len - 1;

    var manifest = manifest_mod.Manifest{
        .session_id = try newSessionId(io, allocator),
        .started_wall_ns = now_wall,
        .started_mono_ns = now_mono,
        .segments = segments.items,
        .max_bytes = opts.max_bytes,
        .max_age_ms = opts.max_age_ms,
        .raw_codec = "compact_v1",
        .history_interval_ms = opts.history_interval_ms,
        .history_retain_ms = opts.history_retain_ms,
    };
    try writeManifest(io, allocator, manifest_path, manifest);

    var capture = live.Capture.open(io, runtime_allocator, opts.live_options) catch |err| {
        try segment.close();
        manifest.state = .failed;
        manifest.updated_wall_ns = now_wall;
        manifest.segments = segments.items;
        try writeManifest(io, allocator, manifest_path, manifest);
        return .{
            .state = .REFUSE,
            .reason = @errorName(err),
            .dir = dir,
            .session_id = manifest.session_id,
            .recovered_orphans = recovery.adopted,
            .overhead = meter.finish(io, allocator, 0, 0),
        };
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
    if (previous_tail) |status| {
        switch (status) {
            .clean => {},
            .dirty => try segment.writeEvent(.{
                .kind = .marker,
                .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                .cpu = -1,
                .detail = "capture_truncated_tail missing_footer=1 dropped=1",
            }),
            .corrupt => try segment.writeEvent(.{
                .kind = .marker,
                .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                .cpu = -1,
                .detail = "capture_corrupt_segment dropped=1",
            }),
            .unsupported => try segment.writeEvent(.{
                .kind = .marker,
                .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                .cpu = -1,
                .detail = "capture_unsupported_segment dropped=1",
            }),
        }
    }
    if (recovery.shouldAnnotate()) {
        var recovery_buf: [160]u8 = undefined;
        try segment.writeEvent(.{
            .kind = .marker,
            .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
            .cpu = -1,
            .detail = recoveryDetail(&recovery_buf, recovery),
        });
    }
    try writeMeta(&segment, &segment_metrics, meta_events);
    try segment.writeEvent(.{
        .kind = .marker,
        .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
        .cpu = -1,
        .detail = "capture_start",
    });

    var last_manifest = now_mono;
    var segment_started = now_mono;
    var history_started = now_mono;
    const deadline: i96 = if (opts.duration_ms) |duration|
        @as(i96, @intCast(now_mono)) + @as(i96, duration) * std.time.ns_per_ms
    else
        std.math.maxInt(i96);
    var total_events: u64 = 0;
    var history_sidecars: u64 = 0;
    var history_dropped: u64 = 0;
    var sidecar_errors: u64 = 0;

    while (std.Io.Clock.now(.awake, io).nanoseconds < deadline and !stopped.requested(opts)) {
        const poll_result = capture.poll(poll_ms) catch {
            break;
        };
        if (poll_result > 0) {
            var batch = try capture.take();
            defer batch.deinit();
            try segment_metrics.append(batch.events);
            for (batch.events) |entry| {
                try segment.writeEvent(entry);
                total_events += 1;
            }
        } else {
            std.Io.sleep(io, .fromMilliseconds(idle_sleep_ms), .awake) catch {};
        }

        const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));
        const size = segment.sizeBytes();
        if (size >= segment_bytes or now - segment_started >= segment_age_ms * std.time.ns_per_ms) {
            try segment.close();
            if (now - history_started >= opts.history_interval_ms * std.time.ns_per_ms) {
                if (writeSidecar(io, dir, segments.items[current].path, &segment_metrics, &segment_arena)) {
                    history_sidecars += 1;
                } else {
                    sidecar_errors += 1;
                }
                history_dropped += sidecar.prune(
                    io,
                    dir,
                    opts.history_retain_ms,
                    @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds))),
                ) catch 0;
                segment_metrics.deinit();
                segment_arena.deinit();
                segment_arena = std.heap.ArenaAllocator.init(runtime_allocator);
                segment_metrics = metrics_mod.Index.init(segment_arena.allocator());
                history_started = now;
            }
            segment.deinit();
            segments.items[current].end_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
            segments.items[current].end_mono_ns = now;
            segments.items[current].bytes = segment.stats.bytes;
            segments.items[current].events = segment.stats.events;
            segments.items[current].closed = true;

            sequence += 1;
            if (sequence > max_seq) sequence = 0;
            const wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
            // Long-lived rotation must use the freeing allocator; the CLI arena
            // would accumulate one 16 KiB encoder table per segment.
            segment = try segment_mod.Writer.create(io, runtime_allocator, dir, sequence, wall, now);
            try writeMeta(&segment, &segment_metrics, meta_events);
            try segments.append(allocator, .{
                .path = try allocator.dupe(u8, segment.path),
                .start_wall_ns = wall,
                .start_mono_ns = now,
                .codec = "compact_v1",
            });
            current = segments.items.len - 1;
            segment_started = now;
            const retention_result = try retention_mod.apply(io, allocator, dir, &segments, &current, .{
                .max_bytes = opts.max_bytes,
                .max_age_ms = opts.max_age_ms,
                .now_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds))),
            });
            if (retention_result.trimmed()) {
                var detail_buf: [retention_mod.max_detail_bytes]u8 = undefined;
                var detail_writer = std.Io.Writer.fixed(&detail_buf);
                try retention_mod.writeLossDetail(&detail_writer, retention_result);
                try segment.writeEvent(.{
                    .kind = .marker,
                    .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
                    .cpu = -1,
                    .detail = detail_writer.buffered(),
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

    const stopped_by_signal = signal.requested() and opts.stop == null;
    var stop_buf: [96]u8 = undefined;
    const stop_detail = if (stopped_by_signal)
        std.fmt.bufPrint(&stop_buf, "capture_stop signal=terminated", .{}) catch "capture_stop"
    else
        "capture_stop";
    try segment.writeEvent(.{
        .kind = .marker,
        .ts_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds),
        .cpu = -1,
        .detail = stop_detail,
    });
    try segment.close();
    if (writeSidecar(io, dir, segments.items[current].path, &segment_metrics, &segment_arena)) {
        history_sidecars += 1;
    } else {
        sidecar_errors += 1;
    }
    history_dropped += sidecar.prune(
        io,
        dir,
        opts.history_retain_ms,
        @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds))),
    ) catch 0;
    segments.items[current].end_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    segments.items[current].end_mono_ns = @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
    segments.items[current].bytes = segment.stats.bytes;
    segments.items[current].events = segment.stats.events;
    segments.items[current].closed = true;
    manifest.state = .stopped;
    manifest.updated_wall_ns = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    manifest.segments = segments.items;
    try writeManifest(io, allocator, manifest_path, manifest);

    const bytes = totalBytes(segments.items);
    return .{
        .state = .READY,
        .reason = if (stopped_by_signal) "stopped by signal" else "recording stopped",
        .dir = dir,
        .session_id = manifest.session_id,
        .events = total_events,
        .bytes = bytes,
        .history_sidecars = history_sidecars,
        .history_dropped = history_dropped,
        .sidecar_errors = sidecar_errors,
        .recovered_orphans = recovery.adopted,
        .overhead = meter.finish(io, allocator, total_events, bytes),
    };
}

fn tailStatusFor(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segment: manifest_mod.Segment,
) !reader_mod.Status {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, segment.path });
    defer allocator.free(full);
    if (segment.codec.len != 0 and std.mem.eql(u8, segment.codec, "ndjson")) {
        return reader_mod.tailStatusNdjson(io, full);
    }
    if (std.mem.endsWith(u8, segment.path, ".ndjson")) {
        return reader_mod.tailStatusNdjson(io, full);
    }
    return reader_mod.tailStatus(io, full);
}

fn writeMeta(
    segment: *segment_mod.Writer,
    metrics: *metrics_mod.Index,
    events: []const event.RawEvent,
) !void {
    for (events) |entry| {
        try segment.writeEvent(entry);
        try metrics.append(&.{entry});
    }
}

fn writeSidecar(
    io: std.Io,
    dir: []const u8,
    segment_path: []const u8,
    index: *metrics_mod.Index,
    arena: *std.heap.ArenaAllocator,
) bool {
    const metrics = index.snapshot(arena.allocator()) catch return false;
    sidecar.writeMetrics(io, arena.allocator(), dir, segment_path, metrics) catch return false;
    return true;
}

fn totalBytes(segments: []const manifest_mod.Segment) u64 {
    var total: u64 = 0;
    for (segments) |segment| total += segment.bytes;
    return total;
}

const Recovery = struct {
    adopted: usize = 0,
    dirty: usize = 0,
    corrupt: usize = 0,
    unreadable: usize = 0,
    bytes: u64 = 0,
    events: u64 = 0,

    fn shouldAnnotate(self: Recovery) bool {
        return self.adopted != 0 or self.unreadable != 0;
    }
};

/// Adopt compact segment files the manifest does not know about: a crash
/// between segment creation and the manifest rename leaves one behind, and a
/// stopped session's segments stay on disk too. Unknown files are never deleted.
fn reconcileSegments(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segments: *std.ArrayList(manifest_mod.Segment),
    now_wall_ns: u64,
) !Recovery {
    var recovered = Recovery{};
    const segments_dir_path = try std.fmt.allocPrint(allocator, "{s}/segments", .{dir});
    defer allocator.free(segments_dir_path);
    var segments_dir = blk: {
        if (std.fs.path.isAbsolute(segments_dir_path)) {
            break :blk std.Io.Dir.openDirAbsolute(io, segments_dir_path, .{ .iterate = true }) catch
                return recovered;
        }
        break :blk std.Io.Dir.cwd().openDir(io, segments_dir_path, .{ .iterate = true }) catch
            return recovered;
    };
    defer segments_dir.close(io);
    var iterator = segments_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".xsraw")) continue;
        if (manifestContains(segments.items, entry.name)) continue;
        const rel = try std.fmt.allocPrint(allocator, "segments/{s}", .{entry.name});
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, rel });
        const adoption = adoptSegment(io, full, now_wall_ns) catch {
            allocator.free(rel);
            allocator.free(full);
            recovered.unreadable += 1;
            continue;
        };
        allocator.free(full);
        var adopted = adoption.segment;
        adopted.path = rel;
        segments.insert(allocator, chronologicalIndex(segments.items, adopted.start_wall_ns), adopted) catch |err| {
            allocator.free(rel);
            return err;
        };
        recovered.adopted += 1;
        recovered.bytes +|= adopted.bytes;
        recovered.events +|= adopted.events;
        switch (adoption.status) {
            .clean => {},
            .dirty => recovered.dirty += 1,
            .corrupt => recovered.corrupt += 1,
            .unsupported => recovered.unreadable += 1,
        }
    }
    return recovered;
}

const Adopted = struct {
    segment: manifest_mod.Segment,
    status: reader_mod.Status,
};

/// Cheaply index one orphan `.xsraw`: header for timing, stat for bytes, and
/// the footer for exact counts when the tail is clean. Only a dirty/corrupt
/// tail is decoded, so startup stays proportional to the crash tail.
fn adoptSegment(io: std.Io, full_path: []const u8, now_wall_ns: u64) !Adopted {
    var reader = try reader_mod.Reader.open(io, full_path);
    const header = reader.header orelse {
        reader.deinit();
        return error.InvalidSegment;
    };
    const stat = reader.file.stat(io) catch null;
    const size = if (stat) |value| value.size else reader.size;
    const mtime_ns: u64 = if (stat) |value|
        std.math.cast(u64, value.mtime.nanoseconds) orelse 0
    else
        0;
    const status = reader_mod.tailStatus(io, full_path) catch reader_mod.Status.dirty;
    var events: u64 = 0;
    if (status == .clean) {
        if (footerCounts(io, reader.file, size)) |footer| events = footer.event_count;
    }
    if (events == 0) {
        var decoded: u64 = 0;
        while (true) {
            const maybe = reader.next() catch break;
            if (maybe == null) break;
            decoded += 1;
        }
        events = decoded;
    }
    reader.deinit();
    return .{
        .status = status,
        .segment = .{
            .path = "",
            .start_wall_ns = header.start_wall_ns,
            .start_mono_ns = header.start_mono_ns,
            .end_wall_ns = @max(header.start_wall_ns, @min(mtime_ns, now_wall_ns)),
            .end_mono_ns = 0,
            .bytes = size,
            .events = events,
            .closed = true,
            .codec = "compact_v1",
        },
    };
}

/// Read the clean-close footer counts from the last 32 bytes without decoding.
fn footerCounts(io: std.Io, file: std.Io.File, size: u64) ?compact.Footer {
    const footer_total = compact.block_header_bytes + compact.footer_payload_bytes;
    if (size < compact.header_bytes + footer_total) return null;
    var buffer: [footer_total]u8 = undefined;
    const read = file.readPositionalAll(io, &buffer, size - footer_total) catch return null;
    if (read != buffer.len) return null;
    var block_header: [compact.block_header_bytes]u8 = undefined;
    @memcpy(&block_header, buffer[0..compact.block_header_bytes]);
    const parsed = compact.parseBlockHeader(&block_header) catch return null;
    if (parsed.kind != compact.block_type_footer) return null;
    var payload: [compact.footer_payload_bytes]u8 = undefined;
    @memcpy(&payload, buffer[compact.block_header_bytes..]);
    if (compact.crc(&payload) != std.mem.readInt(u32, block_header[4..][0..4], .little)) return null;
    return compact.Footer.parse(&payload);
}

fn manifestContains(segments: []const manifest_mod.Segment, name: []const u8) bool {
    for (segments) |segment| {
        if (std.mem.eql(u8, std.fs.path.basename(segment.path), name)) return true;
    }
    return false;
}

/// Manifest segments are chronological; adopted orphans are merged in place.
fn chronologicalIndex(segments: []const manifest_mod.Segment, start_wall_ns: u64) usize {
    var at = segments.len;
    while (at > 0 and segments[at - 1].start_wall_ns > start_wall_ns) : (at -= 1) {}
    return at;
}

fn recoveryDetail(buffer: *[160]u8, recovered: Recovery) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        "capture_recovered_orphan adopted={d} dirty={d} corrupt={d} unreadable={d}",
        .{ recovered.adopted, recovered.dirty, recovered.corrupt, recovered.unreadable },
    ) catch "capture_recovered_orphan";
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

fn testRootFrom(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn createTestSegment(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    sequence: u32,
    start_wall_ns: u64,
    count: u64,
    clean_close: bool,
) ![]const u8 {
    var writer = try segment_mod.Writer.create(io, allocator, root, sequence, start_wall_ns, 0);
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        try writer.writeEvent(.{
            .kind = .sched_switch,
            .ts_ns = start_wall_ns + index,
            .cpu = 0,
            .pid = 7,
            .tid = 7,
            .a = index,
            .comm = "worker",
        });
    }
    if (clean_close) try writer.close() else try writer.flush();
    const path = try allocator.dupe(u8, writer.path);
    writer.deinit();
    return path;
}

fn writeTestFile(io: std.Io, allocator: std.mem.Allocator, root: []const u8, relative: []const u8, body: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative });
    defer allocator.free(full);
    const file = try std.Io.Dir.createFileAbsolute(io, full, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

// Checks that a restart adopts unknown compact segments (including a dirty
// crash tail) chronologically, reports them, and leaves other files untouched.
test "daemon restart reconciles manifest orphans and annotates the count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // The adopted manifest entries keep their path strings for the session's
    // lifetime, so the test lets an arena own them.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRootFrom(&tmp, allocator);
    defer allocator.free(root);
    const segments_path = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments_path);
    try std.Io.Dir.cwd().createDirPath(io, segments_path);

    const known_path = try createTestSegment(io, allocator, root, 0, 1_000, 3, true);
    defer allocator.free(known_path);
    const orphan_path = try createTestSegment(io, allocator, root, 1, 2_000, 5, true);
    defer allocator.free(orphan_path);
    const dirty_path = try createTestSegment(io, allocator, root, 2, 3_000, 4, false);
    defer allocator.free(dirty_path);
    try writeTestFile(io, allocator, root, "segments/truncated-0.xsraw", "short");
    try writeTestFile(io, allocator, root, "segments/notes.txt", "keep me");

    var segments: std.ArrayList(manifest_mod.Segment) = .empty;
    defer segments.deinit(allocator);
    try segments.append(allocator, .{
        .path = known_path,
        .start_wall_ns = 1_000,
        .start_mono_ns = 0,
        .end_wall_ns = 1_500,
        .bytes = 0,
        .events = 3,
        .closed = true,
        .codec = "compact_v1",
    });

    const recovered = try reconcileSegments(io, allocator, root, &segments, 10_000);
    try std.testing.expectEqual(@as(usize, 2), recovered.adopted);
    try std.testing.expectEqual(@as(usize, 1), recovered.dirty);
    try std.testing.expectEqual(@as(usize, 0), recovered.corrupt);
    try std.testing.expectEqual(@as(usize, 1), recovered.unreadable);
    try std.testing.expectEqual(@as(usize, 3), segments.items.len);
    try std.testing.expectEqualStrings(known_path, segments.items[0].path);
    try std.testing.expectEqualStrings(orphan_path, segments.items[1].path);
    try std.testing.expectEqualStrings(dirty_path, segments.items[2].path);
    try std.testing.expect(segments.items[1].start_wall_ns >= segments.items[0].start_wall_ns);
    try std.testing.expect(segments.items[2].start_wall_ns >= segments.items[1].start_wall_ns);
    try std.testing.expectEqual(@as(u64, 5), segments.items[1].events);
    try std.testing.expect(segments.items[1].bytes > 0);
    try std.testing.expect(segments.items[1].closed);
    try std.testing.expectEqualStrings("compact_v1", segments.items[1].codec);
    // The dirty crash tail is adopted with its decodable prefix counted.
    try std.testing.expectEqual(@as(u64, 4), segments.items[2].events);

    // Unknown files are reported, not adopted, deleted, or rewritten.
    const notes_full = try std.fmt.allocPrint(allocator, "{s}/segments/notes.txt", .{root});
    defer allocator.free(notes_full);
    const notes = try std.Io.Dir.cwd().readFileAlloc(io, notes_full, allocator, .limited(64));
    defer allocator.free(notes);
    try std.testing.expectEqualStrings("keep me", notes);

    var detail_buf: [160]u8 = undefined;
    const detail = recoveryDetail(&detail_buf, recovered);
    try std.testing.expect(std.mem.indexOf(u8, detail, "capture_recovered_orphan") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "adopted=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "dirty=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "unreadable=1") != null);
}
