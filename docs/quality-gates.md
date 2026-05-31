# quality gates

This is the canonical quality gate for the simulator-lab/product-quality
track. It preserves ADR 0003: the repository remains a deterministic scheduler
simulator and teaching laboratory, not a daemon, service, agent, or production
automation runtime.

## test taxonomy and ownership

| Taxonomy | Primary owner | Build evidence | Update rule |
| --- | --- | --- | --- |
| Unit tests | `src/*` module tests | `zig build test --summary all` | Keep next to implementation unless the behavior spans modules. |
| Integration tests | `src/tests/*_test.zig` | `zig build test --summary all` | Assert public flows, not private helper order. |
| Property tests | `src/tests/property_test.zig` | `zig build test --summary all` | Cover generated groups, topology, phases, deadlines, invalid inputs, and all public policy classes. |
| Golden tests | `src/report_pipeline/root.zig`, `docs/examples/`, `docs/benchmarks/` | `zig build reports -- --check`; `zig build bench -- --format json` | Update only with reviewed artifact diffs and a note explaining the new oracle. |
| Snapshot tests | `src/tui/render.zig`, `src/tui/args.zig` | `zig build test --summary all` | Snapshots cover compact, medium, and large terminal tiers. |
| Contract tests | `src/tests/library_sdk_test.zig`, `src/tests/cli_smoke_test.zig` | `zig build embed-smoke`; `zig build test --summary all` | Changes require migration notes and examples. |
| Architecture tests | `src/tests/policy_architecture_test.zig`, `src/tests/quality_gate_test.zig` | `zig build test --summary all` | Forbidden imports fail the build before cleanup or feature work proceeds. |

## golden fixture governance

Golden artifacts are intentionally committed only when they improve reviewability.
The owner of each artifact class decides when regeneration is valid:

| Artifact class | Canonical location | Regeneration command | Review requirement |
| --- | --- | --- | --- |
| Report markdown/JSON examples | `docs/examples/`, `docs/labs/reproducible-report-pack.md` | `zig build reports -- --check` | Diff must explain scenario, policy, and contract changes. |
| Benchmark baselines | `docs/benchmarks/baselines.*` | `zig build bench -- --format markdown`; `zig build bench -- --format json` | Diff must reference an approved budget or baseline refresh. |
| Dashboard snapshots | TUI snapshot tests and future `docs/snapshots/` fixtures | `zig build test --summary all` | Compact/medium/large rendering changes require snapshot review. |
| Courseware reports | `docs/courseware/` and `docs/labs/` | `zig build reports -- --check` | Keep simulator-first language and ADR guardrails intact. |

## contract-governance executable gates

- **the simulator property testing expansion:** generated scenarios must exercise groups,
  topology, CPU/wait phases, deadlines, policy classes, report export accounting,
  and shrinker regression-save workflows.
- **the simulator determinism oracle:** repeated runs over curated fixtures and generated
  cases must produce identical traces, task metrics, and completion order.
- **the simulator mutation/fault injection harness:** invalid scenario/report/policy inputs
  assert stable diagnostics such as `MissingName`, `InvalidInteger`,
  `ZeroBurstTicks`, and `UnsupportedSchema`; they must not crash.
- **the simulator static architecture checks:** downstream tools consume report contracts,
  not simulator engine internals; policy implementations stay behind the class and
  extension metadata boundaries.

## CLI and SDK compatibility suite

Public CLI and SDK workflows stay frozen by tests:

- `zig build sim -- --scenario short-vs-long --policy fcfs --format json`
- `zig build analyze -- --input <report.json> --format markdown`
- `zig build embed-smoke`
- `zig build test --summary all`

Compatibility changes require updating `docs/library-sdk.md`, examples,
contract inventory metadata, and release notes in the same commit.

## dashboard snapshot regression suite

The TUI must remain deterministic in snapshot mode. Snapshot coverage is grouped
by terminal tier rather than by ad hoc modes:

- compact: 80x24
- medium: 96x28
- large: 120x40

Future screens must be added to the unified dashboard spine instead of creating
new one-off TUI modes.

## release checklist and changelog discipline

Use `docs/release-checklist.md` for release dry-runs. Every release candidate
must document version bumps, contract migrations, benchmark/budget status,
quality dashboard output, and known simulator-lab limits.

## Generated quality dashboard

Run:

```sh
zig build quality
```

The command renders the current quality dashboard from `src/quality/root.zig`.
The dashboard is maintainer evidence for quality gates; it is not a runtime
service or external automation surface.
