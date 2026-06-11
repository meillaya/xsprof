# Packaging defaults

The package skeleton installs read-only operator/preflight defaults. It must not auto-start a scheduler on install.

Default behavior:
- scheduler: `none`
- auto-start scheduler: `false`
- mutation service: disabled and not install-enabled
- mutation service requires `/run/zig-scheduler-vm-lab.marker`, `/etc/zig-scheduler/enable-lab-mutation`, and an evidence approval path
- package status remains path-to-production; not a production-ready arbitrary-host scheduler

Lab enablement requires explicit operator action, VM marker, config, audit id, rollback id, security review, rollback evidence, and release gate approval.
