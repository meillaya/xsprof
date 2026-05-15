# ADR 0004: release decision LTS simulator-lab release decision

Status: Approved
Date: 2026-05-15

## Context

M27-reports/help raised the repository from a teaching simulator toward a product-quality
simulator laboratory: public contracts are inventoried, quality and performance
gates are reproducible, semantics have a stable vocabulary, and the TUI has one
smart dashboard spine.

ADR 0003 still controls the production boundary. This repository does not ship a
daemon, service, agent, kernel scheduler, production automation runtime, live
observability capture, or host-control workflow.

## Decision

release decision does **not** re-charter production runtime work. The project will package an
LTS simulator-lab release from this branch and keep any future production-runtime
proposal on a separate branch with a new PRD, test spec, threat model, operations
model, and superseding ADR.

## Consequences

- release plan release artifacts package simulator-lab/product-quality evidence only.
- `docs/lts-simulator-lab-release-plan.md` is the release plan of record.
- `docs/adr/0003-productionization-gate.md` remains in force.
- Future production work remains blocked until an explicit new ADR supersedes
  this decision and ADR 0003 for a dedicated runtime branch.
