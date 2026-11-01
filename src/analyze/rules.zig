//! Rule applicability and status. A rule is CLEAR only when every signal it
//! needs was collected; otherwise it is SKIP with a reason. Findings are the
//! only source of the FINDING state.

const std = @import("std");
const aggregates = @import("aggregates.zig");
const advisor = @import("advisor.zig");

pub const ids = [_][]const u8{
    "poor-numa-placement",
    "cpu-affinity-churn",
    "unnecessary-wakeups",
    "excessive-locking",
    "false-sharing",
    "allocator-fragmentation",
    "priority-inversion",
};

pub const Status = enum { finding, clear, skip };

pub const Report = struct {
    id: []const u8,
    status: Status,
    reason: []const u8,
};

const Support = struct {
    collected: bool,
    reason: []const u8,
};

fn support(id: []const u8, signals: aggregates.Signals) Support {
    if (std.mem.eql(u8, id, "poor-numa-placement")) {
        return if (signals.numa_fault)
            .{ .collected = true, .reason = "" }
        else
            .{ .collected = false, .reason = "NUMA fault/placement data was not captured" };
    }
    if (std.mem.eql(u8, id, "cpu-affinity-churn")) {
        if (!signals.sched_migrate) {
            return .{ .collected = false, .reason = "sched_migrate produced no events" };
        }
        if (!signals.cpu_topology) {
            return .{ .collected = false, .reason = "CPU LLC topology was not captured" };
        }
        return .{ .collected = true, .reason = "" };
    }
    if (std.mem.eql(u8, id, "unnecessary-wakeups")) {
        if (!signals.sched_switch) {
            return .{ .collected = false, .reason = "sched_switch produced no events" };
        }
        if (!signals.sched_wakeup) {
            return .{ .collected = false, .reason = "sched_wakeup produced no events" };
        }
        return .{ .collected = true, .reason = "" };
    }
    if (std.mem.eql(u8, id, "excessive-locking")) {
        return if (signals.lock_contention)
            .{ .collected = true, .reason = "" }
        else
            .{ .collected = false, .reason = "lock contention tracepoints were not captured" };
    }
    if (std.mem.eql(u8, id, "false-sharing")) {
        return if (signals.pmu_hitm)
            .{ .collected = true, .reason = "" }
        else
            .{ .collected = false, .reason = "PMU HITM counters were not captured" };
    }
    if (std.mem.eql(u8, id, "allocator-fragmentation")) {
        return if (signals.allocator)
            .{ .collected = true, .reason = "" }
        else
            .{ .collected = false, .reason = "buddyinfo/allocator data was not captured" };
    }
    if (std.mem.eql(u8, id, "priority-inversion")) {
        return if (signals.priority_inversion)
            .{ .collected = true, .reason = "" }
        else
            .{ .collected = false, .reason = "scheduler priorities and lock-owner chains were not captured" };
    }
    return .{ .collected = false, .reason = "unknown rule" };
}

fn hasFinding(findings: []const advisor.Finding, id: []const u8) bool {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.id, id)) return true;
    }
    return false;
}

pub fn reports(
    allocator: std.mem.Allocator,
    agg: aggregates.Aggregates,
    findings: []const advisor.Finding,
) ![]Report {
    const out = try allocator.alloc(Report, ids.len);
    for (ids, 0..) |id, index| {
        if (hasFinding(findings, id)) {
            out[index] = .{
                .id = id,
                .status = .finding,
                .reason = "threshold breached by the collected signal",
            };
            continue;
        }
        const state = support(id, agg.signals);
        out[index] = .{
            .id = id,
            .status = if (state.collected) .clear else .skip,
            .reason = if (state.collected) "required signals collected; below threshold" else state.reason,
        };
    }
    return out;
}

pub fn freeReports(allocator: std.mem.Allocator, reports_list: []Report) void {
    allocator.free(reports_list);
}

fn schedOnly() aggregates.Signals {
    return .{ .sched_switch = true, .sched_wakeup = true, .sched_migrate = true };
}

test "empty aggregates report seven SKIPs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const list = try reports(arena.allocator(), .{}, &.{});
    try std.testing.expectEqual(@as(usize, 7), list.len);
    for (list) |report| {
        try std.testing.expectEqual(Status.skip, report.status);
        try std.testing.expect(report.reason.len != 0);
    }
}

test "scheduler-only data clears wakeups but skips topology and priority" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const agg: aggregates.Aggregates = .{ .signals = schedOnly() };
    const list = try reports(arena.allocator(), agg, &.{});
    for (list) |report| {
        if (std.mem.eql(u8, report.id, "unnecessary-wakeups")) {
            try std.testing.expectEqual(Status.clear, report.status);
        }
        if (std.mem.eql(u8, report.id, "cpu-affinity-churn")) {
            try std.testing.expectEqual(Status.skip, report.status);
        }
        if (std.mem.eql(u8, report.id, "priority-inversion")) {
            try std.testing.expectEqual(Status.skip, report.status);
        }
        try std.testing.expect(report.status != .finding);
    }
}

test "collected allocator data can clear or find, never skip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const agg: aggregates.Aggregates = .{ .signals = .{ .allocator = true } };
    const list = try reports(arena.allocator(), agg, &.{});
    for (list) |report| {
        if (std.mem.eql(u8, report.id, "allocator-fragmentation")) {
            try std.testing.expectEqual(Status.clear, report.status);
        }
    }
}
