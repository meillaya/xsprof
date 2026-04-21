const types = @import("sim/types.zig");

pub const cli = @import("cli/root.zig");
pub const engine = @import("sim/engine.zig");
pub const metrics = @import("sim/metrics.zig");
pub const policies = struct {
    pub const fcfs = @import("policies/fcfs.zig");
    pub const round_robin = @import("policies/round_robin.zig");
    pub const cfs_like = @import("policies/cfs_like.zig");
};
pub const scenario = @import("sim/scenario.zig");
pub const trace = @import("sim/trace.zig");

pub const AggregateMetrics = types.AggregateMetrics;
pub const BuiltinScenario = scenario.BuiltinScenario;
pub const BuiltinScenarioMeta = scenario.BuiltinScenarioMeta;
pub const PolicyKind = types.PolicyKind;
pub const PolicyName = types.PolicyName;
pub const Scenario = types.Scenario;
pub const ScenarioOwned = types.ScenarioOwned;
pub const SimulationResult = types.SimulationResult;
pub const TaskMetrics = types.TaskMetrics;
pub const TaskSpec = types.TaskSpec;
pub const TaskState = types.TaskState;
pub const TraceEntry = types.TraceEntry;
pub const TraceEventKind = types.TraceEventKind;
pub const ValidationError = types.ValidationError;
pub const default_task_weight = types.default_task_weight;
pub const max_task_weight = types.max_task_weight;

pub const freeScenario = scenario.freeScenario;
pub const listBuiltinScenarios = scenario.listBuiltinScenarios;
pub const loadBuiltinScenario = scenario.loadBuiltinScenario;
pub const loadNamedScenario = scenario.loadNamedScenario;
pub const loadScenarioByName = scenario.loadScenarioByName;
pub const loadScenarioFile = scenario.loadScenarioFile;
pub const parseScenario = scenario.parseScenario;
pub const parseScenarioText = scenario.parseScenarioText;
pub const simulate = engine.simulate;

test {
    _ = @import("tests/scenario_test.zig");
    _ = @import("tests/simulator_test.zig");
    _ = @import("tests/policies_test.zig");
    _ = @import("tests/scenarios_test.zig");
    _ = @import("tests/cli_smoke_test.zig");
}
