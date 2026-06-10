# TEST SUITE NOTES

## OVERVIEW
`src/tests` is the broad contract suite for simulator behavior, CLI output, policy boundaries, fixtures, observability, SDK, and production-surface guardrails.

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| Umbrella imports | `../root.zig`, `../lib.zig`, module `tests.zig` files | `zig build test` discovers tests through module roots. |
| Core simulator goldens | `simulator_test.zig`, `scenario_test.zig`, `scenarios_test.zig` | Large deterministic fixture/golden sets. |
| CLI/report snapshots | `cli_smoke_test.zig`, `quality_gate_test.zig`, `scenario_pack_test.zig` | Output strings are user-facing contracts. |
| Policy boundaries | `policy_architecture_test.zig`, `policy_extension_boundary_test.zig`, `sched_ext_gate_test.zig` | Keep architecture constraints executable. |
| Offline observability | `linux_observability_test.zig`, `observability_comparison_test.zig` | Enforce fixed approved fixture/pairing/caveat boundaries. |
| Public SDK | `library_sdk_test.zig` | Guard the narrow `src/lib.zig` facade. |

## CONVENTIONS
- Add tests through the relevant module root import path; do not assume a file in `src/tests` runs unless imported by a tested module.
- Keep tests deterministic and bounded. Large matrix/property/golden additions can materially slow `zig build test`.
- Prefer committed fixtures under `scenarios/` and `fixtures/linux-observability/` for behavior contracts; update the owning README/metadata when fixture meaning changes.
- For user-facing output changes, assert exact important strings and document why changed wording is intentional.
- Preserve fail-closed tests around sched-ext/backend gates and observability authority boundaries.

## ANTI-PATTERNS
- Do not delete or weaken failing contract tests to get green builds.
- Do not add sleeping/time-sensitive tests except through bounded PTY/system-command helpers with explicit timeouts.
- Do not hide broad behavior changes inside snapshot churn; pair output updates with focused semantic assertions.

## VERIFY
```bash
zig build test --summary all
zig build quality
zig build reports -- --check
```
