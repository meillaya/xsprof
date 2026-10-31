//! The profiler event spine and its canonical `xsprof/event/v1` wire form.

const std = @import("std");
const json = @import("json.zig");
const privacy = @import("privacy.zig");

const Writer = std.Io.Writer;

pub const Kind = enum(u16) {
    sched_switch,
    sched_wakeup,
    sched_migrate,
    runqueue_sample,
    priority_inversion,
    lock_contention,
    page_fault,
    tlb_miss,
    cache_miss,
    huge_page,
    numa_balance,
    alloc_sample,
    malloc_hotspot,
    marker,
    capability,
    refusal,
    incident,
    runtime_sample,
};

pub const RawEvent = struct {
    kind: Kind = .marker,
    ts_ns: u64 = 0,
    cpu: i32 = -1,
    pid: i32 = -1,
    tid: i32 = -1,
    a: u64 = 0,
    b: u64 = 0,
    c: u64 = 0,
    comm: []const u8 = "",
    detail: []const u8 = "",
};

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn kindFromName(name: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".field_names) |field_name| {
        if (std.mem.eql(u8, name, field_name)) return @field(Kind, field_name);
    }
    return null;
}

pub const max_comm_len = 1024;
pub const max_detail_len = 16 * 1024;
pub const detail_wire_buf = 1024;

pub fn writeJson(w: *Writer, event: RawEvent) Writer.Error!void {
    var comm_buf: [15]u8 = undefined;
    var detail_buf: [detail_wire_buf]u8 = undefined;
    const comm = if (event.comm.len == 0) "" else privacy.boundComm(event.comm, &comm_buf);
    const detail = if (event.detail.len == 0)
        ""
    else
        privacy.redactDetail(event.detail, &detail_buf);

    var entries: [12]json.Entry = undefined;
    var n: usize = 0;
    entries[n] = .{ .key = "a", .value = .{ .unsigned = event.a } };
    n += 1;
    entries[n] = .{ .key = "b", .value = .{ .unsigned = event.b } };
    n += 1;
    entries[n] = .{ .key = "c", .value = .{ .unsigned = event.c } };
    n += 1;
    if (comm.len != 0) {
        entries[n] = .{ .key = "comm", .value = .{ .string = comm } };
        n += 1;
    }
    entries[n] = .{ .key = "cpu", .value = .{ .integer = event.cpu } };
    n += 1;
    if (detail.len != 0) {
        entries[n] = .{ .key = "detail", .value = .{ .string = detail } };
        n += 1;
    }
    entries[n] = .{ .key = "event", .value = .{ .string = kindName(event.kind) } };
    n += 1;
    entries[n] = .{ .key = "host_mutation", .value = .{ .boolean = false } };
    n += 1;
    entries[n] = .{ .key = "pid", .value = .{ .integer = event.pid } };
    n += 1;
    entries[n] = .{ .key = "schema", .value = .{ .string = "xsprof/event/v1" } };
    n += 1;
    entries[n] = .{ .key = "tid", .value = .{ .integer = event.tid } };
    n += 1;
    entries[n] = .{ .key = "ts_ns", .value = .{ .unsigned = event.ts_ns } };
    n += 1;
    try json.write(w, .{ .object = entries[0..n] });
}

fn stringField(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidEvent,
    };
}

fn intField(object: std.json.ObjectMap, key: []const u8, default: i64) !i64 {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch error.InvalidEvent,
        else => error.InvalidEvent,
    };
}

fn uintField(object: std.json.ObjectMap, key: []const u8, default: u64) !u64 {
    const value = object.get(key) orelse return default;
    return switch (value) {
        .integer => |i| if (i < 0) error.InvalidEvent else @intCast(i),
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch error.InvalidEvent,
        else => error.InvalidEvent,
    };
}

pub const ParseError = error{
    InvalidEvent,
    UnsafeHostMutation,
    OutOfMemory,
} || std.fmt.ParseIntError;

/// Parse one JSON object into an event. Strings may point into `line`; callers
/// must keep the line alive (arena-based journal readers do).
pub fn parseJson(allocator: std.mem.Allocator, line: []const u8) ParseError!RawEvent {
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        line,
        .{ .max_value_len = line.len },
    ) catch return error.InvalidEvent;
    const object = switch (value) {
        .object => |o| o,
        else => return error.InvalidEvent,
    };
    const schema = try stringField(object, "schema") orelse return error.InvalidEvent;
    if (!std.mem.eql(u8, schema, "xsprof/event/v1")) return error.InvalidEvent;
    if (object.get("host_mutation")) |mutation| {
        switch (mutation) {
            .bool => |v| if (v) return error.UnsafeHostMutation,
            else => return error.InvalidEvent,
        }
    }
    const event_name = try stringField(object, "event") orelse return error.InvalidEvent;
    const kind = kindFromName(event_name) orelse return error.InvalidEvent;
    const comm = try stringField(object, "comm") orelse "";
    const detail = try stringField(object, "detail") orelse "";
    if (comm.len > max_comm_len or detail.len > max_detail_len) return error.InvalidEvent;
    return .{
        .kind = kind,
        .ts_ns = try uintField(object, "ts_ns", 0),
        .cpu = std.math.cast(i32, try intField(object, "cpu", -1)) orelse return error.InvalidEvent,
        .pid = std.math.cast(i32, try intField(object, "pid", -1)) orelse return error.InvalidEvent,
        .tid = std.math.cast(i32, try intField(object, "tid", -1)) orelse return error.InvalidEvent,
        .a = try uintField(object, "a", 0),
        .b = try uintField(object, "b", 0),
        .c = try uintField(object, "c", 0),
        .comm = comm,
        .detail = detail,
    };
}

test "sched_switch matches the archived golden bytes" {
    const golden =
        "{\"a\":0,\"b\":0,\"c\":0,\"comm\":\"worker\",\"cpu\":3,\"event\":\"sched_switch\"," ++
        "\"host_mutation\":false,\"pid\":100,\"schema\":\"xsprof/event/v1\",\"tid\":101," ++
        "\"ts_ns\":1000000}";
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{
        .kind = .sched_switch,
        .ts_ns = 1_000_000,
        .cpu = 3,
        .pid = 100,
        .tid = 101,
        .comm = "worker",
    });
    try std.testing.expectEqualStrings(golden, w.buffered());
}

test "page_fault matches the archived golden bytes" {
    const golden =
        "{\"a\":3,\"b\":0,\"c\":0,\"cpu\":1,\"event\":\"page_fault\"," ++
        "\"host_mutation\":false,\"pid\":200,\"schema\":\"xsprof/event/v1\",\"tid\":201," ++
        "\"ts_ns\":2000000}";
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{
        .kind = .page_fault,
        .ts_ns = 2_000_000,
        .cpu = 1,
        .pid = 200,
        .tid = 201,
        .a = 3,
    });
    try std.testing.expectEqualStrings(golden, w.buffered());
}

test "event parses and rejects mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const event = try parseJson(
        arena.allocator(),
        "{\"schema\":\"xsprof/event/v1\",\"event\":\"sched_wakeup\",\"ts_ns\":7," ++
            "\"cpu\":2,\"pid\":9,\"tid\":9,\"a\":42,\"b\":2,\"host_mutation\":false}",
    );
    try std.testing.expectEqual(Kind.sched_wakeup, event.kind);
    try std.testing.expectEqual(@as(u64, 42), event.a);
    try std.testing.expectError(
        error.UnsafeHostMutation,
        parseJson(
            arena.allocator(),
            "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\",\"host_mutation\":true}",
        ),
    );
    try std.testing.expectError(
        error.InvalidEvent,
        parseJson(arena.allocator(), "{\"schema\":\"other/v1\",\"event\":\"marker\"}"),
    );
}

test "privacy is enforced by the serializer" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{
        .kind = .marker,
        .comm = "abcdefghijklmnopqrstuvwxyz",
        .detail = "token=supersecret",
    });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "abcdefghijklmno") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "supersecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[REDACTED]") != null);
}
