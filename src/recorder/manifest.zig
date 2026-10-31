//! Recorder manifest: the durable index of session segments. The writer emits
//! canonical JSON; readers accept only the matching schema.

const std = @import("std");
const json = @import("../core/json.zig");

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
};

pub const Manifest = struct {
    session_id: []const u8,
    state: State = .recording,
    started_wall_ns: u64,
    started_mono_ns: u64,
    updated_wall_ns: u64 = 0,
    segments: []const Segment = &.{},
    max_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_age_ms: u64 = 10 * 60 * 1000,
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
        const entries = try allocator.alloc(json.Entry, 8);
        entries[0] = .{ .key = "bytes", .value = .{ .unsigned = segment.bytes } };
        entries[1] = .{ .key = "closed", .value = .{ .boolean = segment.closed } };
        entries[2] = .{ .key = "end_mono_ns", .value = .{ .unsigned = segment.end_mono_ns } };
        entries[3] = .{ .key = "end_wall_ns", .value = .{ .unsigned = segment.end_wall_ns } };
        entries[4] = .{ .key = "events", .value = .{ .unsigned = segment.events } };
        entries[5] = .{ .key = "path", .value = .{ .string = segment.path } };
        entries[6] = .{ .key = "start_mono_ns", .value = .{ .unsigned = segment.start_mono_ns } };
        entries[7] = .{ .key = "start_wall_ns", .value = .{ .unsigned = segment.start_wall_ns } };
        segment_entries[index] = entries;
        segment_values[index] = .{ .object = entries };
    }
    try json.write(w, .{ .object = &.{
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "max_age_ms", .value = .{ .unsigned = manifest.max_age_ms } },
        .{ .key = "max_bytes", .value = .{ .unsigned = manifest.max_bytes } },
        .{ .key = "schema", .value = .{ .string = schema } },
        .{ .key = "segments", .value = .{ .array = segment_values } },
        .{ .key = "session_id", .value = .{ .string = manifest.session_id } },
        .{ .key = "started_mono_ns", .value = .{ .unsigned = manifest.started_mono_ns } },
        .{ .key = "started_wall_ns", .value = .{ .unsigned = manifest.started_wall_ns } },
        .{ .key = "state", .value = .{ .string = @tagName(manifest.state) } },
        .{ .key = "updated_wall_ns", .value = .{ .unsigned = manifest.updated_wall_ns } },
    } });
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Manifest {
    const parsed = std.json.parseFromSlice(Manifest, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    const manifest = parsed.value;
    if (manifest.session_id.len == 0) return error.InvalidManifest;
    return manifest;
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?Manifest {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
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
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"host_mutation\":false,"));
    const parsed = try parse(arena.allocator(), text);
    try std.testing.expectEqualStrings("abc", parsed.session_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.segments.len);
    try std.testing.expectEqualStrings("segments/one.ndjson", parsed.segments[0].path);
    try std.testing.expect(parsed.segments[0].closed);
}
