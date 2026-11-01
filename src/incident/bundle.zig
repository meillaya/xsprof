//! Incident bundle: extract the recent recorder window into one offline folder
//! with raw events, a canonical summary, a static report, and Chrome Trace.

const std = @import("std");
const chrome_trace = @import("../viz/chrome_trace.zig");
const extract = @import("../recorder/extract.zig");
const manifest_mod = @import("../recorder/manifest.zig");
const session_mod = @import("../stream/session.zig");
const advisor = @import("../analyze/advisor.zig");
const rules = @import("../analyze/rules.zig");
const summary = @import("summary.zig");

pub const max_window_bytes = 192 * 1024 * 1024;

pub const Options = struct {
    dir: []const u8,
    out: []const u8,
    last_ms: u64 = 10 * 60 * 1000,
};

pub const Result = struct {
    out: []const u8,
    summary_path: []const u8,
    report_path: []const u8,
    trace_path: []const u8,
    window_path: []const u8,
    events: usize,
    findings: usize,
    clears: usize,
    skips: usize,
};

fn join(allocator: std.mem.Allocator, out: []const u8, name: []const u8) ![]const u8 {
    const base = std.mem.trimEnd(u8, out, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

fn createFile(io: std.Io, path: []const u8) !std.Io.File {
    if (path.len != 0 and path[0] == '/') {
        return std.Io.Dir.createFileAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().createFile(io, path, .{});
}

fn writeBytes(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try createFile(io, path);
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn countStatus(report_list: []const rules.Report, status: rules.Status) usize {
    var total: usize = 0;
    for (report_list) |item| {
        if (item.status == status) total += 1;
    }
    return total;
}

pub fn write(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Result {
    const manifest_path = try join(allocator, opts.dir, "manifest.json");
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse
        return error.NoRecorder;
    const now_wall = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, io).nanoseconds)));
    const requested_ns = std.math.mul(u64, opts.last_ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
    const cutoff_wall = now_wall -| requested_ns;
    var oldest_start: u64 = std.math.maxInt(u64);
    var newest_end: u64 = 0;
    var overlapping_bytes: u64 = 0;
    for (manifest.segments) |segment| {
        oldest_start = @min(oldest_start, segment.start_wall_ns);
        const end = if (segment.end_wall_ns != 0)
            segment.end_wall_ns
        else if (manifest.updated_wall_ns != 0)
            manifest.updated_wall_ns
        else
            now_wall;
        newest_end = @max(newest_end, end);
        if (end >= cutoff_wall) overlapping_bytes +|= segment.bytes;
    }
    if (manifest.segments.len == 0 or oldest_start == std.math.maxInt(u64)) return error.NoWindow;
    // Refuse before reading a multi-gigabyte window into memory.
    if (overlapping_bytes > max_window_bytes) return error.WindowTooLarge;

    const data = try extract.extract(io, allocator, .{
        .dir = opts.dir,
        .last_ms = opts.last_ms,
    });
    if (data.len == 0) return error.NoWindow;
    if (data.len > max_window_bytes) return error.WindowTooLarge;
    const covered_start = @max(oldest_start, cutoff_wall);
    const covered_end = @min(newest_end, now_wall);
    const retained_ms = @min(
        opts.last_ms,
        if (covered_end > covered_start) (covered_end - covered_start) / std.time.ns_per_ms else 0,
    );

    var session = try session_mod.Session.fromData(allocator, "incident window", data);
    const agg = session.aggregate();
    const findings = try advisor.analyze(allocator, agg, .{});
    const report_list = try rules.reports(allocator, agg, findings);

    try std.Io.Dir.cwd().createDirPath(io, opts.out);
    const window_path = try join(allocator, opts.out, "window.ndjson");
    const summary_path = try join(allocator, opts.out, "summary.json");
    const report_path = try join(allocator, opts.out, "report.html");
    const trace_path = try join(allocator, opts.out, "trace.json");

    try writeBytes(io, window_path, data);

    const ctx: summary.Context = .{
        .source_dir = opts.dir,
        .requested_ms = opts.last_ms,
        .retained_ms = retained_ms,
        .artifacts = .{
            .report = "report.html",
            .summary = "summary.json",
            .trace = "trace.json",
            .window = "window.ndjson",
        },
    };

    {
        var text = std.Io.Writer.Allocating.init(allocator);
        defer text.deinit();
        try summary.writeJson(&text.writer, &session, findings, report_list, ctx);
        try writeBytes(io, summary_path, text.written());
    }
    {
        var text = std.Io.Writer.Allocating.init(allocator);
        defer text.deinit();
        try summary.writeHtml(&text.writer, &session, findings, report_list, ctx);
        try writeBytes(io, report_path, text.written());
    }
    {
        const file = try createFile(io, trace_path);
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try chrome_trace.writeTimeline(&writer.interface, allocator, session.events, null, null);
        try writer.interface.flush();
    }

    return .{
        .out = opts.out,
        .summary_path = summary_path,
        .report_path = report_path,
        .trace_path = trace_path,
        .window_path = window_path,
        .events = session.events.len,
        .findings = countStatus(report_list, .finding),
        .clears = countStatus(report_list, .clear),
        .skips = countStatus(report_list, .skip),
    };
}

test "bundle writes all artifacts from a recorder window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-incident-{d}", .{std.testing.random_seed});
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};

    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, std.testing.io).nanoseconds)));
    const start = now - 120 * std.time.ns_per_s;
    const body =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":0,\"cpu\":-1,\"pid\":7,\"tid\":7,\"comm\":\"xsprof\",\"detail\":\"capture_owner\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":0,\"cpu\":-1,\"detail\":\"host_memory buddy_fragmentation=0.75\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_wakeup\",\"ts_ns\":61000000000,\"cpu\":0,\"pid\":7,\"tid\":7,\"a\":9,\"comm\":\"worker\",\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_wakeup\",\"ts_ns\":62000000000,\"cpu\":0,\"pid\":7,\"tid\":7,\"a\":9,\"comm\":\"worker\",\"host_mutation\":false}\n";
    const segment_path = try std.fmt.allocPrint(allocator, "{s}/segments/0-0.ndjson", .{root});
    try writeBytes(std.testing.io, segment_path, body);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    try manifest_mod.writeAtomic(std.testing.io, allocator, manifest_path, .{
        .session_id = "incident-test",
        .state = .stopped,
        .started_wall_ns = start,
        .started_mono_ns = 0,
        .segments = &.{.{
            .path = "segments/0-0.ndjson",
            .start_wall_ns = start,
            .start_mono_ns = 0,
            .end_wall_ns = now,
            .end_mono_ns = 70 * std.time.ns_per_s,
            .bytes = body.len,
            .events = 4,
            .closed = true,
        }},
    });

    const out = try std.fmt.allocPrint(allocator, "{s}/incident", .{root});
    const result = try write(std.testing.io, allocator, .{
        .dir = root,
        .out = out,
        .last_ms = 60_000,
    });
    try std.testing.expect(result.events > 0);
    try std.testing.expect(result.findings >= 1);
    const summary_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        result.summary_path,
        allocator,
        .limited(64 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "\"schema\":\"xsprof/incident-summary/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "\"host_mutation\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_text, "\"status\":\"finding\"") != null);
    const report_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        result.report_path,
        allocator,
        .limited(64 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, report_text, "xsprof incident") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_text, "window.ndjson") != null);
    try std.testing.expect(std.mem.indexOf(u8, report_text, "<script") == null);
    const trace_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        result.trace_path,
        allocator,
        .limited(96 * 1024),
    );
    try std.testing.expect(std.mem.indexOf(u8, trace_text, "\"traceEvents\"") != null);

    std.Io.Dir.deleteFileAbsolute(std.testing.io, result.window_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, result.summary_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, result.report_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, result.trace_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, segment_path) catch {};
    std.Io.Dir.deleteFileAbsolute(std.testing.io, manifest_path) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, out) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, segments) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}

test "bundle refuses an oversized window before reading segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, "/tmp/xsprof-incident-large-{d}", .{std.testing.random_seed});
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.real, std.testing.io).nanoseconds)));
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    try manifest_mod.writeAtomic(std.testing.io, allocator, manifest_path, .{
        .session_id = "too-large",
        .state = .stopped,
        .started_wall_ns = now - 60 * std.time.ns_per_s,
        .started_mono_ns = 0,
        .updated_wall_ns = now,
        .segments = &.{.{
            .path = "segments/missing.ndjson",
            .start_wall_ns = now - 60 * std.time.ns_per_s,
            .start_mono_ns = 0,
            .end_wall_ns = now,
            .bytes = max_window_bytes + 1,
            .closed = true,
        }},
    });
    try std.testing.expectError(error.WindowTooLarge, write(std.testing.io, allocator, .{
        .dir = root,
        .out = try std.fmt.allocPrint(allocator, "{s}/bundle", .{root}),
        .last_ms = 60_000,
    }));
    std.Io.Dir.deleteFileAbsolute(std.testing.io, manifest_path) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, root) catch {};
}
