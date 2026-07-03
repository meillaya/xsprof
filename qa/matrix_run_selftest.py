#!/usr/bin/env python3
"""Top-level self-test runner for matrix-run contract validation."""
from __future__ import annotations

import shutil
from contextlib import suppress
from pathlib import Path
from tempfile import TemporaryDirectory

from qa.matrix_run_json import load_json, obj, text
from qa.matrix_run_manifest_validate import validate_manifest
from qa.matrix_run_model import DOC_FILE, MATRIX_BASE, REQUIRED_INVALID_FIXTURES, SCHEMA_FILE, Args, JsonObject, MatrixRunContractError
from qa.matrix_run_selftest_cases_basic import handle_basic_manifest_case
from qa.matrix_run_selftest_cases_live import handle_live_manifest_case
from qa.matrix_run_selftest_cases_workload import handle_workload_manifest_case
from qa.matrix_run_selftest_common import ManifestSelfTestContext, write_json, write_self_test_pack
from qa.matrix_run_selftest_pack import write_host_safe_fixture_pass_self_test_pack, write_manifest_self_test_pack
from qa.matrix_run_validate import validate

MANIFEST_SELF_TEST_CASES: tuple[str, ...] = (
    "root-outside-matrix",
    "absolute-artifact-path",
    "artifact-outside-run-root",
    "duplicate-scenario",
    "duplicate-artifact",
    "row-count-mismatch",
    "manifest-out-dir-mismatch",
    "manifest-run-id-basename-mismatch",
    "row-run-id-manifest-mismatch",
    "row-internal-path-outside-root",
    "missing-proof-artifact",
    "invalid-runtime-sample-artifact",
    "host-safe-vm-live-claim",
    "forged-pass-host-refusal-no-marker",
    "forged-fixture-mode-false-fixture-pass",
    "host-safe-fixture-mode-false-fixture-pass",
    "vm-live-missing-marker-proof",
    "vm-live-marker-proof-mismatch",
    "malicious-workload-spec-token",
    "malicious-capability-token",
    "false-private-fields-found",
    "workload-claim-leakage",
    "workload-spec-class-mismatch",
    "workload-spec-required-tools-mismatch",
    "workload-mixed-metadata-canonical-mismatch",
    "workload-spec-threshold-source-mismatch",
    "workload-cgroup-semantic-label-mismatch",
    "workload-cpu-hotplug-semantic-label-mismatch",
    "unsupported-bpf-abi-drift",
    "workload-benchmark-provenance-missing",
    "workload-calibrated-benchmark-provenance-absent",
    "workload-benchmark-provenance-malformed",
    "workload-benchmark-provenance-claim",
    "workload-uncataloged-scenario",
    "workload-capability-required-tools-mismatch",
    "workload-capability-threshold-source-mismatch",
    "workload-capability-missing-prereq-mismatch",
    "workload-capability-outcome-mismatch",
    "workload-capability-pass-missing-prereq",
    "workload-capability-skip-empty-missing-prereq",
    "live-backend-forged-pass-without-marker-proof",
    "live-backend-missing-cleanup-proof-artifact",
    "live-backend-missing-host-refusal-proof-artifact",
    "live-backend-daemon-events-outside-root",
    "live-backend-dirty-summary-masked-pass",
    "live-backend-missing-live-summary-artifact",
    "live-backend-noncanonical-live-summary-path",
    "live-backend-fake-unavailable-counter",
    "extra-property",
)


def assert_invalid_fixture_gate(args: Args, name: str, good: JsonObject) -> None:
    if args.fixtures is None:
        raise MatrixRunContractError("self-test fixture directory missing")
    write_json(args.fixtures / "invalid" / name, good)
    try:
        _ = validate(args)
    except MatrixRunContractError as exc:
        print(f"PASS self-test detects missing rejection coverage for {name}: {exc}")
        return
    raise MatrixRunContractError(f"self-test failed to reject accepted invalid fixture: {name}")


def run_manifest_self_test_case(good: JsonObject, name: str, index: int) -> None:
    run_root = MATRIX_BASE / f"selftest-{index}"
    if run_root.exists():
        shutil.rmtree(run_root)
    run_root.mkdir(parents=True)
    try:
        manifest_path = write_manifest_self_test_pack(run_root, good)
        _ = validate_manifest(manifest_path)
        manifest = load_json(manifest_path)
        rows = manifest.get("rows")
        if not isinstance(rows, list):
            raise MatrixRunContractError("manifest self-test setup produced non-list rows")
        row = obj(rows[0], "manifest self-test first row")
        artifact_path = Path(text(row.get("artifact_path"), "manifest self-test artifact_path"))
        ctx = ManifestSelfTestContext(good, name, run_root, manifest_path, manifest, rows, row, artifact_path)
        try:
            handled = handle_basic_manifest_case(ctx) or handle_workload_manifest_case(ctx) or handle_live_manifest_case(ctx)
            if not handled:
                raise MatrixRunContractError(f"unknown manifest self-test case: {name}")
        except AssertionError as exc:
            raise MatrixRunContractError(f"unknown manifest self-test case: {name}") from exc
    finally:
        shutil.rmtree(run_root)


def run_self_test() -> None:
    good = load_json(Path("fixtures/matrix-run/pass.json"))
    for name in sorted(REQUIRED_INVALID_FIXTURES):
        with TemporaryDirectory(prefix="zigsched-matrix-run-") as tmp:
            root = Path(tmp)
            fixtures = root / "fixtures"
            invalid = fixtures / "invalid"
            schemas = root / "schemas"
            docs = root / "docs"
            invalid.mkdir(parents=True)
            schemas.mkdir()
            docs.mkdir()
            _ = (schemas / SCHEMA_FILE).write_text((Path("schemas/control") / SCHEMA_FILE).read_text())
            _ = (docs / DOC_FILE).write_text((Path("docs/control") / DOC_FILE).read_text())
            write_self_test_pack(fixtures, invalid, good)
            args = Args(fixtures, schemas, docs, None, False)
            _ = validate(args)
            assert_invalid_fixture_gate(args, name, good)
    MATRIX_BASE.mkdir(parents=True, exist_ok=True)
    try:
        host_safe_root = MATRIX_BASE / "selftest-host-safe-fixture-pass"
        if host_safe_root.exists():
            shutil.rmtree(host_safe_root)
        host_safe_root.mkdir(parents=True)
        try:
            host_safe_manifest = write_host_safe_fixture_pass_self_test_pack(host_safe_root, good)
            _ = validate_manifest(host_safe_manifest)
            print("PASS self-test accepts host-safe fixture PASS without VM marker claim")
        finally:
            shutil.rmtree(host_safe_root)
        for index, name in enumerate(MANIFEST_SELF_TEST_CASES):
            run_manifest_self_test_case(good, name, index)
    finally:
        with suppress(OSError):
            MATRIX_BASE.rmdir()
