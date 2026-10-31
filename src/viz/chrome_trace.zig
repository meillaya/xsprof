//! Chrome Trace Event Format export for `xsprof/event/v1` rows.
//!
//! Corrections over the archived implementation:
//! - sched_switch durations come from the next switch on the same CPU;
//! - wakeup flows have a matching end when the task is switched in;
//! - timestamps are microseconds everywhere (display unit is ms);
//! - loss is only signalled by explicit loss events, never inferred gaps.

const std = @import("std");
const event = @import("../core/event.zig");

const Writer = std.Io.Writer;

pub const TimeWindow = struct {
    start_us: u64 = 0,
    end_us: ?u64 = null,

    pub fn contains(self: TimeWindow, ts_us: u64) bool {
        if (ts_us < self.start_us) return false;
        if (self.end_us) |end| {
            if (ts_us > end) return false;
        }
        return true;
    }
};

pub fn parseWindow(text: []const u8) ?TimeWindow {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const start = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    if (colon + 1 >= text.len) return null;
    const end_text = text[colon + 1 ..];
    const end = std.fmt.parseInt(u64, end_text, 10) catch return null;
    if (end != 0 and end < start) return null;
    return .{ .start_us = start, .end_us = if (end == 0) null else end };
}

const Args = union(enum) {
    none,
    name: []const u8,
    pids: struct { next: u64, prev: u64 },
    cpus: struct { orig: u64, dest: u64 },
    count: u64,
    loss: []const u8,
    text: []const u8,
    bp_end,
};

const TraceEvent = struct {
    name: []const u8,
    cat: []const u8,
    ph: []const u8,
    ts_us: u64 = 0,
    dur_us: u64 = 0,
    pid: i64 = -1,
    tid: i64 = -1,
    id: u64 = 0,
    args: Args = .none,
};

fn writeArgs(w: *Writer, args: Args) Writer.Error!void {
    switch (args) {
        .none => {},
        .name => |name| {
            try w.writeAll("\"args\":{\"name\":");
            try @import("../core/json.zig").write(w, .{ .string = name });
            try w.writeByte('}');
        },
        .pids => |pids| try w.print(
            "\"args\":{{\"next_pid\":{d},\"prev_pid\":{d}}}",
            .{ pids.next, pids.prev },
        ),
        .cpus => |cpus| try w.print(
            "\"args\":{{\"dest_cpu\":{d},\"orig_cpu\":{d}}}",
            .{ cpus.dest, cpus.orig },
        ),
        .count => |count| try w.print("\"args\":{{\"count\":{d}}}", .{count}),
        .loss => |reason| {
            try w.writeAll("\"args\":{\"reason\":");
            try @import("../core/json.zig").write(w, .{ .string = reason });
            try w.writeAll(",\"unsafe\":true}");
        },
        .text => |detail| {
            try w.writeAll("\"args\":{\"detail\":");
            try @import("../core/json.zig").write(w, .{ .string = detail });
            try w.writeByte('}');
        },
        .bp_end => try w.writeAll("\"args\":{\"bp\":\"e\"}"),
    }
}

fn writeTraceEvent(w: *Writer, e: TraceEvent) Writer.Error!void {
    try w.writeByte('{');
    try writeArgs(w, e.args);
    if (e.args != .none) try w.writeByte(',');
    const json = @import("../core/json.zig");
    try w.writeAll("\"cat\":");
    try json.write(w, .{ .string = e.cat });
    if (std.mem.eql(u8, e.ph, "X")) {
        try w.print(",\"dur\":{d}", .{e.dur_us});
    }
    if (e.ph.len == 1 and (e.ph[0] == 's' or e.ph[0] == 'f')) {
        try w.print(",\"id\":{d}", .{e.id});
    }
    try w.writeAll(",\"name\":");
    try json.write(w, .{ .string = e.name });
    try w.writeAll(",\"ph\":");
    try json.write(w, .{ .string = e.ph });
    try w.print(",\"pid\":{d},\"tid\":{d},\"ts\":{d}", .{ e.pid, e.tid, e.ts_us });
    try w.writeByte('}');
}

fn push(list: *std.ArrayList(TraceEvent), allocator: std.mem.Allocator, e: TraceEvent) !void {
    try list.append(allocator, e);
}

fn metadata(list: *std.ArrayList(TraceEvent), allocator: std.mem.Allocator) !void {
    try push(list, allocator, .{
        .name = "process_name",
        .cat = "__metadata",
        .ph = "M",
        .pid = -1,
        .tid = 0,
        .args = .{ .name = "CPUs" },
    });
}

fn lossReason(detail: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, detail, "sample_loss") != null or
        std.mem.indexOf(u8, detail, "lost") != null)
    {
        return detail;
    }
    return null;
}

fn buildTrace(
    allocator: std.mem.Allocator,
    events: []const event.RawEvent,
    window: ?TimeWindow,
) ![]TraceEvent {
    var list: std.ArrayList(TraceEvent) = .empty;
    try metadata(&list, allocator);

    const durations = try allocator.alloc(u64, events.len);
    @memset(durations, 0);
    var next_switch = std.AutoHashMap(i32, u64).init(allocator);
    defer next_switch.deinit();
    var i = events.len;
    while (i > 0) {
        i -= 1;
        const e = events[i];
        if (e.kind != .sched_switch) continue;
        if (next_switch.get(e.cpu)) |next_ts| {
            if (next_ts >= e.ts_ns) durations[i] = next_ts - e.ts_ns;
        }
        try next_switch.put(e.cpu, e.ts_ns);
    }

    var pending = std.AutoHashMap(u64, struct { id: u64, pid: i32, tid: i32 }).init(allocator);
    defer pending.deinit();
    var flow_id: u64 = 0;

    for (events, 0..) |e, index| {
        const ts_us = e.ts_ns / 1000;
        if (window) |w| {
            if (!w.contains(ts_us)) continue;
        }
        switch (e.kind) {
            .sched_switch => {
                try push(&list, allocator, .{
                    .name = if (e.comm.len == 0) "run" else e.comm,
                    .cat = "sched",
                    .ph = "X",
                    .ts_us = ts_us,
                    .dur_us = durations[index] / 1000,
                    .pid = -1,
                    .tid = e.cpu,
                    .args = .{ .pids = .{ .next = e.a, .prev = e.b } },
                });
                if (pending.fetchRemove(e.a)) |entry| {
                    try push(&list, allocator, .{
                        .name = "wakeup",
                        .cat = "sched",
                        .ph = "f",
                        .ts_us = ts_us,
                        .pid = -1,
                        .tid = e.cpu,
                        .id = entry.value.id,
                        .args = .bp_end,
                    });
                }
            },
            .sched_wakeup => {
                flow_id += 1;
                try pending.put(e.a, .{ .id = flow_id, .pid = e.pid, .tid = e.tid });
                try push(&list, allocator, .{
                    .name = "wakeup",
                    .cat = "sched",
                    .ph = "s",
                    .ts_us = ts_us,
                    .pid = e.pid,
                    .tid = e.tid,
                    .id = flow_id,
                });
            },
            .sched_migrate => try push(&list, allocator, .{
                .name = "migrate",
                .cat = "sched",
                .ph = "i",
                .ts_us = ts_us,
                .pid = e.pid,
                .tid = e.tid,
                .args = .{ .cpus = .{ .orig = e.a, .dest = e.b } },
            }),
            .page_fault => try push(&list, allocator, .{
                .name = "page_fault",
                .cat = "memory",
                .ph = "i",
                .ts_us = ts_us,
                .pid = e.pid,
                .tid = e.tid,
                .args = .{ .count = e.a },
            }),
            .marker => {
                if (lossReason(e.detail)) |reason| {
                    try push(&list, allocator, .{
                        .name = "SAMPLE_LOSS",
                        .cat = "unsafe",
                        .ph = "i",
                        .ts_us = ts_us,
                        .pid = e.pid,
                        .tid = e.tid,
                        .args = .{ .loss = reason },
                    });
                } else {
                    try push(&list, allocator, .{
                        .name = "marker",
                        .cat = "control",
                        .ph = "i",
                        .ts_us = ts_us,
                        .pid = e.pid,
                        .tid = e.tid,
                        .args = if (e.detail.len == 0) .none else .{ .text = e.detail },
                    });
                }
            },
            .refusal, .incident => try push(&list, allocator, .{
                .name = event.kindName(e.kind),
                .cat = "unsafe",
                .ph = "i",
                .ts_us = ts_us,
                .pid = e.pid,
                .tid = e.tid,
                .args = if (e.detail.len == 0) .none else .{ .text = e.detail },
            }),
            .capability => try push(&list, allocator, .{
                .name = "capability",
                .cat = "control",
                .ph = "i",
                .ts_us = ts_us,
                .pid = e.pid,
                .tid = e.tid,
                .args = if (e.detail.len == 0) .none else .{ .text = e.detail },
            }),
            .runtime_sample => try push(&list, allocator, .{
                .name = "runtime_sample",
                .cat = "runtime",
                .ph = "i",
                .ts_us = ts_us,
                .pid = e.pid,
                .tid = e.tid,
                .args = if (e.detail.len == 0) .none else .{ .text = e.detail },
            }),
            else => {},
        }
    }
    return list.toOwnedSlice(allocator);
}

fn writeDocument(w: *Writer, trace: []const TraceEvent) Writer.Error!void {
    try w.writeAll("{\"displayTimeUnit\":\"ms\",\"traceEvents\":[");
    for (trace, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try writeTraceEvent(w, e);
    }
    try w.writeAll("]}");
}

pub fn writeTimeline(
    w: *Writer,
    allocator: std.mem.Allocator,
    events: []const event.RawEvent,
    window: ?TimeWindow,
    chunk_size: ?usize,
) !void {
    if (chunk_size) |size| {
        if (size == 0) return error.InvalidChunkSize;
        var index: usize = 0;
        var first = true;
        try w.writeAll("{\"chunks\":[");
        while (index < events.len) {
            const end = @min(index + size, events.len);
            if (!first) try w.writeByte(',');
            first = false;
            const trace = try buildTrace(allocator, events[index..end], window);
            try writeDocument(w, trace);
            index = end;
        }
        if (events.len == 0) {
            const trace = try buildTrace(allocator, &.{}, window);
            try writeDocument(w, trace);
        }
        try w.writeAll("]}\n");
        return;
    }
    const trace = try buildTrace(allocator, events, window);
    try writeDocument(w, trace);
    try w.writeByte('\n');
}

test "window parsing rejects invalid ranges" {
    const window = parseWindow("100:500").?;
    try std.testing.expectEqual(@as(u64, 100), window.start_us);
    try std.testing.expectEqual(@as(?u64, 500), window.end_us);
    try std.testing.expect(parseWindow("500:100") == null);
    try std.testing.expect(parseWindow("bad") == null);
    try std.testing.expect(parseWindow("1:2:3") == null);
}

test "switch durations and wakeup flows are corrected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .comm = "idle", .a = 0, .b = 0 },
        .{ .kind = .sched_wakeup, .ts_ns = 100_000, .cpu = 0, .pid = 5, .tid = 6, .a = 5, .b = 0 },
        .{ .kind = .sched_switch, .ts_ns = 200_000, .cpu = 0, .comm = "worker", .a = 5, .b = 0 },
        .{ .kind = .sched_switch, .ts_ns = 500_000, .cpu = 0, .comm = "idle", .a = 0, .b = 5 },
        .{ .kind = .marker, .ts_ns = 600_000, .detail = "sample_loss ring_overflow" },
    };
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeTimeline(&w, arena.allocator(), &events, null, null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"displayTimeUnit\":\"ms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"worker\",\"ph\":\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"dur\":300") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ph\":\"s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ph\":\"f\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"SAMPLE_LOSS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"unsafe\":true") != null);
}

test "chunked output is bounded and windowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .a = 1 },
        .{ .kind = .page_fault, .ts_ns = 1_000_000, .cpu = 0, .a = 1 },
        .{ .kind = .page_fault, .ts_ns = 2_000_000, .cpu = 0, .a = 1 },
    };
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeTimeline(&w, arena.allocator(), &events, .{ .start_us = 500, .end_us = 2500 }, 2);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"chunks\":["));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"chunks\":[]") == null);
}
