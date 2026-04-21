const contract = @import("report_contract");
const trace = @import("../sim/trace.zig");
const types = @import("../sim/types.zig");

pub const schema_name = contract.schema_name;
pub const schema_version = contract.schema_version;
pub const top_level_fields = contract.top_level_fields;
pub const source_fields = contract.source_fields;
pub const scenario_fields = contract.scenario_fields;
pub const policy_fields = contract.policy_fields;
pub const trace_entry_fields = contract.trace_entry_fields;
pub const task_fields = contract.task_fields;
pub const aggregate_fields = contract.aggregate_fields;
pub const ContractError = contract.ContractError;
pub const SourceKind = contract.SourceKind;
pub const assertSupportedContract = contract.assertSupportedContract;

pub fn publicTraceEventKinds() []const types.TraceEventKind {
    return trace.public_event_kinds[0..];
}

pub const SourceInfo = struct {
    kind: SourceKind,
    value: []const u8,
};

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

        try jw.objectField("core_count");
        try jw.write(self.result.core_count);

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
            try jw.objectField("core_id");
            try jw.write(entry.core_id);
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
