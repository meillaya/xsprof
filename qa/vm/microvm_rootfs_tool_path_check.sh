#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/vm/microvm_rootfs.sh

scratch="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-rootfs-tool-path.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM HUP

fake_profile="$scratch/home/mei/.omx-runs/nix-profiles/zig-scheduler-vm-proof-stress-ng/bin"
root="$scratch/root"
mkdir -p "$fake_profile" "$root"
cat > "$fake_profile/stress-ng" <<'SH'
#!/bin/sh
echo fake stress-ng
SH
chmod +x "$fake_profile/stress-ng"

PATH="$fake_profile:/usr/bin:/bin" microvm_copy_tool_with_deps "$root" stress-ng

if [ ! -x "$root/usr/bin/stress-ng" ]; then
  echo "FAIL: stress-ng was not installed into guest PATH at /usr/bin/stress-ng" >&2
  exit 1
fi
if [ ! -x "$root$fake_profile/stress-ng" ]; then
  echo "FAIL: original absolute tool path copy was not preserved" >&2
  exit 1
fi
if ! PATH="$root/usr/bin:/bin" command -v stress-ng >/dev/null 2>&1; then
  echo "FAIL: stress-ng is not discoverable through the guest PATH layout" >&2
  exit 1
fi

missing_root="$scratch/missing-root"
mkdir -p "$missing_root"
PATH=/usr/bin:/bin microvm_copy_tool_with_deps "$missing_root" not-a-zig-scheduler-tool
if [ -e "$missing_root/usr/bin/not-a-zig-scheduler-tool" ]; then
  echo "FAIL: missing workload tool unexpectedly created a guest PATH entry" >&2
  exit 1
fi

echo "PASS microvm rootfs workload tools are copied into guest PATH without weakening missing-tool refusal"
