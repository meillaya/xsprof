# Linux-observability fixtures

This directory stores **offline, observability-only** Linux scheduler
snapshot fixtures admitted through the production fixture governance process.

Rules for this surface:
- fixtures are committed and scrubbed
- every fixture has a provenance manifest
- support is fail-closed on explicit tuple approval only
- these fixtures do not widen simulator-native `scenarios/`
- these fixtures do not authorize live capture, replay, calibration, or
  Linux-performance claims

Current approved family:
- `tracefs-sched-snapshot`

Current approved tuple count:
- exactly one literal tuple in `support-matrix.json`
