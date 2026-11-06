//! Read-only recorder state verifier. It decodes every segment with the same
//! readers extraction uses and reports clean, dirty (torn tail), corrupt, or
//! missing segments. It never repairs, rewrites, or trusts the manifest counts.

const std = @import("std");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const safety = @import("../core/safety.zig");
const manifest_mod = @import("manifest.zig");
const reader_mod = @import("segment_reader.zig");

pub const Options = struct {
    dir: []const u8,
};

pub const SegmentReport = struct {
    path: []const u8,
    codec: []const u8,
    bytes: u64 = 0,
    events: u64 = 0,
    offset: u64 = 0,
    status: []const u8 = "unknown",
};

pub const Report = struct {
    state: []const u8 = "SKIP",
    segments: []const SegmentReport = &.{},
    events: u64 = 0,
    bytes: u64 = 0,
    decoded_events: u64 = 0,
    clean: usize = 0,
    dirty: usize = 0,
    corrupt: usize = 0,
    missing: usize = 0,
    unsupported: usize = 0,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, opts: Options) !Report {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{opts.dir});
    defer allocator.free(manifest_path);
    const manifest = (try manifest_mod.read(io, allocator, manifest_path)) orelse
        return error.NoRecorder;
    var reports: std.ArrayList(SegmentReport) = .empty;
    errdefer reports.deinit(allocator);
    var report = Report{};

    for (manifest.segments) |segment| {
        const codec_name = codecName(segment);
        var item = SegmentReport{
            .path = segment.path,
            .codec = codec_name,
            .bytes = segment.bytes,
        };
        if (!safety.isSafeRelative(segment.path)) {
            item.status = "corrupt";
            report.corrupt += 1;
            try reports.append(allocator, item);
            continue;
        }
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.dir, segment.path });
        defer allocator.free(full);
        if (std.mem.eql(u8, codec_name, "compact_v1")) {
            try verifyCompact(io, full, &item);
        } else if (std.mem.eql(u8, codec_name, "ndjson")) {
            try verifyLegacy(io, allocator, full, &item);
        } else {
            item.status = "unsupported";
            report.unsupported += 1;
        }
        if (std.mem.eql(u8, item.status, "clean")) {
            report.clean += 1;
        } else if (std.mem.eql(u8, item.status, "dirty")) {
            report.dirty += 1;
        } else if (std.mem.eql(u8, item.status, "corrupt")) {
            report.corrupt += 1;
        } else if (std.mem.eql(u8, item.status, "missing")) {
            report.missing += 1;
        } else {
            report.unsupported += 1;
        }
        report.events += item.events;
        report.bytes += item.bytes;
        try reports.append(allocator, item);
    }
    report.decoded_events = report.events;
    report.segments = try reports.toOwnedSlice(allocator);
    report.state = if (report.corrupt != 0 or report.missing != 0)
        "REFUSE"
    else if (report.dirty != 0 or report.unsupported != 0)
        "DEGRADED"
    else
        "READY";
    return report;
}

fn codecName(segment: manifest_mod.Segment) []const u8 {
    if (segment.codec.len != 0) return segment.codec;
    if (std.mem.endsWith(u8, segment.path, ".xsraw")) return "compact_v1";
    if (std.mem.endsWith(u8, segment.path, ".ndjson")) return "ndjson";
    return "unknown";
}

fn verifyCompact(io: std.Io, path: []const u8, item: *SegmentReport) !void {
    var reader = reader_mod.Reader.open(io, path) catch |open_error| switch (open_error) {
        error.FileNotFound => {
            item.status = "missing";
            return;
        },
        error.UnsupportedVersion => {
            item.status = "unsupported";
            return;
        },
        error.InvalidSegment => {
            item.status = "corrupt";
            return;
        },
        else => {
            item.status = "missing";
            return;
        },
    };
    defer reader.deinit();
    while (true) {
        const maybe = reader.next() catch break;
        if (maybe == null) break;
        item.events += 1;
    }
    item.status = reader.status.label();
    item.offset = reader.err_offset;
}

fn verifyLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8, item: *SegmentReport) !void {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |open_error| switch (open_error) {
            error.FileNotFound => {
                item.status = "missing";
                return;
            },
            else => {
                item.status = "missing";
                return;
            },
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            item.status = "missing";
            return;
        };
    defer file.close(io);
    const stat = file.stat(io) catch null;
    if (stat) |value| item.bytes = value.size;
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    var malformed: u64 = 0;
    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        _ = line_arena.reset(.retain_capacity);
        if (event.parseJson(line_arena.allocator(), line)) |_| {
            item.events += 1;
        } else |_| {
            malformed += 1;
        }
    }
    item.status = if (malformed == 0) "clean" else "corrupt";
}

pub fn writeJson(w: *std.Io.Writer, report: Report) !void {
    const allocator = std.heap.smp_allocator;
    var segment_values = try allocator.alloc(json.Value, report.segments.len);
    defer allocator.free(segment_values);
    var segment_entries = try allocator.alloc([]json.Entry, report.segments.len);
    defer {
        for (segment_entries) |entries| allocator.free(entries);
        allocator.free(segment_entries);
    }
    for (report.segments, 0..) |segment, index| {
        const entries = try allocator.alloc(json.Entry, 6);
        entries[0] = .{ .key = "bytes", .value = .{ .unsigned = segment.bytes } };
        entries[1] = .{ .key = "codec", .value = .{ .string = segment.codec } };
        entries[2] = .{ .key = "events", .value = .{ .unsigned = segment.events } };
        entries[3] = .{ .key = "offset", .value = .{ .unsigned = segment.offset } };
        entries[4] = .{ .key = "path", .value = .{ .string = segment.path } };
        entries[5] = .{ .key = "status", .value = .{ .string = segment.status } };
        segment_entries[index] = entries;
        segment_values[index] = .{ .object = entries };
    }
    try json.write(w, .{ .object = &.{
        .{ .key = "bytes", .value = .{ .unsigned = report.bytes } },
        .{ .key = "clean", .value = .{ .unsigned = report.clean } },
        .{ .key = "corrupt", .value = .{ .unsigned = report.corrupt } },
        .{ .key = "decoded_events", .value = .{ .unsigned = report.decoded_events } },
        .{ .key = "dirty", .value = .{ .unsigned = report.dirty } },
        .{ .key = "events", .value = .{ .unsigned = report.events } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "missing", .value = .{ .unsigned = report.missing } },
        .{ .key = "schema", .value = .{ .string = "xsprof/recorder-verify/v1" } },
        .{ .key = "segments", .value = .{ .array = segment_values } },
        .{ .key = "state", .value = .{ .string = report.state } },
        .{ .key = "unsupported", .value = .{ .unsigned = report.unsupported } },
    } });
}

pub fn writeText(w: *std.Io.Writer, report: Report) !void {
    try w.print("xsprof verify: state={s} segments={d} events={d} bytes={d}\n", .{
        report.state,
        report.segments.len,
        report.events,
        report.bytes,
    });
    try w.print("  clean={d} dirty={d} corrupt={d} missing={d} unsupported={d}\n", .{
        report.clean,
        report.dirty,
        report.corrupt,
        report.missing,
        report.unsupported,
    });
    for (report.segments) |segment| {
        try w.print("  {s:<11} {s:<12} bytes={d} events={d} offset={d} {s}\n", .{
            segment.status,
            segment.codec,
            segment.bytes,
            segment.events,
            segment.offset,
            segment.path,
        });
    }
}

fn testRoot(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/tmp/xsprof-verify-{d}", .{std.testing.random_seed});
}

const segment_mod = @import("segment.zig");

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

fn writeManifest(io: std.Io, allocator: std.mem.Allocator, root: []const u8, segment: manifest_mod.Segment) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(path);
    try manifest_mod.writeAtomic(io, allocator, path, .{
        .session_id = "verify-test",
        .state = .stopped,
        .started_wall_ns = segment.start_wall_ns,
        .started_mono_ns = 0,
        .raw_codec = "compact_v1",
        .segments = &.{segment},
    });
}

// Checks a clean compact directory verifies READY.
test "verify reports READY for a clean compact segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator);
    defer allocator.free(root);
    defer cleanup(allocator, root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    const segments = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    defer allocator.free(segments);
    std.Io.Dir.createDirAbsolute(std.testing.io, segments, .default_dir) catch {};
    var writer = try segment_mod.Writer.create(std.testing.io, allocator, root, 0, 1, 2);
    defer writer.deinit();
    var index: u64 = 0;
    while (index < 100) : (index += 1) {
        try writer.writeEvent(.{ .kind = .sched_switch, .ts_ns = index * 1000, .cpu = 0, .pid = 7, .tid = 7, .a = index, .comm = "worker" });
    }
    try writer.close();
    try writeManifest(std.testing.io, allocator, root, .{
        .path = writer.path,
        .start_wall_ns = 1,
        .start_mono_ns = 2,
        .bytes = writer.stats.bytes,
        .events = 100,
        .closed = true,
        .codec = "compact_v1",
    });
    const report = try run(std.testing.io, allocator, .{ .dir = root });
    try std.testing.expectEqualStrings("READY", report.state);
    try std.testing.expectEqual(@as(u64, 100), report.events);
    try std.testing.expectEqual(@as(usize, 1), report.clean);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try writeJson(&out, report);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"schema\":\"xsprof/recorder-verify/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"host_mutation\":false") != null);
}

// Checks a missing segment is REFUSE, not silently skipped.
test "verify refuses a manifest with a missing segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try testRoot(allocator);
    defer allocator.free(root);
    defer cleanup(allocator, root);
    std.Io.Dir.createDirAbsolute(std.testing.io, root, .default_dir) catch {};
    try writeManifest(std.testing.io, allocator, root, .{
        .path = "segments/missing-0.xsraw",
        .start_wall_ns = 1,
        .start_mono_ns = 2,
        .bytes = 10,
        .events = 1,
        .closed = true,
        .codec = "compact_v1",
    });
    const report = try run(std.testing.io, allocator, .{ .dir = root });
    try std.testing.expectEqualStrings("REFUSE", report.state);
    try std.testing.expectEqual(@as(usize, 1), report.missing);
}
