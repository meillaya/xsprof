const types = @import("sim/types.zig");
const scenario = @import("sim/scenario.zig");

pub const BuiltinScenario = scenario.BuiltinScenario;
pub const BuiltinScenarioMeta = scenario.BuiltinScenarioMeta;
pub const PolicyName = types.PolicyName;
pub const Scenario = types.Scenario;
pub const TaskSpec = types.TaskSpec;
pub const TraceEventKind = types.TraceEventKind;
pub const ValidationError = types.ValidationError;
pub const freeScenario = scenario.freeScenario;
pub const listBuiltinScenarios = scenario.listBuiltinScenarios;
pub const loadBuiltinScenario = scenario.loadBuiltinScenario;
pub const loadNamedScenario = scenario.loadNamedScenario;
pub const loadScenarioFile = scenario.loadScenarioFile;
pub const parseScenario = scenario.parseScenario;

test {
    _ = @import("tests/scenario_test.zig");
}
