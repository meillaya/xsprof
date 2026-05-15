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
    try writer.print("Core Count: {d}\n", .{report.result.core_count});
    if (report.result.policy == .round_robin) try writer.print("Round Robin Quantum: {d}\n", .{report.result.quantum});

    if (report.result.domains.len != 0) {
        try writer.writeAll("Topology Domains:\n");
        for (report.result.domains) |domain| {
            try writer.print("- {s}: cores=", .{domain.id});
            for (domain.cores, 0..) |core_id, index| {
                if (index != 0) try writer.writeAll(",");
                try writer.print("{d}", .{core_id});
            }
            try writer.writeByte('\n');
        }
        try writer.writeByte('\n');
    }

    if (report.result.groups.len != 0) {
        try writer.writeAll("Groups:\n");
        for (report.result.groups) |group| {
            try writer.print("- {s}: weight={d} quota_ticks={d}\n", .{ group.id, group.weight, group.quota_ticks });
        }
        try writer.writeByte('\n');
    }

    try writer.writeAll("Completion Order: ");
    for (report.result.completion_order, 0..) |task_index, index| {
        if (index != 0) try writer.writeAll(" -> ");
        try writer.writeAll(report.result.tasks[task_index].id);
    }
    try writer.writeAll("\n\nTrace:\n");
    for (report.result.trace) |entry| {
        if (entry.task_id) |task_id| {
            if (entry.core_id) |core_id| {
                try writer.print("- t={d}: {s} {s} group={any} domain={any} core={d}\n", .{ entry.tick, trace.eventLabel(entry.kind), task_id, entry.group_id, entry.domain_id, core_id });
            } else {
                try writer.print("- t={d}: {s} {s} group={any} domain={any}\n", .{ entry.tick, trace.eventLabel(entry.kind), task_id, entry.group_id, entry.domain_id });
            }
        } else {
            if (entry.core_id) |core_id| {
                try writer.print("- t={d}: {s} domain={any} core={d}\n", .{ entry.tick, trace.eventLabel(entry.kind), entry.domain_id, core_id });
            } else {
                try writer.print("- t={d}: {s}\n", .{ entry.tick, trace.eventLabel(entry.kind) });
            }
        }
    }

    try writer.writeAll("\nPer-Task Metrics:\n");
    for (report.result.tasks) |task| {
        try writer.print("- {s}: arrival={d} burst={d} weight={d} group={any} ", .{ task.id, task.arrival_tick, task.burst_ticks, task.weight, task.group_id });
        if (task.sleep_after_ticks) |sleep_after_ticks| {
            try writer.print("sleep_after={d} ", .{sleep_after_ticks});
        } else {
            try writer.writeAll("sleep_after=- ");
        }
        try writer.print(
            "sleep_duration={d} phase_count={d} deadline={any} first_dispatch={d} completion={d} turnaround={d} waiting={d} blocked={d} response={d}\n",
            .{ task.sleep_duration, task.phase_count, task.deadline_tick, task.first_dispatch_tick, task.completion_time, task.turnaround_time, task.waiting_time, task.blocked_time, task.response_time },
        );
    }

    try writer.writeAll("\nAggregate Metrics:\n");
    try writer.print("- average_waiting_time: {d:.3}\n", .{report.result.aggregate.average_waiting_time});
    try writer.print("- average_response_time: {d:.3}\n", .{report.result.aggregate.average_response_time});
    try writer.print("- throughput: {d:.6} ({d}/{d} tasks/tick)\n", .{ report.result.aggregate.throughput, report.result.aggregate.throughput_numerator, report.result.aggregate.throughput_denominator });
    try writer.print("- waiting_time_spread: {d}\n", .{report.result.aggregate.waiting_time_spread});
    try writer.print("- max_waiting_time: {d}\n", .{report.result.aggregate.max_waiting_time});
    try writer.print("- max_response_time: {d}\n", .{report.result.aggregate.max_response_time});
    try writer.print("- response_time_spread: {d}\n", .{report.result.aggregate.response_time_spread});

    try writer.writeAll("\nNotes:\n");
    for (report_mod.SimulationReport.notes()) |note| try writer.print("- {s}\n", .{note});
}

pub fn writeJsonReport(writer: anytype, report: report_mod.SimulationReport) !void {
    const Writer = @TypeOf(writer.*);
    if (@hasDecl(Writer, "writeJsonValue")) {
        try writer.writeJsonValue(report);
        try writer.writeAll("\n");
        return;
    }

    try std.json.Stringify.value(report, .{}, writer);
    try writer.writeAll("\n");
}
