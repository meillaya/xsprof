//! Raw-tier retention: a pure planner plus its delete application.
//!
//! `plan` decides which of the oldest closed segments must go (byte budget or
//! age cap) without touching the filesystem, so the policy is table-testable.
//! `apply` executes one attempt: it deletes what the plan kept eligible and
//! reports a failed delete instead of silently stopping the trim. A failed
//! delete leaves the segment in the manifest so the next rotation retries it.

const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const Options = struct {
    max_bytes: u64,
    max_age_ms: u64,
    now_wall_ns: u64,
};

/// Pure planning result. The dropped list is the oldest prefix
/// `[0..drop_count)`; everything from `drop_count` on is kept, including the
/// segment the caller is writing.
pub const Plan = struct {
    drop_count: usize = 0,
    dropped_bytes: u64 = 0,
    dropped_events: u64 = 0,
    kept_bytes: u64 = 0,
    kept_events: u64 = 0,

    pub fn trims(self: Plan) bool {
        return self.drop_count != 0;
    }

    /// The kept tail of a segment list the plan was computed from.
    pub fn keptSegments(self: Plan, segments: []const manifest_mod.Segment) []const manifest_mod.Segment {
        return segments[self.drop_count..];
    }
};

pub fn plan(
    segments: []const manifest_mod.Segment,
    current: usize,
    options: Options,
) Plan {
    var result = Plan{
        .kept_bytes = total(segments, .bytes),
        .kept_events = total(segments, .events),
    };
    const max_age_ns = std.math.mul(u64, options.max_age_ms, std.time.ns_per_ms) catch
        std.math.maxInt(u64);
    // The current segment (normally the last one) is never a drop candidate.
    const limit = @min(current, segments.len -| 1);
    while (result.drop_count < limit) {
        const oldest = segments[result.drop_count];
        if (!oldest.closed) break;
        const too_old = oldest.end_wall_ns != 0 and
            options.now_wall_ns > oldest.end_wall_ns +| max_age_ns;
        const over_budget = result.kept_bytes > options.max_bytes;
        if (!too_old and !over_budget) break;
        result.drop_count += 1;
        result.dropped_bytes +|= oldest.bytes;
        result.dropped_events +|= oldest.events;
        result.kept_bytes -|= oldest.bytes;
        result.kept_events -|= oldest.events;
    }
    return result;
}

pub const ApplyResult = struct {
    dropped: usize = 0,
    dropped_bytes: u64 = 0,
    dropped_events: u64 = 0,
    /// A failed delete keeps the segment in the manifest and is retried on the
    /// next rotation. The caller still emits exactly one marker for this attempt.
    failed_path: ?[]const u8 = null,
    failed_error: ?anyerror = null,

    /// True when this attempt changed or tried to change retention and owes an
    /// explicit `retention_loss` marker.
    pub fn trimmed(self: ApplyResult) bool {
        return self.dropped != 0 or self.failed_path != null;
    }
};

pub const max_detail_bytes = 768;

/// One retention attempt. Deleting stops at the first failure; the caller keeps
/// the manifest entry and retries on the next rotation. Returns the number of
/// dropped segments and the first failure, if any.
pub fn apply(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    segments: *std.ArrayList(manifest_mod.Segment),
    current: *usize,
    options: Options,
) !ApplyResult {
    const decision = plan(segments.items, current.*, options);
    var result = ApplyResult{};
    var remaining = decision.drop_count;
    while (remaining != 0) : (remaining -= 1) {
        const oldest = segments.items[0];
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, oldest.path });
        const deleted = deletePath(io, full);
        allocator.free(full);
        if (deleted) |_| {} else |err| switch (err) {
            // The file is already gone: drop the stale manifest entry instead
            // of retrying it forever, and let the marker report the drop.
            error.FileNotFound => {},
            else => {
                result.failed_path = oldest.path;
                result.failed_error = err;
                return result;
            },
        }
        _ = segments.orderedRemove(0);
        if (current.* > 0) current.* -= 1;
        result.dropped += 1;
        result.dropped_bytes +|= oldest.bytes;
        result.dropped_events +|= oldest.events;
    }
    return result;
}

/// Render the one marker an attempt owes (never more than one per attempt).
pub fn writeLossDetail(w: *std.Io.Writer, result: ApplyResult) !void {
    try w.print(
        "retention_loss dropped_segments={d} dropped_bytes={d} dropped_events={d}",
        .{ result.dropped, result.dropped_bytes, result.dropped_events },
    );
    if (result.failed_path) |path| {
        try w.print(" delete_failed=1 path={s}", .{path});
        if (result.failed_error) |err| try w.print(" error={s}", .{@errorName(err)});
    }
}

fn deletePath(io: std.Io, full: []const u8) !void {
    if (std.fs.path.isAbsolute(full)) return std.Io.Dir.deleteFileAbsolute(io, full);
    return std.Io.Dir.cwd().deleteFile(io, full);
}

fn total(segments: []const manifest_mod.Segment, field: enum { bytes, events }) u64 {
    var sum: u64 = 0;
    for (segments) |segment| sum +|= switch (field) {
        .bytes => segment.bytes,
        .events => segment.events,
    };
    return sum;
}

fn testSegment(
    path: []const u8,
    start_wall: u64,
    end_wall: u64,
    bytes: u64,
    events: u64,
    closed: bool,
) manifest_mod.Segment {
    return .{
        .path = path,
        .start_wall_ns = start_wall,
        .start_mono_ns = 0,
        .end_wall_ns = end_wall,
        .end_mono_ns = 0,
        .bytes = bytes,
        .events = events,
        .closed = closed,
        .codec = "compact_v1",
    };
}

fn tmpRoot(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn createEmptyFile(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    file.close(io);
}

// Planner table: age and byte budgets only ever drop the oldest closed prefix.
test "retention planner drops the oldest closed prefix and keeps current" {
    const segments = [_]manifest_mod.Segment{
        testSegment("segments/a.xsraw", 100, 1_000, 400, 40, true),
        testSegment("segments/b.xsraw", 200, 2_000, 300, 30, true),
        testSegment("segments/c.xsraw", 300, 3_000, 100, 10, true),
    };
    // Byte budget: 800 -> 100 retains only the current segment.
    const by_budget = plan(&segments, 2, .{ .max_bytes = 200, .max_age_ms = 1_000_000, .now_wall_ns = 5_000 });
    try std.testing.expectEqual(@as(usize, 2), by_budget.drop_count);
    try std.testing.expectEqual(@as(u64, 700), by_budget.dropped_bytes);
    try std.testing.expectEqual(@as(u64, 70), by_budget.dropped_events);
    try std.testing.expectEqual(@as(u64, 100), by_budget.kept_bytes);
    try std.testing.expect(by_budget.trims());
    try std.testing.expectEqualStrings("segments/c.xsraw", by_budget.keptSegments(&segments)[0].path);

    // Byte budget large enough: nothing is dropped.
    const no_trim = plan(&segments, 2, .{ .max_bytes = 1_000, .max_age_ms = 1_000_000, .now_wall_ns = 5_000 });
    try std.testing.expectEqual(@as(usize, 0), no_trim.drop_count);
    try std.testing.expectEqual(@as(u64, 800), no_trim.kept_bytes);

    // Age cap: a one-second cap at now=10s drops a and b, keeps the current one.
    const by_age = plan(&segments, 2, .{ .max_bytes = 1_000_000, .max_age_ms = 1_000, .now_wall_ns = 10_000_000_000 });
    try std.testing.expectEqual(@as(usize, 2), by_age.drop_count);
    try std.testing.expectEqual(@as(u64, 700), by_age.dropped_bytes);
}

test "retention planner stops at open and current segments" {
    const segments = [_]manifest_mod.Segment{
        testSegment("segments/a.xsraw", 100, 1_000, 400, 40, true),
        testSegment("segments/b.xsraw", 200, 0, 300, 30, false),
        testSegment("segments/c.xsraw", 300, 0, 100, 10, true),
    };
    const stopped = plan(&segments, 2, .{ .max_bytes = 1, .max_age_ms = 1_000_000, .now_wall_ns = 5_000 });
    try std.testing.expectEqual(@as(usize, 1), stopped.drop_count);
    try std.testing.expectEqualStrings("segments/b.xsraw", stopped.keptSegments(&segments)[0].path);

    const empty = [_]manifest_mod.Segment{};
    try std.testing.expectEqual(@as(usize, 0), plan(&empty, 0, .{ .max_bytes = 0, .max_age_ms = 0, .now_wall_ns = 9 }).drop_count);
    // The current segment is never dropped, even when it alone exceeds budget.
    try std.testing.expectEqual(@as(usize, 0), plan(&segments, 0, .{ .max_bytes = 0, .max_age_ms = 0, .now_wall_ns = 9 }).drop_count);
}

// Successful application deletes exactly the planned files and reports totals.
test "retention apply drops planned files and writes one marker decision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmpRoot(&tmp, allocator);
    defer allocator.free(root);
    const segments_dir = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_dir);
    const names = [_][]const u8{ "segments/a.xsraw", "segments/b.xsraw", "segments/c.xsraw" };
    for (names) |name| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
        defer allocator.free(full);
        try createEmptyFile(std.testing.io, full);
    }
    var segments: std.ArrayList(manifest_mod.Segment) = .empty;
    defer segments.deinit(allocator);
    try segments.append(allocator, testSegment(names[0], 100, 1_000, 400, 40, true));
    try segments.append(allocator, testSegment(names[1], 200, 2_000, 300, 30, true));
    try segments.append(allocator, testSegment(names[2], 300, 3_000, 100, 10, true));
    var current: usize = 2;

    const result = try apply(std.testing.io, allocator, root, &segments, &current, .{
        .max_bytes = 200,
        .max_age_ms = 1_000_000,
        .now_wall_ns = 5_000,
    });
    try std.testing.expectEqual(@as(usize, 2), result.dropped);
    try std.testing.expectEqual(@as(u64, 700), result.dropped_bytes);
    try std.testing.expectEqual(@as(u64, 70), result.dropped_events);
    try std.testing.expect(result.failed_path == null);
    try std.testing.expect(result.trimmed());
    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqualStrings("segments/c.xsraw", segments.items[0].path);
    for (names[0..2]) |name| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
        defer allocator.free(full);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.openFileAbsolute(std.testing.io, full, .{}));
    }
    var detail_buf: [max_detail_bytes]u8 = undefined;
    var detail_writer = std.Io.Writer.fixed(&detail_buf);
    try writeLossDetail(&detail_writer, result);
    try std.testing.expect(std.mem.indexOf(u8, detail_writer.buffered(), "retention_loss dropped_segments=2") != null);
}

// A manifest entry whose file already disappeared is dropped from the index,
// not retried forever with a fresh failure marker every rotation.
test "retention drops a stale entry whose file is already missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmpRoot(&tmp, allocator);
    defer allocator.free(root);
    const segments_dir = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_dir);
    var segments: std.ArrayList(manifest_mod.Segment) = .empty;
    defer segments.deinit(allocator);
    try segments.append(allocator, testSegment("segments/gone-0.xsraw", 1, 10, 500, 50, true));
    try segments.append(allocator, testSegment("segments/live-0.xsraw", 100, 200, 100, 10, true));
    var current: usize = 1;
    const result = try apply(std.testing.io, allocator, root, &segments, &current, .{
        .max_bytes = 200,
        .max_age_ms = 1_000_000,
        .now_wall_ns = 5_000,
    });
    try std.testing.expectEqual(@as(usize, 1), result.dropped);
    try std.testing.expect(result.failed_path == null);
    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), current);
    try std.testing.expectEqualStrings("segments/live-0.xsraw", segments.items[0].path);
}

// A failed delete is reported once per attempt, keeps the segment, and is
// retried; trimming resumes once the obstacle is gone.
test "retention delete failure marks, retries, and never silently stops" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmpRoot(&tmp, allocator);
    defer allocator.free(root);
    const segments_dir = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_dir);
    const blocked = "segments/blocked-0.xsraw";
    const blocked_full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, blocked });
    defer allocator.free(blocked_full);
    // A directory at the segment path makes delete fail deterministically.
    try std.Io.Dir.cwd().createDirPath(std.testing.io, blocked_full);
    var segments: std.ArrayList(manifest_mod.Segment) = .empty;
    defer segments.deinit(allocator);
    try segments.append(allocator, testSegment(blocked, 1, 10, 500, 50, true));
    try segments.append(allocator, testSegment("segments/new-0.xsraw", 100, 200, 100, 10, true));
    var current: usize = 1;
    const options = Options{ .max_bytes = 200, .max_age_ms = 10 * 60 * 1000, .now_wall_ns = 1_000_000_000 };

    const first = try apply(std.testing.io, allocator, root, &segments, &current, options);
    try std.testing.expectEqual(@as(usize, 0), first.dropped);
    try std.testing.expectEqualStrings(blocked, first.failed_path.?);
    try std.testing.expect(first.trimmed());
    try std.testing.expectEqual(@as(usize, 2), segments.items.len);
    try std.testing.expectEqual(@as(usize, 1), current);
    var detail_buf: [max_detail_bytes]u8 = undefined;
    var detail_writer = std.Io.Writer.fixed(&detail_buf);
    try writeLossDetail(&detail_writer, first);
    const detail = detail_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, detail, "retention_loss") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "delete_failed=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "blocked-0.xsraw") != null);

    // Every rotation retries the same delete instead of silently giving up.
    const second = try apply(std.testing.io, allocator, root, &segments, &current, options);
    try std.testing.expectEqualStrings(blocked, second.failed_path.?);
    try std.testing.expectEqual(@as(usize, 2), segments.items.len);

    // Once the obstacle is replaced by a real file, trimming succeeds.
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, blocked_full);
    try createEmptyFile(std.testing.io, blocked_full);
    const third = try apply(std.testing.io, allocator, root, &segments, &current, options);
    try std.testing.expectEqual(@as(usize, 1), third.dropped);
    try std.testing.expect(third.failed_path == null);
    try std.testing.expectEqual(@as(usize, 1), segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), current);
}
