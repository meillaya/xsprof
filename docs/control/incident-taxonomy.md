# Backend incident and refusal taxonomy

This backend-only taxonomy documents stable client-visible incident/refusal codes. It adds no frontend behavior, simulator behavior, real-host attach, release approval, or production readiness.

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

All incident/refusal rows and JSON-RPC errors preserve `host_mutation=false`.
