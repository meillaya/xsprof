# Backend incident and refusal taxonomy

This backend-only taxonomy documents stable client-visible incident/refusal codes. It adds no frontend behavior, simulator behavior, real-host attach, release approval, and must not claim production readiness.

| Code | Event kind | Severity | Retryability | Expected client/operator response |
| --- | --- | --- | --- | --- |
| `malformed_action` | refusal | operator_error | retry_after_fix | Reject input locally and show schema/action formatting guidance. |
| `invalid_field` | refusal | operator_error | retry_after_fix | Correct unsafe or missing operator-action field. |
| `invalid_action_id` | refusal | operator_error | retry_after_fix | Generate a safe unique action ID. |
| `duplicate_action_id` | refusal | operator_error | retry_with_new_id | Generate a new action ID; do not replay as success. |
| `target_id_required` | refusal | operator_error | retry_after_fix | Supply explicit target ID for target-owning VM-lab actions. |
| `target_action_id_and_rollback_id_required` | refusal | operator_error | retry_after_fix | Supply both active target action ID and rollback ID. |
| `duplicate_target` | refusal | safety_gate | retry_after_cleanup | Existing golden alias for duplicate target refusal. Treat like `duplicate_target_id`. |
| `duplicate_target_id` | refusal | safety_gate | retry_after_cleanup | Refuse stale/duplicate target until active target is rolled back or cleaned. |
| `stale_target` | refusal | safety_gate | retry_after_refresh | Refresh target list and use an active target action ID. |
| `stale_rollback_id` | refusal | safety_gate | retry_after_refresh | Refresh rollback ID from the active target journal. |
| `journal_limit_exceeded` | refusal | daemon_safety | retry_new_state_dir | Start a new bounded state directory or reduce event volume. |
| `live_bundle_rejected` | incident | unsafe_to_assume | no_auto_retry | Do not claim live proof; inspect artifact bundle. |
| `lost_stream` | incident | unsafe_to_assume | retry_run | Treat stream gap as incomplete proof; rerun or replay known-good fixture. |
| `timeout` | incident | unsafe_to_assume | retry_run | Treat timeout as incomplete proof; cleanup and rerun if safe. |
| `verifier_reject` | incident | unsafe_to_assume | retry_after_fix | Fix BPF/verifier issue before attach. |
| `rollback_failure` | incident | unsafe_to_assume | manual_review | Keep target incident-visible until rollback proof exists. |
| `cleanup_residue` | incident | unsafe_to_assume | manual_cleanup | Do not treat run as clean until residue scan passes. |
| `private_fields_rejected` | incident | privacy_gate | retry_after_redaction | Redact command/environment/private fields before streaming samples. |
| `stale_git_sha` | incident | freshness_gate | retry_current_build | Rebuild or rerun against the current git SHA. |
| `stream_backpressure_dropped` | incident | daemon_safety | retry_with_replay | Treat dropped stream data as incomplete proof; use replay or rerun. |
| `malformed_runtime_sample` | incident | data_error | retry_after_fix | Fix runtime sample JSON producer. |
| `qemu_untrusted_or_unavailable` | refusal | prerequisite_gate | retry_after_lab_setup | Provide a trusted VM-lab QEMU path before treating VM evidence as runnable. |
| `kvm_unavailable` | refusal | prerequisite_gate | retry_after_lab_setup | Enable or choose a supported VM acceleration lane before live VM proof. |
| `kernel_tuple_unsupported` | refusal | prerequisite_gate | retry_after_lab_setup | Use a documented VM-lab kernel tuple before attempting sched_ext proof. |
| `btf_unavailable` | refusal | prerequisite_gate | retry_after_lab_setup | Provide matching BTF metadata before verifier or attach evidence is considered complete. |
| `cgroup_target_disappeared` | incident | cgroup_race | retry_after_refresh | Refresh target state; the selected cgroup vanished before safe VM-lab ownership proof. |
| `cgroup_parent_changed` | incident | cgroup_race | retry_after_refresh | Refresh target state; parent cgroup changed during ownership proof. |
| `cgroup_membership_changed` | incident | cgroup_race | retry_after_refresh | Refresh target state; membership changed during ownership proof. |
| `cgroup_symlink_race` | incident | cgroup_race | manual_review | Treat symlink traversal as unsafe and inspect the cgroup evidence bundle. |
| `cgroup_systemd_escape` | incident | cgroup_race | manual_review | Refuse escaped systemd target paths until ownership boundaries are repaired. |
| `dsq_perf_fairness_gate` | incident | performance_gate | retry_after_fix | Do not claim live proof; fix DSQ/perf fairness evidence and rerun in VM lab. |
| `runtime_nr_rejected_nonzero` | incident | runtime_alert | retry_after_fix | Treat nonzero rejected dispatch count as unsafe until runtime evidence is clean. |
| `runtime_workload_dead` | incident | runtime_alert | retry_after_fix | Treat dead workload observation as unsafe until workload liveness is restored. |
| `release_ineligible` | incident | governance_gate | no_auto_retry | Withhold release eligibility; collect required lab/governance evidence first. |
| `malformed_rpc` | rpc_error | operator_error | retry_after_fix | Send valid JSON-RPC 2.0 JSON per line. |
| `invalid_rpc_version` | rpc_error | operator_error | retry_after_fix | Use JSON-RPC `"2.0"`. |
| `unknown_rpc_method` | rpc_error | operator_error | retry_after_fix | Use a documented daemon RPC method. |
| `action_json_required` | rpc_error | operator_error | retry_after_fix | Include operator-action/v1 JSON in `params.action_json`. |
| `rpc_action_mismatch` | rpc_error | operator_error | retry_after_fix | Use the JSON-RPC method matching the embedded operator-action kind. |
| `replay_row_bad_version` | refusal | replay_gate | retry_after_fix | Reject replay rows whose schema is not `zig-scheduler/daemon-event/v1`; do not reinterpret them as v1. |
| `replay_row_nonmonotonic_seq` | refusal | replay_gate | retry_after_fix | Reject replay rows that move backward, repeat, or otherwise break the requested event-sequence cursor. |
| `replay_row_host_mutation_true` | refusal | replay_gate | safety_gate | Reject replay rows that claim host mutation; v1 contract fixtures must remain `host_mutation=false`. |
| `matrix_artifact_referenced` | validation | matrix_gate | inspect_artifact | A daemon-event row points to a standalone `matrix-run/v1` artifact; validate that artifact with the matrix contract checker before treating it as proof. |
| `bpf_object_metadata_missing` | incident | bpf_gate | retry_after_fix | BPF object metadata or object hash is absent; do not treat BPF evidence as complete. |
| `libbpf_load_failed` | incident | bpf_gate | retry_after_fix | libbpf failed in the VM-lab lane; inspect verifier/libbpf logs and do not retry on the host. |
| `scx_register_failed` | incident | scx_gate | retry_after_fix | sched_ext registration failed in the VM lab; collect tuple/rollback/cleanup proof before rerun. |
| `workload_capability_missing` | refusal | workload_gate | retry_after_lab_setup | Required VM workload tool or capability is unavailable; emit SKIP/REFUSE rather than falling back to host mutation. |
| `runtime_sample_loss` | incident | runtime_alert | retry_with_replay | Runtime sample loss/backpressure makes proof incomplete; use replay or rerun after cleanup. |

All incident/refusal rows and JSON-RPC errors preserve `host_mutation=false`.

## Documentation-only namespace groupings

The labels below are human documentation groupings for phases and sources. They
MUST NOT appear as `daemon-event/v1.reason` values. The v1 wire contract keeps
underscore-only reason codes for compatibility with existing clients and
fixtures.

| Namespace label | Phase/source | Stable v1 wire codes |
| --- | --- | --- |
| rpc.invalid_version | JSON-RPC framing | `invalid_rpc_version` |
| rpc.action_mismatch | JSON-RPC action dispatch | `rpc_action_mismatch` |
| rpc.missing_action_json | JSON-RPC action dispatch | `action_json_required` |
| replay.bad_version | replay row validation | `replay_row_bad_version` |
| replay.nonmonotonic_seq | replay row validation | `replay_row_nonmonotonic_seq` |
| replay.host_mutation_true | replay row validation | `replay_row_host_mutation_true` |
| matrix.artifact_reference | matrix evidence handoff | `matrix_artifact_referenced` |
| bpf.object_metadata_missing | BPF artifact gate | `bpf_object_metadata_missing` |
| bpf.libbpf_load_failed | VM-only libbpf load gate | `libbpf_load_failed` |
| bpf.scx_register_failed | VM-only sched_ext registration gate | `scx_register_failed` |
| workload.capability_missing | VM workload prerequisite gate | `workload_capability_missing` |
| runtime.sample_loss | runtime stream/sample quality gate | `runtime_sample_loss` |
| governance.release_ineligible | release governance gate | `release_ineligible` |
