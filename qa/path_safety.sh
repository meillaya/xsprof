#!/usr/bin/env bash

path_safety_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

prepare_evidence_dir() {
  local base="$1"
  local out_dir="$2"
  case "$out_dir" in "$base"/*) ;; *) path_safety_fail "--out must be a relative path under $base" ;; esac
  case "$out_dir" in *$'\n'*|*$'\r'*|*'/../'*|../*|*/..) path_safety_fail 'unsafe output path' ;; esac
  mkdir -p "$base"
  local allowed_root parent_dir parent_real target_real link_hit
  allowed_root="$(realpath "$base")"
  parent_dir="$(dirname "$out_dir")"
  mkdir -p "$parent_dir"
  parent_real="$(realpath "$parent_dir")"
  case "$parent_real" in "$allowed_root"|"$allowed_root"/*) ;; *) path_safety_fail 'unsafe output parent realpath' ;; esac
  if [ -L "$out_dir" ]; then path_safety_fail 'output path must not be a symlink'; fi
  mkdir -p "$out_dir"
  target_real="$(realpath "$out_dir")"
  case "$target_real" in "$allowed_root"|"$allowed_root"/*) ;; *) path_safety_fail 'unsafe output realpath' ;; esac
  link_hit="$(find "$out_dir" -type l -print -quit 2>/dev/null || true)"
  [ -z "$link_hit" ] || path_safety_fail "output directory contains symlink: $link_hit"
}
