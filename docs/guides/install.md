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

## Debian package

On Debian or Ubuntu, `./tools/package_deb.sh` builds
`dist/xsprof_<version>_<arch>.deb` with the binary, web assets, fixture, and
systemd unit. The unit is installed but not enabled.

## Homebrew

The release workflow renders `Formula/xsprof.rb` and `Casks/xsprof-app.rb` from
the templates in `packaging/homebrew/` and can push them to
`meillaya/homebrew-xsprof` when `HOMEBREW_TAP_TOKEN` is configured. The formula
is Linux-only; the cask is published only after a notarized app exists.

```sh
brew tap meillaya/xsprof
brew install xsprof          # Linux arm64/x86_64 tarball
```

`tools/update_homebrew_tap.sh` can render into any tap checkout with
`--dry-run` for review.

## macOS app

Unzip `Xsprof-<version>-macos.zip` and open `Xsprof.app`. Release builds are
universal (arm64 + x86_64). `tools/package_macos_app.sh` ad-hoc-signs locally;
setting `XSPROF_SIGN_IDENTITY` and `XSPROF_NOTARIZE=1` performs Developer ID
signing, notarization, and stapling through `tools/notarize_macos.sh`.

## Release CI

`.github/workflows/release.yml` builds Linux arm64/x86_64 tarballs and the
macOS app when a `v*` tag is pushed (or from a manual dispatch). It creates the
GitHub release and updates the tap when the optional signing and tap secrets
are present. Missing Apple credentials produce an ad-hoc-signed, non-notarized
artifact; the workflow never substitutes a fake signature.

## Verify

```sh
xsprof help
xsprof doctor --json
xsprof demo
```
