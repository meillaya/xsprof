#!/bin/sh
# Bundle, verify, and prune durable VM verification evidence.
#
# Evidence is a QA artifact, not product wire: tools/vm_lab.sh writes one
# directory per run under dist/vm/evidence/<run-id>/ (gitignored), containing a
# canonical `xsprof/vm-evidence/v1` manifest, per-gate logs, and extracted
# JSON/PNG artifacts. This tool packages one run for release attachment, checks
# the hash chain again, or prunes old runs by age/byte budget.
#
# Never commits, never uploads, never touches the network.
#
# Usage:
#   sh tools/vm_evidence.sh bundle --run DIR [--out FILE]
#   sh tools/vm_evidence.sh verify --bundle FILE
#   sh tools/vm_evidence.sh prune [--keep N] [--max-bytes BYTES] [--dry-run]
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EVIDENCE_ROOT="$ROOT/dist/vm/evidence"
DIST_ROOT="$ROOT/dist"
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
[ -n "$VERSION" ] || {
    echo "vm_evidence: cannot read version from build.zig.zon" >&2
    exit 2
}

say() { printf 'vm_evidence: %s\n' "$*"; }
fail() {
    printf 'vm_evidence: FAIL: %s\n' "$*" >&2
    exit 1
}
usage() {
    sed -n '2,20p' "$0"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

mtime_of() {
    if stat -c %Y "$1" >/dev/null 2>&1; then
        stat -c %Y "$1"
    else
        stat -f %m "$1"
    fi
}

# require_inside_repo PATH: resolve PATH and refuse anything outside $ROOT.
require_inside_repo() {
    target=$1
    [ -e "$target" ] || fail "missing path: $target"
    resolved=$(CDPATH= cd -- "$(dirname -- "$target")" && pwd -P)/$(basename -- "$target")
    case "$resolved" in
        "$ROOT"/*) ;;
        *) fail "refusing path outside the repository: $target" ;;
    esac
    printf '%s\n' "$resolved"
}

# valid_manifest FILE: assert parseable canonical `xsprof/vm-evidence/v1` JSON.
valid_manifest() {
    manifest=$1
    [ -f "$manifest" ] || fail "missing manifest: $manifest"
    python3 - "$manifest" <<'PY'
import json
import sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()
data = json.loads(text)
if data.get("schema") != "xsprof/vm-evidence/v1":
    raise SystemExit("vm_evidence: manifest schema is not xsprof/vm-evidence/v1")
if data.get("host_mutation") is not False:
    raise SystemExit("vm_evidence: manifest host_mutation must be false")
canonical = json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n"
if text != canonical:
    raise SystemExit("vm_evidence: manifest is not canonical JSON")
PY
}

cmd_bundle() {
    run=
    out=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --run)
                run=${2:-}
                shift 2
                ;;
            --out)
                out=${2:-}
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                fail "bundle: unknown argument: $1"
                ;;
        esac
    done
    [ -n "$run" ] || fail "bundle: --run DIR is required"
    run=$(require_inside_repo "$run")
    [ -d "$run" ] || fail "bundle: not a directory: $run"
    valid_manifest "$run/manifest.json"

    mkdir -p "$DIST_ROOT"
    if [ -z "$out" ]; then
        stamp=$(date -u +%Y%m%d)
        out="$DIST_ROOT/xsprof-$VERSION-vm-evidence-$stamp.tar.gz"
        n=1
        while [ -e "$out" ]; do
            n=$((n + 1))
            out="$DIST_ROOT/xsprof-$VERSION-vm-evidence-$stamp-$n.tar.gz"
        done
    fi
    out=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$out")
    case "$out" in
        "$DIST_ROOT"/*) ;;
        *) fail "bundle: --out must be under $DIST_ROOT" ;;
    esac

    parent=$(CDPATH= cd -- "$(dirname -- "$run")" && pwd -P)
    base=$(basename -- "$run")
    epoch=$(mtime_of "$run/manifest.json")
    say "packaging $base -> $out"
    tar -C "$parent" --sort=name --mtime="@$epoch" --owner=0 --group=0 \
        --numeric-owner -czf "$out" "$base" || fail "tar failed"
    hash=$(sha256_of "$out")
    printf '%s  %s\n' "$hash" "$(basename -- "$out")" >"$out.sha256"
    say "PASS sha256=$hash"
    printf '%s\n' "$out"
}

cmd_verify() {
    bundle=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --bundle)
                bundle=${2:-}
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                fail "verify: unknown argument: $1"
                ;;
        esac
    done
    [ -n "$bundle" ] || fail "verify: --bundle FILE is required"
    [ -f "$bundle" ] || fail "verify: missing bundle: $bundle"
    [ -f "$bundle.sha256" ] || fail "verify: missing sidecar $bundle.sha256"
    expected=$(cut -d' ' -f1 <"$bundle.sha256")
    actual=$(sha256_of "$bundle")
    [ "$expected" = "$actual" ] || fail "verify: sha256 mismatch"
    say "PASS sha256=$actual"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    tar -xzf "$bundle" -C "$tmp" || fail "verify: cannot extract bundle"
    manifest=$(find "$tmp" -name manifest.json -type f | head -n 1)
    [ -n "$manifest" ] || fail "verify: bundle has no manifest.json"
    valid_manifest "$manifest" || fail "verify: invalid manifest"
    say "PASS manifest"
    python3 - "$manifest" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
gates = data.get("gates", [])
print("  run=%s backend=%s exit=%s" % (data.get("run_id"), data.get("backend"), data.get("exit_code")))
for gate in gates:
    print("  gate=%s status=%s exit=%s" % (gate.get("id"), gate.get("status"), gate.get("exit")))
audit = data.get("audit", {})
print("  audit=%s method=%s" % (audit.get("status"), audit.get("method")))
PY
}

cmd_prune() {
    keep=5
    max_bytes=$((512 * 1024 * 1024))
    dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --keep)
                keep=${2:-}
                shift 2
                ;;
            --max-bytes)
                max_bytes=${2:-}
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                fail "prune: unknown argument: $1"
                ;;
        esac
    done
    case "$keep" in
        '' | *[!0-9]*) fail "prune: --keep must be a non-negative integer" ;;
    esac
    case "$max_bytes" in
        '' | *[!0-9]*) fail "prune: --max-bytes must be an integer" ;;
    esac
    [ -d "$EVIDENCE_ROOT" ] || {
        say "nothing to prune (no evidence root)"
        exit 0
    }
    # Newest first by manifest mtime.
    list=$(mktemp)
    trap 'rm -f "$list"' EXIT HUP INT TERM
    for dir in "$EVIDENCE_ROOT"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/manifest.json" ] || continue
        printf '%s\t%s\n' "$(mtime_of "$dir/manifest.json")" "$dir"
    done | sort -rn >"$list"
    total=0
    index=0
    while IFS="$(printf '\t')" read -r _mtime dir; do
        [ -n "$dir" ] || continue
        index=$((index + 1))
        bytes=$(du -sb "$dir" 2>/dev/null | cut -f1)
        [ -n "$bytes" ] || bytes=0
        over=0
        [ "$index" -gt "$keep" ] && over=1
        [ $((total + bytes)) -gt "$max_bytes" ] && over=1
        if [ "$over" = 1 ]; then
            if [ "$dry_run" = 1 ]; then
                say "would prune $dir (${bytes} bytes)"
            else
                say "pruning $dir (${bytes} bytes)"
                rm -rf "$dir"
            fi
        else
            total=$((total + bytes))
        fi
    done <"$list"
    say "PASS prune (kept $((index > keep ? keep : index)) newest runs; remaining budget ${total} bytes)"
}

main() {
    [ "$#" -gt 0 ] || {
        usage >&2
        exit 2
    }
    cmd=$1
    shift
    case "$cmd" in
        bundle) cmd_bundle "$@" ;;
        verify) cmd_verify "$@" ;;
        prune) cmd_prune "$@" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown command: $cmd"
            ;;
    esac
}

main "$@"
