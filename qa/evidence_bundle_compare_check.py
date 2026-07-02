#!/usr/bin/env python3
# pyright: reportAny=false
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/evidence_bundle_compare_check.py --left evidence/a --right evidence/b
# python3 qa/evidence_bundle_compare_check.py --left evidence/a/evidence-manifest.json --right evidence/b/evidence-manifest.json --expect-bpf-change
# python3 qa/evidence_bundle_compare_check.py --self-test
"""Compare protected evidence bundle manifests without performance judgments. # noqa: SIZE_OK - bundle comparison keeps manifest parsing, self-test fixtures, and CLI behavior together for reviewability."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
import json
import subprocess
import sys
from pathlib import Path
from typing import Final, TypeAlias, assert_never

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa.evidence_bundle_paths import BundleCompareError, artifact_path, file_sha, obj, require, resolve_manifest, text
from qa.evidence_manifest_check import JsonObject, JsonValue, ManifestError, load_json

REF_FIELDS: Final[frozenset[str]] = frozenset(("path", "sha256", "schema_role"))
REQUIRED_ROLES: Final[frozenset[str]] = frozenset(("matrix-manifest", "matrix-row", "rollback-proof", "cleanup-proof", "host-refusal-proof", "privacy-scan", "runner-substrate-proof", "runner-cleanliness-proof", "protected-environment-review"))
BPF_ROLES: Final[frozenset[str]] = frozenset(("bpf-metadata", "bpf-skip-json"))
BenchmarkState: TypeAlias = tuple[str, int]


@dataclass(frozen=True, slots=True)
class CompareOptions:
    expect_tuple_change: bool = False
    expect_bpf_change: bool = False
    expect_git_sha_change: bool = False
    left_artifact_root: Path | None = None
    right_artifact_root: Path | None = None


@dataclass(frozen=True, slots=True)
class BundleIndex:
    manifest_path: Path
    manifest: JsonObject
    roles: Counter[str]
    refs_by_role: dict[str, list[tuple[Path, str]]]
    matrix_rows: frozenset[str]
    supported_tuple: str
    runner_tuple: str
    git_sha: str
    bpf_identity: str
    benchmark_state: BenchmarkState


def refs_from_manifest(manifest: JsonObject) -> list[JsonObject]:
    refs: list[JsonObject] = []
    for field in ("matrix_manifest", "daemon_events", "bpf_metadata_or_skip", "runner_substrate", "runner_cleanliness"):
        refs.append(obj(manifest.get(field), field))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise BundleCompareError("artifacts must be a list")
    for index, item in enumerate(artifacts):
        refs.append(obj(item, f"artifacts[{index}]"))
    benchmark = manifest.get("benchmark_provenance")
    if isinstance(benchmark, list):
        for index, item in enumerate(benchmark):
            refs.append(obj(item, f"benchmark_provenance[{index}]"))
    return refs


def validate_ref(manifest_path: Path, artifact_root: Path | None, ref: JsonObject, context: str) -> tuple[str, Path, str]:
    extra = sorted(set(ref) - REF_FIELDS)
    require(not extra, f"{context} has unexpected fields: {', '.join(extra)}")
    path = artifact_path(manifest_path, artifact_root, ref.get("path"), f"{context}.path")
    digest = text(ref.get("sha256"), f"{context}.sha256")
    require(file_sha(path) == digest, f"{context}.sha256 does not match {path}")
    return text(ref.get("schema_role"), f"{context}.schema_role"), path, digest


def reject_release_claims(value: JsonValue, context: str) -> None:
    match value:
        case dict():
            for key, child in value.items():
                if key == "host_mutation":
                    require(child is False, f"{context}.host_mutation must be false")
                if key in {"release_eligible", "production_capacity_claim", "hard_thresholds_enforced"}:
                    require(child is False, f"{context}.{key} must be false")
                if key == "record_only":
                    require(child is True, f"{context}.record_only must be true")
                reject_release_claims(child, f"{context}.{key}")
        case list():
            for index, child in enumerate(value):
                reject_release_claims(child, f"{context}[{index}]")
        case None | bool() | int() | float() | str():
            return
        case unreachable:
            assert_never(unreachable)


def reject_json_artifact_claims(path: Path, context: str) -> None:
    if path.suffix == ".json":
        reject_release_claims(load_json(path), context)
        return
    if path.suffix != ".jsonl":
        return
    for line_no, line in enumerate(path.read_text().splitlines(), start=1):
        if line.strip() == "":
            continue
        try:
            value: JsonValue = json.loads(line)
        except json.JSONDecodeError as exc:
            raise BundleCompareError(f"invalid referenced JSON {path}:{line_no}: {exc}") from exc
        reject_release_claims(value, f"{context}:{line_no}")


def row_set(matrix_path: Path, label: str) -> frozenset[str]:
    matrix = load_json(matrix_path)
    reject_release_claims(matrix, label)
    rows = matrix.get("rows")
    if not isinstance(rows, list):
        raise BundleCompareError(f"{label}.rows must be a list")
    scenarios: set[str] = set()
    for index, row in enumerate(rows):
        scenario = text(obj(row, f"{label}.rows[{index}]").get("scenario_id"), f"{label}.rows[{index}].scenario_id")
        require(scenario not in scenarios, f"{label}.rows contains duplicate scenario_id: {scenario}")
        scenarios.add(scenario)
    row_count = matrix.get("row_count")
    if isinstance(row_count, int):
        require(row_count == len(rows), f"{label}.row_count does not match rows length")
    return frozenset(scenarios)


def nested_text(value: JsonValue, keys: tuple[str, ...]) -> str | None:
    current = value
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current if isinstance(current, str) and current != "" else None


def first_json_text(path: Path, keys: tuple[str, ...], fallback: str) -> str:
    if path.suffix != ".json":
        return fallback
    return nested_text(load_json(path), keys) or fallback


def bpf_identity(path: Path, fallback_digest: str) -> str:
    if path.suffix != ".json":
        return fallback_digest
    data = load_json(path)
    for keys in (("bpf_object_sha256",), ("object_sha256",), ("object_hash",), ("bpf", "object_sha256"), ("metadata", "object_sha256")):
        found = nested_text(data, keys)
        if found is not None:
            return found
    return fallback_digest


def benchmark_state(manifest: JsonObject) -> BenchmarkState:
    benchmark = manifest.get("benchmark_provenance")
    if isinstance(benchmark, list):
        return ("refs", len(benchmark))
    status = text(obj(benchmark, "benchmark_provenance").get("status"), "benchmark_provenance.status")
    return (status, 0)


def index_bundle(path: Path, label: str, artifact_root: Path | None = None) -> BundleIndex:
    manifest_path = resolve_manifest(path)
    manifest = load_json(manifest_path)
    reject_release_claims(manifest, label)
    refs_by_role: dict[str, list[tuple[Path, str]]] = {}
    roles: Counter[str] = Counter()
    for index, ref in enumerate(refs_from_manifest(manifest)):
        role, path_value, digest = validate_ref(manifest_path, artifact_root, ref, f"{label}.ref[{index}]")
        roles[role] += 1
        refs_by_role.setdefault(role, []).append((path_value, digest))
        reject_json_artifact_claims(path_value, f"{label}.{role}")
    missing = sorted(REQUIRED_ROLES - set(roles))
    require(not missing, f"{label} missing required role(s): {', '.join(missing)}")
    require(bool(BPF_ROLES & set(roles)), f"{label} requires BPF metadata or skip role")
    matrix_path = single_role(refs_by_role, "matrix-manifest", label)[0]
    runner_path = single_role(refs_by_role, "runner-substrate-proof", label)[0]
    review_path = single_role(refs_by_role, "protected-environment-review", label)[0]
    bpf_role = "bpf-metadata" if "bpf-metadata" in refs_by_role else "bpf-skip-json"
    bpf_path, bpf_digest = single_role(refs_by_role, bpf_role, label)
    manifest_tuple = text(manifest.get("supported_tuple"), f"{label}.supported_tuple")
    runner_tuple = first_json_text(runner_path, ("kernel_tuple", "supported_tuple"), manifest_tuple)
    require(manifest_tuple == runner_tuple, f"{label} manifest and runner supported_tuple differ")
    return BundleIndex(manifest_path, manifest, roles, refs_by_role, row_set(matrix_path, f"{label}.matrix"), manifest_tuple, runner_tuple, first_json_text(review_path, ("head_sha",), "unavailable"), bpf_identity(bpf_path, bpf_digest), benchmark_state(manifest))


def single_role(refs_by_role: dict[str, list[tuple[Path, str]]], role: str, label: str) -> tuple[Path, str]:
    values = refs_by_role.get(role, [])
    require(len(values) == 1, f"{label} requires exactly one {role} artifact")
    return values[0]


def compare(left_path: Path, right_path: Path, options: CompareOptions | None = None) -> None:
    effective_options = options if options is not None else CompareOptions()
    left = index_bundle(left_path, "left", effective_options.left_artifact_root)
    right = index_bundle(right_path, "right", effective_options.right_artifact_root)
    require(left.roles == right.roles, "bundle schema-role artifact counts differ")
    require(left.matrix_rows == right.matrix_rows, "matrix row sets differ")
    require(effective_options.expect_tuple_change or left.supported_tuple == right.supported_tuple, "supported_tuple changed without expected-change flag")
    require(effective_options.expect_git_sha_change or left.git_sha == right.git_sha, "protected review git SHA changed without expected-change flag")
    require(effective_options.expect_bpf_change or left.bpf_identity == right.bpf_identity, "BPF object hash changed without expected-change flag")
    require(left.benchmark_state == right.benchmark_state, "benchmark provenance role state differs")



def self_test() -> None:
    result = subprocess.run([sys.executable, "qa/evidence_bundle_compare_selftest.py"], check=False)
    if result.returncode != 0:
        raise BundleCompareError(f"evidence bundle compare self-test failed with rc={result.returncode}")


def parse_cli(argv: list[str]) -> tuple[Path, Path, CompareOptions] | None:
    if argv == ["--self-test"]:
        return None
    flags = {"--expect-tuple-change", "--allow-tuple-change", "--expect-bpf-change", "--allow-bpf-change", "--expect-git-sha-change", "--allow-git-sha-change"}
    positional: list[str] = []
    left_artifact_root: Path | None = None
    right_artifact_root: Path | None = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in flags:
            index += 1
            continue
        if arg == "--artifact-root":
            index += 1
            if index >= len(argv):
                raise BundleCompareError("--artifact-root requires a path")
            left_artifact_root = Path(argv[index])
            right_artifact_root = Path(argv[index])
        elif arg == "--left-artifact-root":
            index += 1
            if index >= len(argv):
                raise BundleCompareError("--left-artifact-root requires a path")
            left_artifact_root = Path(argv[index])
        elif arg == "--right-artifact-root":
            index += 1
            if index >= len(argv):
                raise BundleCompareError("--right-artifact-root requires a path")
            right_artifact_root = Path(argv[index])
        else:
            positional.append(arg)
        index += 1
    options = CompareOptions(
        expect_tuple_change="--expect-tuple-change" in argv or "--allow-tuple-change" in argv,
        expect_bpf_change="--expect-bpf-change" in argv or "--allow-bpf-change" in argv,
        expect_git_sha_change="--expect-git-sha-change" in argv or "--allow-git-sha-change" in argv,
        left_artifact_root=left_artifact_root,
        right_artifact_root=right_artifact_root,
    )
    args = positional
    if len(args) == 4 and args[0] == "--left" and args[2] == "--right":
        return Path(args[1]), Path(args[3]), options
    raise BundleCompareError("usage: evidence_bundle_compare_check.py --self-test | --left <manifest-or-root> --right <manifest-or-root> [--artifact-root <root> | --left-artifact-root <root> --right-artifact-root <root>] [--expect-tuple-change] [--expect-bpf-change] [--expect-git-sha-change]")


def main(argv: list[str]) -> int:
    try:
        parsed = parse_cli(argv)
        if parsed is None:
            self_test()
            return 0
        left, right, options = parsed
        compare(left, right, options)
        print(f"PASS evidence bundle compare: {left} {right}")
        return 0
    except (OSError, ManifestError, BundleCompareError) as exc:
        print(f"FAIL evidence bundle compare: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
