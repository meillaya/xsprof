#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_file="bpf/zigsched_minimal.bpf.c"
header_file="bpf/include/zigsched_common.h"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
meta_file="zig-out/bpf/zigsched_minimal.bpf.meta.json"
skip_json="zig-out/bpf/zigsched_minimal.bpf.skip.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_dispatch_consume=1
require_stats_events=1
for arg in "$@"; do
  case "$arg" in
    --require-dispatch-consume)
      require_dispatch_consume=1
      ;;
    --require-stats-events)
      require_stats_events=1
      ;;
    --help|-h)
      printf 'usage: %s [--require-dispatch-consume] [--require-stats-events]\n' "$0"
      exit 0
      ;;
    *)
      fail "unknown argument: $arg"
      ;;
  esac
done

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

if [ "$require_dispatch_consume" -eq 1 ]; then
  grep -q 'scx_bpf_create_dsq(ZIGSCHED_DSQ_FIFO' "$source_file" || fail 'FIFO DSQ creation missing'
  grep -q 'scx_bpf_create_dsq(ZIGSCHED_DSQ_VTIME' "$source_file" || fail 'vtime DSQ creation missing'
  grep -q 'scx_bpf_dsq_move_to_local(ZIGSCHED_DSQ_FIFO)' "$source_file" || fail 'FIFO DSQ dispatch consumption missing'
  grep -q 'scx_bpf_dsq_move_to_local(ZIGSCHED_DSQ_VTIME)' "$source_file" || fail 'vtime DSQ dispatch consumption missing'
fi

if [ "$require_stats_events" -eq 1 ]; then
  grep -q 'zigsched_events' "$source_file" "$header_file" || fail 'event counter map missing'
  grep -q 'zigsched_stats_increment' "$source_file" || fail 'stats update helper missing'
  grep -q 'zigsched_event_increment' "$source_file" || fail 'event update helper missing'
  grep -q 'ZIGSCHED_EVENT_SELECT_CPU_FALLBACK' "$source_file" "$header_file" || fail 'select-cpu fallback event missing'
  grep -q 'ZIGSCHED_STAT_DISPATCH_CALLS' "$source_file" "$header_file" || fail 'dispatch stats counter missing'
fi

if grep -R -n -E 'SCX_OPS_SWITCH_ALL|SWITCH_ALL|struct_ops[[:space:]].*(register|attach)|bpftool[[:space:]].*(struct_ops|prog load)|bpf_probe_write_user|bpf_trace_printk|bpf_override_return|/sys/fs/cgroup/.*/(cgroup.procs|cgroup.threads).*>' bpf; then
  fail 'forbidden full-switch or mutation pattern found'
fi

zig build bpf --summary all
if [ -f "$object_file" ]; then
  file "$object_file" | grep -q 'eBPF' || fail 'object is not an eBPF ELF'
  [ -f "$meta_file" ] || fail 'BPF metadata JSON missing for built object'
  python3 - "$meta_file" "$object_file" <<'PY' || fail 'BPF metadata JSON invalid'
import hashlib
import json
import sys
from pathlib import Path

meta = json.loads(Path(sys.argv[1]).read_text())
object_path = Path(sys.argv[2])
if meta.get("schema") != "zig-scheduler/bpf-object-metadata/v1":
    raise SystemExit("bad metadata schema")
if meta.get("status") != "built":
    raise SystemExit("metadata status is not built")
if meta.get("object_sha256") != hashlib.sha256(object_path.read_bytes()).hexdigest():
    raise SystemExit("metadata object sha mismatch")
expected_object = meta.get("expected_verifier_object")
valid_expected = {str(object_path), str(object_path.resolve())}
if expected_object not in valid_expected:
    raise SystemExit("metadata expected verifier object mismatch")
object_value = meta.get("object")
if object_value not in valid_expected:
    raise SystemExit("metadata object path mismatch")
if meta.get("verification_claimed") is not False:
    raise SystemExit("metadata must not claim verification")
PY
  if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump -h "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  elif command -v readelf >/dev/null 2>&1; then
    readelf -S "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  fi
elif [ -f zig-out/bpf/zigsched_minimal.bpf.skip.txt ]; then
  grep -q '^SKIP:' zig-out/bpf/zigsched_minimal.bpf.skip.txt || fail 'invalid skip artifact'
  [ -f "$skip_json" ] || fail 'BPF skip JSON missing'
  python3 - "$skip_json" <<'PY' || fail 'BPF skip JSON invalid'
import json
import sys
from pathlib import Path

skip = json.loads(Path(sys.argv[1]).read_text())
if skip.get("schema") != "zig-scheduler/bpf-build-skip/v1":
    raise SystemExit("bad skip schema")
if skip.get("status") != "SKIP":
    raise SystemExit("bad skip status")
if not skip.get("reason"):
    raise SystemExit("skip reason missing")
if skip.get("expected_verifier_object") is not None:
    raise SystemExit("skip must not provide verifier object")
if skip.get("verification_claimed") is not False:
    raise SystemExit("skip must not claim verification")
PY
else
  fail 'neither BPF object nor skip artifact exists'
fi

printf 'PASS: BPF static partial-switch checks\n'
