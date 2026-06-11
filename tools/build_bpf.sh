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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

clang_version() {
  if command -v "$cc" >/dev/null 2>&1; then
    "$cc" --version | head -n 1
  else
    printf 'unavailable'
  fi
}

write_skip_json() {
  local reason="$1"
  REASON="$reason" SOURCE_FILE="$source_file" SOURCE_SHA="$(sha256_file "$source_file")" \
  CLANG_VERSION="$(clang_version)" TARGET_ARCH="bpf" SKIP_FILE="$skip_file" python3 - <<'PY' > "$skip_json"
import json
import os

print(json.dumps({
    "schema": "zig-scheduler/bpf-build-skip/v1",
    "status": "SKIP",
    "reason": os.environ["REASON"],
    "source": os.environ["SOURCE_FILE"],
    "source_sha256": os.environ["SOURCE_SHA"],
    "clang_version": os.environ["CLANG_VERSION"],
    "target_arch": os.environ["TARGET_ARCH"],
    "btf": "unavailable-build-skipped",
    "policy_mode": "minimal-partial-switch",
    "expected_verifier_object": None,
    "skip_text_path": os.environ["SKIP_FILE"],
    "verification_claimed": False,
}, indent=2, sort_keys=True))
PY
}

write_meta_json() {
  OBJECT_SHA="$(sha256_file "$object_file")" SOURCE_SHA="$(sha256_file "$source_file")" \
  CLANG_VERSION="$(clang_version)" OBJECT_FILE="$object_file" SOURCE_FILE="$source_file" python3 - <<'PY' > "$meta_file"
import json
import os

print(json.dumps({
    "schema": "zig-scheduler/bpf-object-metadata/v1",
    "status": "built",
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": os.environ["OBJECT_SHA"],
    "source": os.environ["SOURCE_FILE"],
    "source_sha256": os.environ["SOURCE_SHA"],
    "clang_version": os.environ["CLANG_VERSION"],
    "target_arch": "bpf",
    "btf": "enabled",
    "policy_mode": "minimal-partial-switch",
    "sched_ext_switch_mode": "SCX_OPS_SWITCH_PARTIAL",
    "expected_verifier_object": os.environ["OBJECT_FILE"],
    "verification_claimed": False,
}, indent=2, sort_keys=True))
PY
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
trap 'rm -f "$probe_c" "$probe_o"' EXIT
cat >"$probe_c" <<'PROBE'
char _license[] __attribute__((section("license"), used)) = "GPL";
int zigsched_probe(void *ctx) { (void)ctx; return 0; }
PROBE

if ! "$cc" -target bpf -O2 -c "$probe_c" -o "$probe_o" >"$log_file" 2>&1; then
  skip "clang cannot emit -target bpf objects; see $log_file"
fi

rm -f "$skip_file" "$skip_json" "$meta_file"
"$cc" -target bpf -O2 -g -Wall -Wextra \
  -I "$repo_root/bpf/include" \
  -c "$source_file" \
  -o "$object_file" >"$log_file" 2>&1

write_meta_json

printf 'BPF object: %s\n' "$object_file"
printf 'BPF metadata: %s\n' "$meta_file"
if command -v file >/dev/null 2>&1; then
  file "$object_file"
fi
