//! Read-only recorder state verifier. It decodes every segment with the same
//! readers extraction uses and reports clean, dirty (torn tail), corrupt, or
//! missing segments. It never repairs, rewrites, or trusts the manifest counts.

const std = @import("std");
const compact = @import("compact.zig");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");
const safety = @import("../core/safety.zig");
const schema_mod = @import("../core/schema.zig");
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
    /// Compact footer claims and the decoded block count. A mismatch means the
    /// file's own close record disagrees with its payload, so it cannot be clean.
    footer_events: u64 = 0,
    footer_blocks: u64 = 0,
    blocks: u64 = 0,
    footer_mismatch: bool = false,
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
    footer_mismatch: usize = 0,
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
        if (item.footer_mismatch) report.footer_mismatch += 1;
        report.events += item.events;
        report.bytes += item.bytes;
        try reports.append(allocator, item);
    }
    report.decoded_events = report.events;
    report.segments = try reports.toOwnedSlice(allocator);
    report.state = if (report.corrupt != 0 or report.missing != 0 or report.footer_mismatch != 0)
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
    }
    item.events = reader.events;
    item.blocks = reader.blocks;
    item.status = reader.status.label();
    item.offset = reader.err_offset;
    // The footer is the segment's own close record: a clean file whose footer
    // counts disagree with the decoded payload is not clean, even when every
    // block CRC and the footer CRC still check out.
    if (reader.footer) |footer| {
        item.footer_events = footer.event_count;
        item.footer_blocks = footer.block_count;
        if (std.mem.eql(u8, item.status, "clean") and
            (footer.event_count != item.events or footer.block_count != item.blocks))
        {
            item.footer_mismatch = true;
            item.status = "corrupt";
        }
    }
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
        const entries = try allocator.alloc(json.Entry, 9);
        var n: usize = 0;
        entries[n] = .{ .key = "bytes", .value = .{ .unsigned = segment.bytes } };
        n += 1;
        entries[n] = .{ .key = "codec", .value = .{ .string = segment.codec } };
        n += 1;
        entries[n] = .{ .key = "events", .value = .{ .unsigned = segment.events } };
        n += 1;
        if (segment.footer_mismatch) {
            // Machine-readable per-segment detail only when the file's own
            // close record disagrees with its decoded payload.
            entries[n] = .{ .key = "footer_blocks", .value = .{ .unsigned = segment.footer_blocks } };
            n += 1;
            entries[n] = .{ .key = "footer_events", .value = .{ .unsigned = segment.footer_events } };
            n += 1;
            entries[n] = .{ .key = "footer_mismatch", .value = .{ .boolean = true } };
            n += 1;
        }
        entries[n] = .{ .key = "offset", .value = .{ .unsigned = segment.offset } };
        n += 1;
        entries[n] = .{ .key = "path", .value = .{ .string = segment.path } };
        n += 1;
        entries[n] = .{ .key = "status", .value = .{ .string = segment.status } };
        n += 1;
        segment_entries[index] = entries[0..n];
        segment_values[index] = .{ .object = entries[0..n] };
    }
    try json.write(w, .{ .object = &.{
        .{ .key = "bytes", .value = .{ .unsigned = report.bytes } },
        .{ .key = "clean", .value = .{ .unsigned = report.clean } },
        .{ .key = "corrupt", .value = .{ .unsigned = report.corrupt } },
        .{ .key = "decoded_events", .value = .{ .unsigned = report.decoded_events } },
        .{ .key = "dirty", .value = .{ .unsigned = report.dirty } },
        .{ .key = "events", .value = .{ .unsigned = report.events } },
        .{ .key = "footer_mismatch", .value = .{ .unsigned = report.footer_mismatch } },
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
    try w.print("  clean={d} dirty={d} corrupt={d} missing={d} unsupported={d} footer_mismatch={d}\n", .{
        report.clean,
        report.dirty,
        report.corrupt,
        report.missing,
        report.unsupported,
        report.footer_mismatch,
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
        if (segment.footer_mismatch) {
            try w.print(
                "      footer_mismatch: footer_events={d} decoded_events={d} footer_blocks={d} decoded_blocks={d}\n",
                .{ segment.footer_events, segment.events, segment.footer_blocks, segment.blocks },
            );
        }
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
    // The decoded payload matches the clean-close footer exactly.
    try std.testing.expectEqual(@as(usize, 0), report.footer_mismatch);
    try std.testing.expectEqual(@as(u64, 100), report.segments[0].footer_events);
    try std.testing.expectEqual(@as(u64, 100), report.segments[0].events);
    try std.testing.expectEqual(report.segments[0].footer_blocks, report.segments[0].blocks);
    try std.testing.expect(!report.segments[0].footer_mismatch);
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

fn tmpRoot(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn writeBytes(io: std.Io, allocator: std.mem.Allocator, root: []const u8, relative: []const u8, bytes: []const u8) !void {
    const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative });
    defer allocator.free(full);
    const file = try std.Io.Dir.createFileAbsolute(io, full, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn writeManifestList(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    segments: []const manifest_mod.Segment,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{root});
    defer allocator.free(path);
    try manifest_mod.writeAtomic(io, allocator, path, .{
        .session_id = "verify-test",
        .state = .stopped,
        .started_wall_ns = 1,
        .started_mono_ns = 0,
        .raw_codec = "compact_v1",
        .segments = segments,
    });
}

/// Rewrites a clean segment's footer with wrong counts and a valid CRC, so the
/// reader decodes a clean file whose own close record disagrees with the data.
fn craftFooterMismatch(
    allocator: std.mem.Allocator,
    original: []const u8,
    extra_events: u64,
    extra_blocks: u64,
) ![]u8 {
    const footer_total = compact.block_header_bytes + compact.footer_payload_bytes;
    if (original.len < compact.header_bytes + footer_total) return error.TestUnexpectedResult;
    const footer_start = original.len - footer_total;
    var out = try allocator.dupe(u8, original);
    var payload: [compact.footer_payload_bytes]u8 = undefined;
    @memcpy(&payload, out[footer_start + compact.block_header_bytes ..]);
    var footer = compact.Footer.parse(&payload);
    footer.event_count += extra_events;
    footer.block_count += extra_blocks;
    footer.encode(&payload);
    @memcpy(out[footer_start + compact.block_header_bytes ..], &payload);
    var header: [compact.block_header_bytes]u8 = undefined;
    compact.writeBlockHeader(&header, compact.block_type_footer, &payload);
    @memcpy(out[footer_start..][0..compact.block_header_bytes], &header);
    return out;
}

// Checks a segment whose footer counts disagree with the decoded payload is
// refused with an explicit footer_mismatch reason, never reported READY.
test "verify refuses footer count mismatches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const root = try tmpRoot(&tmp, allocator);
    const segments_path = try std.fmt.allocPrint(allocator, "{s}/segments", .{root});
    try std.Io.Dir.cwd().createDirPath(io, segments_path);

    var writer = try segment_mod.Writer.create(io, allocator, root, 0, 1, 2);
    var index: u64 = 0;
    while (index < 100) : (index += 1) {
        try writer.writeEvent(.{
            .kind = .sched_switch,
            .ts_ns = index * 1000,
            .cpu = 0,
            .pid = 7,
            .tid = 7,
            .a = index,
            .comm = "worker",
        });
    }
    try writer.close();
    const original_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, writer.path });
    defer allocator.free(original_path);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, original_path, allocator, .limited(1024 * 1024));
    const writer_stats = writer.stats;
    writer.deinit();

    const event_mismatch = "segments/event-mismatch-0.xsraw";
    const block_mismatch = "segments/block-mismatch-0.xsraw";
    try writeBytes(io, allocator, root, event_mismatch, try craftFooterMismatch(allocator, original, 1, 0));
    try writeBytes(io, allocator, root, block_mismatch, try craftFooterMismatch(allocator, original, 0, 1));
    try writeManifestList(io, allocator, root, &.{
        .{ .path = event_mismatch, .start_wall_ns = 1, .start_mono_ns = 2, .bytes = writer_stats.bytes, .events = 100, .closed = true, .codec = "compact_v1" },
        .{ .path = block_mismatch, .start_wall_ns = 1, .start_mono_ns = 2, .bytes = writer_stats.bytes, .events = 100, .closed = true, .codec = "compact_v1" },
    });

    const report = try run(io, allocator, .{ .dir = root });
    try std.testing.expectEqualStrings("REFUSE", report.state);
    try std.testing.expectEqual(@as(usize, 2), report.footer_mismatch);
    try std.testing.expectEqual(@as(usize, 2), report.corrupt);
    try std.testing.expectEqual(@as(usize, 0), report.clean);
    // Both payloads decode fine; only their own footer counts are wrong.
    try std.testing.expectEqual(@as(u64, 200), report.events);
    try std.testing.expect(report.segments[0].footer_mismatch);
    try std.testing.expectEqual(@as(u64, 101), report.segments[0].footer_events);
    try std.testing.expectEqual(@as(u64, 100), report.segments[0].events);
    try std.testing.expect(report.segments[1].footer_mismatch);
    try std.testing.expectEqual(@as(u64, 100), report.segments[1].footer_events);
    try std.testing.expectEqual(report.segments[1].footer_blocks, report.segments[1].blocks + 1);

    var text_buffer: [4096]u8 = undefined;
    var text = std.Io.Writer.fixed(&text_buffer);
    try writeText(&text, report);
    try std.testing.expect(std.mem.indexOf(u8, text.buffered(), "footer_mismatch:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.buffered(), "footer_events=101") != null);

    // The machine-readable report carries the count and per-segment detail,
    // and must satisfy the committed recorder-verify schema.
    var json_buffer: [16 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&json_buffer);
    try writeJson(&out, report);
    const json_text = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"state\":\"REFUSE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"footer_mismatch\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"footer_events\":101") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"footer_blocks\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"footer_mismatch\":true") != null);

    var schema_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer schema_arena.deinit();
    const schema_text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "schemas/xsprof/recorder-verify.v1.schema.json",
        schema_arena.allocator(),
        .limited(schema_mod.max_schema_bytes),
    );
    var validator = try schema_mod.Schema.parse(schema_arena.allocator(), schema_text);
    defer validator.deinit();
    try validator.validateText(json_text);
}
