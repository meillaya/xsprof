# M14 Scenario Pack and Policy Extension Boundary

M14 defines a reviewable extension boundary without turning the simulator into a plugin host.

## Scenario pack convention

The simulator supports two scenario-loading paths:
- curated named scenarios via `--scenario <name>`
- arbitrary fixture files via `--scenario-file <path>`

The named-loading registry lives in `src/sim/scenario.zig` and points at committed teaching fixtures under `scenarios/basic/`. The broader curriculum metadata index added later lives alongside it in `src/sim/scenario_pack.zig`.

Additional scenario packs follow a directory convention rather than a runtime plugin API:
- keep fixtures in canonical object-style `.zon`
- organize them under any contributor-owned directory that can be addressed by path
- load them through `--scenario-file <path>` or the library surface `loadScenarioFile`

That means a "scenario pack" is just a portable fixture tree. The core simulator does not need dynamic discovery, dependency injection, or optional-pack registration to stay usable.

## Policy extension boundary

The policy boundary is the scheduling class in `src/policies/class.zig`.

Current expectation:
- `src/sim/engine.zig` depends on the scheduling-class boundary instead of importing individual policy modules directly
- policy modules remain responsible for policy-specific selection, preemption, and tick-accounting behavior
- engine-owned concerns stay centralized in the simulator core: lifecycle flow, trace production, aggregate metrics, and shared deterministic state handling

This keeps policy growth reviewable: adding or refining a policy should mostly change the policy module plus the scheduling-class surface, not scatter policy logic throughout the engine.

## Core-without-optional-packs rule

Optional packs must remain optional:
- the default regression suite should keep passing without external packs
- README quick-start examples should continue to work with committed fixtures
- core package review should not depend on loading non-core fixture trees

## Docs/examples audit summary

The repository docs and examples should continue to reflect the actual CLI contract:
- `--scenario` is for curated named scenarios from the committed core corpus
- `--scenario-file` is the extension path for pack-style fixtures
- scenario fixtures remain canonical `.zon`
- policy-extension language should describe a simulator architecture boundary, not a production plugin system

## Registry helpers

The current boundary is exercised through small library helpers such as `loadPackScenario(...)` and registry/listing helpers for builtin and optional packs.

Optional packs may live under paths such as `scenarios/regressions/` without being required for core execution.
