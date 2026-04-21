const std = @import("std");

pub const schema_name = "zig-scheduler/report";
pub const schema_version: u32 = 1;

pub const top_level_fields = [_][]const u8{
    "schema",
    "version",
    "source",
    "scenario",
    "policy",
    "core_count",
    "completion_order",
    "trace",
    "tasks",
    "aggregate",
    "notes",
};
pub const source_fields = [_][]const u8{
    "kind",
    "value",
};
pub const scenario_fields = [_][]const u8{
    "name",
    "round_robin_quantum",
};
pub const policy_fields = [_][]const u8{
    "kind",
    "display_name",
    "quantum",
};
pub const trace_entry_fields = [_][]const u8{
    "tick",
    "kind",
    "task_id",
    "core_id",
};
pub const task_fields = [_][]const u8{
    "id",
    "arrival_tick",
    "burst_ticks",
    "weight",
    "sleep_after_ticks",
    "sleep_duration",
    "phase_count",
    "deadline_tick",
    "input_order",
    "first_dispatch_tick",
    "completion_time",
    "turnaround_time",
    "waiting_time",
    "blocked_time",
    "response_time",
    "total_executed",
};
pub const aggregate_fields = [_][]const u8{
    "average_waiting_time",
    "average_response_time",
    "throughput",
    "throughput_numerator",
    "throughput_denominator",
    "waiting_time_spread",
    "max_waiting_time",
    "max_response_time",
    "response_time_spread",
};

pub const ContractError = error{
    MissingSchema,
    UnsupportedSchema,
    MissingVersion,
    UnsupportedVersion,
};

pub const SourceKind = enum {
    builtin,
    file,
};

pub const PolicyKind = enum {
    fcfs,
    round_robin,
    cfs_like,
    deadline,
};

pub const TraceEventKind = enum {
    arrival,
    dispatch,
    tick,
    preempt,
    block,
    wakeup,
    complete,
    idle,
};

const public_trace_event_kinds = [_]TraceEventKind{
    .arrival,
    .dispatch,
    .tick,
    .preempt,
    .block,
    .wakeup,
    .complete,
    .idle,
};

pub fn assertSupportedContract(schema: ?[]const u8, version: ?u32) ContractError!void {
    const actual_schema = schema orelse return error.MissingSchema;
    if (!std.mem.eql(u8, actual_schema, schema_name)) return error.UnsupportedSchema;

    const actual_version = version orelse return error.MissingVersion;
    if (actual_version != schema_version) return error.UnsupportedVersion;
}

pub fn publicTraceEventKinds() []const TraceEventKind {
    return public_trace_event_kinds[0..];
}
