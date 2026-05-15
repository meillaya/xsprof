//! Public value/model namespace for embedders.
//!
//! Shape-stable enums and value helpers are re-exported directly. The raw
//! allocator-owning workflow structs (`ScenarioOwned`, `SimulationResult`) are
//! stable only for the documented parse -> simulate -> report workflow and
//! their documented deinit/lookup patterns; their full field layout is not a
//! production-runtime ABI.

const internal = @import("zig_scheduler_internal");

pub const PolicyKind = internal.PolicyKind;
pub const CoreId = internal.CoreId;
pub const DomainSpec = internal.DomainSpec;
pub const GroupSpec = internal.GroupSpec;
pub const TaskSpec = internal.TaskSpec;
pub const TaskPhase = internal.TaskPhase;
pub const TaskPhaseKind = internal.TaskPhaseKind;
/// Owned scenario graph allocated by parse/load helpers.
///
/// Caller owns the value and must call `deinit()` once, or use
/// `scenario_io.freeScenario` when following the SDK facade helper pattern.
pub const ScenarioOwned = internal.ScenarioOwned;
/// Owned simulation output allocated by `simulate`.
///
/// Caller owns duplicated result strings/slices and must call `deinit()` once
/// after report/export consumers are done borrowing from it.
pub const SimulationResult = internal.SimulationResult;
pub const TaskMetrics = internal.TaskMetrics;
pub const AggregateMetrics = internal.AggregateMetrics;
pub const TraceEntry = internal.TraceEntry;
pub const TraceEventKind = internal.TraceEventKind;
pub const ValidationError = internal.ValidationError;
pub const default_task_weight = internal.default_task_weight;
pub const max_task_weight = internal.max_task_weight;
