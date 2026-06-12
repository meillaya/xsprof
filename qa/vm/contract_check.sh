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
require(contract.get("status") in {"specified-not-implemented", "implemented-fixture-gated"}, "status must avoid production claim")
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
gate = contract.get("implementation_gate", {})
require(gate.get("execute_mode_before_t15") == "refuse" or gate.get("execute_mode_t15") == "fixture-gated", "execute mode gate missing")
run_lab = Path("qa/vm/run_lab.sh").read_text()
require("execute" in run_lab, "run_lab.sh does not document/accept execute mode")
require("VM_CONFIG_REQUIRED" in run_lab, "run_lab.sh does not require explicit execute config")
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
case "$execute_output" in *'REFUSE: VM_CONFIG_REQUIRED'*) ;; *)
  printf 'FAIL contract: execute mode did not require explicit config\n' >&2
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
if manifest.get("reason") != "VM_CONFIG_REQUIRED":
    raise SystemExit("FAIL contract: execute manifest reason mismatch")
if manifest.get("host_mutation") is not False:
    raise SystemExit("FAIL contract: execute manifest host_mutation must be false")
print("PASS execute refusal: explicit config is required without booting")
PY

rm -rf "$out_dir/execute-fixture"
fixture_output="$(bash qa/vm/run_lab.sh --mode execute --env-file qa/vm/lab.env --out "$out_dir/execute-fixture" 2>&1)"
printf '%s\n' "$fixture_output" > "$out_dir/execute-fixture/stdout.txt"
case "$fixture_output" in *'PASS: fixture disposable VM execute transcript created'*) ;; *)
  printf 'FAIL contract: fixture execute did not produce transcript\n' >&2
  printf '%s\n' "$fixture_output" >&2
  exit 1
  ;;
esac

python3 - <<'PY'
import json
from pathlib import Path
root = Path("evidence/lab/task-T07-contract-check/execute-fixture")
manifest = json.loads((root / "manifest.json").read_text())
if manifest.get("schema") != "zig-scheduler/vm-transcript-index/v1":
    raise SystemExit("FAIL contract: fixture manifest schema mismatch")
if manifest.get("vm_marker") != "/run/zig-scheduler-vm-lab.marker" or manifest.get("vm_marker_present") is not True:
    raise SystemExit("FAIL contract: fixture manifest missing VM marker")
if manifest.get("host_mutation") is not False:
    raise SystemExit("FAIL contract: fixture manifest host_mutation must be false")
if manifest.get("release_eligible_live_proof") is not False:
    raise SystemExit("FAIL contract: fixture must not be release eligible")
for field in ("transcript_path", "cleanup_receipt", "copy_in_hashes"):
    if not Path(manifest[field]).exists():
        raise SystemExit(f"FAIL contract: fixture missing {field}")
transcript = Path(manifest["transcript_path"]).read_text()
if "/run/zig-scheduler-vm-lab.marker" not in transcript:
    raise SystemExit("FAIL contract: transcript missing VM marker probe")
print("PASS execute fixture: marker transcript and copy-out manifest recorded")
PY

printf 'PASS disposable VM execution contract check\n'
