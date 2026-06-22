#!/usr/bin/env bash

microvm_fixture_enabled() {
  case "${ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE:-0}" in
    1|lost-stream|malformed-stream|timeout|failed-rollback|failed-cleanup) return 0 ;;
    *) return 1 ;;
  esac
}

microvm_fixture_event() {
  printf 'ZIGSCHED_DAEMON_EVENT %s\n' "$1"
  sleep 0.1
}

microvm_write_lifecycle_fixture() {
  local out_dir="$1" git_sha runtime_samples daemon_events partial_evidence verifier_log audit_ledger
  case "${ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE:-0}" in
    lost-stream)
      printf 'REFUSE: lifecycle fixture intentionally emitted no daemon events\n' >&2
      return 23
      ;;
    malformed-stream)
      microvm_fixture_event 'not-json'
      printf 'REFUSE: lifecycle fixture intentionally emitted malformed daemon event\n' >&2
      return 24
      ;;
    timeout)
      mkdir -p "$out_dir"
      cat > "$out_dir/summary.json" <<JSON
{"schema":"zig-scheduler/run-all-lab/v1","status":"INCIDENT","mode":"microvm-live-fixture","evidence_mode":"vm-live","output_dir":"$out_dir","host_mutation":false,"cleanup":{"qemu_leftovers":false,"tmux_leftovers":false,"timeout_rc":124,"process_group_reaped":true,"temp_dirs_removed":true}}
JSON
      microvm_fixture_event "{\"event\":\"incident\",\"status\":\"unsafe_to_assume\",\"state\":\"unsafe_to_assume\",\"reason\":\"timeout\",\"artifact\":\"$out_dir/summary.json\"}"
      printf 'REFUSE: lifecycle fixture intentionally timed out summary=%s\n' "$out_dir/summary.json" >&2
      return 124
      ;;
  esac
  git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
  runtime_samples="$out_dir/runtime-samples.jsonl"
  daemon_events="$out_dir/daemon-runtime-events.jsonl"
  partial_evidence="$out_dir/partial-attach-evidence.json"
  verifier_log="$out_dir/bpf-verifier.log"
  audit_ledger="$out_dir/audit-ledger.jsonl"
  printf '%s\n' 'verifier fixture accepted host_mutation=false' > "$verifier_log"
  printf '%s\n' '{}' > "$partial_evidence"
  cat > "$runtime_samples" <<'JSONL'
{"schema":"zig-scheduler/runtime-sample/v1","sequence":0,"state":{"status":"present","value":"disabled"},"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
{"schema":"zig-scheduler/runtime-sample/v1","sequence":1,"state":{"status":"present","value":"enabled"},"ops":{"status":"present","value":"zigsched_minimal"},"private_command_lines_sampled":false,"workload_alive":true}
{"schema":"zig-scheduler/runtime-sample/v1","sequence":2,"state":{"status":"present","value":"disabled"},"ops":{"status":"present","value":"none"},"private_command_lines_sampled":false,"workload_alive":true}
JSONL
  cat > "$daemon_events" <<'JSONL'
{"schema":"zig-scheduler/daemon-event/v1","event":"runtime_sample","ops":"zigsched_minimal","host_mutation":false}
JSONL
  printf '%s\n' '{"schema":"zig-scheduler/audit-ledger/v1","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-microvm-live","host_mutation":false}' > "$audit_ledger"
  cat > "$out_dir/summary.json" <<JSON
{
  "schema": "zig-scheduler/run-all-lab/v1",
  "status": "PASS",
  "mode": "microvm-live-fixture",
  "evidence_mode": "vm-live",
  "git_sha": "$git_sha",
  "git_dirty": false,
  "bpf_object_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "output_dir": "$out_dir",
  "output_dir_created_fresh": true,
  "host_mutation": false,
  "vm_kind": "qemu-vm-fixture",
  "vm_marker_present": true,
  "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
  "rollback_result": "PASS",
  "artifact_paths": ["$runtime_samples", "$daemon_events", "$partial_evidence", "$verifier_log", "$audit_ledger"],
  "cleanup": {"qemu_leftovers": false, "tmux_leftovers": false, "process_group_reaped": true, "temp_dirs_removed": true},
  "stages": [{"stage":"partial_attach","status":"PASS","reason":"fixture attach event stream","artifact":"$partial_evidence"}]
}
JSON
  case "${ZIG_SCHEDULER_MICROVM_LIFECYCLE_FIXTURE:-0}" in
    failed-rollback)
      microvm_fixture_event "{\"event\":\"boot\",\"status\":\"PASS\",\"state\":\"vm_live\",\"reason\":\"fixture boot observed\",\"artifact\":\"$out_dir/summary.json\"}"
      microvm_fixture_event "{\"event\":\"rollback\",\"status\":\"FAIL\",\"state\":\"incident\",\"reason\":\"fixture rollback failed\",\"artifact\":\"$audit_ledger\"}"
      printf 'INCIDENT: microVM lifecycle fixture failed rollback summary=%s\n' "$out_dir/summary.json"
      return 0
      ;;
    failed-cleanup)
      microvm_fixture_event "{\"event\":\"boot\",\"status\":\"PASS\",\"state\":\"vm_live\",\"reason\":\"fixture boot observed\",\"artifact\":\"$out_dir/summary.json\"}"
      microvm_fixture_event "{\"event\":\"cleanup\",\"status\":\"FAIL\",\"state\":\"incident\",\"reason\":\"fixture cleanup failed\",\"artifact\":\"$out_dir/summary.json\"}"
      printf 'INCIDENT: microVM lifecycle fixture failed cleanup summary=%s\n' "$out_dir/summary.json"
      return 0
      ;;
  esac
  microvm_fixture_event "{\"event\":\"boot\",\"status\":\"PASS\",\"state\":\"vm_live\",\"reason\":\"fixture boot observed\",\"artifact\":\"$out_dir/summary.json\"}"
  microvm_fixture_event "{\"event\":\"marker\",\"status\":\"PASS\",\"state\":\"vm_live\",\"reason\":\"/run/zig-scheduler-vm-lab.marker\",\"artifact\":\"$out_dir/summary.json\"}"
  microvm_fixture_event "{\"event\":\"verifier\",\"status\":\"PASS\",\"state\":\"verified\",\"reason\":\"BPF verifier fixture accepted\",\"artifact\":\"$verifier_log\"}"
  microvm_fixture_event "{\"event\":\"attach\",\"status\":\"PASS\",\"state\":\"zigsched_minimal\",\"reason\":\"fixture runtime ops observed\",\"artifact\":\"$partial_evidence\"}"
  microvm_fixture_event "{\"event\":\"runtime_sample\",\"status\":\"accepted\",\"state\":\"observing\",\"reason\":\"runtime samples fixture accepted\",\"artifact\":\"$runtime_samples\",\"ops\":\"zigsched_minimal\"}"
  microvm_fixture_event "{\"event\":\"rollback\",\"status\":\"PASS\",\"state\":\"rolled_back\",\"reason\":\"fixture rollback complete\",\"artifact\":\"$audit_ledger\"}"
  microvm_fixture_event "{\"event\":\"cleanup\",\"status\":\"PASS\",\"state\":\"clean\",\"reason\":\"fixture process scan clean\",\"artifact\":\"$out_dir/summary.json\"}"
  microvm_fixture_event "{\"event\":\"validation\",\"status\":\"PASS\",\"state\":\"vm_live_validated\",\"reason\":\"fixture live bundle accepted\",\"artifact\":\"$out_dir/summary.json\",\"live_bundle_path\":\"$out_dir/summary.json\"}"
  printf 'PASS: microVM lifecycle fixture summary=%s\n' "$out_dir/summary.json"
}
