# Worklog

## Current posture

- Root `zig-scheduler` is a fail-closed Linux scheduler operator surface.
- Root code exposes read-only preflight, dry-run planning, disabled-safe daemon actions, VM/lab evidence validators, package safety checks, and governance gates.
- Root UI surfaces have been removed by request: no root terminal UI, no browser UI, no desktop WebView shell, and no root build steps for those surfaces.
- The deterministic simulator remains archived under `simulator/` and must be run from that package root.
- Root must not claim production readiness.
- Root must not load BPF programs or mutate cgroups, cpusets, affinities, priorities, or scheduler state without a later explicit approval and lab evidence gate.

## Future-agent notes

- Keep ordinary root commands host-safe and fail-closed.
- Do not restore root UI/WebView code unless the user explicitly requests a new UI direction.
- Do not touch `simulator/` when working on root operator cleanup unless the user explicitly scopes simulator work.
- Treat `.omo/` and `.omx/` as local workflow state, not repository behavior.
