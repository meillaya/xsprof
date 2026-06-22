# shellcheck shell=bash

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail 'sha256sum or shasum is required'
  fi
}

validate_bpf_metadata() {
  [ -f "$metadata_file" ] || fail "BPF object metadata not found: $metadata_file"
  python3 - "$metadata_file" "$object_file" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

meta_path = Path(sys.argv[1])
object_path = Path(sys.argv[2])
meta = json.loads(meta_path.read_text())
object_sha = hashlib.sha256(object_path.read_bytes()).hexdigest()

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)

required = {
    "schema", "status", "policy_name", "object", "object_hash", "object_sha256",
    "tuple", "tool_versions", "struct_ops", "vm_only", "vm_marker_required",
    "vm_contract", "host_mutation", "host_attach_allowed", "verification_claimed",
}
missing = sorted(required - set(meta))
require(not missing, "BPF metadata missing fields: " + ", ".join(missing))
require(meta.get("schema") == "zig-scheduler/bpf-object-metadata/v1", "bad BPF metadata schema")
require(meta.get("status") == "built", "BPF metadata status is not built")
require(meta.get("policy_name") == "zigsched_minimal", "BPF metadata policy mismatch")
require(meta.get("object_sha256") == object_sha, "BPF object sha does not match metadata")
require(meta.get("object_hash") == "sha256:" + object_sha, "BPF object_hash does not match metadata")
require(meta.get("object") in {str(object_path), str(object_path.resolve())}, "BPF metadata object path mismatch")
require(meta.get("expected_verifier_object") in {str(object_path), str(object_path.resolve())}, "BPF metadata verifier object path mismatch")
require(meta.get("vm_only") is True, "BPF metadata must be VM-only")
require(meta.get("vm_marker_required") == "/run/zig-scheduler-vm-lab.marker", "BPF metadata VM marker mismatch")
require(meta.get("vm_contract") == "qa/vm/execution_contract.json", "BPF metadata VM contract mismatch")
require(meta.get("host_mutation") is False, "BPF metadata host_mutation must be false")
require(meta.get("host_attach_allowed") is False, "BPF metadata host attach must be false")
require(meta.get("verification_claimed") is False, "BPF metadata must not claim verifier success")
tuple_info = meta.get("tuple") or {}
require(tuple_info.get("target_arch") == "bpf", "BPF metadata tuple target mismatch")
require(tuple_info.get("vm_required_for_attach") is True, "BPF metadata tuple VM gate missing")
struct_ops = meta.get("struct_ops") or {}
require(struct_ops.get("object_name") == "zigsched_minimal_ops", "BPF metadata struct_ops object mismatch")
require(struct_ops.get("expected_switch_mode") == "SCX_OPS_SWITCH_PARTIAL", "BPF metadata struct_ops switch mode mismatch")
require("SCX_OPS_SWITCH_ALL" in set(struct_ops.get("prohibited_switch_modes") or []), "BPF metadata full-switch prohibition missing")
print(object_sha)
PY
}

json_write_refusal() {
  local reason="$1"
  REASON="$reason" OBJECT_FILE="$object_file" OBJECT_SHA="$object_sha_for_refusal" OUT_DIR="$out_dir" \
  METADATA_FILE="$metadata_file" METADATA_SHA="$metadata_sha_for_refusal" python3 - <<'PY' > "$refusal_json"
import json, os
print(json.dumps({
    "schema": "zig-scheduler/verifier-only-refusal/v1",
    "status": "refused-host",
    "reason": os.environ["REASON"],
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": os.environ["OBJECT_SHA"],
    "bpf_metadata_path": os.environ["METADATA_FILE"],
    "bpf_metadata_object_sha256": os.environ["METADATA_SHA"],
    "out": os.environ["OUT_DIR"],
    "host_mutation": False,
}, indent=2, sort_keys=True))
PY
}

read_fact() {
  local path="$1"
  if [ -r "$path" ]; then
    head -c 4096 "$path" | tr '\n' ' ' | sed 's/[[:space:]]\+$//'
  else
    printf 'unavailable'
  fi
}

cgroup_membership_digest() {
  if [ ! -d /sys/fs/cgroup ]; then
    printf 'unavailable'
    return
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    find /sys/fs/cgroup -xdev -type f \( -name cgroup.procs -o -name cgroup.threads \) -print 2>/dev/null \
      | LC_ALL=C sort \
      | while IFS= read -r file; do printf 'FILE %s\n' "$file"; cat "$file" 2>/dev/null || true; done \
      | sha256sum | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}
