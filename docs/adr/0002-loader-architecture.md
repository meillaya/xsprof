# ADR 0002: Loader architecture for the Zig sched_ext lifecycle

## Status

Accepted for the path-to-production roadmap. This ADR does not approve host
mutation; it chooses the architecture that future lab-gated mutation work must
implement.

## Context

This repository is building a root Zig operator around Linux `sched_ext` while
remaining fail-closed on ordinary hosts. The current root CLI can render
preflight, build a BPF object, and produce VM-lab evidence, but it must not load,
attach, or mutate scheduler/cgroup state outside explicit disposable lab gates.

Upstream `scx` provides sched_ext schedulers and support utilities. The separate
`scx_loader` project describes itself as a system daemon and DBus-based loader,
with `scxctl` acting as the client used to switch schedulers, modes, and
arguments dynamically. Its configuration model is useful prior art: a declarative
file can select a default scheduler, mode, and scheduler-specific flags. This
project should stay compatible with those concepts, but it should not add a DBus
service dependency in v1.

## Decision

We will implement an **internal Zig lifecycle manager** in this repository for
v1. It will own the local state machine for read-only, verifier-only,
partial-switch lab, rollback, and incident states. It will use scx-compatible
concept names for scheduler identity, modes, arguments, and comparison reports,
but it will not silently call or require `scx_loader`, `scxctl`, or a DBus
service.

The internal lifecycle manager must be explicit at every hazardous boundary:

1. read-only host preflight remains available by default;
2. verifier-only work requires a disposable VM marker;
3. partial-switch attach requires lab tuple evidence, audit id, rollback id, and
   cgroup allowlist evidence;
4. full-host switch remains out of scope until later governance approval;
5. every future mutation command must emit a rollback snapshot and audit record.

## Alternatives considered

### Depend directly on scx_loader in v1

Rejected. `scx_loader` is valuable upstream infrastructure, but a hard runtime
DBus dependency would hide this repository's fail-closed gates behind another
service. It would also make host refusal, audit ids, rollback evidence, and VM
lab boundaries harder to prove from this codebase alone.

### Shell out to scxctl only for lifecycle actions

Rejected for v1. A CLI wrapper would be easy to prototype, but it would push
safety-critical state, argument construction, and rollback semantics outside the
Zig type/schema system. This plan forbids shell-concatenating user config and
requires argv-level, typed execution boundaries.

### Reimplement every upstream concept with unrelated names

Rejected. Operators need to compare this project's behavior with upstream `scx`
and `scx_loader`. Reusing concepts such as scheduler, mode, arguments,
verifier-only, partial switch, and fallback keeps future migration and comparison
possible without claiming drop-in compatibility.

## Consequences

- Root default behavior stays fail-closed and host-safe.
- Future lifecycle code can be tested with repository-owned schemas and fixtures.
- Documentation can compare this operator with `scx_loader` without implying a
  DBus dependency.
- Migration remains open: a later ADR may add optional scx_loader integration if
  it preserves typed config, explicit lab gates, rollback, audit ids, and no
  silent scheduler mutation.

## Required implementation rules

- The CLI must never auto-detect `scx_loader` and mutate through DBus as a side
  effect of read-only commands.
- Any optional integration must be explicit in config and in command output.
- State names must distinguish `read_only`, `verifier_only`, `partial_switch_lab`,
  `rollback_pending`, `rolled_back`, and `refused_host`.
- ADR, runbook, and TUI wording must keep saying path-to-production, not
  ready for production use.

## Verification

- `bash qa/wording_audit.sh`
- `grep -R "internal Zig lifecycle\|scx_loader\|DBus" docs/adr/0002-loader-architecture.md`
- Future lifecycle tasks must add tests proving no DBus or `scx_loader` command
  is used unless a typed, explicit integration mode is introduced by a later ADR.
