//! Read-only `/proc/PID/maps` snapshots and the bounded local capture sidecar
//! that records them next to a sampled capture.
//!
//! The sidecar is **not** product wire: it is a local analysis aid for module
//! base/backing identification (the symbolizer uses it to map runtime addresses
//! back to file virtual addresses). It is never displayed, never parsed by the
//! viewer, and contains only path-backed mappings — no argv, environment, or
//! open-file data. Every record is bounded in length and count.
//!
//! Filesystem layout: a capture written to `session.ndjson` gets the optional
//! sidecar `session.maps.ndjson` in the same directory (`sidecarPath`).
//!
//! On non-Linux hosts every reader fails closed with `error.MapsUnavailable`;
//! nothing here writes to `/proc` or `/sys`.

const std = @import("std");
const builtin = @import("builtin");
const json = @import("../../core/json.zig");

const Writer = std.Io.Writer;

/// Local sidecar schema id. Deliberately not an `xsprof/<product>` contract.
pub const schema = "xsprof/session-maps/v0";
pub const sidecar_suffix = ".maps.ndjson";
pub const max_maps = 20_000;
pub const max_records = max_maps * 2;
pub const max_path_bytes = 512;
pub const max_proc_maps_bytes = 8 * 1024 * 1024;
pub const max_sidecar_bytes = 32 * 1024 * 1024;
pub const max_line_bytes = 1024;

pub const Error = error{
    MapsUnavailable,
    InvalidSidecar,
    SidecarTooLarge,
    TooManyMaps,
    OutOfMemory,
};

pub const Mapping = struct {
    start: u64,
    end: u64,
    offset: u64,
    /// The four `rwxp` permission characters verbatim.
    perms: [4]u8,
    /// Path-backed mappings only; the path is bounded to `max_path_bytes`.
    path: []const u8,

    pub fn isExecutable(self: Mapping) bool {
        return self.perms[2] == 'x';
    }
};

pub const Phase = enum { start, stop };

pub const Record = struct {
    phase: Phase,
    pid: i32,
    ts_ns: u64,
    mapping: Mapping,
};

/// A loaded module identified in the sidecar: the ELF load bias (`base`) plus
/// the runtime address range of its executable mappings.
pub const Module = struct {
    base: u64,
    start: u64,
    end: u64,
    path: []const u8,
};

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r");
}

fn hexU64(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 16) catch null;
}

fn skipSpaces(line: []const u8, start: usize) usize {
    var pos = start;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    return pos;
}

fn nextToken(line: []const u8, start: *usize) ?[]const u8 {
    var pos = skipSpaces(line, start.*);
    if (pos >= line.len) return null;
    const begin = pos;
    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') : (pos += 1) {}
    start.* = pos;
    return line[begin..pos];
}

/// Parse the text of a `/proc/PID/maps` file. Only path-backed mappings are
/// retained (module base identification is the sidecar's only purpose), and
/// every retained record is bounded.
pub fn parseProcMaps(allocator: std.mem.Allocator, text: []const u8) Error![]Mapping {
    var list: std.ArrayList(Mapping) = .empty;
    errdefer list.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0) continue;
        var cursor: usize = 0;
        const range = nextToken(line, &cursor) orelse continue;
        const perms = nextToken(line, &cursor) orelse continue;
        const offset_text = nextToken(line, &cursor) orelse continue;
        _ = nextToken(line, &cursor) orelse continue; // dev
        _ = nextToken(line, &cursor) orelse continue; // inode
        const path = trim(line[skipSpaces(line, cursor)..]);
        if (path.len == 0) continue; // anonymous mapping: no module backing
        if (perms.len != 4) continue;
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = hexU64(range[0..dash]) orelse continue;
        const end = hexU64(range[dash + 1 ..]) orelse continue;
        if (end <= start) continue;
        const offset = hexU64(offset_text) orelse continue;
        if (list.items.len >= max_maps) return error.TooManyMaps;
        const kept = try allocator.dupe(u8, path[0..@min(path.len, max_path_bytes)]);
        var perms_bytes: [4]u8 = undefined;
        @memcpy(&perms_bytes, perms[0..4]);
        try list.append(allocator, .{
            .start = start,
            .end = end,
            .offset = offset,
            .perms = perms_bytes,
            .path = kept,
        });
    }
    return list.toOwnedSlice(allocator);
}

fn readBoundedFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) Error![]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.MapsUnavailable;
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.SidecarTooLarge,
        else => error.MapsUnavailable,
    };
}

/// Snapshot `/proc/PID/maps`. Never writes, never follows argv/env.
pub fn readProcMaps(io: std.Io, allocator: std.mem.Allocator, pid: i32) Error![]Mapping {
    if (comptime builtin.os.tag != .linux) return error.MapsUnavailable;
    if (pid <= 0) return error.MapsUnavailable;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/maps", .{pid}) catch
        return error.MapsUnavailable;
    const text = try readBoundedFile(io, allocator, path, max_proc_maps_bytes);
    return parseProcMaps(allocator, text);
}

/// Sidecar path next to a capture: `session.ndjson` -> `session.maps.ndjson`.
pub fn sidecarPath(allocator: std.mem.Allocator, capture_path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, capture_path, ".ndjson")) {
        return std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ capture_path[0 .. capture_path.len - ".ndjson".len], sidecar_suffix },
        );
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ capture_path, sidecar_suffix });
}

fn writeMappingLine(
    out: *std.Io.Writer.Allocating,
    phase_name: []const u8,
    pid: i32,
    ts_ns: u64,
    mapping: Mapping,
) !void {
    try json.write(&out.writer, .{ .object = &.{
        .{ .key = "capture", .value = .{ .string = phase_name } },
        .{ .key = "end", .value = .{ .unsigned = mapping.end } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "offset", .value = .{ .unsigned = mapping.offset } },
        .{ .key = "path", .value = .{ .string = mapping.path } },
        .{ .key = "perms", .value = .{ .string = mapping.perms[0..] } },
        .{ .key = "pid", .value = .{ .integer = pid } },
        .{ .key = "schema", .value = .{ .string = schema } },
        .{ .key = "start", .value = .{ .unsigned = mapping.start } },
        .{ .key = "ts_ns", .value = .{ .unsigned = ts_ns } },
    } });
    try out.writer.writeByte('\n');
}

fn createFile(io: std.Io, path: []const u8, truncate: bool) !std.Io.File {
    const options: std.Io.Dir.CreateFileOptions = .{ .truncate = truncate };
    if (path.len != 0 and path[0] == '/') return std.Io.Dir.createFileAbsolute(io, path, options);
    return std.Io.Dir.cwd().createFile(io, path, options);
}

fn openWritable(io: std.Io, path: []const u8) !std.Io.File {
    const options: std.Io.Dir.OpenFileOptions = .{ .mode = .write_only };
    if (path.len != 0 and path[0] == '/') return std.Io.Dir.openFileAbsolute(io, path, options);
    return std.Io.Dir.cwd().openFile(io, path, options);
}

/// Append one capture phase (`start` truncates, `stop` appends) to the sidecar.
/// The whole phase is bounded by `max_maps`, so one flat write is enough.
pub fn append(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    phase: Phase,
    pid: i32,
    mappings: []const Mapping,
    ts_ns: u64,
) !void {
    const is_start = phase == .start;
    var file = if (is_start) try createFile(io, path, true) else try openWritable(io, path);
    defer file.close(io);
    var offset: u64 = 0;
    if (!is_start) offset = (try file.stat(io)).size;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const phase_name = if (is_start) "start" else "stop";
    for (mappings, 0..) |mapping, index| {
        if (index == max_maps) break;
        try writeMappingLine(&out, phase_name, pid, ts_ns, mapping);
    }
    if (out.written().len != 0) try file.writePositionalAll(io, out.written(), offset);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = object.get(key) orelse return error.InvalidSidecar;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidSidecar,
    };
}

fn uintField(object: std.json.ObjectMap, key: []const u8) Error!u64 {
    const value = object.get(key) orelse return error.InvalidSidecar;
    return switch (value) {
        .integer => |integer| if (integer < 0) error.InvalidSidecar else @intCast(integer),
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.InvalidSidecar,
        else => error.InvalidSidecar,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8) Error!i32 {
    const value = object.get(key) orelse return error.InvalidSidecar;
    return switch (value) {
        .integer => |integer| std.math.cast(i32, integer) orelse error.InvalidSidecar,
        .number_string => |text| blk: {
            const parsed = std.fmt.parseInt(i64, text, 10) catch return error.InvalidSidecar;
            break :blk std.math.cast(i32, parsed) orelse error.InvalidSidecar;
        },
        else => error.InvalidSidecar,
    };
}

/// Parse sidecar bytes. Strings are duplicated into `allocator` so the caller
/// may release the file buffer; `allocator` is normally the symbolizer arena.
pub fn parseSidecarBytes(allocator: std.mem.Allocator, text: []const u8) Error![]Record {
    var records: std.ArrayList(Record) = .empty;
    errdefer records.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line.len > max_line_bytes) return error.InvalidSidecar;
        if (!json.depthOk(line, 8)) return error.InvalidSidecar;
        const value = std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            line,
            .{ .max_value_len = line.len },
        ) catch return error.InvalidSidecar;
        const object = switch (value) {
            .object => |map| map,
            else => return error.InvalidSidecar,
        };
        const line_schema = try stringField(object, "schema");
        if (!std.mem.eql(u8, line_schema, schema)) return error.InvalidSidecar;
        const mutation = object.get("host_mutation") orelse return error.InvalidSidecar;
        switch (mutation) {
            .bool => |flag| if (flag) return error.InvalidSidecar,
            else => return error.InvalidSidecar,
        }
        if (records.items.len >= max_records) return error.TooManyMaps;
        const phase_text = try stringField(object, "capture");
        const phase: Phase = if (std.mem.eql(u8, phase_text, "start"))
            .start
        else if (std.mem.eql(u8, phase_text, "stop"))
            .stop
        else
            return error.InvalidSidecar;
        const perms_text = try stringField(object, "perms");
        if (perms_text.len != 4) return error.InvalidSidecar;
        const path_text = try stringField(object, "path");
        if (path_text.len > max_path_bytes) return error.InvalidSidecar;
        var perms_bytes: [4]u8 = undefined;
        @memcpy(&perms_bytes, perms_text[0..4]);
        const start = try uintField(object, "start");
        const end = try uintField(object, "end");
        if (end <= start) return error.InvalidSidecar;
        try records.append(allocator, .{
            .phase = phase,
            .pid = try intField(object, "pid"),
            .ts_ns = try uintField(object, "ts_ns"),
            .mapping = .{
                .start = start,
                .end = end,
                .offset = try uintField(object, "offset"),
                .perms = perms_bytes,
                .path = try allocator.dupe(u8, path_text),
            },
        });
    }
    return records.toOwnedSlice(allocator);
}

pub fn readSidecar(io: std.Io, allocator: std.mem.Allocator, path: []const u8) Error![]Record {
    const text = try readBoundedFile(io, allocator, path, max_sidecar_bytes);
    return parseSidecarBytes(allocator, text);
}

fn stripDeleted(path: []const u8) []const u8 {
    const suffix = " (deleted)";
    if (std.mem.endsWith(u8, path, suffix)) return path[0 .. path.len - suffix.len];
    return path;
}

fn sameModulePath(candidate: []const u8, wanted: []const u8) bool {
    const clean = stripDeleted(candidate);
    if (std.mem.eql(u8, clean, wanted)) return true;
    return std.mem.eql(u8, std.fs.path.basename(clean), std.fs.path.basename(wanted));
}

fn addModuleMapping(found: *?Module, mapping: Mapping, binary_path: []const u8) void {
    if (!mapping.isExecutable()) return;
    if (!sameModulePath(mapping.path, binary_path)) return;
    const base = mapping.start -| mapping.offset;
    if (found.*) |previous| {
        found.* = .{
            .base = previous.base,
            .start = @min(previous.start, mapping.start),
            .end = @max(previous.end, mapping.end),
            .path = previous.path,
        };
    } else {
        found.* = .{
            .base = base,
            .start = mapping.start,
            .end = mapping.end,
            .path = stripDeleted(mapping.path),
        };
    }
}

/// Find the executable module loaded from `binary_path` in a `/proc/PID/maps`
/// snapshot. Returns null rather than guessing when no mapping matches.
pub fn moduleFromMappings(mappings: []const Mapping, binary_path: []const u8) ?Module {
    var found: ?Module = null;
    for (mappings) |mapping| addModuleMapping(&found, mapping, binary_path);
    return found;
}

/// Find the module in the capture-start sidecar phase (falling back to any
/// phase when a capture was interrupted before the stop snapshot).
pub fn moduleFromRecords(records: []const Record, binary_path: []const u8) ?Module {
    var found: ?Module = null;
    for (records) |record| {
        if (record.phase != .start) continue;
        addModuleMapping(&found, record.mapping, binary_path);
    }
    if (found != null) return found;
    for (records) |record| addModuleMapping(&found, record.mapping, binary_path);
    return found;
}

test "proc maps parsing keeps only bounded path-backed mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        "55d0f0000000-55d0f0001000 r--p 00000000 08:02 1234 /usr/bin/xsprof\n" ++
        "55d0f0001000-55d0f0200000 r-xp 00001000 08:02 1234 /usr/bin/xsprof\n" ++
        "55d0f0200000-55d0f0210000 rw-p 00000000 00:00 0\n" ++
        "7ffd00000000-7ffd00021000 rw-p 00000000 00:00 0 [stack]\n";
    const mappings = try parseProcMaps(arena.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), mappings.len);
    try std.testing.expectEqual(@as(u64, 0x55d0f0000000), mappings[0].start);
    try std.testing.expect(!mappings[0].isExecutable());
    try std.testing.expect(mappings[1].isExecutable());
    try std.testing.expectEqual(@as(u64, 0x1000), mappings[1].offset);
    try std.testing.expectEqualStrings("[stack]", mappings[2].path);

    const module = moduleFromMappings(mappings, "/usr/bin/xsprof").?;
    try std.testing.expectEqual(@as(u64, 0x55d0f0000000), module.base);
    try std.testing.expectEqual(@as(u64, 0x55d0f0200000), module.end);
    try std.testing.expect(moduleFromMappings(mappings, "/usr/bin/other") == null);
}

test "sidecar path derives from the capture name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try sidecarPath(arena.allocator(), "session-1.ndjson");
    try std.testing.expectEqualStrings("session-1.maps.ndjson", a);
    const b = try sidecarPath(arena.allocator(), "/tmp/capture");
    try std.testing.expectEqualStrings("/tmp/capture.maps.ndjson", b);
}

test "sidecar start/stop round-trips and identifies the module base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dir_path = ".zig-cache/tmp";
    std.Io.Dir.cwd().createDirPath(std.testing.io, dir_path) catch {};
    const path = dir_path ++ "/xsprof-maps-test.maps.ndjson";
    {
        const mappings = [_]Mapping{
            .{ .start = 0x400000, .end = 0x401000, .offset = 0, .perms = .{ 'r', '-', '-', 'p' }, .path = "/bin/probe" },
            .{ .start = 0x401000, .end = 0x402000, .offset = 0x1000, .perms = .{ 'r', '-', 'x', 'p' }, .path = "/bin/probe" },
        };
        try append(std.testing.io, allocator, path, .start, 4242, &mappings, 111);
        try append(std.testing.io, allocator, path, .stop, 4242, &mappings, 222);
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    const records = try readSidecar(std.testing.io, allocator, path);
    try std.testing.expectEqual(@as(usize, 4), records.len);
    try std.testing.expectEqual(Phase.start, records[0].phase);
    try std.testing.expectEqual(@as(u64, 111), records[0].ts_ns);
    try std.testing.expectEqual(Phase.stop, records[2].phase);
    const module = moduleFromRecords(records, "/bin/probe").?;
    try std.testing.expectEqual(@as(u64, 0x400000), module.base);
    try std.testing.expectEqual(@as(u64, 0x402000), module.end);
}

test "sidecar parsing rejects wrong schema and unsafe records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const good =
        "{\"capture\":\"start\",\"end\":8192,\"host_mutation\":false,\"offset\":0," ++
        "\"path\":\"/bin/x\",\"perms\":\"r-xp\",\"pid\":7,\"schema\":\"xsprof/session-maps/v0\"," ++
        "\"start\":4096,\"ts_ns\":1}\n";
    const records = try parseSidecarBytes(allocator, good);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectError(
        error.InvalidSidecar,
        parseSidecarBytes(allocator, "{\"schema\":\"other/v1\"}\n"),
    );
    try std.testing.expectError(
        error.InvalidSidecar,
        parseSidecarBytes(allocator, "{\"host_mutation\":true}\n"),
    );
    try std.testing.expectError(
        error.InvalidSidecar,
        parseSidecarBytes(allocator, "{\"capture\":\"start\",\"end\":1}\n"),
    );
}
