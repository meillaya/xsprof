# M13 property-style scenario generation and shrinking

M13 adds a deterministic property harness for the simulator mainline.

## Generator path
- Implementation: `src/testing/property.zig`
- Verification suite: `src/tests/property_test.zig`
- Entry point: `sim.property.generateScenario(...)`

The generator is seed-driven and produces valid object-style ZON scenarios with deterministic names, task ids, and optional teaching-scope features such as weights, deadlines, groups, and topology domains.

Generated scenarios are not injected directly into the engine. They are rendered back into canonical ZON text and then materialized through the existing parser so the property suite exercises the public scenario-loading path.

## Property / invariant coverage
The M13 tests use generated scenarios to check that:
- generated scenarios satisfy core validity constraints
- every policy can simulate the generated cases deterministically
- per-task accounting stays reconciled (`turnaround = waiting + blocked + burst`)
- tick events reconcile with total burst work
- exported JSON keeps the documented schema/version and aggregate invariants
- core identities stay within the declared core-count range

This remains a deterministic simulator-local teaching workflow, not a claim of kernel-faithful fuzzing.

## Shrinking and regression fixtures
`sim.property.shrinkScenario(...)` greedily simplifies a failing generated case by trying smaller task sets and lower-complexity field values while preserving a caller-supplied failing predicate.

Once a smaller reproducer is found, `GeneratedScenario.writeZonFile(...)` can persist it as a regression fixture. The M13 test suite exercises that path by writing a shrunk `.zon` file to a temporary directory, reparsing it, and re-running the preserved predicate.

## Recommended verification
```sh
zig build
zig build test
zig fmt --check src/root.zig src/testing/property.zig src/tests/property_test.zig
```
