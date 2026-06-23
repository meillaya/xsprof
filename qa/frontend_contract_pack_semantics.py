from __future__ import annotations

from collections.abc import Iterator
from typing import Final

from qa.frontend_contract_pack_types import ContractPackError, JsonObject, JsonValue

REQUIRED_SCENARIOS: Final = (
    "queued", "booting", "verifier", "attached", "observing", "rollback-ready", "rollback-active", "cleaned",
    "incident", "lost-stream", "timeout", "verifier-reject", "rollback-failure", "cleanup-residue",
    "stale-target", "duplicate-target", "stale-rollback", "malformed-action", "stream-backpressure", "stale-git",
    "privacy-rejection", "replay-event-cursor", "replay-runtime-sample-cursor",
    "qemu-unavailable", "unsupported-kernel-tuple", "unsupported-btf-tuple", "unsupported-kvm-tuple",
    "cgroup-race-target-disappeared", "cgroup-race-parent-changed", "cgroup-race-membership-changed",
    "cgroup-race-symlink", "cgroup-race-systemd-escape", "dsq-perf-fairness-gate",
    "runtime-alert-nr-rejected", "runtime-alert-workload-dead", "malformed-runtime-sample",
    "privacy-runtime-variant", "release-ineligible",
)
PREREQUISITE_SCENARIOS: Final = {
    "qemu-unavailable": "qemu_untrusted_or_unavailable",
    "unsupported-kernel-tuple": "kernel_tuple_unsupported",
    "unsupported-btf-tuple": "btf_unavailable",
    "unsupported-kvm-tuple": "kvm_unavailable",
}
CGROUP_RACE_SCENARIOS: Final = {
    "cgroup-race-target-disappeared": "cgroup_target_disappeared",
    "cgroup-race-parent-changed": "cgroup_parent_changed",
    "cgroup-race-membership-changed": "cgroup_membership_changed",
    "cgroup-race-symlink": "cgroup_symlink_race",
    "cgroup-race-systemd-escape": "cgroup_systemd_escape",
}
RELEASE_INELIGIBLE_FORBIDDEN_TEXT: Final = (
    "release_approved",
    "release-approved",
    "release approved",
    "release_proof",
    "release proof",
    "release-proof",
    "proof success",
    "proof_success",
    "proof-success",
)
RELEASE_PROOF_FORBIDDEN_TEXT: Final = (
    "release_proof",
    "release-proof",
    "release proof",
    "proof success",
    "proof_success",
    "proof-success",
)


def validate_replay(rows_by_name: dict[str, list[JsonObject]]) -> None:
    event_rows = rows_by_name["replay-event-cursor"]
    if event_rows[0].get("seq") != 2 or any(row.get("replay_cursor") != "event_seq" for row in event_rows):
        raise ContractPackError("event replay fixture does not prove event-seq cursor semantics")
    runtime_rows = rows_by_name["replay-runtime-sample-cursor"]
    sample_rows = [row for row in runtime_rows if row.get("event") == "runtime_sample"]
    if (
        len(sample_rows) != 1
        or sample_rows[0].get("sample_sequence") != 2
        or sample_rows[0].get("replay_cursor") != "runtime_sample_sequence"
    ):
        raise ContractPackError("runtime replay fixture does not prove sample-seq cursor semantics")


def int_field(row: JsonObject, field: str) -> int | None:
    raw = row.get(field)
    if isinstance(raw, int):
        return raw
    if isinstance(raw, str) and raw.isdecimal():
        return int(raw)
    return None


def require_reasoned_terminal(rows: list[JsonObject], scenario: str, reason: str) -> None:
    for row in rows:
        if is_reasoned_terminal(row, reason):
            return
    raise ContractPackError(f"{scenario} missing terminal unsafe/refused row for {reason}")


def is_reasoned_terminal(row: JsonObject, reason: str) -> bool:
    if row.get("reason") != reason or row.get("event") not in {"incident", "refusal"}:
        return False
    status = row.get("status")
    state = row.get("state")
    return status in {"REFUSE", "refused", "unsafe_to_assume", "INCIDENT"} or state == "unsafe_to_assume"


def reject_pass(rows: list[JsonObject], scenario: str) -> None:
    for row in rows:
        if row.get("status") == "PASS":
            raise ContractPackError(f"{scenario} must not claim PASS")


def string_values(value: JsonValue) -> Iterator[str]:
    if isinstance(value, str):
        yield value
        return
    if isinstance(value, dict):
        for child in value.values():
            yield from string_values(child)
        return
    if isinstance(value, list):
        for child in value:
            yield from string_values(child)


def reject_forbidden_strings(rows: list[JsonObject], scenario: str, needles: tuple[str, ...]) -> None:
    for row in rows:
        for value in string_values(row):
            lower_value = value.lower()
            if any(needle in lower_value for needle in needles):
                raise ContractPackError(f"{scenario} contains forbidden release-proof success language: {value}")


def validate_scenario_semantics(name: str, rows: list[JsonObject]) -> None:
    if name in PREREQUISITE_SCENARIOS:
        reason = PREREQUISITE_SCENARIOS[name]
        if not any(row.get("event") == "refusal" and row.get("status") in {"REFUSE", "refused"} for row in rows):
            raise ContractPackError(f"{name} must be a visible refusal")
        require_reasoned_terminal(rows, name, reason)
    if name in CGROUP_RACE_SCENARIOS:
        reason = CGROUP_RACE_SCENARIOS[name]
        require_reasoned_terminal(rows, name, reason)
        if not any(isinstance(row.get("artifact"), str) and "cgroup-race/" in str(row.get("artifact")) for row in rows):
            raise ContractPackError(f"{name} missing cgroup race artifact")
    if name == "dsq-perf-fairness-gate":
        reject_pass(rows, name)
        reject_forbidden_strings(rows, name, RELEASE_PROOF_FORBIDDEN_TEXT)
        require_reasoned_terminal(rows, name, "dsq_perf_fairness_gate")
    if name == "runtime-alert-nr-rejected":
        sample_seen = False
        for row in rows:
            if row.get("event") == "runtime_sample" and (int_field(row, "nr_rejected") or 0) > 0:
                sample_seen = True
            if is_reasoned_terminal(row, "runtime_nr_rejected_nonzero") and not sample_seen:
                raise ContractPackError(f"{name} terminal incident precedes nr_rejected runtime_sample")
        if not sample_seen:
            raise ContractPackError(f"{name} missing nonzero nr_rejected runtime_sample")
        require_reasoned_terminal(rows, name, "runtime_nr_rejected_nonzero")
    if name == "runtime-alert-workload-dead":
        sample_seen = False
        for row in rows:
            if row.get("event") == "runtime_sample" and row.get("workload_alive") is False:
                sample_seen = True
            if is_reasoned_terminal(row, "runtime_workload_dead") and not sample_seen:
                raise ContractPackError(f"{name} terminal incident precedes workload_dead runtime_sample")
        if not sample_seen:
            raise ContractPackError(f"{name} missing workload_alive=false runtime_sample")
        require_reasoned_terminal(rows, name, "runtime_workload_dead")
    if name == "malformed-runtime-sample":
        require_reasoned_terminal(rows, name, "malformed_runtime_sample")
    if name == "privacy-runtime-variant":
        require_reasoned_terminal(rows, name, "private_fields_rejected")
    if name == "release-ineligible":
        reject_pass(rows, name)
        reject_forbidden_strings(rows, name, RELEASE_INELIGIBLE_FORBIDDEN_TEXT)
        if not any(row.get("event") == "validation" and row.get("state") == "release_ineligible" for row in rows):
            raise ContractPackError("release-ineligible missing validation release_ineligible state")
        require_reasoned_terminal(rows, name, "release_ineligible")
