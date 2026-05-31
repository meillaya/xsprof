# contract-governance memory ownership and production-boundary contract inventory

## Status

The contract-governance inventory artifact for the contract cleanup tranche. It documents the
current simulator/laboratory contracts without reopening the production runtime
branch. ADR 0003 (`docs/adr/0003-productionization-gate.md`) remains the
governing productionization gate: this inventory classifies portability and
ownership, but it does not authorize daemon, service, live-capture, kernel, or
automation implementation work.

The lightweight test metadata mirror for owner/classification checks lives in
`src/contract/inventory.zig`.

## allocator and lifetime ownership rules

| Surface | Owner module | Allocator/lifetime rule | Deinit/release rule | Notes |
| --- | --- | --- | --- | --- |
| Scenario input parse/load | `src/sim/scenario.zig`; public facade `src/sdk/scenario_io.zig` | `parseScenarioText`, `parseScenario`, and `loadScenarioFile` allocate a fresh `ScenarioOwned` with the caller allocator. Input text/path slices are borrowed only during the call. | Caller releases once with `ScenarioOwned.deinit()` or `scenario_io.freeScenario`. | The stable SDK promise covers the documented workflow, not every internal parser helper. |
| Scenario value graph | `src/sim/types.zig` (`ScenarioOwned`, `DomainSpec`, `GroupSpec`, `TaskSpec`) | `ScenarioOwned` owns duplicated scenario name, domains, groups, task ids, optional group ids, and optional phase slices. | `ScenarioOwned.deinit()` recursively releases owned child allocations and invalidates the value. | Borrowed lookups such as `groupById` and `domainByCore` must not outlive the scenario. |
| Simulation execution output | `src/sim/engine.zig`; type definitions in `src/sim/types.zig` | `simulate` borrows a scenario and allocates a separate `SimulationResult` with duplicated scenario/result strings plus owned domains, groups, trace, task metrics, and completion order. | Caller releases once with `SimulationResult.deinit()` after all report/analysis consumers are done. | Report generation borrows the result; it does not own or retain it. |
| Report JSON writing | `src/cli/report.zig`; public facade `src/sdk/report.zig`; schema constants in `src/contract/report.zig` | `SimulationReport` borrows `ScenarioOwned`, `SimulationResult`, and source metadata slices while `writeJsonReport` serializes. | No report-owned heap state exists in `SimulationReport`; release borrowed scenario/result separately. | The stable external contract is `zig-scheduler/report` v1. |
| Analysis parsed JSON | `src/analysis/model.zig`, `src/analysis/root.zig` | `std.json.Parsed(analysis.model.Report)` owns parsed JSON memory through its arena/parser allocation. Rendered markdown/SVG buffers are caller-owned returned slices. | Call `parsed.deinit()` for parsed reports; free rendered buffers with the allocator that requested them. | Analysis is a downstream consumer of report JSON, not an owner of simulator state. |
| Generated workloads / property cases | `src/testing/property.zig`, `src/tests/property_test.zig` | Generators allocate temporary scenarios and case data under the test allocator. | Tests release generated owned scenarios/results before exit; `std.testing.allocator` remains the leak detector. | This is lab/test workload generation, not a production fuzzing or live workload API. |
| TUI history and loaded data | `src/tui/root.zig` | The TUI `App` owns parsed reports, observability fixtures, comparison summaries, dashboard entries, and duplicated history entries while the UI loop/snapshot runs. | `App.deinit()` releases parsed reports, fixtures, comparison summaries, history entries, and dashboard entries. | Snapshot output is an explicitly requested rendering surface, not a daemon UI loop contract. |
| Benchmark report data | `src/bench/root.zig` | `bench.run` owns benchmark `cases`; transient scenarios/results/exports/analysis outputs are released per case. | `Report.deinit(allocator)` releases the cases slice; transient values use local `defer` cleanup. | Baselines are deterministic lab artifacts, not Linux or production performance claims. |

## public contract and production-boundary matrix

Classification:

- **Runtime-portable**: could be reused by a future runtime branch after a new
  ADR/re-charter, but only as a data/format contract.
- **Lab-only**: intentionally scoped to deterministic simulator, teaching,
  analysis, or offline fixture workflows.
- **Intentionally non-runtime**: deliberately not a production runtime API or
  service boundary.

| Contract / surface | Owner module(s) | Public artifact | Boundary classification | Compatibility promise | Current proving tests |
| --- | --- | --- | --- | --- | --- |
| Scenario input | `src/sim/scenario.zig`, `src/sim/types.zig`, facade `src/sdk/scenario_io.zig` | Object-style ZON scenario files under `scenarios/basic/` plus parser helpers | Runtime-portable data shape, lab-only semantics | Parser accepts documented scenario fields and returns owned `ScenarioOwned`; scheduler meaning remains simulator-local. | `src/tests/scenario_test.zig`, `src/tests/scenarios_test.zig`, SDK workflow test |
| Simulator result/value API | `src/sim/engine.zig`, `src/sim/types.zig`, facade `src/lib.zig` / `src/sdk/model.zig` | `simulate(allocator, &scenario, policy) -> SimulationResult` | Runtime-portable data shape, lab-only execution semantics | Caller owns allocated result and may inspect documented result/value fields used by SDK docs/tests. | `src/tests/simulator_test.zig`, `src/tests/library_sdk_test.zig` |
| Report JSON export | `src/contract/report.zig`, `src/cli/report.zig`, facade `src/sdk/report.zig` | `zig-scheduler/report` schema/version 1 JSON | Runtime-portable serialized artifact | Versioned schema and top-level/nested fields remain explicit; unsupported schema/version is rejected. | `src/tests/cli_smoke_test.zig`, `src/analysis/tests.zig`, report-pipeline tests |
| SDK facade | `src/lib.zig`, `src/sdk/*.zig` | `zig_scheduler` module, `sdk_api_version`, `model`, `scenario_io`, `simulate`, `report` | Runtime-portable embedder facade, not a production service API | Only the documented narrow stable subset in `docs/library-sdk.md` and this inventory is stable. | `src/tests/library_sdk_test.zig`, `zig build embed-smoke` |
| CLI arguments | `src/cli/args.zig`, `src/main.zig`, `src/sim_main.zig` | `zig build run`, `zig build sim`, flags for scenario/source/policy/output | Lab-only command contract | Flags remain deterministic simulator/report entrypoints; no live process control is implied. | CLI args tests, CLI smoke tests |
| TUI snapshot output | `src/tui/args.zig`, `src/tui/root.zig`, `src/tui/render.zig` | `--snapshot`, dimensions, input/report/scenario sources | Lab-only presentation artifact | Explicit snapshot mode renders deterministic report/fixture views; interactive mode requires TTY and is not a service UI. | TUI args/root/render tests |
| Benchmark output | `src/bench/root.zig`, `docs/benchmarks/*` | `zig-scheduler/benchmark-baseline` schema/version 1 | Lab-only baseline artifact | Baselines record deterministic output sizes/trace volumes over committed fixtures; no Linux-performance claim. | Bench tests, `zig build bench`, report check when artifacts change |
| Analysis markdown/SVG | `src/analysis/*`, `docs/examples/analysis/*` | Markdown/SVG derived from report JSON | Lab-only downstream reporting | Consumes `zig-scheduler/report` without widening the report contract. | Analysis tests, report-pipeline tests |
| Offline Linux observability fixtures | `fixtures/linux-observability/*`, `src/observability/*` | Version-pinned imported snapshots and comparison summaries | Intentionally non-runtime | Offline, curated, scrubbed fixtures only; no live capture, replay authority, or monitoring daemon. | Linux observability and comparison tests |
| Production runtime branch | ADR 0003 plus future release decision/release plan planning only | No runtime package/API exists in the current tree | Intentionally non-runtime | Production work remains deferred until a new ADR/re-charter names sponsor, operator, threat model, owners, and compatibility plan. | ADR wording checks and contract-governance final verification |

## Public API/error/logging/config boundaries

- **Public API boundary:** the `zig_scheduler` module is the SDK facade. Repo
  tools that need wider internals import `zig_scheduler_internal`; embedders use
  only `zig_scheduler`.
- **Error boundary:** parser, validation, CLI, and report contract errors are
  Zig error sets surfaced by their owning modules. contract-governance does not translate
  them into production service status codes.
- **Logging boundary:** the current simulator surfaces user-facing output
  through CLI/TUI/report writers. There is no stable production logging,
  telemetry, journald, syslog, or daemon log contract.
- **Config boundary:** configuration is explicit command arguments, scenario
  files, fixture manifests, and benchmark matrices. There is no production
  config file, reload protocol, or operator policy surface.

## Production-boundary compatibility notes

1. Runtime-portable data contracts may be useful evidence for a future
   production re-charter, but they remain simulator/lab contracts today.
2. Any future runtime branch must define separate ownership, error, logging,
   configuration, security, and operations contracts before implementation.
3. ADR 0003 blocks interpreting this inventory as permission to add a daemon,
   service process, live Linux integration, or scheduler control plane.
