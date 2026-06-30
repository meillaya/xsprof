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

import os

contract_path = Path(os.environ.get("ZIG_SCHEDULER_VM_CONTRACT", "qa/vm/execution_contract.json"))
contract = json.loads(contract_path.read_text())

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL contract: {message}")

require(contract.get("schema") == "zig-scheduler/vm-execution-contract/v1", "schema mismatch")
require(contract.get("status") in {"specified-not-implemented", "implemented-fixture-gated", "implemented-disposable-vm-runner"}, "status must avoid production claim")
require(contract.get("host_mutation") is False, "contract must be host_mutation=false")
require("execute" in contract.get("modes", []), "execute mode missing from contract")
for mode_name in ("host-safe", "auto", "vm-required"):
    require(mode_name in contract.get("modes", []), f"backend mode missing {mode_name}")
backend = contract.get("backend_entrypoint", {})
require(backend.get("build_target") == "vm-lab-backend", "backend build target must be vm-lab-backend")
require(backend.get("command") == "zig build vm-lab-backend", "backend command must be zig build vm-lab-backend")
require(backend.get("implementation_status") in {"specified-not-implemented", "implemented-disposable-vm-runner"}, "backend implementation status mismatch")
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
bpf_input = inputs.get("bpf_object", {})
require(bpf_input.get("path") == "zig-out/bpf/zigsched_minimal.bpf.o", "BPF object input path mismatch")
require(bpf_input.get("metadata") == "zig-out/bpf/zigsched_minimal.bpf.meta.json", "BPF metadata input path mismatch")
require(bpf_input.get("metadata_schema") == "zig-scheduler/bpf-object-metadata/v1", "BPF metadata schema mismatch")
require(bpf_input.get("skip_schema") == "zig-scheduler/bpf-build-skip/v1", "BPF skip schema mismatch")
require(bpf_input.get("vm_marker_required") == "/run/zig-scheduler-vm-lab.marker", "BPF metadata VM marker mismatch")
require(bpf_input.get("skip_is_release_eligible") is False, "BPF SKIP must not be release eligible")
required_metadata_fields = set(bpf_input.get("required_metadata_fields", []))
for field in ("policy_name", "object_hash", "tuple", "tool_versions", "struct_ops", "vm_only", "vm_marker_required", "host_mutation", "host_attach_allowed"):
    require(field in required_metadata_fields, f"BPF metadata required field missing {field}")
vm_tuple = contract.get("vm_tuple_requirements", {})
require("x86_64" in vm_tuple.get("arch", []), "x86_64 VM arch requirement missing")
for key in ("kvm", "btf", "cgroup_v2", "sched_ext"):
    require(vm_tuple.get(key, {}).get("required") is True, f"VM tuple requirement missing {key}")
for config in ("CONFIG_SCHED_CLASS_EXT", "CONFIG_BPF", "CONFIG_BPF_SYSCALL", "CONFIG_BPF_JIT", "CONFIG_DEBUG_INFO_BTF"):
    require(config in vm_tuple.get("kernel", {}).get("config_required", []), f"kernel config requirement missing {config}")
require(contract.get("guest_marker", {}).get("path") == "/run/zig-scheduler-vm-lab.marker", "VM marker path mismatch")
require(contract.get("guest_marker", {}).get("required_for_vm_live_evidence") is True, "VM-live marker gate missing")
copy_in = set(contract.get("copy_in", []))
require(len(copy_in) >= 5, "copy-in list too small")
for path in ("zig-out/bpf/zigsched_minimal.bpf.o", "zig-out/bpf/zigsched_minimal.bpf.meta.json", "qa/vm/verifier_only.sh"):
    require(path in copy_in, f"copy-in list missing {path}")
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
require(evidence.get("backend_event_jsonl") == "evidence/lab/<run-id>/daemon-events.jsonl", "backend event JSONL path mismatch")
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
live = contract.get("stable_live_proof", {})
require(live.get("description", "").startswith("Static VM-live bundle semantics"), "stable live-proof contract description missing")
require(live.get("summary_schema") == "zig-scheduler/run-all-lab/v1", "stable live-proof summary schema mismatch")
require(live.get("status") == "PASS", "stable live-proof status must be PASS")
require(live.get("evidence_mode") == "vm-live", "stable live-proof evidence_mode must be vm-live")
require(live.get("vm_kind") == "qemu-vm", "stable live-proof vm_kind must be qemu-vm")
require(live.get("host_mutation") is False, "stable live-proof host_mutation must be false")
require(live.get("release_eligible_live_proof") is False, "stable live-proof must be release-ineligible")
require(live.get("vm_marker_path") == "/run/zig-scheduler-vm-lab.marker", "stable live-proof VM marker path mismatch")
require(live.get("vm_marker_present") is True, "stable live-proof VM marker presence must be true")
require(live.get("rollback_result") == "PASS", "stable live-proof rollback_result must be PASS")
cleanup = live.get("cleanup", {})
require(cleanup.get("required") is True, "stable live-proof cleanup receipt must be required")
cleanup_values = cleanup.get("required_values", {})
for field, expected in {
    "qemu_leftovers": False,
    "tmux_leftovers": False,
    "process_group_reaped": True,
    "temp_dirs_removed": True,
}.items():
    require(cleanup_values.get(field) is expected, f"stable live-proof cleanup field mismatch: {field}")
require(cleanup.get("timeout_rc_must_not_equal") == 124, "stable live-proof cleanup must reject timeout rc 124")
live_artifacts = set(live.get("required_artifact_paths", []))
for path in (
    "partial-attach/partial-attach-evidence.json",
    "observe-partial/summary.json",
    "observe-partial/runtime-samples.jsonl",
    "observe-partial/daemon-runtime-events.jsonl",
    "rollback-drill/audit-ledger.jsonl",
):
    require(path in live_artifacts, f"stable live-proof required artifact missing {path}")
observe = live.get("observe_summary", {})
require(observe.get("schema") == "zig-scheduler/observe-partial-summary/v1", "observe summary schema mismatch")
observe_fields = set(observe.get("required_fields", []))
for field in (
    "schema",
    "status",
    "evidence_mode",
    "runtime_samples",
    "daemon_runtime_events",
    "sample_count",
    "workload_alive_all_samples",
    "final_ops",
    "final_state",
    "final_state_disabled_or_rolled_back",
    "private_command_lines_sampled",
    "release_eligible_live_proof",
):
    require(field in observe_fields, f"observe summary required field missing {field}")
observe_values = observe.get("required_values", {})
for field, expected in {
    "status": "PASS",
    "evidence_mode": "vm-live",
    "workload_alive_all_samples": True,
    "final_state_disabled_or_rolled_back": True,
    "private_command_lines_sampled": False,
    "release_eligible_live_proof": False,
}.items():
    require(observe_values.get(field) == expected, f"observe summary required value mismatch: {field}")
require(observe.get("sample_count_min") == 3, "observe summary sample_count_min must be 3")
partial = live.get("partial_attach", {})
require(partial.get("schema") == "zig-scheduler/partial-attach-evidence/v1", "partial attach schema mismatch")
partial_fields = set(partial.get("required_fields", []))
for field in (
    "schema",
    "host_mutation",
    "release_eligible_live_proof",
    "object",
    "object_sha256",
    "ops_during_attach",
    "switch_mode",
    "target_cgroup",
    "rollback_id",
    "rollback_status",
    "post_state",
    "transcript_path",
):
    require(field in partial_fields, f"partial attach required field missing {field}")
partial_values = partial.get("required_values", {})
for field, expected in {
    "host_mutation": False,
    "release_eligible_live_proof": False,
    "ops_during_attach": "zigsched_minimal",
    "switch_mode": "SCX_OPS_SWITCH_PARTIAL",
    "rollback_status": "PASS",
}.items():
    require(partial_values.get(field) == expected, f"partial attach required value mismatch: {field}")
require(partial.get("target_cgroup_prefix") == "/sys/fs/cgroup/zig-scheduler-lab.slice/", "partial attach target cgroup prefix mismatch")
require(partial.get("object_sha256_shape") == "sha256-hex-64-nonzero", "partial attach object sha shape mismatch")
runtime_sample = live.get("runtime_sample_artifact", {})
require(runtime_sample.get("path_suffix") == "observe-partial/runtime-samples.jsonl", "runtime sample artifact path suffix mismatch")
require(runtime_sample.get("schema") == "zig-scheduler/runtime-sample/v1", "runtime sample schema mismatch")
runtime_sample_fields = set(runtime_sample.get("required_fields", []))
for field in ("schema", "sequence", "ops", "state", "events", "workload_alive", "private_command_lines_sampled", "cgroup_membership_digest", "cgroup_membership_status"):
    require(field in runtime_sample_fields, f"runtime sample required field missing {field}")
require(runtime_sample.get("required_values", {}).get("workload_alive") is True, "runtime sample workload_alive must be true")
require(runtime_sample.get("required_values", {}).get("private_command_lines_sampled") is False, "runtime sample private command lines must be false")
daemon_runtime = live.get("daemon_runtime_event_artifact", {})
require(daemon_runtime.get("path_suffix") == "observe-partial/daemon-runtime-events.jsonl", "daemon runtime event artifact path suffix mismatch")
require(daemon_runtime.get("schema") == "zig-scheduler/daemon-event/v1", "daemon runtime event schema mismatch")
require(daemon_runtime.get("event") == "runtime_sample", "daemon runtime event name mismatch")
daemon_runtime_fields = set(daemon_runtime.get("required_fields", []))
for field in ("schema", "event", "ops", "host_mutation"):
    require(field in daemon_runtime_fields, f"daemon runtime event required field missing {field}")
require(daemon_runtime.get("required_values", {}).get("host_mutation") is False, "daemon runtime events must require host_mutation=false")
validator_boundaries = set(live.get("validator_boundaries", {}).get("kept_in_runtime_validators", []))
for boundary in (
    "sample ordering before/during/after attach",
    "counter growth and explicit counter fact validation",
    "cgroup membership digest validation",
    "daemon runtime_sample occurrence and zigsched_minimal occurrence checks",
):
    require(boundary in validator_boundaries, f"runtime validator boundary missing {boundary}")
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
backend_runner = Path("qa/vm/vm_lab_backend.sh").read_text()
for required_text in ("daemon-events.jsonl", "vm-required", "qemu_discovery", "zig-out/bpf/zigsched_minimal.bpf.meta.json", "/run/zig-scheduler-vm-lab.marker"):
    require(required_text in backend_runner, f"backend runner missing {required_text}")
qemu_discovery = Path("qa/vm/qemu_discovery.sh").read_text()
qemu_refuse_paths = set(qemu.get("refuse_paths", []))
for refused in ("relative paths", "/home/*", "/tmp/*", "/var/tmp/*", "/dev/shm/*", "paths containing traversal components", "*/.zig-cache/*", "*/.omo/*", "*/.omx/*"):
    require(refused in qemu_refuse_paths, f"contract qemu refusal path missing {refused}")
for trusted in ("/usr/bin/", "/run/current-system/sw/bin/", "/nix/store/*/bin/"):
    require(trusted in qemu_discovery, f"qemu discovery missing trusted prefix {trusted}")
for refused in ("/tmp/*", "/var/tmp/*", "/dev/shm/*", "*/.omo/*", "*/.omx/*"):
    require(refused in qemu_discovery, f"qemu discovery missing refusal pattern {refused}")
runbook = Path("docs/runbooks/vm-lab.md").read_text()
for required_text in (
    "zig build vm-lab-backend",
    "C/clang-owned",
    "Zig owns orchestration",
    "zig-scheduler/vm-lab-lifecycle-event/v1",
    "qemu-system-x86_64",
    "evidence_mode=vm-live",
    "vm_kind=qemu-vm",
    "vm_marker_path=/run/zig-scheduler-vm-lab.marker",
    "qemu_leftovers=false",
    "observe-partial/runtime-samples.jsonl",
    "observe-partial/daemon-runtime-events.jsonl",
    "ops_during_attach=zigsched_minimal",
    "zig-scheduler/runtime-sample/v1",
    "zig-scheduler/daemon-event/v1",
    "does **not** duplicate runtime-order",
):
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
