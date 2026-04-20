const std = @import("std");
const trace = @import("../sim/trace.zig");
const types = @import("../sim/types.zig");

pub fn writeSimulationReport(writer: anytype, scenario: *const types.ScenarioOwned, result: *const types.SimulationResult) !void {
    try writer.print("Scenario: {s}\n", .{scenario.name});
    try writer.print("Policy: {s}\n", .{result.policy.displayName()});
    if (result.policy == .round_robin) {
        try writer.print("Round Robin Quantum: {d}\n", .{result.quantum});
    }
    try writer.writeAll("Completion Order: ");
    for (result.completion_order, 0..) |task_index, index| {
        if (index != 0) try writer.writeAll(" -> ");
        try writer.writeAll(result.tasks[task_index].id);
    }
    try writer.writeAll("\n\nTrace:\n");
    for (result.trace) |entry| {
        if (entry.task_id) |task_id| {
            try writer.print("- t={d}: {s} {s}\n", .{ entry.tick, trace.eventLabel(entry.kind), task_id });
        } else {
            try writer.print("- t={d}: {s}\n", .{ entry.tick, trace.eventLabel(entry.kind) });
        }
    }

    try writer.writeAll("\nPer-Task Metrics:\n");
    for (result.tasks) |task| {
        try writer.print(
            "- {s}: arrival={d} burst={d} first_dispatch={d} completion={d} turnaround={d} waiting={d} response={d}\n",
            .{
                task.id,
                task.arrival_tick,
                task.burst_ticks,
                task.first_dispatch_tick,
                task.completion_time,
                task.turnaround_time,
                task.waiting_time,
                task.response_time,
            },
        );
    }

    try writer.writeAll("\nAggregate Metrics:\n");
    try writer.print("- average_waiting_time: {d:.3}\n", .{result.aggregate.average_waiting_time});
    try writer.print("- average_response_time: {d:.3}\n", .{result.aggregate.average_response_time});
    try writer.print(
        "- throughput: {d:.6} ({d}/{d} tasks/tick)\n",
        .{ result.aggregate.throughput, result.aggregate.throughput_numerator, result.aggregate.throughput_denominator },
    );
    try writer.print("- waiting_time_spread: {d}\n", .{result.aggregate.waiting_time_spread});

    try writer.writeAll("\nNotes:\n");
    try writer.writeAll("- Phase 1 is an in-process simulator only; it does not spawn or control real processes.\n");
    try writer.writeAll("- The CFS-inspired policy uses simple virtual-runtime-style accounting and is not faithful Linux CFS.\n");
}
