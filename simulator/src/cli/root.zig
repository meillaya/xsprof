const args = @import("args.zig");
const output = @import("output.zig");
const report = @import("report.zig");

pub const Command = args.Command;
pub const InputSource = args.InputSource;
pub const Options = args.Options;
pub const OutputFormat = args.OutputFormat;
pub const parseArgs = args.parseArgs;
pub const parsePolicy = args.parsePolicy;

pub const writeHumanReport = output.writeHumanReport;
pub const writeJsonReport = output.writeJsonReport;
pub const writeSimulationReport = output.writeSimulationReport;

pub const SimulationReport = report.SimulationReport;
pub const SourceInfo = report.SourceInfo;
pub const SourceKind = report.SourceKind;
pub const schema_name = report.schema_name;
pub const schema_version = report.schema_version;
pub const top_level_fields = report.top_level_fields;
pub const source_fields = report.source_fields;
pub const scenario_fields = report.scenario_fields;
pub const domain_fields = report.domain_fields;
pub const group_fields = report.group_fields;
pub const policy_fields = report.policy_fields;
pub const trace_entry_fields = report.trace_entry_fields;
pub const task_fields = report.task_fields;
pub const aggregate_fields = report.aggregate_fields;
pub const ContractError = report.ContractError;
pub const assertSupportedContract = report.assertSupportedContract;
pub const publicTraceEventKinds = report.publicTraceEventKinds;
