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
| `malformed_rpc` | rpc_error | operator_error | retry_after_fix | Send valid JSON-RPC 2.0 JSON per line. |
| `invalid_rpc_version` | rpc_error | operator_error | retry_after_fix | Use JSON-RPC `"2.0"`. |
| `unknown_rpc_method` | rpc_error | operator_error | retry_after_fix | Use a documented daemon RPC method. |
| `action_json_required` | rpc_error | operator_error | retry_after_fix | Include operator-action/v1 JSON in `params.action_json`. |
| `rpc_action_mismatch` | rpc_error | operator_error | retry_after_fix | Use the JSON-RPC method matching the embedded operator-action kind. |

All incident/refusal rows and JSON-RPC errors preserve `host_mutation=false`.
