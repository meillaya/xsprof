# M14 scenario packs and policy extension boundary

M14 keeps the simulator core reviewable by defining **registry conventions** instead of introducing runtime plugin dependencies.

## Scenario pack layout

Scenario packs are registered in `src/sim/scenario_pack.zig` and point at committed directories:

- `core` -> `scenarios/basic`
- `regressions` -> `scenarios/regressions`

Each entry records:

- a stable scenario key
- the committed `.zon` path
- a short teaching/regression description

Loaders should use the registry boundary instead of hard-coding extra paths:

```zig
const sim = @import("root.zig");

var scenario = try sim.scenario_packs.loadPackScenario(allocator, "core", "weighted-fairness");
defer scenario.deinit();
```

The `regressions` pack is intentionally marked as one of the optional packs. Core fixtures must continue to load even when no extra regression scenarios have been committed yet.

## Policy extension boundary

Policy modules continue to stay behind `src/policies/class.zig`, while `src/policies/extension.zig` now defines the documented contract for extension-friendly policy modules:

- queue-style modules may export `selectNext(...)`
- chooser-style modules may export `chooseRunnable(...)`
- optional hooks such as `shouldPreempt(...)`, `onTaskTick(...)`, and `keeps_running_selection` refine behavior without changing engine ownership

This keeps `src/sim/engine.zig` free of direct concrete-policy imports and gives future policy experiments one explicit boundary to satisfy before they are wired into the class resolver.

## Verification focus

The M14 tests cover:

- registry discovery for the committed scenario packs
- extension loading through `loadPackScenario`
- contract checks for built-in policy modules
- adapter defaults for queue-style and chooser-style policy modules
