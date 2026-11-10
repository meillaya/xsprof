//! Bounded recorder window loader for the UI and the loopback HTTP bridge.
//! It never materializes an unbounded NDJSON window: extraction stops at
//! max_events/max_bytes with an explicit capture_truncated marker, and the
//! returned data stays canonical xsprof/event/v1 NDJSON.

const std = @import("std");
const extract = @import("extract.zig");
const manifest_mod = @import("manifest.zig");

pub const default_last_ms: u64 = 10 * 60 * 1000;
pub const default_max_events: u64 = 2_000_000;
pub const default_max_bytes: u64 = 128 * 1024 * 1024;

pub const Options = struct {
    dir: []const u8,
    last_ms: u64 = default_last_ms,
    max_events: u64 = default_max_events,
    max_bytes: u64 = default_max_bytes,
};

pub const Result = struct {
    /// Canonical xsprof/event/v1 NDJSON. The caller owns and frees it.
    data: []u8,
    events: u64 = 0,
    bytes: u64 = 0,
    decoded_events: u64 = 0,
    truncated: bool = false,
    sample_loss: u64 = 0,
    covered_ms: u64 = 0,
    segments: u32 = 0,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stats: extract.Stats = .{};
    try extract.writeTo(io, allocator, .{
        .dir = opts.dir,
        .last_ms = opts.last_ms,
        .max_events = opts.max_events,
        .max_bytes = opts.max_bytes,
        .stats = &stats,
    }, &out.writer);
    const data = try out.toOwnedSlice();
    const coverage = readCoverage(io, allocator, opts.dir, opts.last_ms) catch Coverage{};
    return .{
        .data = data,
        .events = stats.emitted_events,
        .bytes = stats.emitted_bytes,
        .decoded_events = stats.decoded_events,
        .truncated = stats.truncated,
        .sample_loss = stats.sample_loss,
        .covered_ms = coverage.covered_ms,
        .segments = coverage.segments,
    };
}

const Coverage = struct {
    covered_ms: u64 = 0,
    segments: u32 = 0,
};

fn readCoverage(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    last_ms: u64,
) !Coverage {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{dir});
    defer allocator.free(manifest_path);
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse return .{};
    var oldest: u64 = std.math.maxInt(u64);
    var newest: u64 = 0;
    for (manifest.segments) |segment| {
        oldest = @min(oldest, segment.start_wall_ns);
        const end = if (segment.end_wall_ns != 0)
            segment.end_wall_ns
        else if (manifest.updated_wall_ns != 0)
            manifest.updated_wall_ns
        else
            segment.start_wall_ns;
        newest = @max(newest, end);
    }
    const span_ms: u64 = if (newest > oldest) (newest - oldest) / std.time.ns_per_ms else 0;
    return .{ .covered_ms = @min(span_ms, last_ms), .segments = @intCast(manifest.segments.len) };
}

fn testRoot(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-window-{d}", .{std.testing.random_seed});
}

const segment_mod = @import("segment.zig");

// Checks the bounded loader returns canonical events, coverage, and truncation.
test "window load is bounded and reports coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator);
    defer allocator.free(root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    defer {
        const segments_path = std.fmt.allocPrint(allocator, "{s}/segments", .{root}) catch null;
        if (segments_path) |path| {
            std.Io.Dir.deleteDirAbsolute(std.testing.io, path) catch {};
            allocator.free(path);
        }
        std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
    }
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};

    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, std.testing.io).nanoseconds)));
    const started = now - 120 * std.time.ns_per_s;
    var writer = try segment_mod.Writer.create(std.testing.io, allocator, root, 0, started, 0);
    defer writer.deinit();
    // Keep event timestamps well above the test's wall-derived cutoff: the
    // loader maps the 120 s wall window into segment monotonic time, and a
    // few milliseconds of scheduling jitter between setup and load must not
    // drop the events the test asserts on (CI failed on exactly that race).
    try writer.writeEvent(.{ .kind = .marker, .ts_ns = 0, .detail = "capture_owner", .comm = "xsprof", .pid = 7, .tid = 7 });
    var index: u64 = 0;
    while (index < 5) : (index += 1) {
        try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = 60 * std.time.ns_per_s + index * 1000, .cpu = 0, .pid = 7, .tid = 7, .a = index, .comm = "worker" });
    }
    try writer.close();
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(manifest_path);
    try manifest_mod.writeAtomic(std.testing.io, allocator, manifest_path, .{
        .session_id = "window-test",
        .state = .stopped,
        .started_wall_ns = started,
        .started_mono_ns = 0,
        .raw_codec = "compact_v1",
        .segments = &.{.{
            .path = writer.path,
            .start_wall_ns = started,
            .start_mono_ns = 0,
            .end_wall_ns = now,
            .end_mono_ns = 10 * std.time.ns_per_s,
            .bytes = writer.stats.bytes,
            .events = writer.stats.events,
            .closed = true,
            .codec = "compact_v1",
        }},
    });

    const result = try load(std.testing.io, allocator, .{ .dir = root, .last_ms = 120_000 });
    try std.testing.expect(result.events >= 6);
    try std.testing.expect(result.covered_ms > 0);
    try std.testing.expect(!result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.data, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.data, "\"event\":\"sched_switch\"") != null);

    const limited = try load(std.testing.io, allocator, .{ .dir = root, .last_ms = 120_000, .max_events = 2 });
    try std.testing.expect(limited.truncated);
    try std.testing.expect(std.mem.indexOf(u8, limited.data, "capture_truncated reason=max_events") != null);
}
