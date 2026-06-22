#!/usr/bin/env bash

vm_kernel_validate_image() {
  local raw="$1" canonical desc header
  case "$raw" in
    /*) ;;
    *) printf 'kernel image refused: path must be absolute\n' >&2; return 1 ;;
  esac
  case "$raw" in
    *$'\n'*|*$'\r'*) printf 'kernel image refused: control characters are not allowed\n' >&2; return 1 ;;
    */../*|*/..|*/./*|*/.) printf 'kernel image refused: traversal components are not allowed\n' >&2; return 1 ;;
  esac
  canonical="$(readlink -f -- "$raw" 2>/dev/null || true)"
  [ -n "$canonical" ] || { printf 'kernel image refused: canonical path does not exist\n' >&2; return 1; }
  case "$canonical" in
    /boot/vmlinuz*|/boot/bzImage*|/usr/lib/modules/*/vmlinuz|/run/current-system/kernel|/run/booted-system/kernel|/nix/store/*) ;;
    *) printf 'kernel image refused: canonical path is outside trusted kernel locations\n' >&2; return 1 ;;
  esac
  [ -f "$canonical" ] || { printf 'kernel image refused: canonical path is not a file\n' >&2; return 1; }
  [ -r "$canonical" ] || { printf 'kernel image refused: canonical path is not readable\n' >&2; return 1; }
  desc="$(file -b -- "$canonical" 2>/dev/null || true)"
  case "$desc" in
    *text*|*Text*|*script*|*JSON*|*XML*) printf 'kernel image refused: file content is not a kernel image (%s)\n' "$desc" >&2; return 1 ;;
  esac
  case "$desc" in
    *Linux\ kernel*|*bzImage*|*boot\ executable*|*gzip\ compressed\ data*) printf '%s\n' "$canonical"; return 0 ;;
  esac
  header="$(dd if="$canonical" bs=1 skip=514 count=4 2>/dev/null || true)"
  if [ "$header" = HdrS ]; then printf '%s\n' "$canonical"; return 0; fi
  printf 'kernel image refused: missing Linux kernel signature (%s)\n' "${desc:-unknown}" >&2
  return 1
}

vm_kernel_find_image() {
  local candidate validated
  if [ -n "${1:-}" ]; then
    vm_kernel_validate_image "$1"
    return
  fi
  for candidate in "/boot/vmlinuz-$(uname -r)" /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux /boot/vmlinuz-*; do
    [ -r "$candidate" ] || continue
    validated="$(vm_kernel_validate_image "$candidate" 2>/dev/null || true)"
    [ -n "$validated" ] && { printf '%s\n' "$validated"; return 0; }
  done
  return 1
}
