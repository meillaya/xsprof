# M22 library / SDK stable inventory

## Status
Draft public inventory for the M22 optional library branch.

## Purpose
This document defines the **stable subset** of the public `zig_scheduler`
module.

Only the symbols and workflows documented here carry the M22 compatibility
promise. Other public declarations that may remain reachable during transition
are **not automatically stable**.

## Top-level stable subset
The public `zig_scheduler` root is intended to expose exactly these stable
entrypoints:

- `sdk_api_version`
- `model`
- `scenario_io`
- `simulate`
- `report`

## `model` stable subset
The `model` namespace is the public home for simulator-facing value types.

### Shape-stable items
- `PolicyKind`
- `CoreId`
- `DomainSpec`
- `GroupSpec`
- `TaskSpec`
- `TaskPhase`
- `TaskPhaseKind`
- `TaskMetrics`
- `AggregateMetrics`
- `TraceEntry`
- `TraceEventKind`
- `ValidationError`
- `default_task_weight`
- `max_task_weight`

### Workflow-stable allocator-owning types
These remain usable through the public API, but M22 only promises documented
ownership and access patterns, not full field/layout freeze:
- `ScenarioOwned`
- `SimulationResult`

## `scenario_io` stable subset
- `parseScenarioText`
- `parseScenario`
- `loadScenarioFile`
- `freeScenario`

## `report` stable subset
- `schema_name`
- `schema_version`
- `ContractError`
- `SourceKind`
- `SourceInfo`
- `SimulationReport`
- `assertSupportedContract`
- `publicTraceEventKinds`
- `writeJsonReport`

## Stable proof workflow
The exact embedding smoke path for M22 is:

1. `parseScenarioText`
2. `simulate`
3. non-CLI `report.writeJsonReport`

Build step:

```sh
zig build m22-embed-smoke
```

## Explicitly outside the stable subset
These names must not be presented as part of the stable SDK boundary:
- `engine`
- `metrics`
- `policies`
- `scenario_packs`
- `cli`
- `property`
- `observability`
- `observability_comparison`

## Internal-consumer rule
Repo-owned tools import the internal module/root by default if they need
anything outside the stable subset.

Only:
- the embedding smoke example
- dedicated library contract tests

should be required to use `zig_scheduler` alone.

## Identity boundary
M22 does not change the repo’s simulator-first identity.
It does not imply:
- browser/WASM delivery
- service/daemon scope
- production automation
- packaging or distribution breadth
