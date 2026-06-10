const std = @import("std");
const contract = @import("report_contract");
const model = @import("model.zig");

pub const EventCount = struct {
    kind: contract.TraceEventKind,
    count: u32,
};

pub const CoreStats = struct {
    core_id: u32,
    arrivals: u32 = 0,
    dispatches: u32 = 0,
    busy_ticks: u32 = 0,
    preemptions: u32 = 0,
    blocks: u32 = 0,
    wakeups: u32 = 0,
    completions: u32 = 0,
    idle_events: u32 = 0,
};

pub const Derived = struct {
    allocator: std.mem.Allocator,
    core_stats: []CoreStats,
    tasks_by_input_order: []const *const model.TaskMetrics,
    event_counts: [contract.publicTraceEventKinds().len]EventCount,
    max_waiting_time: u32,
    max_turnaround_time: u32,

    pub fn deinit(self: *Derived) void {
        self.allocator.free(self.core_stats);
        self.allocator.free(self.tasks_by_input_order);
        self.* = undefined;
    }
};

pub fn derive(allocator: std.mem.Allocator, report: *const model.Report) !Derived {
    var core_stats = try allocator.alloc(CoreStats, report.core_count);
    errdefer allocator.free(core_stats);
    for (core_stats, 0..) |*entry, index| {
        entry.* = .{ .core_id = @intCast(index) };
    }

    var event_counts: [contract.publicTraceEventKinds().len]EventCount = undefined;
    for (contract.publicTraceEventKinds(), 0..) |kind, index| {
        event_counts[index] = .{ .kind = kind, .count = 0 };
    }

    for (report.trace) |entry| {
        incrementEventCount(&event_counts, entry.kind);
        if (entry.core_id) |core_id| {
            if (core_id < core_stats.len) {
                updateCoreStats(&core_stats[core_id], entry.kind);
            }
        }
    }

    var tasks_by_input_order = try allocator.alloc(*const model.TaskMetrics, report.tasks.len);
    errdefer allocator.free(tasks_by_input_order);
    var max_waiting_time: u32 = 0;
    var max_turnaround_time: u32 = 0;
    for (report.tasks, 0..) |*task, index| {
        tasks_by_input_order[index] = task;
        max_waiting_time = @max(max_waiting_time, task.waiting_time);
        max_turnaround_time = @max(max_turnaround_time, task.turnaround_time);
    }
    std.mem.sort(*const model.TaskMetrics, tasks_by_input_order, {}, lessThanTaskByInputOrder);

    return .{
        .allocator = allocator,
        .core_stats = core_stats,
        .tasks_by_input_order = tasks_by_input_order,
        .event_counts = event_counts,
        .max_waiting_time = max_waiting_time,
        .max_turnaround_time = max_turnaround_time,
    };
}

fn lessThanTaskByInputOrder(_: void, lhs: *const model.TaskMetrics, rhs: *const model.TaskMetrics) bool {
    if (lhs.input_order != rhs.input_order) return lhs.input_order < rhs.input_order;
    return std.mem.order(u8, lhs.id, rhs.id) == .lt;
}

fn incrementEventCount(event_counts: *[contract.publicTraceEventKinds().len]EventCount, kind: contract.TraceEventKind) void {
    for (event_counts) |*entry| {
        if (entry.kind == kind) {
            entry.count += 1;
            return;
        }
    }
}

fn updateCoreStats(core_stats: *CoreStats, kind: contract.TraceEventKind) void {
    switch (kind) {
        .arrival => core_stats.arrivals += 1,
        .dispatch => core_stats.dispatches += 1,
        .tick => core_stats.busy_ticks += 1,
        .preempt => core_stats.preemptions += 1,
        .block => core_stats.blocks += 1,
        .wakeup => core_stats.wakeups += 1,
        .complete => core_stats.completions += 1,
        .idle => core_stats.idle_events += 1,
    }
}
