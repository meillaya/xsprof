#!/usr/bin/env python3
"""Verify an xsprof/macos-notarization/v1 artifact attestation.

This is the fail-closed publication gate shared by CI and local tooling. It is
deliberately dependency-free (Python 3 stdlib only) so it runs on Linux and
macOS without Homebrew, jq, or network access.

Exit codes:
  0   valid (notarized, or a consistently labelled unsigned artifact when
      --allow-unnotarized is given)
  10  malformed, unknown-schema, or structurally invalid attestation
  11  version, artifact name, artifact sha256, or size mismatch
  12  not notarized while --allow-unnotarized was not given
"""
import argparse
import json
import re
import sys

SCHEMA = "xsprof/macos-notarization/v1"
EXIT_OK = 0
EXIT_INVALID = 10
EXIT_MISMATCH = 11
EXIT_NOT_NOTARIZED = 12

HEX64 = re.compile(r"^[0-9a-f]{64}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TEAM_RE = re.compile(r"^[A-Z0-9]{10}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$")
DEV_ID_PREFIX = "Developer ID Application:"

TOP_KEYS = {"artifact", "created_at", "notarized", "notarization", "schema", "signing", "version"}
ARTIFACT_KEYS = {"name", "sha256", "size_bytes"}
SIGNING_KEYS = {"hardened_runtime", "identity", "team_id"}
NOTARY_KEYS = {"gatekeeper", "stapled", "status", "submission_id"}


def fail(code, message):
    print(f"verify_macos_attestation: {message}", file=sys.stderr)
    sys.exit(code)


def require_keys(value, allowed, where):
    if not isinstance(value, dict):
        fail(EXIT_INVALID, f"{where} must be an object")
    unknown = set(value) - allowed
    if unknown:
        fail(EXIT_INVALID, f"{where} has unknown keys: {sorted(unknown)}")
    missing = allowed - set(value)
    if missing:
        fail(EXIT_INVALID, f"{where} is missing keys: {sorted(missing)}")


def main():
    parser = argparse.ArgumentParser(description="Verify an xsprof macOS notarization attestation")
    parser.add_argument("--attestation", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--artifact-name", required=True)
    parser.add_argument("--artifact-sha256", required=True)
    parser.add_argument("--artifact-size", required=True, type=int)
    parser.add_argument("--allow-unnotarized", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    try:
        with open(args.attestation, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        fail(EXIT_INVALID, f"cannot read {args.attestation}: {error}")
    except json.JSONDecodeError as error:
        fail(EXIT_INVALID, f"invalid JSON: {error}")

    require_keys(data, TOP_KEYS, "attestation")
    if data.get("schema") != SCHEMA:
        fail(EXIT_INVALID, f"schema must be {SCHEMA!r}, got {data.get('schema')!r}")

    if data.get("version") != args.version:
        fail(EXIT_MISMATCH, f"version mismatch: attestation has {data.get('version')!r}, expected {args.version!r}")

    artifact = data.get("artifact")
    require_keys(artifact, ARTIFACT_KEYS, "artifact")
    if artifact.get("name") != args.artifact_name:
        fail(EXIT_MISMATCH, f"artifact name mismatch: {artifact.get('name')!r} != {args.artifact_name!r}")
    if artifact.get("sha256") != args.artifact_sha256:
        fail(EXIT_MISMATCH, "artifact sha256 mismatch")
    if not HEX64.match(str(artifact.get("sha256", ""))):
        fail(EXIT_INVALID, "artifact sha256 is not 64 lowercase hex characters")
    if artifact.get("size_bytes") != args.artifact_size:
        fail(EXIT_MISMATCH, f"artifact size mismatch: {artifact.get('size_bytes')!r} != {args.artifact_size}")

    created_at = data.get("created_at")
    if not isinstance(created_at, str) or not DATE_RE.match(created_at):
        fail(EXIT_INVALID, "created_at must be an RFC3339 UTC timestamp")

    signing = data.get("signing")
    require_keys(signing, SIGNING_KEYS, "signing")
    notarized = data.get("notarized")
    if not isinstance(notarized, bool):
        fail(EXIT_INVALID, "notarized must be a boolean")

    if notarized:
        if not signing.get("hardened_runtime") is True:
            fail(EXIT_INVALID, "notarized artifacts require hardened_runtime=true")
        identity = signing.get("identity")
        if not isinstance(identity, str) or not identity.startswith(DEV_ID_PREFIX):
            fail(EXIT_INVALID, f"signing.identity must start with {DEV_ID_PREFIX!r}")
        if not TEAM_RE.match(str(signing.get("team_id", ""))):
            fail(EXIT_INVALID, "signing.team_id must be a 10-character Apple team id")
        notary = data.get("notarization")
        require_keys(notary, NOTARY_KEYS, "notarization")
        if notary.get("status") != "Accepted":
            fail(EXIT_INVALID, f"notarization.status must be 'Accepted', got {notary.get('status')!r}")
        if notary.get("stapled") is not True:
            fail(EXIT_INVALID, "notarization.stapled must be true")
        if notary.get("gatekeeper") != "accepted":
            fail(EXIT_INVALID, "notarization.gatekeeper must be 'accepted'")
        if not UUID_RE.match(str(notary.get("submission_id", ""))):
            fail(EXIT_INVALID, "notarization.submission_id must be a UUID")
        if not args.artifact_name.endswith("-macos.zip"):
            fail(EXIT_INVALID, "notarized artifacts must use the Xsprof-<version>-macos.zip name")
        if not args.quiet:
            print(f"verify_macos_attestation: PASS (notarized) {args.artifact_name}")
        return EXIT_OK

    # Unsigned artifact: only publishable as a labelled, non-cask artifact.
    if not args.artifact_name.endswith("-macos-unsigned.zip"):
        fail(EXIT_INVALID, "unsigned artifacts must use the Xsprof-<version>-macos-unsigned.zip name")
    notary = data.get("notarization")
    require_keys(notary, NOTARY_KEYS, "notarization")
    if notary.get("status") != "NotNotarized":
        fail(EXIT_INVALID, "unsigned artifacts must carry notarization.status='NotNotarized'")
    if notary.get("stapled") is not False or notary.get("gatekeeper") != "rejected":
        fail(EXIT_INVALID, "unsigned artifacts must report stapled=false and gatekeeper='rejected'")
    if signing.get("identity") != "ad-hoc":
        fail(EXIT_INVALID, "unsigned artifacts must report signing.identity='ad-hoc'")
    if signing.get("hardened_runtime") is not False:
        fail(EXIT_INVALID, "unsigned artifacts must report hardened_runtime=false")
    if not args.allow_unnotarized:
        fail(EXIT_NOT_NOTARIZED, "artifact is not notarized; pass --allow-unnotarized only for explicitly labelled unsigned builds")
    if not args.quiet:
        print(f"verify_macos_attestation: PASS (unsigned, allowed) {args.artifact_name}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
