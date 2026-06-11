#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
out_dir="$repo_root/zig-out/bpf"
source_file="$repo_root/bpf/zigsched_minimal.bpf.c"
object_file="$out_dir/zigsched_minimal.bpf.o"
skip_file="$out_dir/zigsched_minimal.bpf.skip.txt"
log_file="$out_dir/zigsched_minimal.bpf.log"
cc="${CLANG:-clang}"

mkdir -p "$out_dir"

skip() {
  local reason="$1"
  rm -f "$object_file"
  printf 'SKIP: %s\n' "$reason" | tee "$skip_file"
  printf 'SKIP: %s\n' "$reason" > "$log_file"
  exit 0
}

if ! command -v "$cc" >/dev/null 2>&1; then
  skip "clang unavailable; cannot compile BPF object"
fi

probe_c="$(mktemp "${TMPDIR:-/tmp}/zigsched-bpf-probe.XXXXXX.c")"
probe_o="$(mktemp "${TMPDIR:-/tmp}/zigsched-bpf-probe.XXXXXX.o")"
trap 'rm -f "$probe_c" "$probe_o"' EXIT
cat >"$probe_c" <<'PROBE'
char _license[] __attribute__((section("license"), used)) = "GPL";
int zigsched_probe(void *ctx) { (void)ctx; return 0; }
PROBE

if ! "$cc" -target bpf -O2 -c "$probe_c" -o "$probe_o" >"$log_file" 2>&1; then
  skip "clang cannot emit -target bpf objects; see $log_file"
fi

rm -f "$skip_file"
"$cc" -target bpf -O2 -g -Wall -Wextra \
  -I "$repo_root/bpf/include" \
  -c "$source_file" \
  -o "$object_file" >"$log_file" 2>&1

printf 'BPF object: %s\n' "$object_file"
if command -v file >/dev/null 2>&1; then
  file "$object_file"
fi
