from __future__ import annotations

import json
import shutil
from collections.abc import Callable
from pathlib import Path
from tempfile import TemporaryDirectory

from qa.frontend_contract_pack_types import Args, ContractPackError, JsonObject, parse_json_object


def load_fixture_rows(fixture: Path) -> list[JsonObject]:
    return [parse_json_object(line, str(fixture)) for line in fixture.read_text().splitlines() if line.strip()]


def write_fixture_rows(fixture: Path, rows: list[JsonObject]) -> None:
    _ = fixture.write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in rows))


def run_self_test(args: Args, validate_pack: Callable[[Args], None]) -> None:
    validate_pack(args)
    with TemporaryDirectory(prefix="zigsched-contract-pack-") as tmp:
        tmp_path = Path(tmp)

        def assert_rejected(label: str, fixture_name: str, mutate: Callable[[list[JsonObject]], None]) -> None:
            bad_fixtures = tmp_path / f"fixtures-{label}"
            bad_docs = tmp_path / f"docs-{label}"
            _ = shutil.copytree(args.fixtures, bad_fixtures)
            _ = shutil.copytree(args.docs, bad_docs)
            fixture = bad_fixtures / fixture_name
            rows = load_fixture_rows(fixture)
            mutate(rows)
            write_fixture_rows(fixture, rows)
            try:
                validate_pack(Args(bad_fixtures, args.schemas, bad_docs, False))
            except ContractPackError as exc:
                print(f"PASS self-test rejected {label}: {exc}")
            else:
                raise ContractPackError(f"self-test failed to reject {label}")

        def assert_extra_fixture_rejected() -> None:
            bad_fixtures = tmp_path / "fixtures-extra-jsonl"
            bad_docs = tmp_path / "docs-extra-jsonl"
            _ = shutil.copytree(args.fixtures, bad_fixtures)
            _ = shutil.copytree(args.docs, bad_docs)
            _ = (bad_fixtures / "bogus-extra.jsonl").write_text((bad_fixtures / "incident.jsonl").read_text())
            try:
                validate_pack(Args(bad_fixtures, args.schemas, bad_docs, False))
            except ContractPackError as exc:
                if "unlisted fixture" not in str(exc):
                    raise ContractPackError(f"self-test rejected extra fixture for wrong reason: {exc}") from exc
                print(f"PASS self-test rejected extra jsonl fixture: {exc}")
            else:
                raise ContractPackError("self-test failed to reject extra jsonl fixture")

        def assert_privacy_rejected(label: str, mutate: Callable[[list[JsonObject]], None]) -> None:
            bad_fixtures = tmp_path / f"fixtures-{label}"
            bad_docs = tmp_path / f"docs-{label}"
            _ = shutil.copytree(args.fixtures, bad_fixtures)
            _ = shutil.copytree(args.docs, bad_docs)
            fixture = bad_fixtures / "incident.jsonl"
            rows = load_fixture_rows(fixture)
            mutate(rows)
            write_fixture_rows(fixture, rows)
            try:
                validate_pack(Args(bad_fixtures, args.schemas, bad_docs, False))
            except ContractPackError as exc:
                if "privacy-unsafe" not in str(exc):
                    raise ContractPackError(f"self-test rejected {label} for non-privacy reason: {exc}") from exc
                print(f"PASS self-test rejected {label}: {exc}")
            else:
                raise ContractPackError(f"self-test failed to reject {label}")

        def assert_privacy_accepted(label: str, mutate: Callable[[list[JsonObject]], None]) -> None:
            ok_fixtures = tmp_path / f"fixtures-{label}"
            ok_docs = tmp_path / f"docs-{label}"
            _ = shutil.copytree(args.fixtures, ok_fixtures)
            _ = shutil.copytree(args.docs, ok_docs)
            fixture = ok_fixtures / "incident.jsonl"
            rows = load_fixture_rows(fixture)
            mutate(rows)
            write_fixture_rows(fixture, rows)
            validate_pack(Args(ok_fixtures, args.schemas, ok_docs, False))
            print(f"PASS self-test accepted {label}")

        def incident_before_sample(rows: list[JsonObject]) -> None:
            incident = rows[1]
            sample = rows[0]
            incident["seq"] = 1
            sample["seq"] = 2
            rows[:] = [incident, sample]

        assert_extra_fixture_rejected()
        assert_rejected("undocumented reason", "incident.jsonl", lambda rows: rows[0].__setitem__("reason", "undocumented_reason"))
        assert_privacy_rejected("uppercase private text", lambda rows: rows[0].__setitem__("state", "PASSWORD=credential"))
        assert_privacy_rejected("generic token text", lambda rows: rows[0].__setitem__("state", "token=credential"))
        assert_privacy_rejected("generic token value", lambda rows: rows[0].__setitem__("state", "token=abc123"))
        assert_privacy_rejected("api-key text", lambda rows: rows[0].__setitem__("state", "api-key"))
        assert_privacy_rejected("private-key text", lambda rows: rows[0].__setitem__("state", "private-key"))
        assert_privacy_rejected("command-line text", lambda rows: rows[0].__setitem__("state", "command-line"))
        assert_privacy_rejected("slash token credential text", lambda rows: rows[0].__setitem__("state", "token/credential"))
        assert_privacy_rejected("dot token credential text", lambda rows: rows[0].__setitem__("state", "token.credential"))
        assert_privacy_rejected("reversed token credential text", lambda rows: rows[0].__setitem__("state", "credential/token"))
        assert_privacy_rejected("spaced token credential text", lambda rows: rows[0].__setitem__("state", "token credential"))
        assert_privacy_rejected("access token credential text", lambda rows: rows[0].__setitem__("state", "access token credential"))
        assert_privacy_rejected("uppercase token credential text", lambda rows: rows[0].__setitem__("state", "TOKEN credential"))
        assert_privacy_rejected("colon token credential text", lambda rows: rows[0].__setitem__("state", "Token: credential"))
        assert_privacy_accepted("plural tokens text", lambda rows: rows[0].__setitem__("state", "tokens available"))
        assert_privacy_accepted("command argv hash field", lambda rows: rows[0].__setitem__("command_argv_hash", "sha256:" + "a" * 64))
        assert_rejected("raw command argv hash", "incident.jsonl", lambda rows: rows[0].__setitem__("command_argv_hash", "/usr/bin/zig-scheduler-daemon --foreground --state-dir state"))
        assert_rejected("short command argv hash", "incident.jsonl", lambda rows: rows[0].__setitem__("command_argv_hash", "sha256:abc"))
        assert_privacy_rejected("command argv hash unsafe value", lambda rows: rows[0].__setitem__("command_argv_hash", "/bin/app --token abc123"))
        assert_privacy_rejected("authorization text", lambda rows: rows[0].__setitem__("state", "Authorization: credential"))
        assert_privacy_rejected("bearer text", lambda rows: rows[0].__setitem__("state", "Bearer credential"))
        assert_privacy_rejected("password word text", lambda rows: rows[0].__setitem__("state", "password credential"))
        assert_privacy_rejected("private key", lambda rows: rows[0].__setitem__("private_key", "redacted"))
        assert_privacy_rejected("token key", lambda rows: rows[0].__setitem__("access_token", "redacted"))
        assert_privacy_rejected("authorization key", lambda rows: rows[0].__setitem__("authorization_header", "redacted"))
        assert_privacy_rejected("bearer key", lambda rows: rows[0].__setitem__("bearer_credential", "redacted"))
        assert_privacy_rejected("password key", lambda rows: rows[0].__setitem__("password_hint", "redacted"))
        assert_rejected("schema extra field", "incident.jsonl", lambda rows: rows[0].__setitem__("unexpected_contract_field", "bad"))
        assert_rejected("host_mutation true", "incident.jsonl", lambda rows: rows[0].__setitem__("host_mutation", True))
        assert_rejected("nonmonotonic seq", "incident.jsonl", lambda rows: rows[0].__setitem__("seq", 2))
        assert_rejected("absolute artifact path", "incident.jsonl", lambda rows: rows[0].__setitem__("artifact", "/tmp/escape.json"))
        assert_rejected("traversing artifact path", "incident.jsonl", lambda rows: rows[0].__setitem__("artifact", "../escape.json"))
        assert_rejected("nested absolute artifact path", "incident.jsonl", lambda rows: rows[0].__setitem__("artifact_paths", ["/tmp/escape.json"]))
        assert_rejected("nested traversing artifact path", "incident.jsonl", lambda rows: rows[0].__setitem__("artifact_paths", {"runtime": ["../escape.json"]}))
        assert_rejected("release-ineligible marked PASS", "release-ineligible.jsonl", lambda rows: rows[0].__setitem__("status", "PASS"))
        assert_rejected("release-ineligible approved state", "release-ineligible.jsonl", lambda rows: rows[0].__setitem__("state", "release_approved"))
        assert_rejected("release-ineligible proof success", "release-ineligible.jsonl", lambda rows: rows[0].__setitem__("artifact", "evidence/releases/lab/release-approved-proof-success.json"))
        assert_rejected("dsq fairness release proof state", "dsq-perf-fairness-gate.jsonl", lambda rows: rows[0].__setitem__("state", "release_proof"))
        assert_rejected("dsq fairness release proof text", "dsq-perf-fairness-gate.jsonl", lambda rows: rows[0].__setitem__("artifact", "evidence/lab/dsq/release-proof-success.json"))
        assert_rejected("runtime nr_rejected incident before sample", "runtime-alert-nr-rejected.jsonl", incident_before_sample)
        assert_rejected("runtime workload_dead incident before sample", "runtime-alert-workload-dead.jsonl", incident_before_sample)
