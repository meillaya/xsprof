# Desktop WebView dependency and live VM desktop notes

The current live VM desktop product path is a small Linux WebKitGTK host helper
(`src/desktop/linux_webview_host.c`) launched by the Zig desktop executable. The
host loads the offline bundle, injects a WebKitGTK script-message bridge named
`window.ZigSchedulerDesktopBridge`, and delegates only the allowlisted methods
`status`, `run`, `rollback`, `stop`, and `subscribe` back to the Zig controller.
The bridge remains VM-lab-only and fail-closed: `host_mutation=false`, no shell
bridge, and no arbitrary argv/action surface.

Earlier planning documents discussed a direct `webview/webview` C ABI canary.
That canary is not the authoritative product runtime. It remains only as a
compile-time comparison/probe surface until a future change deliberately adopts
it with fresh evidence.

`zig build desktop-webview-probe --summary all` runs a runtime-light dependency
probe for GTK/WebKitGTK packages. It does not create a product desktop window;
the actual entrypoint is `zig build live-vm-desktop`.

If system dependencies are unavailable, the probe exits successfully with:

```text
SKIP webview dependency unavailable
```

and prints actionable package guidance:

- Debian/Ubuntu: `libgtk-3-dev libwebkit2gtk-4.1-dev` (fallback:
  `libwebkit2gtk-4.0-dev`)
- Fedora: `gtk3-devel webkit2gtk4.1-devel` (or `webkit2gtk4.0-devel`)
- Arch: `gtk3 webkit2gtk-4.1` (or distro `webkit2gtk` package)
- macOS/Windows: not product-supported by this Linux helper path yet; any future
  platform host must preserve the same fail-closed bridge contract.

## Live VM desktop shell

The VM-lab desktop app is launched with:

```bash
zig build live-vm-desktop
```

For non-GUI verification, the build graph also exposes:

```bash
zig build live-vm-desktop -- --smoke
zig build live-vm-desktop -- --bridge-test stop --fake-daemon tools/tui_pty_authoritative_daemon.py
```

The desktop shell is VM-lab-only and fail-closed. It is not a production install,
and it does not repoint `zig build run`. The runtime still requires a disposable
VM host and the live-lab dependency tuple. When prerequisites are missing, the
live path must fail closed with `SKIP`/`REFUSE` output and keep
`host_mutation=false`.

The browser-server reference path remains `zig build live-vm-web`; it is useful
for comparison, but it is not the desktop shell.

## Cleanup receipts

Every desktop or live VM run should end with a cleanup receipt that proves the
host is still clean:

```bash
pgrep -af 'zig-scheduler-live-vm-desktop|zig-scheduler-daemon|qemu|Xvfb|zigsched-microvm-live' || true
```

The expected outcome is no lingering desktop, daemon, QEMU, Xvfb, or
`zigsched-microvm-live.*` residue. The evidence bundle still needs to show
`host_mutation=false`.

If a `/tmp/zigsched-microvm-live.*` directory is present, inspect it before
removal. Only delete empty stale leftovers; non-empty trees can contain live-lab
rootfs payloads and should stay in place unless a separate cleanup receipt proves
they are safe to remove.

## Packaging note

`zig build package` intentionally excludes `zig-scheduler-live-vm-desktop`.
That package remains the read-only operator/preflight/TUI bundle; the desktop
shell is a separate VM-lab-only system WebView entrypoint with its own host
dependency surface. The package manifest records that exclusion explicitly so it
is not silent.
