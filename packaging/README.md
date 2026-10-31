# Packaging

`tools/package.sh` builds a ReleaseSafe binary and a self-contained tarball.
`tools/package_macos_app.sh` builds an ad-hoc-signed `.app` bundle. Neither
script publishes, enables a service, or requests credentials.

The Linux tarball is the primary package layout:

```text
xsprof-<version>-<os>-<arch>/
  bin/xsprof
  share/xsprof/web/
  share/xsprof/fixtures/healthy.ndjson
  lib/systemd/system/xsprof-recorder.service
  share/doc/xsprof/
```

The systemd unit is opt-in. Create the `xsprof` user, install the unit, and
review the capability set before enabling it. `xsprof doctor --json` reports
the exact missing permission or tracefs state.

The macOS `.app` runs `ui` through a small launcher. Ad-hoc signing works
without an Apple account. Developer ID signing and notarization are release
operations and require external credentials.
