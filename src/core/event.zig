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
    /// Experimental per-PID sampled stack (perf software CPU clock +
    /// PERF_SAMPLE_CALLCHAIN). `a` is the sample IP; `stack` is the recorded
    /// callchain (leaf first) and may be absent for IP-only sampling.
    stack_sample,
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
    /// Raw callchain addresses for `stack_sample` rows (leaf first). Only the
    /// sampler produces this; every other kind must leave it empty.
    stack: []const u64 = &.{},
};

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

/// The task the row is about. Perf's sample TID is the CPU-current task, which
/// is the previous task for a switch and the waker for a wakeup; `comm` always
/// names the subject. Presentation must use this, not the raw sample pid.
pub fn subjectPid(entry: RawEvent) i32 {
    return switch (entry.kind) {
        .sched_switch, .sched_wakeup => @intCast(@min(entry.a, std.math.maxInt(i32))),
        else => entry.pid,
    };
}

/// The other participant when a row correlates two tasks (switch prev, wakeup
/// waker); -1 when there is no actor field.
pub fn actorPid(entry: RawEvent) i32 {
    return switch (entry.kind) {
        .sched_switch => @intCast(@min(entry.b, std.math.maxInt(i32))),
        .sched_wakeup => entry.pid,
        else => -1,
    };
}

/// Loss markers carry either `dropped=N` or `lost=N`. Return the magnitude so
/// the UI can report events, not marker rows.
pub fn lossMagnitude(detail: []const u8) u32 {
    var value: u32 = 1;
    inline for ([_][]const u8{ "dropped=", "lost=" }) |prefix| {
        if (std.mem.indexOf(u8, detail, prefix)) |at| {
            const start = at + prefix.len;
            var end = start;
            while (end < detail.len and std.ascii.isDigit(detail[end])) : (end += 1) {}
            if (end > start) {
                value = std.fmt.parseInt(u32, detail[start..end], 10) catch 1;
            }
        }
    }
    return value;
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
/// Wire bound for the optional sampled `stack` array (schema `maxItems`). The
/// sampler's `sample_max_stack` is capped to the same value.
pub const max_stack_frames = 64;

pub fn writeJson(w: *Writer, event: RawEvent) Writer.Error!void {
    var comm_buf: [15]u8 = undefined;
    var detail_buf: [detail_wire_buf]u8 = undefined;
    const comm = if (event.comm.len == 0) "" else privacy.boundComm(event.comm, &comm_buf);
    const detail = if (event.detail.len == 0)
        ""
    else
        privacy.redactDetail(event.detail, &detail_buf);

    var entries: [13]json.Entry = undefined;
    var stack_values: [max_stack_frames]json.Value = undefined;
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
    if (event.stack.len != 0) {
        // The sampler bounds this to max_stack_frames. A caller that violates
        // the contract is truncated at the schema bound rather than emitting an
        // invalid document; readers reject longer arrays at the boundary.
        const count = @min(event.stack.len, max_stack_frames);
        for (event.stack[0..count], 0..) |address, index| {
            stack_values[index] = .{ .unsigned = address };
        }
        entries[n] = .{ .key = "stack", .value = .{ .array = stack_values[0..count] } };
        n += 1;
    }
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

fn stackField(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    kind: Kind,
) ParseError![]const u64 {
    const value = object.get("stack") orelse return &.{};
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidEvent,
    };
    if (array.items.len > max_stack_frames) return error.InvalidEvent;
    if (array.items.len == 0) return &.{};
    // Only sampled-stack rows carry frames; a frames array on any other kind is
    // a semantic mismatch, not something to silently drop.
    if (kind != .stack_sample) return error.InvalidEvent;
    const stack = allocator.alloc(u64, array.items.len) catch return error.OutOfMemory;
    for (array.items, 0..) |item, index| {
        stack[index] = switch (item) {
            .integer => |integer| if (integer < 0) return error.InvalidEvent else @intCast(integer),
            .number_string => |text| std.fmt.parseInt(u64, text, 10) catch return error.InvalidEvent,
            else => return error.InvalidEvent,
        };
    }
    return stack;
}

/// Parse an already-decoded JSON object into an event. Strings point into the
/// decoded value; callers keep the owning arena/line alive. The allocator only
/// backs the optional sampled `stack` array.
pub fn fromValue(allocator: std.mem.Allocator, value: std.json.Value) ParseError!RawEvent {
    const object = switch (value) {
        .object => |o| o,
        else => return error.InvalidEvent,
    };
    const schema = try stringField(object, "schema") orelse return error.InvalidEvent;
    if (!std.mem.eql(u8, schema, "xsprof/event/v1")) return error.InvalidEvent;
    const mutation = object.get("host_mutation") orelse return error.InvalidEvent;
    switch (mutation) {
        .bool => |v| if (v) return error.UnsafeHostMutation,
        else => return error.InvalidEvent,
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
        .stack = try stackField(allocator, object, kind),
    };
}

/// Parse one JSON object into an event. Strings may point into `line`; callers
/// must keep the line alive (arena-based journal readers do).
pub const max_line_bytes = 64 * 1024;
pub const max_json_depth = 64;

pub fn parseJson(allocator: std.mem.Allocator, line: []const u8) ParseError!RawEvent {
    if (line.len > max_line_bytes or !json.depthOk(line, max_json_depth)) return error.InvalidEvent;
    const value = std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        line,
        .{ .max_value_len = line.len },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEvent,
    };
    return fromValue(allocator, value);
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

test "missing host_mutation is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidEvent,
        parseJson(arena.allocator(), "{\"schema\":\"xsprof/event/v1\",\"event\":\"marker\"}"),
    );
}

test "stack_sample matches the canonical ascending bytes" {
    const golden =
        "{\"a\":4096,\"b\":0,\"c\":0,\"comm\":\"worker\",\"cpu\":2,\"event\":\"stack_sample\"," ++
        "\"host_mutation\":false,\"pid\":100,\"schema\":\"xsprof/event/v1\"," ++
        "\"stack\":[4096,8192,12288],\"tid\":101,\"ts_ns\":3000000}";
    const stack = [_]u64{ 4096, 8192, 12288 };
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{
        .kind = .stack_sample,
        .ts_ns = 3_000_000,
        .cpu = 2,
        .pid = 100,
        .tid = 101,
        .a = 4096,
        .comm = "worker",
        .stack = &stack,
    });
    try std.testing.expectEqualStrings(golden, w.buffered());
}

test "stack_sample parses and enforces the stack bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const event = try parseJson(
        allocator,
        "{\"a\":4096,\"b\":0,\"c\":0,\"cpu\":2,\"event\":\"stack_sample\"," ++
            "\"host_mutation\":false,\"pid\":100,\"schema\":\"xsprof/event/v1\"," ++
            "\"stack\":[4096,8192],\"tid\":101,\"ts_ns\":3000000}",
    );
    try std.testing.expectEqual(Kind.stack_sample, event.kind);
    try std.testing.expectEqual(@as(usize, 2), event.stack.len);
    try std.testing.expectEqual(@as(u64, 8192), event.stack[1]);

    // 65 frames exceed the schema maxItems/reader bound.
    var big: [4096]u8 = undefined;
    var writer = Writer.fixed(&big);
    try writer.writeAll(
        "{\"a\":0,\"b\":0,\"c\":0,\"cpu\":0,\"event\":\"stack_sample\"," ++
            "\"host_mutation\":false,\"pid\":1,\"schema\":\"xsprof/event/v1\",\"stack\":[",
    );
    for (0..65) |index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{index});
    }
    try writer.writeAll("],\"tid\":1,\"ts_ns\":1}");
    try std.testing.expectError(error.InvalidEvent, parseJson(allocator, writer.buffered()));

    // A frames array on a non-sampled kind is a semantic mismatch.
    try std.testing.expectError(
        error.InvalidEvent,
        parseJson(
            allocator,
            "{\"a\":0,\"b\":0,\"c\":0,\"cpu\":0,\"event\":\"marker\"," ++
                "\"host_mutation\":false,\"pid\":-1,\"schema\":\"xsprof/event/v1\"," ++
                "\"stack\":[1],\"tid\":-1,\"ts_ns\":1}",
        ),
    );
    // Negative or non-integer frame addresses are refused.
    try std.testing.expectError(
        error.InvalidEvent,
        parseJson(
            allocator,
            "{\"a\":0,\"b\":0,\"c\":0,\"cpu\":0,\"event\":\"stack_sample\"," ++
                "\"host_mutation\":false,\"pid\":1,\"schema\":\"xsprof/event/v1\"," ++
                "\"stack\":[-1],\"tid\":1,\"ts_ns\":1}",
        ),
    );
    try std.testing.expectError(
        error.InvalidEvent,
        parseJson(
            allocator,
            "{\"a\":0,\"b\":0,\"c\":0,\"cpu\":0,\"event\":\"stack_sample\"," ++
                "\"host_mutation\":false,\"pid\":1,\"schema\":\"xsprof/event/v1\"," ++
                "\"stack\":[\"0x10\"],\"tid\":1,\"ts_ns\":1}",
        ),
    );
}

test "an IP-only stack_sample omits the stack array" {
    const golden =
        "{\"a\":4096,\"b\":0,\"c\":0,\"cpu\":2,\"event\":\"stack_sample\"," ++
        "\"host_mutation\":false,\"pid\":100,\"schema\":\"xsprof/event/v1\"," ++
        "\"tid\":101,\"ts_ns\":3000000}";
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeJson(&w, .{
        .kind = .stack_sample,
        .ts_ns = 3_000_000,
        .cpu = 2,
        .pid = 100,
        .tid = 101,
        .a = 4096,
    });
    try std.testing.expectEqualStrings(golden, w.buffered());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseJson(arena.allocator(), golden);
    try std.testing.expectEqual(@as(usize, 0), parsed.stack.len);
}
