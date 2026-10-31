# Install

## Linux tarball

```sh
tar -xzf xsprof-<version>-linux-<arch>.tar.gz
cd xsprof-<version>-linux-<arch>
./bin/xsprof demo
```

For a system install, copy `bin/xsprof` to `/usr/local/bin`, `share/xsprof` to
`/usr/local/share/xsprof`, and the unit to
`/usr/local/lib/systemd/system/`. `xsprof serve` and `demo` search
`/usr/local/share/xsprof/web` and `/usr/share/xsprof/web`.

The recorder needs `CAP_PERFMON` and tracefs read access. Use the provided
unit or grant equivalent capabilities explicitly. `xsprof doctor --json` names
the missing piece.

## macOS app

Unzip `Xsprof-<version>-macos.zip` and open `Xsprof.app`. The bundle is
ad-hoc-signed. Developer ID signing and notarization are separate release
steps.

## Verify

```sh
xsprof help
xsprof doctor --json
xsprof demo
```
