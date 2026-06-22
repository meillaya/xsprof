#!/usr/bin/env bash

microvm_validate_nix_bin() {
  local raw="$1" canonical base
  case "$raw" in /*) ;; *) fail 'nix override refused: path must be absolute' ;; esac
  base="$(basename -- "$raw")"
  [ "$base" = nix ] || fail 'nix override refused: basename must be nix'
  case "$raw" in
    *$'\n'*|*$'\r'*) fail 'nix override refused: control characters are not allowed' ;;
    */../*|*/..|*/./*|*/.) fail 'nix override refused: traversal components are not allowed' ;;
    /home/*|/tmp/*|/var/tmp/*|/dev/shm/*) fail 'nix override refused: user/writable paths are not trusted' ;;
    */.zig-cache/*|*/.omo/*|*/.omx/*) fail 'nix override refused: repo-local scratch paths are not trusted' ;;
  esac
  canonical="$(readlink -f -- "$raw" 2>/dev/null || true)"
  [ -n "$canonical" ] || fail 'nix override refused: canonical path does not exist'
  case "$canonical" in
    /usr/bin/nix|/run/current-system/sw/bin/nix|/nix/var/nix/profiles/default/bin/nix|/nix/profile/bin/nix|/nix/store/*/bin/nix) ;;
    *) fail 'nix override refused: canonical path is outside trusted nix locations' ;;
  esac
  [ -x "$canonical" ] || fail 'nix override refused: canonical path is not executable'
  printf '%s\n' "$canonical"
}

microvm_find_nix_bin() {
  local nix_arg="$1" candidate
  if [ -n "$nix_arg" ]; then microvm_validate_nix_bin "$nix_arg"; return; fi
  for candidate in /nix/var/nix/profiles/default/bin/nix /run/current-system/sw/bin/nix /usr/bin/nix /nix/profile/bin/nix; do
    if [ -x "$candidate" ]; then microvm_validate_nix_bin "$candidate"; return; fi
  done
  fail 'nix not found in trusted locations; install nix or set ZIG_SCHEDULER_NIX_BIN to /usr/bin/nix, /run/current-system/sw/bin/nix, /nix/var/nix/profiles/default/bin/nix, /nix/profile/bin/nix, or /nix/store/.../bin/nix'
}

microvm_find_qemu() {
  local qemu_arg="$1" canonical
  if [ -n "$qemu_arg" ]; then
    qemu_discovery_validate_override "$qemu_arg" || fail 'qemu override refused or unavailable'
    return
  fi
  canonical="$(qemu_discovery_find 2>/dev/null || true)"
  [ -n "$canonical" ] || fail 'qemu-system-x86_64 not found in trusted qemu locations; install qemu or set ZIG_SCHEDULER_QEMU_BIN to /usr/bin/qemu-system-x86_64, /run/current-system/sw/bin/qemu-system-x86_64, or /nix/store/.../bin/qemu-system-x86_64'
  printf '%s\n' "$canonical"
}

microvm_find_kernel() {
  local kernel_arg="$1" resolved
  resolved="$(vm_kernel_find_image "$kernel_arg" 2>/dev/null || true)"
  [ -n "$resolved" ] || fail 'trusted readable kernel image not found; pass --kernel /boot/vmlinuz-* or another trusted bzImage'
  printf '%s\n' "$resolved"
}

microvm_build_bpf_metadata() {
  local out_dir="$1" object_file="$2"
  bash tools/build_bpf.sh > "$out_dir/build-bpf.txt"
  [ -f "$object_file" ] || fail "BPF object missing after build: $object_file"
  sha256sum "$object_file" | awk '{print $1}'
}

microvm_fetch_busybox() {
  local nix_bin="$1" busybox_store busybox_bin
  busybox_store="$("$nix_bin" build nixpkgs#pkgsStatic.busybox --no-link --print-out-paths 2>/dev/null | tail -n 1 || true)"
  [ -n "$busybox_store" ] || fail 'could not build/fetch pkgsStatic.busybox through nix'
  busybox_bin="$busybox_store/bin/busybox"
  [ -x "$busybox_bin" ] || fail "busybox not executable: $busybox_bin"
  printf '%s\n' "$busybox_bin"
}
