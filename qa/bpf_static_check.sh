#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_file="bpf/zigsched_minimal.bpf.c"
header_file="bpf/include/zigsched_common.h"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
meta_file="zig-out/bpf/zigsched_minimal.bpf.meta.json"
skip_file="zig-out/bpf/zigsched_minimal.bpf.skip.txt"
skip_json="zig-out/bpf/zigsched_minimal.bpf.skip.json"
vm_marker="/run/zig-scheduler-vm-lab.marker"
vm_contract="qa/vm/execution_contract.json"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_prebuild_artifact_conflicts() {
  if [ -f "$object_file" ] && { [ -f "$skip_file" ] || [ -f "$skip_json" ]; }; then
    fail "pre-build artifact conflict: BPF object exists beside SKIP artifact(s)"
  fi
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

check_prebuild_artifact_conflicts

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
  fail 'forbidden full-switch or mutation pattern found in BPF policy sources'
fi

host_scan=(
  build.zig
  tools/build_bpf.sh
  src/main.zig
  src/preflight_main.zig
  src/root.zig
  src/sched_ext/root.zig
  src/sched_ext/loader/root.zig
)
if grep -n -E 'bpftool[[:space:]]+((prog[[:space:]]+load)|(struct_ops[[:space:]]+(register|unregister)))|bpf\([[:space:]]*BPF_(PROG_LOAD|LINK_CREATE)|/sys/fs/cgroup/.*/(cgroup.procs|cgroup.threads)[[:space:]]*(>|>>)' "${host_scan[@]}"; then
  fail 'host build/root surfaces contain a load/register/cgroup mutation path'
fi

zig build bpf --summary all
if [ -f "$object_file" ]; then
  [ ! -f "$skip_file" ] || fail 'stale skip text remained beside built object'
  [ ! -f "$skip_json" ] || fail 'stale skip JSON remained beside built object'
  file "$object_file" | grep -q 'eBPF' || fail 'object is not an eBPF ELF'
  [ -f "$meta_file" ] || fail 'BPF metadata JSON missing for built object'
  python3 - "$meta_file" "$object_file" "$source_file" "$vm_marker" "$vm_contract" <<'PY' || fail 'BPF metadata JSON invalid'
import hashlib
import json
import sys
from pathlib import Path

meta_path = Path(sys.argv[1])
object_path = Path(sys.argv[2])
source_path = Path(sys.argv[3])
vm_marker = sys.argv[4]
vm_contract = sys.argv[5]
meta = json.loads(meta_path.read_text())
object_sha = hashlib.sha256(object_path.read_bytes()).hexdigest()
source_sha = hashlib.sha256(source_path.read_bytes()).hexdigest()

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)

required = {
    "schema", "status", "artifact_kind", "policy_name", "object", "object_hash",
    "object_sha256", "source", "source_hash", "source_sha256", "tuple",
    "tool_versions", "struct_ops", "vm_only", "vm_marker_required",
    "vm_contract", "host_mutation", "host_attach_allowed", "verification_claimed",
}
missing = sorted(required - set(meta))
require(not missing, "metadata missing fields: " + ", ".join(missing))
require(meta.get("schema") == "zig-scheduler/bpf-object-metadata/v1", "bad metadata schema")
require(meta.get("status") == "built", "metadata status is not built")
require(meta.get("artifact_kind") == "sched_ext_struct_ops_policy_object", "bad artifact kind")
require(meta.get("policy_name") == "zigsched_minimal", "bad policy name")
require(meta.get("policy_symbol") == "zigsched_minimal_ops", "bad policy symbol")
require(meta.get("object_sha256") == object_sha, "metadata object sha mismatch")
require(meta.get("object_hash") == "sha256:" + object_sha, "metadata object_hash mismatch")
require(meta.get("source_sha256") == source_sha, "metadata source sha mismatch")
require(meta.get("source_hash") == "sha256:" + source_sha, "metadata source_hash mismatch")
expected_object = meta.get("expected_verifier_object")
valid_expected = {str(object_path), str(object_path.resolve())}
require(expected_object in valid_expected, "metadata expected verifier object mismatch")
require(meta.get("object") in valid_expected, "metadata object path mismatch")
require(meta.get("verification_claimed") is False, "metadata must not claim verification")
require(meta.get("vm_only") is True, "metadata must be VM-only")
require(meta.get("vm_marker_required") == vm_marker, "metadata VM marker mismatch")
require(meta.get("vm_contract") == vm_contract, "metadata VM contract mismatch")
require(meta.get("host_mutation") is False, "metadata host_mutation must be false")
require(meta.get("host_attach_allowed") is False, "metadata host attach must be false")
tuple_info = meta.get("tuple") or {}
require(tuple_info.get("target_arch") == "bpf", "tuple target_arch mismatch")
require(tuple_info.get("target_define") == "__TARGET_ARCH_x86", "tuple target define mismatch")
require(tuple_info.get("vm_required_for_attach") is True, "tuple must be VM-required for attach")
require(tuple_info.get("vm_contract") == vm_contract, "tuple VM contract mismatch")
for key in ("host_arch", "host_kernel_release"):
    require(bool(tuple_info.get(key)), f"tuple missing {key}")
tools = meta.get("tool_versions") or {}
for key in ("clang", "clang_path", "llvm_objdump", "bpftool", "file", "zig"):
    require(key in tools and tools[key] not in (None, ""), f"tool_versions missing {key}")
struct_ops = meta.get("struct_ops") or {}
require(struct_ops.get("policy_name") == "zigsched_minimal", "struct_ops policy name mismatch")
require(struct_ops.get("object_name") == "zigsched_minimal_ops", "struct_ops object mismatch")
require(struct_ops.get("scheduler_name") == "zigsched_minimal", "struct_ops scheduler mismatch")
require(struct_ops.get("object_section") == ".struct_ops", "struct_ops section mismatch")
require(struct_ops.get("expected_switch_mode") == "SCX_OPS_SWITCH_PARTIAL", "struct_ops switch mode mismatch")
require("SCX_OPS_SWITCH_ALL" in set(struct_ops.get("prohibited_switch_modes") or []), "full-switch prohibition missing")
require(set(struct_ops.get("expected_callbacks") or []) == {"init", "enqueue", "dispatch"}, "struct_ops callbacks mismatch")
sections = set(struct_ops.get("program_sections") or [])
for section in ("struct_ops.s/zigsched_minimal_init", "struct_ops/zigsched_minimal_enqueue", "struct_ops/zigsched_minimal_dispatch"):
    require(section in sections, f"struct_ops program section missing {section}")
PY
  if command -v llvm-objdump >/dev/null 2>&1; then
    llvm-objdump -h "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  elif command -v readelf >/dev/null 2>&1; then
    readelf -S "$object_file" | grep -q 'struct_ops' || fail 'object missing struct_ops section'
  fi
elif [ -f "$skip_file" ]; then
  [ ! -f "$object_file" ] || fail 'stale object remained beside skip artifact'
  [ ! -f "$meta_file" ] || fail 'stale built metadata remained beside skip artifact'
  grep -q '^SKIP:' "$skip_file" || fail 'invalid skip artifact'
  [ -f "$skip_json" ] || fail 'BPF skip JSON missing'
  python3 - "$skip_json" "$source_file" "$vm_marker" "$vm_contract" <<'PY' || fail 'BPF skip JSON invalid'
import hashlib
import json
import sys
from pathlib import Path

skip = json.loads(Path(sys.argv[1]).read_text())
source_sha = hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
vm_marker = sys.argv[3]
vm_contract = sys.argv[4]

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)

required = {"schema", "status", "policy_name", "object_hash", "tuple", "tool_versions", "struct_ops", "reason", "vm_only", "vm_marker_required", "host_mutation", "host_attach_allowed", "skip_is_release_eligible", "verification_claimed"}
missing = sorted(required - set(skip))
require(not missing, "skip missing fields: " + ", ".join(missing))
require(skip.get("schema") == "zig-scheduler/bpf-build-skip/v1", "bad skip schema")
require(skip.get("status") == "SKIP", "bad skip status")
require(skip.get("policy_name") == "zigsched_minimal", "bad skip policy name")
require(bool(skip.get("reason")), "skip reason missing")
require(skip.get("object") is None, "skip must not provide object")
require(skip.get("object_hash") is None, "skip must not provide object_hash")
require(skip.get("object_sha256") is None, "skip must not provide object_sha256")
require(skip.get("source_sha256") == source_sha, "skip source sha mismatch")
require(skip.get("source_hash") == "sha256:" + source_sha, "skip source_hash mismatch")
require(skip.get("expected_verifier_object") is None, "skip must not provide verifier object")
require(skip.get("verification_claimed") is False, "skip must not claim verification")
require(skip.get("release_eligible") is False, "skip must not be release eligible")
require(skip.get("skip_is_release_eligible") is False, "skip release flag must be false")
require(skip.get("vm_only") is True, "skip metadata must preserve VM-only boundary")
require(skip.get("vm_marker_required") == vm_marker, "skip VM marker mismatch")
require(skip.get("vm_contract") == vm_contract, "skip VM contract mismatch")
require(skip.get("host_mutation") is False, "skip host_mutation must be false")
require(skip.get("host_attach_allowed") is False, "skip host attach must be false")
tuple_info = skip.get("tuple") or {}
require(tuple_info.get("target_arch") == "bpf", "skip tuple target_arch mismatch")
require(tuple_info.get("vm_required_for_attach") is True, "skip tuple VM gate missing")
struct_ops = skip.get("struct_ops") or {}
require(struct_ops.get("expected_switch_mode") == "SCX_OPS_SWITCH_PARTIAL", "skip struct_ops switch mode mismatch")
require("SCX_OPS_SWITCH_ALL" in set(struct_ops.get("prohibited_switch_modes") or []), "skip full-switch prohibition missing")
PY
else
  fail 'neither BPF object nor skip artifact exists'
fi

printf 'PASS: BPF static partial-switch checks\n'
