const std = @import("std");
const derive = @import("derive.zig");
const model = @import("model.zig");

pub fn render(allocator: std.mem.Allocator, report: *const model.Report, summary: *const derive.Derived) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try writer.writeAll("# zig-scheduler analysis report\n\n");
    try writer.print("- Contract: `{s}` v{d}\n", .{ report.schema, report.version });
    try writer.print("- Scenario: `{s}`\n", .{report.scenario.name});
    try writer.print("- Policy: `{s}` (`{s}`)\n", .{ report.policy.display_name, @tagName(report.policy.kind) });
    try writer.print("- Source: `{s}` `{s}`\n", .{ @tagName(report.source.kind), report.source.value });
    try writer.print("- Core count: {d}\n", .{report.core_count});
    try writer.print("- Task count: {d}\n", .{report.tasks.len});
    const completion_order = try std.mem.join(allocator, " -> ", report.completion_order);
    defer allocator.free(completion_order);
    try writer.print("- Completion order: `{s}`\n\n", .{completion_order});

    try writer.writeAll("## Aggregate metrics\n\n");
    try writer.writeAll("| metric | value |\n");
    try writer.writeAll("| --- | ---: |\n");
    try writer.print("| average_waiting_time | {d:.3} |\n", .{report.aggregate.average_waiting_time});
    try writer.print("| average_response_time | {d:.3} |\n", .{report.aggregate.average_response_time});
    try writer.print("| throughput | {d:.3} |\n", .{report.aggregate.throughput});
    try writer.print("| throughput_ratio | {d}/{d} |\n", .{ report.aggregate.throughput_numerator, report.aggregate.throughput_denominator });
    try writer.print("| waiting_time_spread | {d} |\n\n", .{report.aggregate.waiting_time_spread});

    try writer.writeAll("## Trace event counts\n\n");
    try writer.writeAll("| event | count |\n");
    try writer.writeAll("| --- | ---: |\n");
    for (summary.event_counts) |entry| {
        try writer.print("| {s} | {d} |\n", .{ @tagName(entry.kind), entry.count });
    }
    try writer.writeAll("\n");

    try writer.writeAll("## Per-core activity\n\n");
    try writer.writeAll("| core | arrivals | dispatches | busy_ticks | completions | idle_events | preemptions |\n");
    try writer.writeAll("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    for (summary.core_stats) |entry| {
        try writer.print(
            "| {d} | {d} | {d} | {d} | {d} | {d} | {d} |\n",
            .{ entry.core_id, entry.arrivals, entry.dispatches, entry.busy_ticks, entry.completions, entry.idle_events, entry.preemptions },
        );
    }
    try writer.writeAll("\n");

    try writer.writeAll("## Per-task metrics (input order)\n\n");
    try writer.writeAll("| task | arrival | burst | first_dispatch | completion | wait | response | turnaround | executed | weight |\n");
    try writer.writeAll("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n");
    for (summary.tasks_by_input_order) |task| {
        try writer.print(
            "| {s} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} |\n",
            .{
                task.id,
                task.arrival_tick,
                task.burst_ticks,
                task.first_dispatch_tick,
                task.completion_time,
                task.waiting_time,
                task.response_time,
                task.turnaround_time,
                task.total_executed,
                task.weight,
            },
        );
    }
    try writer.writeAll("\n");

    try writer.writeAll("## Export notes\n\n");
    for (report.notes) |note| {
        try writer.print("- {s}\n", .{note});
    }

    return try buffer.toOwnedSlice(allocator);
}
