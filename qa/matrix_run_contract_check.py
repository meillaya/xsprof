#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# python3 qa/matrix_run_contract_check.py --fixtures fixtures/matrix-run --schemas schemas/control --docs docs/control
"""Stable CLI and import-compatibility wrapper for matrix-run/v1 validation."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from qa import matrix_run_json as _json
from qa import matrix_run_live_backend as _live_backend
from qa import matrix_run_manifest_validate as _manifest_validate
from qa import matrix_run_model as _model
from qa import matrix_run_selftest as _selftest
from qa import runtime_sample_check as _runtime_sample
from qa import matrix_run_selftest_common as _selftest_common
from qa import matrix_run_selftest_pack as _selftest_pack
from qa import matrix_run_validate as _validate
from qa import matrix_run_workload as _workload

Args = _model.Args
JsonLoader = _json.JsonLoader
JsonObject = _model.JsonObject
JsonValue = _model.JsonValue
ManifestSelfTestContext = _selftest_common.ManifestSelfTestContext
MatrixRunContractError = _model.MatrixRunContractError
WorkloadScenarioMetadata = _model.WorkloadScenarioMetadata

AUDIT_RE = _model.AUDIT_RE
CGROUP_WORKLOAD_SEMANTICS = _model.CGROUP_WORKLOAD_SEMANTICS
CLAIM_TEXT_RE = _model.CLAIM_TEXT_RE
CLEANUP_PROOF_FIELDS = _model.CLEANUP_PROOF_FIELDS
CPU_HOTPLUG_SEMANTICS = _model.CPU_HOTPLUG_SEMANTICS
DOC_FILE = _model.DOC_FILE
EVIDENCE_MODES = _model.EVIDENCE_MODES
GIT_FIELDS = _model.GIT_FIELDS
HOST_REFUSAL_FIELDS = _model.HOST_REFUSAL_FIELDS
ID_RE = _model.ID_RE
INCIDENT_FIELDS = _model.INCIDENT_FIELDS
KERNEL_TUPLE_FIELDS = _model.KERNEL_TUPLE_FIELDS
MANIFEST_FIELDS = _model.MANIFEST_FIELDS
MANIFEST_FILE = _model.MANIFEST_FILE
MANIFEST_ROW_FIELDS = _model.MANIFEST_ROW_FIELDS
MANIFEST_SELF_TEST_CASES = _selftest.MANIFEST_SELF_TEST_CASES
MATRIX_BASE = _model.MATRIX_BASE
MATRIX_BPF_ABI_VERSION = _model.MATRIX_BPF_ABI_VERSION
OUTCOMES = _model.OUTCOMES
PATH_FIELDS = _model.PATH_FIELDS
POLICY_FIELDS = _model.POLICY_FIELDS
PRIVACY_REPORT_FIELDS = _model.PRIVACY_REPORT_FIELDS
PRIVACY_SCAN_FIELDS = _model.PRIVACY_SCAN_FIELDS
PRIVACY_SCAN_SCHEMA = _model.PRIVACY_SCAN_SCHEMA
PRIVATE_NEEDLES = _model.PRIVATE_NEEDLES
PRIVATE_PATH_RE = _model.PRIVATE_PATH_RE
REQUIRED_FIXTURES = _model.REQUIRED_FIXTURES
REQUIRED_INVALID_FIXTURES = _model.REQUIRED_INVALID_FIXTURES
ROLLBACK_PROOF_FIELDS = _model.ROLLBACK_PROOF_FIELDS
ROW_FIELDS = _model.ROW_FIELDS
RUN_ID_MAX = _model.RUN_ID_MAX
RUN_ID_RE = _model.RUN_ID_RE
SAFE_RELATIVE_PATH_PATTERN = _model.SAFE_RELATIVE_PATH_PATTERN
SCHED_DISABLE_REASONS = _model.SCHED_DISABLE_REASONS
SCHED_STATES = _model.SCHED_STATES
SCHED_STATE_FIELDS = _model.SCHED_STATE_FIELDS
SCHEMA = _model.SCHEMA
SCHEMA_FILE = _model.SCHEMA_FILE
SCHEMA_PATH_FIELDS = _model.SCHEMA_PATH_FIELDS
SHA256_RE = _model.SHA256_RE
TUPLE_STATUS = _model.TUPLE_STATUS
VM_MARKER = _model.VM_MARKER
VM_MARKER_FIELDS = _model.VM_MARKER_FIELDS
VM_MARKER_PROOF_FIELDS = _model.VM_MARKER_PROOF_FIELDS
WORKLOAD_CAPABILITY_FIELDS = _model.WORKLOAD_CAPABILITY_FIELDS
WORKLOAD_CAPABILITY_MODES = _model.WORKLOAD_CAPABILITY_MODES
WORKLOAD_CAPABILITY_SCHEMA = _model.WORKLOAD_CAPABILITY_SCHEMA
WORKLOAD_FIELDS = _model.WORKLOAD_FIELDS
WORKLOAD_PRIVATE_NEEDLES = _model.WORKLOAD_PRIVATE_NEEDLES
WORKLOAD_SCENARIO_METADATA = _model.WORKLOAD_SCENARIO_METADATA
WORKLOAD_SPEC_FIELDS = _model.WORKLOAD_SPEC_FIELDS
WORKLOAD_SPEC_SCHEMA = _model.WORKLOAD_SPEC_SCHEMA
WORKLOAD_THRESHOLD_FIELDS = _model.WORKLOAD_THRESHOLD_FIELDS
WORKLOAD_THRESHOLD_SOURCES = _model.WORKLOAD_THRESHOLD_SOURCES
WORKLOAD_TOOL_NAMES = _model.WORKLOAD_TOOL_NAMES

assert_invalid_fixture_gate = _selftest.assert_invalid_fixture_gate
assert_invalid_manifest = _selftest_common.assert_invalid_manifest
bool_field = _json.bool_field
clone_object = _selftest_common.clone_object
expected_workload_metadata = _workload.expected_workload_metadata
file_sha256 = _json.file_sha256
fixture_names = _validate.fixture_names
invalid_self_test_rows = _selftest_common.invalid_self_test_rows
json_loader = _json.json_loader
load_json = _json.load_json
obj = _json.obj
reject_constant = _json.reject_constant
reject_private = _json.reject_private
reject_workload_artifact_private = _json.reject_workload_artifact_private
require = _json.require
require_descendant = _json.require_descendant
require_expected_missing_prereq = _workload.require_expected_missing_prereq
require_expected_threshold_source = _workload.require_expected_threshold_source
require_expected_tools = _workload.require_expected_tools
require_expected_workload_metadata = _workload.require_expected_workload_metadata
require_identifier = _json.require_identifier
require_manifest_root = _json.require_manifest_root
require_only_fields = _json.require_only_fields
require_safe_path = _json.require_safe_path
require_sched_enable_seq = _json.require_sched_enable_seq
require_sha = _json.require_sha
require_workload_tools = _workload.require_workload_tools
required_fields = _validate.required_fields
run_manifest_self_test_case = _selftest.run_manifest_self_test_case
run_self_test = _selftest.run_self_test
text = _json.text
text_list = _json.text_list
validate_cleanup_artifact = _manifest_validate.validate_cleanup_artifact
validate_docs = _validate.validate_docs
validate_fixture_pack = _validate.validate_fixture_pack
validate_git = _validate.validate_git
validate_host_refusal_artifact = _manifest_validate.validate_host_refusal_artifact
validate_incident_artifact = _manifest_validate.validate_incident_artifact
validate_live_backend_summary_consistency = _live_backend.validate_live_backend_summary_consistency
validate_manifest = _manifest_validate.validate_manifest
validate_manifest_daemon_events = _manifest_validate.validate_manifest_daemon_events
validate_manifest_proof_artifacts = _manifest_validate.validate_manifest_proof_artifacts
validate_manifest_row_paths = _manifest_validate.validate_manifest_row_paths
validate_manifest_runtime_sample = _manifest_validate.validate_manifest_runtime_sample
validate_manifest_vm_claim = _manifest_validate.validate_manifest_vm_claim
validate_manifest_workload_artifacts = _manifest_validate.validate_manifest_workload_artifacts
validate_pass_evidence_mode = _validate.validate_pass_evidence_mode
validate_policy = _validate.validate_policy
validate_privacy = _validate.validate_privacy
validate_privacy_report = _workload.validate_privacy_report
validate_rollback_artifact = _manifest_validate.validate_rollback_artifact
validate_row = _validate.validate_row
validate_runtime_sample_file = _runtime_sample.validate_file
validate_scheduler_state = _json.validate_scheduler_state
validate_schema_file = _validate.validate_schema_file
validate_semantics_exact = _workload.validate_semantics_exact
validate_vm_marker = _validate.validate_vm_marker
validate_vm_marker_proof = _manifest_validate.validate_vm_marker_proof
validate_workload = _workload.validate_workload
validate_workload_benchmark_provenance = _workload.validate_workload_benchmark_provenance
validate_workload_capability = _workload.validate_workload_capability
validate_workload_fixture_artifacts = _validate.validate_workload_fixture_artifacts
validate_workload_semantics = _workload.validate_workload_semantics
validate_workload_spec = _workload.validate_workload_spec
validate_workload_thresholds = _workload.validate_workload_thresholds
without_field = _selftest_common.without_field
workload_semantic_fields = _workload.workload_semantic_fields
write_host_safe_fixture_pass_self_test_pack = _selftest_pack.write_host_safe_fixture_pass_self_test_pack
write_json = _selftest_common.write_json
write_json_digest = _selftest_common.write_json_digest
write_manifest_self_test_pack = _selftest_pack.write_manifest_self_test_pack
write_self_test_pack = _selftest_common.write_self_test_pack


class ParsedArgs(argparse.Namespace):
    fixtures: Path | None
    schemas: Path
    docs: Path
    manifest: Path | None

    def __init__(self) -> None:
        super().__init__()
        self.fixtures = None
        self.schemas = Path()
        self.docs = Path()
        self.manifest = None


def parse_args(argv: list[str]) -> Args:
    if argv == ["--self-test"]:
        return Args(Path("fixtures/matrix-run"), Path("schemas/control"), Path("docs/control"), None, True)
    parser = argparse.ArgumentParser(description="Validate standalone matrix-run/v1 evidence manifests.")
    _ = parser.add_argument("--fixtures", type=Path)
    _ = parser.add_argument("--manifest", type=Path)
    _ = parser.add_argument("--schemas", required=True, type=Path)
    _ = parser.add_argument("--docs", required=True, type=Path)
    parsed = parser.parse_args(argv, namespace=ParsedArgs())
    if (parsed.fixtures is None) == (parsed.manifest is None):
        raise MatrixRunContractError("exactly one of --fixtures or --manifest is required")
    return Args(parsed.fixtures, parsed.schemas, parsed.docs, parsed.manifest, False)


def validate(args: Args) -> tuple[int, int]:
    validate_schema_file(args.schemas)
    validate_docs(args.docs)
    if args.manifest is not None:
        return validate_manifest(args.manifest)
    if args.fixtures is None:
        raise MatrixRunContractError("internal argument parser error")
    return validate_fixture_pack(args.fixtures)


def run(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        print("PASS matrix-run contract self-test")
    else:
        valid_count, invalid_count = validate(args)
        if args.manifest is not None:
            print(f"PASS matrix-run contract: manifest={args.manifest} valid={valid_count} docs={args.docs}")
        else:
            print(f"PASS matrix-run contract: fixtures={args.fixtures} valid={valid_count} invalid={invalid_count} docs={args.docs}")
    return 0


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (OSError, UnicodeError, MatrixRunContractError) as exc:
        print(f"FAIL matrix-run contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
