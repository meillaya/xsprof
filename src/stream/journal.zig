//! Journal ingestion: one `xsprof/event/v1` JSON object per line, or the
//! legacy `xsprof/journal/v1` wrapper with an `entries` array.

const std = @import("std");
const event = @import("../core/event.zig");

pub const max_file_bytes = 256 * 1024 * 1024;

pub const Error = error{
    InvalidJournal,
    JournalTooLarge,
};

fn parseWrapper(allocator: std.mem.Allocator, data: []const u8) ![]event.RawEvent {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        data,
        .{ .max_value_len = data.len },
    ) catch return error.InvalidJournal;
    const object = switch (value) {
        .object => |o| o,
        else => return error.InvalidJournal,
    };
    const schema = object.get("schema") orelse return error.InvalidJournal;
    const schema_text = switch (schema) {
        .string => |s| s,
        else => return error.InvalidJournal,
    };
    if (!std.mem.eql(u8, schema_text, "xsprof/journal/v1")) return error.InvalidJournal;
    const entries = object.get("entries") orelse return error.InvalidJournal;
    const array = switch (entries) {
        .array => |a| a,
        else => return error.InvalidJournal,
    };
    var out: std.ArrayList(event.RawEvent) = .empty;
    for (array.items) |item| {
        const parsed = event.fromValue(item) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJournal,
        };
        out.append(allocator, parsed) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(allocator);
}

/// Parse journal bytes. The returned events may reference strings in `data`
/// or in allocations made through `allocator`; keep both alive.
pub fn parseData(allocator: std.mem.Allocator, data: []const u8) ![]event.RawEvent {
    const trimmed = std.mem.trimStart(u8, data, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    const head = trimmed[0..@min(trimmed.len, 256)];
    if (std.mem.indexOf(u8, head, "\"xsprof/journal/v1\"") != null) {
        return parseWrapper(allocator, data);
    }

    var out: std.ArrayList(event.RawEvent) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const parsed = event.parseJson(allocator, line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJournal,
        };
        out.append(allocator, parsed) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(allocator);
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]event.RawEvent {
    const file = if (path.len != 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.JournalUnreadable
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.JournalUnreadable;
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const data = reader.interface.allocRemaining(allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.JournalTooLarge,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JournalUnreadable,
    };
    return parseData(allocator, data);
}

test "NDJSON parses and rejects mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":1,\"cpu\":-1," ++
        "\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0,\"host_mutation\":false}\n" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"page_fault\",\"ts_ns\":2,\"cpu\":0," ++
        "\"pid\":7,\"tid\":8,\"a\":1,\"b\":0,\"c\":0,\"host_mutation\":false}\n";
    const events = try parseData(arena.allocator(), data);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(event.Kind.page_fault, events[1].kind);

    const unsafe_data =
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"host_mutation\":true}\n";
    try std.testing.expectError(
        error.InvalidJournal,
        parseData(arena.allocator(), unsafe_data),
    );
}

test "journal wrapper parses entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "{\"schema\":\"xsprof/journal/v1\",\"host_mutation\":false,\"entries\":[" ++
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"ts_ns\":0," ++
        "\"cpu\":-1,\"pid\":-1,\"tid\":-1,\"a\":0,\"b\":0,\"c\":0," ++
        "\"detail\":\"session_start\",\"host_mutation\":false}]}";
    const events = try parseData(arena.allocator(), data);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("session_start", events[0].detail);
}

test "empty journal is empty, malformed journal is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try parseData(arena.allocator(), " \n\t")).len);
    try std.testing.expectError(
        error.InvalidJournal,
        parseData(arena.allocator(), "{\"schema\":\"nope\"}\n"),
    );
}
