//! Deterministic ordering for capture batches. Perf rings are drained per CPU
//! and per event type; without a merge, a switch that happened after a wakeup
//! can be processed before it. Every consumer gets the same order.

const std = @import("std");
const event = @import("../core/event.zig");

pub fn lessThan(_: void, a: event.RawEvent, b: event.RawEvent) bool {
    if (a.ts_ns != b.ts_ns) return a.ts_ns < b.ts_ns;
    if (a.cpu != b.cpu) return a.cpu < b.cpu;
    const a_kind: u16 = @backingInt(a.kind);
    const b_kind: u16 = @backingInt(b.kind);
    if (a_kind != b_kind) return a_kind < b_kind;
    if (a.pid != b.pid) return a.pid < b.pid;
    return a.a < b.a;
}

/// Sort in place. A stable order for equal keys is provided by `lessThan`'s
/// total ordering over timestamp, CPU, kind, pid, and a.
pub fn sortBatch(events: []event.RawEvent) void {
    std.mem.sortUnstable(event.RawEvent, events, {}, lessThan);
}

test "batch order is timestamp first and deterministic" {
    var events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 20, .cpu = 1, .a = 2, .b = 1 },
        .{ .kind = .sched_wakeup, .ts_ns = 10, .cpu = 1, .a = 2, .pid = 9 },
        .{ .kind = .sched_switch, .ts_ns = 10, .cpu = 0, .a = 3, .b = 0 },
        .{ .kind = .page_fault, .ts_ns = 20, .cpu = 0, .pid = 2, .a = 1 },
    };
    sortBatch(&events);
    try std.testing.expectEqual(@as(u64, 10), events[0].ts_ns);
    try std.testing.expectEqual(@as(u64, 10), events[1].ts_ns);
    try std.testing.expectEqual(@as(u64, 20), events[2].ts_ns);
    try std.testing.expectEqual(@as(u64, 20), events[3].ts_ns);
    try std.testing.expectEqual(@as(i32, 9), events[1].pid);
}
