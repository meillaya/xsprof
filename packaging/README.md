# Packaging defaults

The package skeleton installs VM/lab backend milestone defaults only. It installs read-only operator/preflight defaults and must not auto-start a scheduler on install.

Default behavior:
- scheduler: `none`
- auto-start scheduler: `false`
- control daemon: packaged but disabled/manual-only; it does not auto-start
- mutation service: disabled and not install-enabled
- mutation service requires `/run/zig-scheduler-vm-lab.marker`, `/etc/zig-scheduler/enable-lab-mutation`, and an evidence approval path
- package status remains path-to-production / VM-lab backend readiness only; not a production-ready arbitrary-host scheduler

Installed systemd units are inert by default:
- `zig-scheduler-preflight.service` is read-only preflight reporting.
- `zig-scheduler-daemon.service` is a manual control surface with no scheduler capabilities and no `[Install]` section.
- `zig-scheduler-lab-mutation.service` is lab-only, gated, and has no `WantedBy=`.

Lab enablement requires explicit operator action, VM marker, config, audit id, rollback id, security review, rollback evidence, cleanup proof, and release gate approval.

## Package/lab check

Packaged binaries should support disabled-safe control checks without enabling services. Install and upgrade must not start or enable a scheduler.

Expected package evidence:

- `bash qa/package_lifecycle_drill.sh` proves install, upgrade, uninstall, config preservation, evidence archive preservation, disabled daemon unit, and no auto-start;
- `systemctl is-enabled zig-scheduler-daemon.service` must be disabled or absent unless a future explicit lab-only procedure says otherwise;
- `zig build package --summary all` stages only the CLI, preflight binary, daemon, config, inert systemd units, docs, and manifest.
- `python3 qa/package_manifest_check.py --manifest zig-out/package/manifest.json` proves VM/lab backend scope, no arbitrary-host claim, no out-of-scope payloads, no archived simulator payload, and gated mutation service metadata.

Mutation-capable package services remain gated by VM marker, config marker, audit id, rollback id, and release evidence. They must not be install-enabled by default.
