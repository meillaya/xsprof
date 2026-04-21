# M19 Linux-observability fixtures

This directory is reserved for **offline, observability-only** Linux scheduler
snapshot fixtures admitted under M19.

Rules for this surface:
- fixtures are committed and scrubbed
- every fixture has a provenance manifest
- support is fail-closed on explicit tuple approval only
- these fixtures do not widen simulator-native `scenarios/`
- these fixtures do not authorize live capture, replay, calibration, or
  Linux-performance claims

Current approved family in the first M19 cut:
- `tracefs-sched-snapshot`

Current approved tuple count in the first M19 cut:
- exactly one literal tuple in `support-matrix.json`
