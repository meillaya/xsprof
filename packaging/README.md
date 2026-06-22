# Packaging defaults

The package skeleton installs read-only operator/preflight defaults. It must not auto-start a scheduler on install.

Default behavior:
- scheduler: `none`
- auto-start scheduler: `false`
- control daemon: packaged but disabled/manual-only; it does not auto-start
- mutation service: disabled and not install-enabled
- mutation service requires `/run/zig-scheduler-vm-lab.marker`, `/etc/zig-scheduler/enable-lab-mutation`, and an evidence approval path
- package status remains path-to-production; not a production-ready arbitrary-host scheduler
- the VM-lab-only desktop WebView shell is intentionally excluded from this package; it is documented as a separate entrypoint because it needs host GUI dependencies and does not belong in the read-only package surface

Installed systemd units are inert by default:
- `zig-scheduler-preflight.service` is read-only preflight reporting.
- `zig-scheduler-daemon.service` is a manual control surface with no scheduler capabilities and no `[Install]` section.
- `zig-scheduler-lab-mutation.service` is lab-only, gated, and has no `WantedBy=`.

Lab enablement requires explicit operator action, VM marker, config, audit id, rollback id, security review, rollback evidence, and release gate approval.

## TUI-driven package/lab check

Packaged binaries should support the TUI-driven lab workflow without enabling services. The package may install the daemon and TUI artifacts, but install and upgrade must not start or enable a scheduler.

After staging or installing into a disposable test root, run the disabled-safe control surface explicitly:

```bash
zig build install
printf 'rviq' | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --fixture fixtures/lab/preflight-ready.json \
  --screen sched-ext --width 120 --height 30 \
  --daemon-bin ./zig-out/bin/zig-scheduler-daemon \
  --daemon-state-dir .omo/evidence/package-tui-daemon-state \
  > .omo/evidence/package-tui-transcript.txt
```

Expected package evidence:

- `.omo/evidence/package-tui-daemon-state/events.jsonl` records typed actions with `host_mutation=false`;
- `bash qa/package_lifecycle_drill.sh` proves install, upgrade, uninstall, config preservation, evidence archive preservation, disabled daemon unit, and no auto-start;
- `systemctl is-enabled zig-scheduler-daemon.service` must be disabled or absent unless a future explicit lab-only procedure says otherwise.
- `zig build package --summary all` prints the desktop exclusion reason and the manifest records `desktop_executable_included=false`.

Mutation-capable package services remain gated by VM marker, config marker, audit id, rollback id, and release evidence. They must not be install-enabled by default.
