#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

contract="qa/vm/execution_contract.json"
out_dir="evidence/lab/task-T07-contract-check"
rm -rf "$out_dir"
mkdir -p "$out_dir"

python3 - <<'PY'
import json
from pathlib import Path

contract_path = Path("qa/vm/execution_contract.json")
contract = json.loads(contract_path.read_text())

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL contract: {message}")

require(contract.get("schema") == "zig-scheduler/vm-execution-contract/v1", "schema mismatch")
require(contract.get("status") == "specified-not-implemented", "status must avoid implementation claim")
require(contract.get("host_mutation") is False, "contract must be host_mutation=false")
require("execute" in contract.get("modes", []), "execute mode missing from contract")
require(contract.get("guest_marker", {}).get("path") == "/run/zig-scheduler-vm-lab.marker", "VM marker path mismatch")
require(contract.get("guest_marker", {}).get("required_for_vm_live_evidence") is True, "VM-live marker gate missing")
require(len(contract.get("copy_in", [])) >= 4, "copy-in list too small")
require(len(contract.get("copy_out", [])) >= 5, "copy-out list too small")
allowlist = contract.get("command_allowlist", [])
require(len(allowlist) >= 4, "command allowlist too small")
for command in allowlist:
    argv0 = command.get("argv0", "")
    require(argv0.startswith("qa/vm/"), f"untrusted argv0: {argv0}")
    require(" " not in argv0 and "\n" not in argv0, f"argv0 is not a fixed path: {argv0}")
    if command.get("mutation_capable") is True:
        require(command.get("requires_guest_marker") is True, f"mutation command lacks VM marker gate: {command.get('name')}")
manifest = contract.get("artifact_manifest", {})
required_fields = set(manifest.get("required_fields", []))
for field in ("git_sha", "host_mutation", "vm_marker", "cleanup_receipt", "transcript_path"):
    require(field in required_fields, f"artifact manifest missing {field}")
require(contract.get("implementation_gate", {}).get("execute_mode_before_t15") == "refuse", "execute mode must refuse before T15")
run_lab = Path("qa/vm/run_lab.sh").read_text()
require("execute" in run_lab, "run_lab.sh does not document/accept execute mode")
require("VM_EXECUTE_NOT_IMPLEMENTED" in run_lab, "run_lab.sh does not fail closed for execute mode")
print("PASS contract schema: disposable VM execution contract is specified and gated")
PY

set +e
before_qemu="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)"
execute_output="$(bash qa/vm/run_lab.sh --mode execute --out "$out_dir/execute-refuse" 2>&1)"
execute_rc=$?
after_qemu="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)"
set -e
printf '%s\n' "$execute_output" > "$out_dir/execute-refuse/stdout.txt"
printf '%s\n' "$before_qemu" > "$out_dir/qemu-before.txt"
printf '%s\n' "$after_qemu" > "$out_dir/qemu-after.txt"

if [ "$execute_rc" -eq 0 ]; then
  printf 'FAIL contract: execute mode unexpectedly succeeded\n' >&2
  exit 1
fi
case "$execute_output" in *'REFUSE: VM_EXECUTE_NOT_IMPLEMENTED'*) ;; *)
  printf 'FAIL contract: execute mode did not refuse with VM_EXECUTE_NOT_IMPLEMENTED\n' >&2
  printf '%s\n' "$execute_output" >&2
  exit 1
  ;;
esac
if [ "$before_qemu" != "$after_qemu" ]; then
  printf 'FAIL contract: qemu process set changed during execute refusal\n' >&2
  exit 1
fi

python3 - <<'PY'
import json
from pathlib import Path
manifest = json.loads(Path("evidence/lab/task-T07-contract-check/execute-refuse/manifest.json").read_text())
if manifest.get("status") != "refuse":
    raise SystemExit("FAIL contract: execute manifest status is not refuse")
if manifest.get("reason") != "VM_EXECUTE_NOT_IMPLEMENTED":
    raise SystemExit("FAIL contract: execute manifest reason mismatch")
if manifest.get("host_mutation") is not False:
    raise SystemExit("FAIL contract: execute manifest host_mutation must be false")
contract = manifest.get("execution_contract", {})
if contract.get("schema") != "zig-scheduler/vm-execution-contract/v1":
    raise SystemExit("FAIL contract: execute manifest missing contract schema")
if contract.get("execute_mode_before_t15") != "refuse":
    raise SystemExit("FAIL contract: execute manifest missing implementation gate")
print("PASS execute refusal: contract mode records manifest without booting")
PY

printf 'PASS disposable VM execution contract check\n'
