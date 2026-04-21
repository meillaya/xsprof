const std = @import("std");
const report_mod = @import("report.zig");
const trace = @import("../sim/trace.zig");
const types = @import("../sim/types.zig");

pub fn writeSimulationReport(writer: anytype, scenario: *const types.ScenarioOwned, result: *const types.SimulationResult) !void {
    const report = report_mod.SimulationReport.init(.{ .kind = .builtin, .value = scenario.name }, scenario, result);
    try writeHumanReport(writer, report);
}

pub fn writeHumanReport(writer: anytype, report: report_mod.SimulationReport) !void {
    try writer.print("Scenario: {s}\n", .{report.scenario.name});
    try writer.print("Policy: {s}\n", .{report.result.policy.displayName()});
    if (report.result.policy == .round_robin) {
        try writer.print("Round Robin Quantum: {d}\n", .{report.result.quantum});
    }
    try writer.writeAll("Completion Order: ");
    for (report.result.completion_order, 0..) |task_index, index| {
        if (index != 0) try writer.writeAll(" -> ");
        try writer.writeAll(report.result.tasks[task_index].id);
    }
    try writer.writeAll("\n\nTrace:\n");
    for (report.result.trace) |entry| {
        if (entry.task_id) |task_id| {
            try writer.print("- t={d}: {s} {s}\n", .{ entry.tick, trace.eventLabel(entry.kind), task_id });
        } else {
            try writer.print("- t={d}: {s}\n", .{ entry.tick, trace.eventLabel(entry.kind) });
        }
    }

    try writer.writeAll("\nPer-Task Metrics:\n");
    for (report.result.tasks) |task| {
        try writer.print(
            "- {s}: arrival={d} burst={d} weight={d} first_dispatch={d} completion={d} turnaround={d} waiting={d} response={d}\n",
            .{
                task.id,
                task.arrival_tick,
                task.burst_ticks,
                task.weight,
                task.first_dispatch_tick,
                task.completion_time,
                task.turnaround_time,
                task.waiting_time,
                task.response_time,
            },
        );
    }

    try writer.writeAll("\nAggregate Metrics:\n");
    try writer.print("- average_waiting_time: {d:.3}\n", .{report.result.aggregate.average_waiting_time});
    try writer.print("- average_response_time: {d:.3}\n", .{report.result.aggregate.average_response_time});
    try writer.print(
        "- throughput: {d:.6} ({d}/{d} tasks/tick)\n",
        .{ report.result.aggregate.throughput, report.result.aggregate.throughput_numerator, report.result.aggregate.throughput_denominator },
    );
    try writer.print("- waiting_time_spread: {d}\n", .{report.result.aggregate.waiting_time_spread});

    try writer.writeAll("\nNotes:\n");
    for (report_mod.SimulationReport.notes()) |note| {
        try writer.print("- {s}\n", .{note});
    }
}

pub fn writeJsonReport(writer: anytype, report: report_mod.SimulationReport) !void {
    const Writer = @TypeOf(writer.*);
    if (@hasField(Writer, "vtable")) {
        try std.json.Stringify.value(report, .{}, writer);
        try writer.writeAll("\n");
        return;
    }

    var bridge_buffer: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&bridge_buffer);
    try std.json.Stringify.value(report, .{}, &adapter.new_interface);
    if (adapter.err) |err| return err;
    try adapter.new_interface.flush();
}
