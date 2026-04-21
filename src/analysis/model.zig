const std = @import("std");
const contract = @import("report_contract");

pub const Source = struct {
    kind: contract.SourceKind,
    value: []const u8,
};

pub const Scenario = struct {
    name: []const u8,
    round_robin_quantum: u32,
};

pub const Policy = struct {
    kind: contract.PolicyKind,
    display_name: []const u8,
    quantum: ?u32,
};

pub const TraceEntry = struct {
    tick: u32,
    kind: contract.TraceEventKind,
    task_id: ?[]const u8,
    core_id: ?u32,
};

pub const TaskMetrics = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    weight: u32,
    input_order: u32,
    first_dispatch_tick: u32,
    completion_time: u32,
    turnaround_time: u32,
    waiting_time: u32,
    response_time: u32,
    total_executed: u32,
};

pub const AggregateMetrics = struct {
    average_waiting_time: f64,
    average_response_time: f64,
    throughput: f64,
    throughput_numerator: u32,
    throughput_denominator: u32,
    waiting_time_spread: u32,
};

pub const Report = struct {
    schema: []const u8,
    version: u32,
    source: Source,
    scenario: Scenario,
    policy: Policy,
    core_count: u32,
    completion_order: []const []const u8,
    trace: []const TraceEntry,
    tasks: []const TaskMetrics,
    aggregate: AggregateMetrics,
    notes: []const []const u8,
};

const ReportHeader = struct {
    schema: ?[]const u8 = null,
    version: ?u32 = null,
};

pub fn parseReport(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Report) {
    var header = try std.json.parseFromSlice(ReportHeader, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();
    try contract.assertSupportedContract(header.value.schema, header.value.version);

    return try std.json.parseFromSlice(Report, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
}
