#!/usr/bin/env bash

qemu_discovery_name="qemu-system-x86_64"

qemu_discovery_is_trusted_canonical_path() {
  case "$1" in
    /usr/bin/"$qemu_discovery_name"|/run/current-system/sw/bin/"$qemu_discovery_name"|/nix/store/*/bin/"$qemu_discovery_name") return 0 ;;
    *) return 1 ;;
  esac
}

qemu_discovery_resolve_candidate() {
  local raw="$1" canonical base
  case "$raw" in
    /*) ;;
    *) return 1 ;;
  esac
  base="$(basename -- "$raw")"
  [ "$base" = "$qemu_discovery_name" ] || return 1
  case "$raw" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  canonical="$(readlink -f -- "$raw" 2>/dev/null || true)"
  [ -n "$canonical" ] || return 1
  qemu_discovery_is_trusted_canonical_path "$canonical" || return 1
  [ -x "$canonical" ] || return 1
  printf '%s\n' "$canonical"
}

qemu_discovery_validate_override() {
  local raw="$1"
  case "$raw" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$raw" in
    *$'\n'*|*$'\r'*) return 1 ;;
    */../*|*/..|*/./*|*/.) return 1 ;;
    /home/*|/tmp/*|/var/tmp/*|/dev/shm/*) return 1 ;;
    */.zig-cache/*|*/.omo/*|*/.omx/*) return 1 ;;
  esac
  qemu_discovery_resolve_candidate "$raw"
}

qemu_discovery_find() {
  local candidate canonical
  if candidate="$(command -v "$qemu_discovery_name" 2>/dev/null || true)"; then
    if canonical="$(qemu_discovery_resolve_candidate "$candidate" 2>/dev/null || true)"; then
      [ -n "$canonical" ] && {
        printf '%s\n' "$canonical"
        return 0
      }
    fi
  fi
  for candidate in /usr/bin/"$qemu_discovery_name" /run/current-system/sw/bin/"$qemu_discovery_name" /nix/store/*/bin/"$qemu_discovery_name"; do
    [ -e "$candidate" ] || continue
    if canonical="$(qemu_discovery_resolve_candidate "$candidate" 2>/dev/null || true)"; then
      [ -n "$canonical" ] && {
        printf '%s\n' "$canonical"
        return 0
      }
    fi
  done
  return 1
}
