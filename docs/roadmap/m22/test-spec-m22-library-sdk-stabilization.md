# Test Spec — M22 library / SDK stabilization for embedders

## Status
Draft for consensus review on 2026-04-22

## Goal
Verify that M22 creates a narrow, documented, versioned embedder contract
without overcommitting internal repo surfaces.

## Required verification
- Public library boundary is explicit, documented, and allowlisted by the exact documented stable-subset inventory in `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution).
- Stable API exports are versioned and intentionally narrow.
- Embedding examples compile/run against `zig_scheduler` only.
- Report/export helpers are reachable without `scheduler.cli`.
- Internal test roots remain wired after `zig_scheduler` points at the curated facade.
- Docs preserve simulator-first identity and do not widen scope into M21/M23
  concerns.

## Minimum checks
- `zig build test --summary all`
- public library/API tests
- exact example embedding smoke: `zig build m22-embed-smoke`
- compatibility/docs audit

## Suggested concrete checks

### 1. Public facade coverage
- dedicated `library_sdk_test.zig` imports only `zig_scheduler`
- includes an explicit allowlist-style compile-time audit of the public root against the exact inventory in the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution)
- proves `parseScenarioText -> simulate -> inspect documented result fields` works
- proves report/export helper path works through the public namespace
- uses concrete negative checks with `@hasDecl`/compile-time absence assertions for at least: `engine`, `metrics`, `policies`, `scenario_packs`, `cli`, `property`, `observability`, `observability_comparison`
- treats allocator-owning raw structs as workflow types: tests only documented fields/access patterns rather than assuming every field/layout is frozen

### 2. Example embedding smoke
- compile/run the exact build step `zig build m22-embed-smoke`
- example uses only `zig_scheduler`
- example proves `parseScenarioText -> simulate -> non-CLI report export`
- example does not rely on repo fixture paths, CLI parsing, TUI entrypoints, or internal module imports

### 3. Compatibility/version audit
- assert public API version constant exists and matches docs
- assert report schema/version contract remains explicit
- verify the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution) is the exact documented stable-subset inventory for the public API
- verify docs define stable-vs-unstable surfaces precisely
- verify docs narrow the promise on allocator-owning raw structs to documented workflows/fields rather than full layout freezing

### 4. Internal wiring audit
- `build.zig` still wires internal module/root tests explicitly after the public split
- repo-owned tools import the internal module by default if they need anything outside the curated facade
- only the embedding example and dedicated library contract tests are required to use `zig_scheduler` alone

### 5. Identity/boundary audit
- README and architecture docs still call the repo a deterministic simulator
- library branch is described as optional
- no browser/WASM, service, packaging, or production-automation claims are
  introduced

## Pass condition
M22 passes when an embedder can import `zig_scheduler`, run `parseScenarioText -> simulate -> non-CLI report export` through the allowlisted public API documented in the planning-stage stable inventory doc `docs/roadmap/drafts/m22-library-sdk-draft.md` (to be promoted to `docs/m22-library-sdk.md` during execution), and do so without depending on repo-internal convenience modules or broadened identity claims, while internal tests remain wired through the separate internal module/root.
