const std = @import("std");
const types = @import("types.zig");

pub fn computeAggregate(tasks: []const types.TaskMetrics) types.AggregateMetrics {
    var waiting_sum: u64 = 0;
    var response_sum: u64 = 0;
    var min_waiting: u32 = 0;
    var max_waiting: u32 = 0;
    var min_response: u32 = 0;
    var max_response: u32 = 0;
    var earliest_arrival: u32 = 0;
    var latest_completion: u32 = 0;

    for (tasks, 0..) |task, index| {
        waiting_sum += task.waiting_time;
        response_sum += task.response_time;
        if (index == 0 or task.waiting_time < min_waiting) min_waiting = task.waiting_time;
        if (index == 0 or task.waiting_time > max_waiting) max_waiting = task.waiting_time;
        if (index == 0 or task.response_time < min_response) min_response = task.response_time;
        if (index == 0 or task.response_time > max_response) max_response = task.response_time;
        if (index == 0 or task.arrival_tick < earliest_arrival) earliest_arrival = task.arrival_tick;
        if (index == 0 or task.completion_time > latest_completion) latest_completion = task.completion_time;
    }

    const task_count = @as(f64, @floatFromInt(tasks.len));
    const throughput_denominator = latest_completion - earliest_arrival;
    const throughput = if (throughput_denominator == 0)
        0.0
    else
        @as(f64, @floatFromInt(tasks.len)) / @as(f64, @floatFromInt(throughput_denominator));

    return .{
        .average_waiting_time = @as(f64, @floatFromInt(waiting_sum)) / task_count,
        .average_response_time = @as(f64, @floatFromInt(response_sum)) / task_count,
        .throughput = throughput,
        .throughput_numerator = @intCast(tasks.len),
        .throughput_denominator = throughput_denominator,
        .waiting_time_spread = max_waiting - min_waiting,
        .max_waiting_time = max_waiting,
        .max_response_time = max_response,
        .response_time_spread = max_response - min_response,
    };
}
