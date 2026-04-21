const std = @import("std");
const trace = @import("../sim/trace.zig");
const types = @import("../sim/types.zig");

pub const schema_name = "zig-scheduler/report";
pub const schema_version: u32 = 1;
pub const top_level_fields = [_][]const u8{
    "schema",
    "version",
    "source",
    "scenario",
    "policy",
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
};
pub const task_fields = [_][]const u8{
    "id",
    "arrival_tick",
    "burst_ticks",
    "weight",
    "input_order",
    "first_dispatch_tick",
    "completion_time",
    "turnaround_time",
    "waiting_time",
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

pub const SourceInfo = struct {
    kind: SourceKind,
    value: []const u8,
};

pub fn assertSupportedContract(schema: ?[]const u8, version: ?u32) ContractError!void {
    const actual_schema = schema orelse return error.MissingSchema;
    if (!std.mem.eql(u8, actual_schema, schema_name)) return error.UnsupportedSchema;

    const actual_version = version orelse return error.MissingVersion;
    if (actual_version != schema_version) return error.UnsupportedVersion;
}

pub fn publicTraceEventKinds() []const types.TraceEventKind {
    return trace.public_event_kinds[0..];
}

pub const SimulationReport = struct {
    source: SourceInfo,
    scenario: *const types.ScenarioOwned,
    result: *const types.SimulationResult,

    pub fn init(source: SourceInfo, scenario: *const types.ScenarioOwned, result: *const types.SimulationResult) SimulationReport {
        return .{
            .source = source,
            .scenario = scenario,
            .result = result,
        };
    }

    pub fn notes() []const []const u8 {
        return report_notes[0..];
    }

    pub fn jsonStringify(self: SimulationReport, jw: anytype) !void {
        try jw.beginObject();

        try jw.objectField("schema");
        try jw.write(schema_name);

        try jw.objectField("version");
        try jw.write(schema_version);

        try jw.objectField("source");
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(self.source.kind);
        try jw.objectField("value");
        try jw.write(self.source.value);
        try jw.endObject();

        try jw.objectField("scenario");
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.scenario.name);
        try jw.objectField("round_robin_quantum");
        try jw.write(self.scenario.round_robin_quantum);
        try jw.endObject();

        try jw.objectField("policy");
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write(self.result.policy);
        try jw.objectField("display_name");
        try jw.write(self.result.policy.displayName());
        try jw.objectField("quantum");
        try jw.write(if (self.result.policy == .round_robin) @as(?u32, self.result.quantum) else null);
        try jw.endObject();

        try jw.objectField("completion_order");
        try jw.beginArray();
        for (self.result.completion_order) |task_index| {
            try jw.write(self.result.tasks[task_index].id);
        }
        try jw.endArray();

        try jw.objectField("trace");
        try jw.beginArray();
        for (self.result.trace) |entry| {
            try jw.beginObject();
            try jw.objectField("tick");
            try jw.write(entry.tick);
            try jw.objectField("kind");
            try jw.write(entry.kind);
            try jw.objectField("task_id");
            try jw.write(entry.task_id);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("tasks");
        try jw.beginArray();
        for (self.result.tasks) |task| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(task.id);
            try jw.objectField("arrival_tick");
            try jw.write(task.arrival_tick);
            try jw.objectField("burst_ticks");
            try jw.write(task.burst_ticks);
            try jw.objectField("weight");
            try jw.write(task.weight);
            try jw.objectField("input_order");
            try jw.write(task.input_order);
            try jw.objectField("first_dispatch_tick");
            try jw.write(task.first_dispatch_tick);
            try jw.objectField("completion_time");
            try jw.write(task.completion_time);
            try jw.objectField("turnaround_time");
            try jw.write(task.turnaround_time);
            try jw.objectField("waiting_time");
            try jw.write(task.waiting_time);
            try jw.objectField("response_time");
            try jw.write(task.response_time);
            try jw.objectField("total_executed");
            try jw.write(task.total_executed);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("aggregate");
        try jw.beginObject();
        try jw.objectField("average_waiting_time");
        try jw.write(self.result.aggregate.average_waiting_time);
        try jw.objectField("average_response_time");
        try jw.write(self.result.aggregate.average_response_time);
        try jw.objectField("throughput");
        try jw.write(self.result.aggregate.throughput);
        try jw.objectField("throughput_numerator");
        try jw.write(self.result.aggregate.throughput_numerator);
        try jw.objectField("throughput_denominator");
        try jw.write(self.result.aggregate.throughput_denominator);
        try jw.objectField("waiting_time_spread");
        try jw.write(self.result.aggregate.waiting_time_spread);
        try jw.endObject();

        try jw.objectField("notes");
        try jw.write(notes());

        try jw.endObject();
    }
};

const report_notes = [_][]const u8{
    "Phase 1 is an in-process simulator only; it does not spawn or control real processes.",
    "The CFS-inspired policy uses simple virtual-runtime-style accounting and is not faithful Linux CFS.",
};
