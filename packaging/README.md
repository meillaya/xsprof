# Packaging defaults

The package skeleton installs read-only operator/preflight defaults. It must not auto-start a scheduler on install.

Default behavior:
- scheduler: `none`
- auto-start scheduler: `false`
- control daemon: packaged but disabled/manual-only; it does not auto-start
- mutation service: disabled and not install-enabled
- mutation service requires `/run/zig-scheduler-vm-lab.marker`, `/etc/zig-scheduler/enable-lab-mutation`, and an evidence approval path
- package status remains path-to-production; not a production-ready arbitrary-host scheduler

Installed systemd units are inert by default:
- `zig-scheduler-preflight.service` is read-only preflight reporting.
- `zig-scheduler-daemon.service` is a manual control surface with no scheduler capabilities and no `[Install]` section.
- `zig-scheduler-lab-mutation.service` is lab-only, gated, and has no `WantedBy=`.

Lab enablement requires explicit operator action, VM marker, config, audit id, rollback id, security review, rollback evidence, and release gate approval.
