from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import TypeAlias

JsonValue: TypeAlias = None | bool | int | float | str | list["JsonValue"] | dict[str, "JsonValue"]
JsonObject: TypeAlias = dict[str, JsonValue]


@dataclass(frozen=True, slots=True)
class ReportEnv:
    out: Path
    serial: Path
    object_sha: str
    object_file: str
    meta_file: str
    git_sha: str
    git_dirty: bool
    started_at: str
    kernel_image: str
    qemu_bin: str
    qemu_scan_before: str
    qemu_scan_after: str
    qemu_rc: int
    dirty_snapshot_sha: str


@dataclass(frozen=True, slots=True)
class TimeoutEnv:
    out: Path
    git_sha: str
    git_dirty: bool
    started_at: str
    kernel_image: str
    qemu_bin: str
    qemu_scan_before: str
    qemu_scan_after: str
    qemu_rc: int


@dataclass(frozen=True, slots=True)
class ReportRows:
    boot: JsonObject
    tuple_row: JsonObject
    workload: JsonObject
    mutation_rows: tuple[JsonObject, ...]
    before: JsonObject
    register: JsonObject
    unregister: JsonObject
    stale_refusal: JsonObject
    duplicate_refusal: JsonObject


@dataclass(frozen=True, slots=True)
class SerialLines:
    register: list[str]
    bpftool: list[str]
    duplicate: list[str]


@dataclass(frozen=True, slots=True)
class ReportIds:
    audit_id: str
    audit_suffix: str
    rollback_id: str
    active_target: str
    refused_target: str


@dataclass(frozen=True, slots=True)
class OutputPaths:
    verifier_dir: Path
    partial_dir: Path
    observe_dir: Path
    rollback_dir: Path
    mutation_dir: Path


@dataclass(frozen=True, slots=True)
class VerifierOutputs:
    verifier_evidence: Path
    verifier_log: Path
    partial_evidence: Path
    live_attach_proof: Path
    partial_transcript: Path
    ledger: Path
    snapshot: Path
    rollback_transcript: Path
    refusals: Path
    mutation_evidence: Path


@dataclass(frozen=True, slots=True)
class ObserveOutputs:
    observe_summary: Path
    samples: Path
    daemon: Path
    observe_transcript: Path
    sample_rows: list[JsonObject]
