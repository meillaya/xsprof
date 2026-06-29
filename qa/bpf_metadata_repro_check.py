# /// script
# requires-python = ">=3.11"
# ///
# ─── How to run ───
# python3 qa/bpf_metadata_repro_check.py
"""Verify BPF metadata stays byte-stable across clang symlink aliases."""

from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
from json import loads
from pathlib import Path
from shutil import rmtree, which
from subprocess import run
from tempfile import TemporaryDirectory
import os
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_COMMAND = ("bash", "tools/build_bpf.sh")
OBJECT_PATH = REPO_ROOT / "zig-out/bpf/zigsched_minimal.bpf.o"
METADATA_PATH = REPO_ROOT / "zig-out/bpf/zigsched_minimal.bpf.meta.json"
SKIP_PATH = REPO_ROOT / "zig-out/bpf/zigsched_minimal.bpf.skip.json"


@dataclass(frozen=True, slots=True)
class BuildResult:
    clang_path: str
    object_sha256: str
    metadata_sha256: str


class BpfMetadataReproError(Exception):
    """Raised when metadata bytes diverge across equivalent clang paths."""


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_build(clang_path: Path) -> BuildResult:
    rmtree(OBJECT_PATH.parent, ignore_errors=True)
    env = os.environ.copy()
    env["CLANG"] = str(clang_path)
    completed = run(
        BUILD_COMMAND,
        cwd=REPO_ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise BpfMetadataReproError(
            f"BPF build failed for {clang_path}:\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    if not OBJECT_PATH.is_file() or not METADATA_PATH.is_file():
        if SKIP_PATH.is_file():
            print("SKIP: clang cannot emit BPF objects; metadata repro check not run")
            raise SystemExit(0)
        raise BpfMetadataReproError(f"BPF build did not produce canonical outputs for {clang_path}")
    metadata = loads(METADATA_PATH.read_text())
    tool_versions = metadata.get("tool_versions")
    if not isinstance(tool_versions, dict):
        raise BpfMetadataReproError("metadata missing tool_versions object")
    clang_recorded = tool_versions.get("clang_path")
    if not isinstance(clang_recorded, str) or clang_recorded == "":
        raise BpfMetadataReproError("metadata missing clang_path")
    return BuildResult(
        clang_path=clang_recorded,
        object_sha256=sha256_file(OBJECT_PATH),
        metadata_sha256=sha256_file(METADATA_PATH),
    )


def main() -> int:
    clang_binary = which("clang")
    if clang_binary is None:
        print("SKIP: clang unavailable; BPF metadata repro check not run")
        return 0
    canonical = Path(clang_binary).resolve()
    if not canonical.exists():
        raise BpfMetadataReproError(f"clang resolved to a missing path: {canonical}")

    with TemporaryDirectory(prefix="zigsched-bpf-clang-alias-") as tmpdir:
        alias = Path(tmpdir) / "clang-alias"
        alias.symlink_to(canonical)

        real = run_build(canonical)
        alias_result = run_build(alias)

    if real.object_sha256 != alias_result.object_sha256:
        raise BpfMetadataReproError(
            "BPF object hash changed across clang aliases: "
            f"real={real.object_sha256} alias={alias_result.object_sha256}"
        )
    if real.metadata_sha256 != alias_result.metadata_sha256:
        raise BpfMetadataReproError(
            "BPF metadata hash changed across clang aliases: "
            f"real={real.metadata_sha256} alias={alias_result.metadata_sha256}"
        )
    if real.clang_path != alias_result.clang_path:
        raise BpfMetadataReproError(
            "recorded clang_path changed across aliases: "
            f"real={real.clang_path} alias={alias_result.clang_path}"
        )
    if real.clang_path != str(canonical):
        raise BpfMetadataReproError(
            "recorded clang_path is not canonical: "
            f"recorded={real.clang_path} canonical={canonical}"
        )

    print("PASS: BPF metadata stable across clang symlink aliases")
    print(f"canonical_clang={canonical}")
    print(f"object_sha256={real.object_sha256}")
    print(f"metadata_sha256={real.metadata_sha256}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BpfMetadataReproError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
