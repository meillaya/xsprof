#!/usr/bin/env bash
# Build a minimal initramfs (static busybox + xsprof + its full runtime closure)
# and boot a disposable microVM under KVM to prove xsprof captures LIVE
# sched/memory events when privileged (perf_event_paranoid lowered inside the VM).
# The host stays fail-closed; this runs only inside the throwaway VM.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUSYBOX="$(nix build nixpkgs#pkgsStatic.busybox --no-link --print-out-paths 2>/dev/null)/bin/busybox"
BZIMAGE="$(nix build nixpkgs#linuxPackages.kernel --no-link --print-out-paths 2>/dev/null)/bzImage"
QEMU="$(nix build nixpkgs#qemu --no-link --print-out-paths 2>/dev/null)/bin/qemu-system-x86_64"
XSPROF="${XSPROF_BIN:-/tmp/xsprof-bpf-build/xsprof}"
BPF_OBJECTS="${BPF_OBJECTS_DIR:-$(pwd)/bpf-objects}"

echo "busybox: $BUSYBOX"
echo "bzImage: $BZIMAGE"
echo "qemu:    $QEMU"
echo "xsprof:  $XSPROF"
[ -x "$XSPROF" ] || { echo "xsprof binary missing: $XSPROF"; exit 1; }
[ -f "$BZIMAGE" ] || { echo "bzImage missing"; exit 1; }

# Resolve the FULL runtime closure: every store path referenced by the binary's
# RUNPATH, plus the real (symlink-resolved) location of each ldd dependency, plus
# the interpreter. This follows nix store symlinks to their actual store paths.
mapfile -t STORE_PATHS < <(
  {
    readelf -d "$XSPROF" 2>/dev/null | grep -iE 'runpath|rpath'
    ldd "$XSPROF" 2>/dev/null | grep -o '/nix/store/[^ ]*' | while read -r p; do readlink -f "$p"; done
    interp="$(readelf -l "$XSPROF" 2>/dev/null | grep -o '/nix/store/[^]]*ld-linux[^]]*')"
    [ -n "$interp" ] && readlink -f "$interp"
  } | grep -oE '/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+' | sort -u
)
echo "closure store paths:"
printf '  %s\n' "${STORE_PATHS[@]}"

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/bin" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/tmp" "$STAGE/nix/store"
cp "$BUSYBOX" "$STAGE/bin/busybox"
cp "$XSPROF" "$STAGE/bin/xsprof"
for sp in "${STORE_PATHS[@]}"; do
  [ -d "$sp" ] && cp -aL "$sp" "$STAGE/nix/store/" 2>/dev/null
done
cp "$HERE/init.sh" "$STAGE/init"
for obj in "$BPF_OBJECTS"/*.bpf.o; do
  [ -f "$obj" ] && cp "$obj" "$STAGE/" && echo "bundled $(basename "$obj")"
done
chmod +x "$STAGE/init" "$STAGE/bin/busybox" "$STAGE/bin/xsprof"

INITRD="$HERE/initrd"
( cd "$STAGE" && find . -print0 | cpio --null -o -H newc -F "$INITRD" --quiet )
echo "initramfs: $INITRD ($(du -h "$INITRD" | cut -f1))"

echo "=== booting microVM (KVM, 4 vCPU, 1G RAM) ==="
timeout 150 "$QEMU" \
  -enable-kvm -cpu host -smp 4 -m 1024 \
  -kernel "$BZIMAGE" -initrd "$INITRD" \
  -append "console=ttyS0 loglevel=3" \
  -nographic -no-reboot -nodefaults -serial mon:stdio
rc=$?
echo "=== VM exited (rc=$rc) ==="
exit 0
