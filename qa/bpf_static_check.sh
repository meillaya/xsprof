#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_file="bpf/zigsched_minimal.bpf.c"
header_file="bpf/include/zigsched_common.h"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

grep -q 'SCX_OPS_SWITCH_PARTIAL' "$header_file" "$source_file" || fail 'partial switch flag missing'
grep -q 'struct sched_ext_ops' "$header_file" "$source_file" || fail 'sched_ext ops declaration missing'
grep -q 'zigsched_minimal_ops' "$source_file" || fail 'minimal ops instance missing'
grep -q 'BPF_MAP_TYPE_ARRAY' "$header_file" "$source_file" || fail 'bounded stats map missing'
grep -q 'ZIGSCHED_DSQ_FIFO' "$header_file" || fail 'custom FIFO DSQ id missing'
grep -q 'ZIGSCHED_DSQ_VTIME' "$header_file" || fail 'custom vtime DSQ id missing'
grep -q 'ZIGSCHED_STARVATION_NS_MAX' "$header_file" || fail 'bounded starvation constant missing'
grep -q 'scx_bpf_dsq_insert(p, ZIGSCHED_DSQ_FIFO, SCX_SLICE_DFL, enq_flags)' "$source_file" || fail 'custom FIFO DSQ insertion missing'
grep -q 'scx_bpf_dsq_insert_vtime(p, ZIGSCHED_DSQ_VTIME, SCX_SLICE_DFL, 0, enq_flags)' "$source_file" || fail 'custom vtime DSQ insertion missing'
grep -q 'ZIGSCHED_POLICY_MODE_FIFO' "$header_file" "$source_file" || fail 'FIFO policy mode missing'
grep -q 'ZIGSCHED_POLICY_MODE_VTIME' "$header_file" || fail 'vtime policy mode missing'
grep -q 'zigsched_policy_config' "$source_file" "$header_file" || fail 'policy config map missing'
grep -q 'SEC("struct_ops/' "$source_file" || fail 'struct_ops sections missing'

if grep -R -n -E 'SCX_OPS_SWITCH_ALL|SWITCH_ALL|struct_ops[[:space:]].*(register|attach)|bpftool[[:space:]].*(struct_ops|prog load)|/sys/fs/cgroup/.*/(cgroup.procs|cgroup.threads).*>' bpf; then
  fail 'forbidden full-switch or mutation pattern found'
fi

zig build bpf --summary all
if [ -f "$object_file" ]; then
  file "$object_file" | grep -q 'eBPF' || fail 'object is not an eBPF ELF'
  if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump -h "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  elif command -v readelf >/dev/null 2>&1; then
    readelf -S "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  fi
elif [ -f zig-out/bpf/zigsched_minimal.bpf.skip.txt ]; then
  grep -q '^SKIP:' zig-out/bpf/zigsched_minimal.bpf.skip.txt || fail 'invalid skip artifact'
else
  fail 'neither BPF object nor skip artifact exists'
fi

printf 'PASS: BPF static partial-switch checks\n'
