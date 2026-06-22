from __future__ import annotations

from pathlib import Path
import json
from typing import Final

from qa.evidence_safety_check import JsonObject, JsonValue

SCHEMA: Final[str] = "zig-scheduler/verifier-log-parse/v1"
REFUSAL_SCHEMA: Final[str] = "zig-scheduler/verifier-only-refusal/v1"


class VerifierRefusalError(Exception):
    pass


def parse_refusal_evidence(path: Path, allow_refusal: bool) -> JsonObject:
    raw: JsonValue = json.loads(path.read_text())
    if not isinstance(raw, dict) or raw.get("schema") != REFUSAL_SCHEMA:
        raise VerifierRefusalError("JSON input is not a verifier refusal")
    if not allow_refusal:
        raise VerifierRefusalError("host refusal evidence requires --allow-refusal")
    if raw.get("host_mutation") is not False:
        raise VerifierRefusalError("refusal evidence must have host_mutation=false")
    return {
        "schema": SCHEMA,
        "status": "REFUSE",
        "reason": str(raw.get("reason", "UNKNOWN_REFUSAL")),
        "input": path.as_posix(),
        "object": str(raw.get("object", "")),
        "object_sha256": str(raw.get("object_sha256", "")),
        "bpf_metadata_path": str(raw.get("bpf_metadata_path", "")),
        "bpf_metadata_object_sha256": str(raw.get("bpf_metadata_object_sha256", "")),
        "bpftool_rc": None,
        "verifier_errors": [],
        "host_mutation": False,
    }
