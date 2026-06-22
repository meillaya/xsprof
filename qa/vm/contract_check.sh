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
backend = contract.get("backend_entrypoint", {})
require(backend.get("build_target") == "vm-lab-backend", "backend build target must be vm-lab-backend")
require(backend.get("command") == "zig build vm-lab-backend", "backend command must be zig build vm-lab-backend")
require(backend.get("implementation_status") == "specified-not-implemented", "backend target must be specified before implementation")
require(backend.get("vm_required_command") == "zig build vm-lab-backend -- --mode vm-required --out evidence/lab/<run-id>", "vm-required backend command shape mismatch")
qemu = contract.get("trusted_qemu_discovery", {})
require(qemu.get("script") == "qa/vm/qemu_discovery.sh", "trusted qemu discovery script mismatch")
require(qemu.get("binary") == "qemu-system-x86_64", "trusted qemu binary mismatch")
trusted_qemu = set(qemu.get("trusted_canonical_paths", []))
for path in ("/usr/bin/qemu-system-x86_64", "/run/current-system/sw/bin/qemu-system-x86_64", "/nix/store/*/bin/qemu-system-x86_64"):
    require(path in trusted_qemu, f"trusted qemu path missing {path}")
require(qemu.get("must_not_execute_untrusted_candidate") is True, "qemu discovery must not execute untrusted candidates")
inputs = contract.get("inputs", {})
require(inputs.get("image", {}).get("required_for_vm_required_release") is True, "VM image release requirement missing")
require(inputs.get("kernel", {}).get("required_for_microvm_live") is True, "microVM kernel requirement missing")
require(inputs.get("nix", {}).get("required_for_microvm_live") is True, "Nix microVM requirement missing")
require(inputs.get("bpf_object", {}).get("path") == "zig-out/bpf/zigsched_minimal.bpf.o", "BPF object input path mismatch")
require(inputs.get("bpf_object", {}).get("skip_is_release_eligible") is False, "BPF SKIP must not be release eligible")
vm_tuple = contract.get("vm_tuple_requirements", {})
require("x86_64" in vm_tuple.get("arch", []), "x86_64 VM arch requirement missing")
for key in ("kvm", "btf", "cgroup_v2", "sched_ext"):
    require(vm_tuple.get(key, {}).get("required") is True, f"VM tuple requirement missing {key}")
for config in ("CONFIG_SCHED_CLASS_EXT", "CONFIG_BPF", "CONFIG_BPF_SYSCALL", "CONFIG_BPF_JIT", "CONFIG_DEBUG_INFO_BTF"):
    require(config in vm_tuple.get("kernel", {}).get("config_required", []), f"kernel config requirement missing {config}")
require(contract.get("guest_marker", {}).get("path") == "/run/zig-scheduler-vm-lab.marker", "VM marker path mismatch")
require(contract.get("guest_marker", {}).get("required_for_vm_live_evidence") is True, "VM-live marker gate missing")
require(len(contract.get("copy_in", [])) >= 4, "copy-in list too small")
copy_out = set(contract.get("copy_out", []))
evidence = contract.get("evidence_layout", {})
required_evidence_files = set(evidence.get("required_files", []))
for path in ("manifest.json", "attestation.json", "transcript.jsonl", "bpf-verifier.log", "runtime-samples.jsonl", "rollback-result.json", "cleanup-receipt.json", "audit-ledger.jsonl", "summary.json"):
    require(path in copy_out, f"copy-out list missing {path}")
    require(path in required_evidence_files, f"evidence layout missing {path}")
require(copy_out == required_evidence_files, "copy-out and evidence required_files must match exactly")
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
require(evidence.get("backend_default_out") == "evidence/lab/vm-backend-final", "backend default evidence path mismatch")
require(evidence.get("fixture_release_eligible") is False, "fixture evidence must not be release eligible")
events = contract.get("event_schemas", {})
for name, schema in {
    "transcript_index": "zig-scheduler/vm-transcript-index/v1",
    "lifecycle_event": "zig-scheduler/vm-lab-lifecycle-event/v1",
    "incident_event": "zig-scheduler/vm-lab-incident/v1",
    "runtime_sample": "zig-scheduler/runtime-sample/v1",
    "audit_ledger": "zig-scheduler/audit-ledger/v1",
    "run_all_summary": "zig-scheduler/run-all-lab/v1",
}.items():
    require(events.get(name) == schema, f"event schema mismatch for {name}")
ownership = contract.get("bpf_ownership", {})
require(ownership.get("kernel_program_source") == "C", "BPF kernel program source ownership must remain C")
require(ownership.get("kernel_program_toolchain") == "clang -target bpf", "BPF toolchain ownership must remain clang -target bpf")
require(ownership.get("host_attach_allowed") is False, "host attach must remain forbidden")
for owned in ("build graph", "orchestration", "metadata validation", "VM lab runner entrypoint", "evidence schema checks", "packaging", "release gates"):
    require(owned in ownership.get("zig_owns", []), f"Zig ownership boundary missing {owned}")
vm_attach_requires = set(ownership.get("vm_attach_requires", []))
for gate_name in ("guest_marker", "audit_id", "rollback_id", "verifier_success", "tuple_gates"):
    require(gate_name in vm_attach_requires, f"VM attach gate missing {gate_name}")
require(vm_attach_requires == {"guest_marker", "audit_id", "rollback_id", "verifier_success", "tuple_gates"}, "VM attach gates must match the audited gate set exactly")
gate = contract.get("implementation_gate", {})
require(gate.get("execute_mode_before_t15") == "refuse" or gate.get("execute_mode_t15") == "fixture-gated", "execute mode gate missing")
run_lab = Path("qa/vm/run_lab.sh").read_text()
require("execute" in run_lab, "run_lab.sh does not document/accept execute mode")
require("VM_CONFIG_REQUIRED" in run_lab, "run_lab.sh does not require explicit execute config")
qemu_discovery = Path("qa/vm/qemu_discovery.sh").read_text()
qemu_refuse_paths = set(qemu.get("refuse_paths", []))
for refused in ("relative paths", "/home/*", "/tmp/*", "/var/tmp/*", "/dev/shm/*", "paths containing traversal components", "*/.zig-cache/*", "*/.omo/*", "*/.omx/*"):
    require(refused in qemu_refuse_paths, f"contract qemu refusal path missing {refused}")
for trusted in ("/usr/bin/", "/run/current-system/sw/bin/", "/nix/store/*/bin/"):
    require(trusted in qemu_discovery, f"qemu discovery missing trusted prefix {trusted}")
for refused in ("/tmp/*", "/var/tmp/*", "/dev/shm/*", "*/.omo/*", "*/.omx/*"):
    require(refused in qemu_discovery, f"qemu discovery missing refusal pattern {refused}")
runbook = Path("docs/runbooks/vm-lab.md").read_text()
for required_text in ("zig build vm-lab-backend", "C/clang-owned", "Zig owns orchestration", "zig-scheduler/vm-lab-lifecycle-event/v1", "qemu-system-x86_64"):
    require(required_text in runbook, f"runbook missing {required_text}")
bpf_readme = Path("bpf/README.md").read_text()
require("C/clang-owned" in bpf_readme and "Zig owns" in bpf_readme, "BPF ownership boundary missing from README")
print("PASS contract schema: disposable VM execution contract is specified and gated")
PY

set +e
before_qemu="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)"
shim_dir="$out_dir/qemu-shim-bin"
shim_sentinel="$out_dir/qemu-shim-invoked.txt"
mkdir -p "$shim_dir"
cat > "$shim_dir/qemu-system-x86_64" <<SH
#!/usr/bin/env bash
printf 'UNTRUSTED QEMU SHIM EXECUTED\n' > "$shim_sentinel"
exit 88
SH
chmod +x "$shim_dir/qemu-system-x86_64"
execute_output="$(PATH="$shim_dir:$PATH" bash qa/vm/run_lab.sh --mode execute --out "$out_dir/execute-refuse" 2>&1)"
execute_rc=$?
after_qemu="$(pgrep -ax 'qemu-system-x86_64|qemu-kvm|qemu-system-aarch64' 2>/dev/null || true)"
set -e
printf '%s\n' "$execute_output" > "$out_dir/execute-refuse/stdout.txt"
printf '%s\n' "$before_qemu" > "$out_dir/qemu-before.txt"
printf '%s\n' "$after_qemu" > "$out_dir/qemu-after.txt"
{
  printf 'shim_path=%s\n' "$shim_dir/qemu-system-x86_64"
  printf 'shim_was_on_path=true\n'
  printf 'execute_rc=%s\n' "$execute_rc"
  printf 'shim_invoked=%s\n' "$([ -e "$shim_sentinel" ] && printf true || printf false)"
} > "$out_dir/qemu-shim-proof.txt"

if [ "$execute_rc" -eq 0 ]; then
  printf 'FAIL contract: execute mode unexpectedly succeeded\n' >&2
  exit 1
fi
if [ -e "$shim_sentinel" ]; then
  printf 'FAIL contract: execute refusal invoked an untrusted qemu shim\n' >&2
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
rm -rf "$shim_dir"

cache_shim_dir=".zig-cache/task-T07-contract-check"
cache_shim="$cache_shim_dir/qemu-system-x86_64"
cache_sentinel="$out_dir/qemu-cache-shim-invoked.txt"
rm -rf "$cache_shim_dir"
mkdir -p "$cache_shim_dir"
cat > "$cache_shim" <<SH
#!/usr/bin/env bash
printf 'GENERATED QEMU SHIM EXECUTED\n' > "$cache_sentinel"
exit 89
SH
chmod +x "$cache_shim"
set +e
cache_refusal_output="$(bash -c 'source qa/vm/qemu_discovery.sh; qemu_discovery_validate_override "$1"' _ "$PWD/$cache_shim" 2>&1)"
cache_refusal_rc=$?
set -e
{
  printf 'generated_shim=%s\n' "$PWD/$cache_shim"
  printf 'validate_override_rc=%s\n' "$cache_refusal_rc"
  printf 'shim_invoked=%s\n' "$([ -e "$cache_sentinel" ] && printf true || printf false)"
  printf 'output=%s\n' "$cache_refusal_output"
} > "$out_dir/qemu-generated-refusal-proof.txt"
rm -rf "$cache_shim_dir"
if [ "$cache_refusal_rc" -eq 0 ]; then
  printf 'FAIL contract: qemu discovery accepted generated/cache override\n' >&2
  exit 1
fi
if [ -e "$cache_sentinel" ]; then
  printf 'FAIL contract: qemu discovery executed generated/cache override candidate\n' >&2
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
for field in ("attestation", "transcript_path", "cleanup_receipt", "copy_in_hashes"):
    if not Path(manifest[field]).exists():
        raise SystemExit(f"FAIL contract: fixture missing {field}")
transcript = Path(manifest["transcript_path"]).read_text()
if "/run/zig-scheduler-vm-lab.marker" not in transcript:
    raise SystemExit("FAIL contract: transcript missing VM marker probe")
print("PASS execute fixture: marker transcript and copy-out manifest recorded")
PY
python3 qa/vm/attestation_check.py --input "$out_dir/execute-fixture/attestation.json"

printf 'PASS disposable VM execution contract check\n'
