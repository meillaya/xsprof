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

The macOS `.app` is a universal bundle whose main executable is the real
binary; `Info.plist` sets `XSPROF_APP_MODE=1`, which selects `ui`. Ad-hoc
signing works without an Apple account. Developer ID signing, notarization,
and stapling are release operations through `tools/notarize_macos.sh` and
require external credentials.

`tools/package_deb.sh` builds a Debian package on a host with `dpkg-deb`.
`packaging/homebrew/` holds formula and cask templates; the release workflow
renders them with `tools/update_homebrew_tap.sh` and pushes the tap.

`.github/workflows/release.yml` produces the Linux tarballs and the macOS zip
on a `v*` tag, publishes the GitHub release, and updates the tap when the
optional secrets exist. The release workflow never publishes an unsigned
artifact as notarized.
