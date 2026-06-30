#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
out_dir="$repo_root/zig-out/bpf"
source_file="$repo_root/bpf/zigsched_minimal.bpf.c"
object_file="$out_dir/zigsched_minimal.bpf.o"
skip_file="$out_dir/zigsched_minimal.bpf.skip.txt"
meta_file="$out_dir/zigsched_minimal.bpf.meta.json"
skip_json="$out_dir/zigsched_minimal.bpf.skip.json"
log_file="$out_dir/zigsched_minimal.bpf.log"
cc="${CLANG:-clang}"

mkdir -p "$out_dir"

probe_c=""
probe_o=""
tmp_build_dir=""
tmp_object=""
tmp_meta=""
cleanup_temps() {
  rm -f \
    ${probe_c:+"$probe_c"} \
    ${probe_o:+"$probe_o"} \
    ${tmp_object:+"$tmp_object"} \
    ${tmp_meta:+"$tmp_meta"}
  [ -n "${tmp_build_dir:-}" ] && rm -rf -- "$tmp_build_dir"
}
trap cleanup_temps EXIT

source "$script_dir/bpf_metadata.sh"

clean_canonical_outputs() {
  rm -f "$object_file" "$meta_file" "$skip_file" "$skip_json"
}

skip() {
  local reason="$1"
  rm -f "$object_file" "$meta_file"
  printf 'SKIP: %s\n' "$reason" | tee "$skip_file"
  printf 'SKIP: %s\n' "$reason" > "$log_file"
  write_skip_json "$reason"
  exit 0
}

if ! command -v "$cc" >/dev/null 2>&1; then
  skip "clang unavailable; cannot compile BPF object"
fi

probe_c="$(mktemp "${TMPDIR:-/tmp}/zigsched-bpf-probe.XXXXXX.c")"
probe_o="$(mktemp "${TMPDIR:-/tmp}/zigsched-bpf-probe.XXXXXX.o")"
cat >"$probe_c" <<'PROBE'
char _license[] __attribute__((section("license"), used)) = "GPL";
int zigsched_probe(void *ctx) { (void)ctx; return 0; }
PROBE

if ! "$cc" -target bpf -O2 -c "$probe_c" -o "$probe_o" >"$log_file" 2>&1; then
  skip "clang cannot emit -target bpf objects; see $log_file"
fi

tmp_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-bpf-build.XXXXXX")"
tmp_object="$tmp_build_dir/zigsched_minimal.bpf.o"
tmp_meta="$tmp_build_dir/zigsched_minimal.bpf.meta.json"

if "$cc" -target bpf -D__TARGET_ARCH_x86 -O2 -g -Wall -Wextra \
  -ffile-prefix-map="$repo_root=." \
  -I "$repo_root/bpf/include" \
  -c "$source_file" \
  -o "$tmp_object" >"$log_file" 2>&1; then
  :
else
  compile_rc=$?
  clean_canonical_outputs
  printf 'FAIL: BPF compile failed; canonical object/metadata/skip outputs removed; see %s\n' "$log_file" >&2
  exit "$compile_rc"
fi

if write_meta_json "$tmp_object" "$tmp_meta"; then
  :
else
  meta_rc=$?
  clean_canonical_outputs
  printf 'FAIL: BPF metadata generation failed; canonical outputs removed\n' >&2
  exit "$meta_rc"
fi

rm -f "$skip_file" "$skip_json"
if mv -f "$tmp_object" "$object_file"; then
  tmp_object=""
else
  install_rc=$?
  clean_canonical_outputs
  printf 'FAIL: could not install BPF object; canonical outputs removed\n' >&2
  exit "$install_rc"
fi
if mv -f "$tmp_meta" "$meta_file"; then
  tmp_meta=""
else
  install_rc=$?
  clean_canonical_outputs
  printf 'FAIL: could not install BPF metadata; canonical outputs removed\n' >&2
  exit "$install_rc"
fi

printf 'BPF object: %s\n' "$object_file"
printf 'BPF metadata: %s\n' "$meta_file"
if command -v file >/dev/null 2>&1; then
  file "$object_file"
fi
