# M20 simulator-to-observability pairings

This directory holds the **single approved simulator/observability pairing manifest**
for the first M20 comparison-summary cut.

Approved first-cut pairing only:
- simulator scenario: `scenarios/basic/sleep-wakeup.zon`
- simulator policy: `cfs_like`
- observability fixture manifest:
  `fixtures/linux-observability/manifests/m19-tracefs-sched-demo.json`
- pairing manifest:
  `fixtures/linux-observability/pairings/m20-sleep-wakeup-vs-m19-tracefs-sched-demo.json`

Boundary rules for this surface:
- comparison is educational and observability-only
- pairing manifests do not authorize replay matching, calibration authority, or
  Linux-performance claims
- the approved metric set is fixed to the exact literals in the committed
  pairing manifest
- `required_caveat_keys` must stay inside the approved M20 caveat-key registry
- M20 v1 remains library/docs/tests only; this directory does not create a CLI
  or `zig-scheduler/report` export path

Reproducibility note:
- regenerate the simulator-side input locally with
  `zig build sim -- --scenario-file scenarios/basic/sleep-wakeup.zon --policy cfs_like --format json`
- compare it only through the M20 library/docs/tests surfaces once they consume
  the committed pairing manifest and M19 fixture manifest
