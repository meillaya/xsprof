from __future__ import annotations

from typing import Final, TypeAlias

PublicSchemaRule: TypeAlias = tuple[str, str, tuple[str, ...]]
EnumRule: TypeAlias = tuple[str, tuple[str, ...], tuple[str, ...]]
RequiredRule: TypeAlias = tuple[str, tuple[str, ...], tuple[str, ...]]

RUNNER_CLEANLINESS_PUBLIC_SCHEMA_RULES: Final[tuple[PublicSchemaRule, ...]] = (
    (
        "runner-cleanliness-proof.v1.schema.json",
        "zig-scheduler/runner-cleanliness-proof/v1",
        (
            "schema", "proof_outcome", "run_url", "runner_identity", "cleanliness_mode",
            "no_reuse_evidence", "removal_receipt", "protected_review", "runner_substrate",
            "host_mutation", "release_eligible", "production_capacity_claim",
        ),
    ),
)

RUNNER_CLEANLINESS_ENUM_RULES: Final[tuple[EnumRule, ...]] = (
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "proof_outcome"), ("PASS", "SKIP", "REFUSE")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "cleanliness_mode", "properties", "kind"), ("jit", "ephemeral", "clean_machine")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "no_reuse_evidence", "properties", "status"), ("PASS", "SKIP", "REFUSE")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "removal_receipt", "properties", "status"), ("removed", "not_applicable", "unavailable")),
)

RUNNER_CLEANLINESS_REQUIRED_RULES: Final[tuple[RequiredRule, ...]] = (
    ("runner-cleanliness-proof.v1.schema.json", ("required",), ("schema", "proof_outcome", "run_url", "runner_identity", "cleanliness_mode", "no_reuse_evidence", "removal_receipt", "protected_review", "runner_substrate", "host_mutation", "release_eligible", "production_capacity_claim")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "runner_identity", "required"), ("name", "group", "labels")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "cleanliness_mode", "required"), ("kind",)),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "no_reuse_evidence", "required"), ("status", "previous_runner_id", "current_runner_id", "evidence")),
    ("runner-cleanliness-proof.v1.schema.json", ("properties", "removal_receipt", "required"), ("status",)),
    ("runner-cleanliness-proof.v1.schema.json", ("definitions", "artifact_ref", "required"), ("path", "sha256", "schema_role")),
)
