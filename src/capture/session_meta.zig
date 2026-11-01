//! Collect the metadata a captured journal needs for self and topology-aware
//! analysis. Markers are written into the journal; the host is only read.

const std = @import("std");
const builtin = @import("builtin");
const event = @import("../core/event.zig");
const session_meta = @import("../core/session_meta.zig");
const aggregates = @import("../analyze/aggregates.zig");
const proc = @import("../os/linux/proc.zig");
const topology = @import("../os/linux/topology.zig");

pub const max_cpus = session_meta.max_cpus;

pub fn collect(io: std.Io, allocator: std.mem.Allocator) ![]event.RawEvent {
    if (comptime builtin.os.tag != .linux) return &.{};
    return collectLinux(io, allocator);
}

fn collectLinux(io: std.Io, allocator: std.mem.Allocator) ![]event.RawEvent {
    var events: std.ArrayList(event.RawEvent) = .empty;
    const now = @as(u64, @intCast(@max(0, std.Io.Clock.now(.awake, io).nanoseconds)));

    const pid = std.os.linux.getpid();
    try events.append(allocator, .{
        .kind = .marker,
        .ts_ns = now,
        .cpu = -1,
        .pid = pid,
        .tid = pid,
        .comm = "xsprof",
        .detail = session_meta.capture_owner,
    });

    const cpu_count: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, max_cpus));
    const map = topology.collect(io, allocator, cpu_count);
    var cpu: u32 = 0;
    while (cpu < cpu_count) : (cpu += 1) {
        const index: usize = @intCast(cpu);
        const group = map.llc[index];
        if (group < 0) continue;
        try events.append(allocator, .{
            .kind = .marker,
            .ts_ns = now,
            .cpu = -1,
            .detail = try std.fmt.allocPrint(
                allocator,
                "cpu_llc cpu={d} llc={d}",
                .{ cpu, group },
            ),
        });
    }

    if (proc.collectFacts(io, allocator)) |facts| {
        if (facts.buddyinfo.len != 0) {
            if (aggregates.fragmentationFromBuddyLine(facts.buddyinfo[facts.buddyinfo.len - 1])) |ratio| {
                try events.append(allocator, .{
                    .kind = .marker,
                    .ts_ns = now,
                    .cpu = -1,
                    .detail = try std.fmt.allocPrint(
                        allocator,
                        "host_memory buddy_fragmentation={d:.6}",
                        .{ratio},
                    ),
                });
            }
        }
    } else |_| {}

    return events.toOwnedSlice(allocator);
}

test "non-linux collection is explicitly empty" {
    if (comptime builtin.os.tag != .linux) {
        const events = try collect(std.testing.io, std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }
}
