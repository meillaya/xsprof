#!/usr/bin/env bash

vm_output_safety_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

vm_output_safety_require_inside() {
  local allowed_root="$1" real_path="$2" label="$3"
  case "$real_path" in
    "$allowed_root"|"$allowed_root"/*) ;;
    *) vm_output_safety_fail "unsafe output ${label} realpath" ;;
  esac
}

vm_output_safety_prepare_parent() {
  local base="$1" out_dir="$2" parent_dir rel_parent cur part
  mkdir -p "$base"
  parent_dir="$(dirname -- "$out_dir")"
  case "$parent_dir" in "$base"|"$base"/*) ;; *) vm_output_safety_fail 'unsafe output parent path' ;; esac
  [ "$parent_dir" = "$base" ] && return 0
  rel_parent="${parent_dir#"$base"/}"
  cur="$base"
  while [ -n "$rel_parent" ]; do
    part="${rel_parent%%/*}"
    [ -n "$part" ] || vm_output_safety_fail 'unsafe empty output parent component'
    case "$part" in .|..) vm_output_safety_fail 'unsafe output parent component' ;; esac
    cur="$cur/$part"
    [ ! -L "$cur" ] || vm_output_safety_fail "unsafe output parent symlink: $cur"
    if [ -e "$cur" ]; then
      [ -d "$cur" ] || vm_output_safety_fail "unsafe output parent is not a directory: $cur"
    else
      mkdir "$cur"
    fi
    [ "$rel_parent" = "$part" ] && break
    rel_parent="${rel_parent#*/}"
  done
}

vm_output_safety_prepare_owned_dir() {
  local base="$1" out_dir="$2" marker_name="$3"
  local allowed_root parent_dir parent_real target_real marker_path marker_real
  case "$out_dir" in "$base"/*) ;; *) vm_output_safety_fail "--out must be a relative path under $base" ;; esac
  case "$out_dir" in *$'\n'*|*$'\r'*|*'/../'*|../*|*/..|*/./*|*/.) vm_output_safety_fail 'unsafe output path' ;; esac
  vm_output_safety_prepare_parent "$base" "$out_dir"
  allowed_root="$(realpath "$base")"
  parent_dir="$(dirname -- "$out_dir")"
  parent_real="$(realpath "$parent_dir")"
  vm_output_safety_require_inside "$allowed_root" "$parent_real" parent
  [ ! -L "$out_dir" ] || vm_output_safety_fail '--out must not be a symlink'
  if [ -e "$out_dir" ] && [ ! -d "$out_dir" ]; then
    vm_output_safety_fail '--out exists and is not a directory'
  fi
  if [ -d "$out_dir" ]; then
    target_real="$(realpath "$out_dir")"
    vm_output_safety_require_inside "$allowed_root" "$target_real" target
    if [ -n "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]; then
      marker_path="$out_dir/$marker_name"
      [ -f "$marker_path" ] || vm_output_safety_fail "stale or unowned output directory refused: $out_dir"
      [ ! -L "$marker_path" ] || vm_output_safety_fail "owned marker must not be a symlink: $marker_path"
      marker_real="$(realpath "$marker_path")"
      vm_output_safety_require_inside "$target_real" "$marker_real" marker
      find "$out_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
  else
    mkdir "$out_dir"
  fi
  target_real="$(realpath "$out_dir")"
  vm_output_safety_require_inside "$allowed_root" "$target_real" target
  : > "$out_dir/$marker_name"
}
