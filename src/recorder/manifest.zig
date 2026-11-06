//! Recorder manifest: the durable index of session segments. The writer emits
//! canonical JSON; readers accept only the matching schema.

const std = @import("std");
const json = @import("../core/json.zig");
const safety = @import("../core/safety.zig");

pub const schema = "xsprof/recorder-manifest/v1";

pub const State = enum { recording, stopped, failed };

pub const Segment = struct {
    path: []const u8,
    start_wall_ns: u64,
    start_mono_ns: u64,
    end_wall_ns: u64 = 0,
    end_mono_ns: u64 = 0,
    bytes: u64 = 0,
    events: u64 = 0,
    closed: bool = false,
    /// "ndjson" legacy segment or "compact_v1" .xsraw segment; empty in 0.3
    /// manifests, where the path suffix is authoritative.
    codec: []const u8 = "",
};

pub const Manifest = struct {
    session_id: []const u8,
    state: State = .recording,
    schema: []const u8 = "",
    host_mutation: bool = false,
    started_wall_ns: u64,
    started_mono_ns: u64,
    updated_wall_ns: u64 = 0,
    segments: []const Segment = &.{},
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_age_ms: u64 = 10 * 60 * 1000,
    raw_codec: []const u8 = "",
    history_interval_ms: u64 = 60 * 1000,
    history_retain_ms: u64 = 24 * 60 * 60 * 1000,
};

pub fn writeJson(w: *std.Io.Writer, manifest: Manifest) !void {
    const allocator = std.heap.smp_allocator;
    var segment_values = try allocator.alloc(json.Value, manifest.segments.len);
    defer allocator.free(segment_values);
    var segment_entries = try allocator.alloc([]json.Entry, manifest.segments.len);
    defer {
        for (segment_entries) |entries| allocator.free(entries);
        allocator.free(segment_entries);
    }
    for (manifest.segments, 0..) |segment, index| {
        const entries = try allocator.alloc(json.Entry, 9);
        var n: usize = 0;
        entries[n] = .{ .key = "bytes", .value = .{ .unsigned = segment.bytes } };
        n += 1;
        entries[n] = .{ .key = "closed", .value = .{ .boolean = segment.closed } };
        n += 1;
        if (segment.codec.len != 0) {
            entries[n] = .{ .key = "codec", .value = .{ .string = segment.codec } };
            n += 1;
        }
        entries[n] = .{ .key = "end_mono_ns", .value = .{ .unsigned = segment.end_mono_ns } };
        n += 1;
        entries[n] = .{ .key = "end_wall_ns", .value = .{ .unsigned = segment.end_wall_ns } };
        n += 1;
        entries[n] = .{ .key = "events", .value = .{ .unsigned = segment.events } };
        n += 1;
        entries[n] = .{ .key = "path", .value = .{ .string = segment.path } };
        n += 1;
        entries[n] = .{ .key = "start_mono_ns", .value = .{ .unsigned = segment.start_mono_ns } };
        n += 1;
        entries[n] = .{ .key = "start_wall_ns", .value = .{ .unsigned = segment.start_wall_ns } };
        n += 1;
        segment_entries[index] = entries[0..n];
        segment_values[index] = .{ .object = entries[0..n] };
    }
    var entries: [13]json.Entry = undefined;
    var n: usize = 0;
    entries[n] = .{ .key = "history_interval_ms", .value = .{ .unsigned = manifest.history_interval_ms } };
    n += 1;
    entries[n] = .{ .key = "history_retain_ms", .value = .{ .unsigned = manifest.history_retain_ms } };
    n += 1;
    entries[n] = .{ .key = "host_mutation", .value = .{ .boolean = false } };
    n += 1;
    entries[n] = .{ .key = "max_age_ms", .value = .{ .unsigned = manifest.max_age_ms } };
    n += 1;
    entries[n] = .{ .key = "max_bytes", .value = .{ .unsigned = manifest.max_bytes } };
    n += 1;
    if (manifest.raw_codec.len != 0) {
        entries[n] = .{ .key = "raw_codec", .value = .{ .string = manifest.raw_codec } };
        n += 1;
    }
    entries[n] = .{ .key = "schema", .value = .{ .string = schema } };
    n += 1;
    entries[n] = .{ .key = "segments", .value = .{ .array = segment_values } };
    n += 1;
    entries[n] = .{ .key = "session_id", .value = .{ .string = manifest.session_id } };
    n += 1;
    entries[n] = .{ .key = "started_mono_ns", .value = .{ .unsigned = manifest.started_mono_ns } };
    n += 1;
    entries[n] = .{ .key = "started_wall_ns", .value = .{ .unsigned = manifest.started_wall_ns } };
    n += 1;
    entries[n] = .{ .key = "state", .value = .{ .string = @tagName(manifest.state) } };
    n += 1;
    entries[n] = .{ .key = "updated_wall_ns", .value = .{ .unsigned = manifest.updated_wall_ns } };
    n += 1;
    try json.write(w, .{ .object = entries[0..n] });
}

fn validCodec(codec: []const u8) bool {
    return codec.len == 0 or
        std.mem.eql(u8, codec, "ndjson") or
        std.mem.eql(u8, codec, "compact_v1");
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Manifest {
    const parsed = std.json.parseFromSlice(Manifest, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    const manifest = parsed.value;
    if (manifest.session_id.len == 0 or manifest.session_id.len > 128) return error.InvalidManifest;
    if (!std.mem.eql(u8, manifest.schema, schema)) return error.InvalidManifest;
    if (manifest.host_mutation) return error.InvalidManifest;
    if (!validCodec(manifest.raw_codec)) return error.InvalidManifest;
    if (manifest.segments.len > 10_000) return error.InvalidManifest;
    for (manifest.segments) |segment| {
        if (segment.path.len == 0 or segment.path.len > 512) return error.InvalidManifest;
        if (!safety.isSafeRelative(segment.path)) return error.InvalidManifest;
        if (!validCodec(segment.codec)) return error.InvalidManifest;
    }
    return manifest;
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?Manifest {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    defer file.close(io);
    var buffer: [32 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidManifest,
        else => return err,
    };
    return parse(allocator, data) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidManifest,
    };
}

pub fn writeAtomic(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    manifest: Manifest,
) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp);
    const file = try std.Io.Dir.createFileAbsolute(io, temp, .{});
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    errdefer file.close(io);
    try writeJson(&writer.interface, manifest);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    try file.sync(io);
    file.close(io);
    try std.Io.Dir.renameAbsolute(temp, path, io);
}

// Checks manifest JSON round-trips with sorted keys and all segment fields.
test "manifest round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = Manifest{
        .session_id = "abc",
        .started_wall_ns = 10,
        .started_mono_ns = 20,
        .updated_wall_ns = 30,
        .segments = &.{.{
            .path = "segments/one.ndjson",
            .start_wall_ns = 10,
            .start_mono_ns = 20,
            .end_wall_ns = 40,
            .end_mono_ns = 50,
            .bytes = 100,
            .events = 3,
            .closed = true,
        }},
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, manifest);
    const text = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"history_interval_ms\":"));
    const parsed = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("abc", parsed.session_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.segments.len);
    try std.testing.expectEqualStrings("segments/one.ndjson", parsed.segments[0].path);
    try std.testing.expect(parsed.segments[0].closed);
    try std.testing.expectEqualStrings("", parsed.raw_codec);
    try std.testing.expectEqualStrings("", parsed.segments[0].codec);
}

test "manifest codecs are additive and validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const manifest = Manifest{
        .session_id = "codec",
        .raw_codec = "compact_v1",
        .started_wall_ns = 10,
        .started_mono_ns = 20,
        .segments = &.{.{
            .path = "segments/one.xsraw",
            .start_wall_ns = 10,
            .start_mono_ns = 20,
            .bytes = 100,
            .events = 3,
            .closed = true,
            .codec = "compact_v1",
        }},
    };
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, manifest);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"raw_codec\":\"compact_v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"codec\":\"compact_v1\"") != null);
    const parsed = try parse(allocator, text);
    try std.testing.expectEqualStrings("compact_v1", parsed.raw_codec);
    try std.testing.expectEqualStrings("compact_v1", parsed.segments[0].codec);

    const bad = "{\"history_interval_ms\":60000,\"history_retain_ms\":86400000," ++
        "\"host_mutation\":false,\"max_age_ms\":600000,\"max_bytes\":1," ++
        "\"raw_codec\":\"lz4\",\"schema\":\"xsprof/recorder-manifest/v1\",\"segments\":[]," ++
        "\"session_id\":\"s\",\"started_mono_ns\":0,\"started_wall_ns\":0,\"state\":\"stopped\",\"updated_wall_ns\":0}";
    try std.testing.expectError(error.InvalidManifest, parse(allocator, bad));
}

test "reads a relative recorder manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try read(
        std.testing.io,
        arena.allocator(),
        "fixtures/ui/design/recorder/manifest.json",
    );
    try std.testing.expect(manifest != null);
    try std.testing.expect(manifest.?.segments.len == 1);
}

test "manifest rejects traversal and mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base =
        "{\"history_interval_ms\":60000,\"history_retain_ms\":86400000," ++
        "\"host_mutation\":false,\"max_age_ms\":600000,\"max_bytes\":1," ++
        "\"schema\":\"xsprof/recorder-manifest/v1\",\"segments\":[" ++
        "{\"bytes\":1,\"closed\":true,\"end_mono_ns\":0,\"end_wall_ns\":0," ++
        "\"events\":1,\"path\":\"../escape.ndjson\",\"start_mono_ns\":0," ++
        "\"start_wall_ns\":0}],\"session_id\":\"s\",\"started_mono_ns\":0," ++
        "\"started_wall_ns\":0,\"state\":\"stopped\",\"updated_wall_ns\":0}";
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), base));
    const mutated = "{\"history_interval_ms\":60000,\"history_retain_ms\":86400000," ++
        "\"host_mutation\":true,\"max_age_ms\":600000,\"max_bytes\":1," ++
        "\"schema\":\"xsprof/recorder-manifest/v1\",\"segments\":[]," ++
        "\"session_id\":\"s\",\"started_mono_ns\":0,\"started_wall_ns\":0," ++
        "\"state\":\"stopped\",\"updated_wall_ns\":0}";
    try std.testing.expectError(error.InvalidManifest, parse(arena.allocator(), mutated));
}
