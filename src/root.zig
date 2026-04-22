const types = @import("sim/types.zig");

pub const cli = @import("cli/root.zig");
pub const engine = @import("sim/engine.zig");
pub const metrics = @import("sim/metrics.zig");
pub const policies = struct {
    pub const fcfs = @import("policies/fcfs.zig");
    pub const round_robin = @import("policies/round_robin.zig");
    pub const cfs_like = @import("policies/cfs_like.zig");
    pub const deadline = @import("policies/deadline.zig");
    pub const class = @import("policies/class.zig");
    pub const extension = @import("policies/extension.zig");
};
pub const scenario = @import("sim/scenario.zig");
pub const scenario_packs = @import("sim/scenario_pack.zig");
pub const trace = @import("sim/trace.zig");
pub const property = @import("testing/property.zig");
pub const observability = @import("observability/root.zig");
pub const observability_comparison = @import("observability/comparison.zig");

pub const AggregateMetrics = types.AggregateMetrics;
pub const BuiltinScenario = scenario.BuiltinScenario;
pub const BuiltinScenarioMeta = scenario.BuiltinScenarioMeta;
pub const CoreId = types.CoreId;
pub const DomainSpec = types.DomainSpec;
pub const GroupSpec = types.GroupSpec;
pub const PolicyKind = types.PolicyKind;
pub const PolicyName = types.PolicyName;
pub const Scenario = types.Scenario;
pub const ScenarioPack = scenario.ScenarioPack;
pub const ScenarioPackEntryMeta = scenario.ScenarioPackEntryMeta;
pub const ScenarioPackMeta = scenario.ScenarioPackMeta;
pub const ScenarioOwned = types.ScenarioOwned;
pub const SimulationResult = types.SimulationResult;
pub const TaskMetrics = types.TaskMetrics;
pub const TaskPhase = types.TaskPhase;
pub const TaskPhaseKind = types.TaskPhaseKind;
pub const TaskSpec = types.TaskSpec;
pub const TaskState = types.TaskState;
pub const TraceEntry = types.TraceEntry;
pub const TraceEventKind = types.TraceEventKind;
pub const ValidationError = types.ValidationError;
pub const default_task_weight = types.default_task_weight;
pub const max_task_weight = types.max_task_weight;
pub const public_trace_event_kinds = trace.public_event_kinds;

pub const freeScenario = scenario.freeScenario;
pub const listBuiltinScenarios = scenario.listBuiltinScenarios;
pub const listScenarioPackEntries = scenario.listScenarioPackEntries;
pub const listScenarioPacks = scenario.listScenarioPacks;
pub const loadBuiltinScenario = scenario.loadBuiltinScenario;
pub const loadNamedScenario = scenario.loadNamedScenario;
pub const loadScenarioPackEntry = scenario.loadScenarioPackEntry;
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
    _ = @import("tests/identity_gate_test.zig");
    _ = @import("tests/fairness_probe_test.zig");
    _ = @import("tests/property_test.zig");
    _ = @import("tests/policy_architecture_test.zig");
    _ = @import("tests/scenario_pack_test.zig");
    _ = @import("tests/policy_extension_boundary_test.zig");
    _ = @import("tests/linux_observability_test.zig");
    _ = @import("tests/observability_comparison_test.zig");
}
