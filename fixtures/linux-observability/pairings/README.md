# Simulator-to-observability pairings

This directory holds the **single approved simulator/observability pairing manifest**
for the comparison-summary proof surface.

Approved pairing:
- simulator scenario: `scenarios/basic/sleep-wakeup.zon`
- simulator policy: `cfs_like`
- observability fixture manifest:
  `fixtures/linux-observability/manifests/tracefs-sched-demo.json`
- pairing manifest:
  `fixtures/linux-observability/pairings/sleep-wakeup-vs-tracefs-sched-demo.json`

Boundary rules for this surface:
- comparison is educational and observability-only
- pairing manifests do not authorize replay matching, calibration authority, or
  Linux-performance claims
- the approved metric set is fixed to the exact literals in the committed
  pairing manifest
- `required_caveat_keys` must stay inside the approved caveat-key registry
- this remains library/docs/tests only; this directory does not create a CLI
  or `zig-scheduler/report` export path

Reproducibility note:
- regenerate the simulator-side input locally with
  `zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs_like --format json`
- compare it only through the library/docs/tests surfaces once they consume
  the committed pairing manifest and fixture manifest
