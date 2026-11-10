#!/bin/sh
# Disposable microvm.nix verification lane for the Nix-packaged xsprof binary.
#
# Builds the requested flake output, boots it as a microvm.nix qemu guest on a
# serial console, waits for the guest's strict markers, and writes a canonical
# machine-readable result plus the captured console log under
# docs/evidence/microvm/ (override with --out-dir).
#
# The guest itself is nix/microvm/configuration.nix + nix/microvm/guest-verify.sh:
# a one-shot NixOS boot that runs version/help, doctor/capabilities/preflight
# canonical JSON checks (host_mutation=false), two byte-identical CPU snapshots
# of the packaged replay fixture, a paper/light themed snapshot, the
# accessibility tree, and the documented `xsprof lab` headless scenario runner.
# It never runs `demo`/`ui --smoke` (they need an X11/Wayland display), and it
# never runs the root perf/live/service/retention gates (qa/vm_acceptance.sh
# owns those on a KVM+podman host).
#
# Variants:
#   auto  KVM when /dev/kvm is readable and writable, otherwise TCG (default)
#   kvm   packages.<system>.xsprof-microvm     (needs /dev/kvm; SKIP without it)
#   tcg   packages.<system>.xsprof-microvm-tcg (qemu TCG fallback, no /dev/kvm)
#
# Exit status: 0 = PASS, 1 = FAIL, 0 = SKIP (explicit reason in the JSON),
#              2 = usage error. A missing XSPROF-VM-VERIFY-PASS marker is FAIL;
#              a PASS is only reported when the guest printed the marker, at
#              least one XSPROF-VM-OK check, and no XSPROF-VM-FAIL/VFAIL.
#
# Usage: sh qa/microvm_verify.sh [--variant auto|kvm|tcg] [--timeout SECONDS]
#                                [--out-dir DIR] [--help]
#
# Requirements: Linux host, nix on PATH, timeout + tail (coreutils), python3
# for the canonical JSON result. qemu comes from the flake output, never from
# the host PATH. Nix cache dirs default to .cache/nix and .cache/tmp inside the
# checkout (the container-friendly override used by the Nix tooling here).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VARIANT=auto
TIMEOUT=1200
OUT_DIR="$ROOT/docs/evidence/microvm"

usage() {
    cat <<'EOF'
Usage: sh qa/microvm_verify.sh [options]

Boot the Nix-packaged xsprof in a disposable microvm.nix qemu guest and verify
it end-to-end. Writes console evidence + results JSON under docs/evidence/microvm/.

Options:
  --variant auto|kvm|tcg  lane variant (default: auto: kvm if /dev/kvm is
                          readable+writable, otherwise tcg)
  --timeout SECONDS       boot/verify timeout (default: 1200)
  --out-dir DIR           evidence directory (default: docs/evidence/microvm)
  -h, --help              show this help

Exit: 0 PASS or SKIP (reason in JSON), 1 FAIL. Never reports a faked PASS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant)
            [ "$#" -ge 2 ] || { echo "microvm_verify: --variant needs a value" >&2; exit 2; }
            VARIANT=$2; shift 2 ;;
        --timeout)
            [ "$#" -ge 2 ] || { echo "microvm_verify: --timeout needs a value" >&2; exit 2; }
            TIMEOUT=$2; shift 2 ;;
        --out-dir)
            [ "$#" -ge 2 ] || { echo "microvm_verify: --out-dir needs a value" >&2; exit 2; }
            OUT_DIR=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "microvm_verify: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$VARIANT" in auto|kvm|tcg) ;; *)
    echo "microvm_verify: --variant must be auto, kvm, or tcg (got $VARIANT)" >&2
    exit 2 ;;
esac
case "$TIMEOUT" in ''|*[!0-9]*)
    echo "microvm_verify: --timeout must be a positive integer (got $TIMEOUT)" >&2
    exit 2 ;;
esac

# Nix needs writable cache/temp dirs. Callers may inject their own, but a
# container host can export a read-only default (for example ~/.cache under a
# sandbox), so probe writability and fall back to the workspace-local
# directories documented for this lane. Without this, `nix build` would fail
# before the guest ever boots and the failure would look like a lane FAIL.
writable_dir() { # DIR
    mkdir -p "$1" 2>/dev/null || return 1
    ( : >"$1/.xsprof-write-probe" ) 2>/dev/null || return 1
    rm -f "$1/.xsprof-write-probe"
    return 0
}
cache_home=${XDG_CACHE_HOME:-}
tmp_home=${TMPDIR:-}
writable_dir "$cache_home" || cache_home="$ROOT/.cache/nix"
writable_dir "$tmp_home" || tmp_home="$ROOT/.cache/tmp"
XDG_CACHE_HOME=$cache_home
TMPDIR=$tmp_home
export XDG_CACHE_HOME TMPDIR
mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"
mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
WORK=$(mktemp -d "$TMPDIR/xsprof-microvm-verify.XXXXXX")
CONSOLE_NORM=""  # set after the boot; kept defined for early SKIP results
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

# Host facts are recorded whether the lane runs, skips, or fails.
HOST_HOSTNAME=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
HOST_KERNEL=$(uname -r 2>/dev/null || echo unknown)
HOST_SYSTEM=$(uname -sm 2>/dev/null | tr ' ' '_' || echo unknown)
HOST_NIX=""
if command -v nix >/dev/null 2>&1; then
    HOST_NIX=$(nix --version 2>/dev/null | head -n 1)
fi
HOST_PYTHON3=""
if command -v python3 >/dev/null 2>&1; then
    HOST_PYTHON3=$(python3 --version 2>&1 | head -n 1)
fi
HOST_KVM_PRESENT=0
HOST_KVM_READABLE=0
HOST_KVM_WRITABLE=0
[ -e /dev/kvm ] && HOST_KVM_PRESENT=1
[ -r /dev/kvm ] && HOST_KVM_READABLE=1
[ -w /dev/kvm ] && HOST_KVM_WRITABLE=1
HOST_CONTAINER=unknown
[ -e /.dockerenv ] && HOST_CONTAINER=docker
[ -e /run/.containerenv ] && HOST_CONTAINER=podman

# write_results writes the canonical (sorted keys, compact) result JSON and
# prints the human summary. Inputs are passed as argv/env to the python block.
write_results() {
    # $1 result, $2 reason, $3 pkg, $4 runner, $5 runner_rc, $6 duration,
    # $7 accel_observed, $8 pass_marker, $9 fail_marker,
    # $10 tcg_fallback, $11 console_log, $12 trimmed_log, $13 checks_file,
    # $14 fails_file, $15 variant, $16 timeout
    RESULT_JSON="$OUT_DIR/results-${15}.json"
    RESULT=$1 RESULT_REASON=$2 RUNNER_PKG=$3 RUNNER_PATH=$4 RUNNER_RC=$5 \
    RUN_DURATION=$6 RUN_ACCEL=$7 RUN_PASS_MARKER=$8 RUN_FAIL_MARKER=$9 \
    RUN_TCG_FALLBACK=${10} RUN_CONSOLE_LOG=${11} RUN_TRIMMED_LOG=${12} \
    RUN_CHECKS_FILE=${13} RUN_FAILS_FILE=${14} RUN_VARIANT=${15} RUN_TIMEOUT=${16} \
    RUN_CONSOLE_NORM=$CONSOLE_NORM \
    HOST_HOSTNAME=$HOST_HOSTNAME HOST_KERNEL=$HOST_KERNEL \
    HOST_SYSTEM=$HOST_SYSTEM HOST_NIX=$HOST_NIX HOST_PYTHON3=$HOST_PYTHON3 \
    HOST_KVM_PRESENT=$HOST_KVM_PRESENT HOST_KVM_READABLE=$HOST_KVM_READABLE \
    HOST_KVM_WRITABLE=$HOST_KVM_WRITABLE HOST_CONTAINER=$HOST_CONTAINER \
    python3 - "$RESULT_JSON" <<'PY'
import json
import os
import re
import sys

out_path = sys.argv[1]

ANSI_CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
ANSI_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def clean(line):
    return ANSI_CSI.sub("", ANSI_OSC.sub("", line))


def val(name, default=""):
    return os.environ.get(name, default)


def flag(name):
    return os.environ.get(name, "") == "1"


def read_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return [line.rstrip("\n") for line in handle if line.strip()]
    except OSError:
        return []


checks = []
for line in read_lines(val("RUN_CHECKS_FILE")):
    marker = "XSPROF-VM-OK "
    text = line.split(marker, 1)[1] if marker in line else line
    text = text.strip()
    if not text:
        continue
    name, _, detail = text.partition(" ")
    checks.append({"name": name, "detail": detail.strip()})

failures = []
for line in read_lines(val("RUN_FAILS_FILE")):
    marker = "XSPROF-VM-FAIL "
    if marker in line:
        failures.append(line.split(marker, 1)[1].strip())
    else:
        failures.append(line.strip())

runner_rc = val("RUNNER_RC", "-1")
record = {
    "schema": "xsprof/microvm-verify/v1",
    "result": val("RESULT"),
    "reason": val("RESULT_REASON"),
    "host_mutation": False,
    "read_only": True,
    "host": {
        "hostname": val("HOST_HOSTNAME"),
        "kernel": val("HOST_KERNEL"),
        "system": val("HOST_SYSTEM"),
        "nix": val("HOST_NIX"),
        "python3": val("HOST_PYTHON3"),
        "container_hint": val("HOST_CONTAINER"),
        "kvm_device_present": flag("HOST_KVM_PRESENT"),
        "kvm_device_readable": flag("HOST_KVM_READABLE"),
        "kvm_device_writable": flag("HOST_KVM_WRITABLE"),
    },
    "lane": {
        "flake_output": val("RUNNER_PKG"),
        "variant": val("RUN_VARIANT"),
        "requested_variant": val("RUN_VARIANT"),
        "runner": val("RUNNER_PATH"),
        "qemu_machine_accel": "kvm:tcg",
        "accelerator_observed": val("RUN_ACCEL"),
        "tcg_fallback_observed": flag("RUN_TCG_FALLBACK"),
    },
    "run": {
        "timeout_seconds": int(val("RUN_TIMEOUT", "0") or 0),
        "duration_seconds": int(val("RUN_DURATION", "0") or 0),
        "runner_exit": int(runner_rc) if runner_rc.lstrip("-").isdigit() else -1,
        "pass_marker": flag("RUN_PASS_MARKER"),
        "fail_marker": flag("RUN_FAIL_MARKER"),
        "console_log": val("RUN_CONSOLE_LOG"),
        "trimmed_console_log": val("RUN_TRIMMED_LOG"),
    },
    "checks": checks,
    "failures": failures,
}

trimmed_path = val("RUN_TRIMMED_LOG")
console_norm = val("RUN_CONSOLE_NORM")
if trimmed_path and console_norm and os.path.exists(console_norm):
    with open(trimmed_path, "w", encoding="utf-8") as evidence:
        evidence.write("# xsprof disposable microVM verification console (filtered evidence)\n")
        evidence.write(
            f"# variant={val('RUN_VARIANT')} flake_output={val('RUNNER_PKG')} "
            f"accelerator_observed={val('RUN_ACCEL')} host={val('HOST_HOSTNAME')} "
            f"kernel={val('HOST_KERNEL')}\n"
        )
        evidence.write(
            "# excerpt: qemu accelerator fallback + xsprof verification markers + guest reset; "
            "the full serial capture is console-<variant>.log (not filtered)\n"
        )
        with open(console_norm, encoding="utf-8", errors="replace") as captured:
            for line in captured:
                lowered = line.lower()
                if (
                    "falling back" in lowered
                    or "could not access kvm" in lowered
                    or "XSPROF-VM-" in line
                    or "reboot: Restarting system" in line
                ):
                    evidence.write(clean(line.rstrip("\n")) + "\n")

with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    handle.write("\n")

print(f"microvm_verify: {record['result']} variant={record['lane']['variant']} "
      f"checks={len(checks)} failures={len(failures)} "
      f"duration={record['run']['duration_seconds']}s")
if record["reason"]:
    print(f"microvm_verify: reason: {record['reason']}")
print(f"microvm_verify: results: {out_path}")
PY
}

# A SKIP must still leave canonical evidence behind, with the explicit reason.
skip_lane() {
    reason=$1
    lane_label=$2
    echo "microvm_verify: SKIP ($reason)" >&2
    write_results SKIP "$reason" "${PKG:-}" "" "-1" "0" "unknown" "0" "0" "0" "" "" "" "" "$lane_label" "$TIMEOUT"
    exit 0
}

# Canonical JSON is written with python3; without it the lane cannot leave
# machine-readable evidence, so skip with the one-line fallback record.
if [ -z "$HOST_PYTHON3" ]; then
    fallback="$OUT_DIR/results-auto.json"
    printf '{"reason":"python3 unavailable; canonical results JSON not written","result":"SKIP","schema":"xsprof/microvm-verify/v1"}\n' > "$fallback"
    echo "microvm_verify: SKIP (python3 unavailable)" >&2
    exit 0
fi

if [ "$(uname -s 2>/dev/null || echo unknown)" != Linux ]; then
    skip_lane "microvm qemu lane is Linux-only (host is $(uname -s 2>/dev/null || echo unknown))" "$VARIANT"
fi

if command -v nix >/dev/null 2>&1; then :; else
    skip_lane "nix is not on PATH; the qemu runner comes from the flake" "$VARIANT"
fi
if command -v timeout >/dev/null 2>&1; then :; else
    skip_lane "timeout (coreutils) is not on PATH" "$VARIANT"
fi
if command -v tail >/dev/null 2>&1; then :; else
    skip_lane "tail (coreutils) is not on PATH" "$VARIANT"
fi

# Resolve the variant exactly as documented: auto picks KVM only when
# /dev/kvm is both readable and writable.
REQUESTED_VARIANT=$VARIANT
if [ "$VARIANT" = auto ]; then
    if [ "$HOST_KVM_READABLE" -eq 1 ] && [ "$HOST_KVM_WRITABLE" -eq 1 ]; then
        VARIANT=kvm
        echo "microvm_verify: auto selected kvm (/dev/kvm readable+writable)" >&2
    else
        VARIANT=tcg
        echo "microvm_verify: auto selected tcg (no readable+writable /dev/kvm)" >&2
    fi
fi
if [ "$VARIANT" = kvm ]; then
    if [ "$HOST_KVM_READABLE" -ne 1 ] || [ "$HOST_KVM_WRITABLE" -ne 1 ]; then
        skip_lane "requested --variant kvm but /dev/kvm is not readable+writable on this host" "$VARIANT"
    fi
fi

if [ "$VARIANT" = tcg ]; then
    PKG=xsprof-microvm-tcg
else
    PKG=xsprof-microvm
fi
LOG="$OUT_DIR/console-$VARIANT.log"
TRIMMED="$OUT_DIR/console-$VARIANT.trimmed.log"
: > "$LOG"

echo "microvm_verify: building flake output .#$PKG (nix cache: $XDG_CACHE_HOME)" >&2
if ! ( cd "$ROOT" && nix build --no-link --print-out-paths ".#$PKG" ) \
        >"$WORK/runner-path" 2>"$WORK/build.log"; then
    echo "microvm_verify: FAIL (nix build .#$PKG failed)" >&2
    tail -n 20 "$WORK/build.log" >&2 || true
    write_results FAIL "nix build .#$PKG failed (see Nix log)" "$PKG" "" "-1" "0" "unknown" "0" "0" "0" "$LOG" "" "" "" "$VARIANT" "$TIMEOUT"
    exit 1
fi
RUNNER=$(head -n 1 "$WORK/runner-path")
if [ -z "$RUNNER" ] || [ ! -x "$RUNNER/bin/microvm-run" ]; then
    echo "microvm_verify: FAIL (runner package has no bin/microvm-run)" >&2
    write_results FAIL "runner package has no bin/microvm-run" "$PKG" "${RUNNER:-}" "-1" "0" "unknown" "0" "0" "0" "$LOG" "" "" "" "$VARIANT" "$TIMEOUT"
    exit 1
fi
echo "microvm_verify: runner $RUNNER/bin/microvm-run" >&2

# Boot. The runner writes kernel + guest journald console output on stdio (the
# machine type is -nographic, serialConsole defaults on), so the guest markers
# are greppable in this log. We stream it while also keeping the full capture.
echo "microvm_verify: booting variant=$VARIANT timeout=${TIMEOUT}s (accel kvm:tcg)" >&2
STARTED=$(date +%s)
# Boot from a scratch cwd: microvm-run creates its QMP unix socket relative to
# the working directory, and no repo artifact should be left behind.
mkdir -p "$WORK/boot"
( cd "$WORK/boot" && exec timeout "$TIMEOUT" "$RUNNER/bin/microvm-run" ) >"$LOG" 2>&1 &
RUNNER_PID=$!
VERIFIED=""
tail -n +1 -f "$LOG" &
TAIL_PID=$!
while kill -0 "$RUNNER_PID" 2>/dev/null; do
    if grep -q -F 'XSPROF-VM-VERIFY-PASS' "$LOG" 2>/dev/null; then
        VERIFIED=PASS
        break
    fi
    if grep -q -F 'XSPROF-VM-VERIFY-FAIL' "$LOG" 2>/dev/null; then
        VERIFIED=FAIL
        break
    fi
    sleep 2
done
# The guest reboots after printing the markers; give the disposable VM a short
# grace period to exit on its own before killing qemu.
if [ -n "$VERIFIED" ]; then
    grace=0
    while kill -0 "$RUNNER_PID" 2>/dev/null && [ "$grace" -lt 20 ]; do
        sleep 1
        grace=$((grace + 1))
    done
fi
if kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$RUNNER_PID" 2>/dev/null || true
fi
RUNNER_RC=0
wait "$RUNNER_PID" 2>/dev/null || RUNNER_RC=$?
kill "$TAIL_PID" 2>/dev/null || true
wait "$TAIL_PID" 2>/dev/null || true
ENDED=$(date +%s)
DURATION=$((ENDED - STARTED))

# Normalize CRLF from the qemu serial console before parsing/diffing.
tr -d '\r' < "$LOG" > "$WORK/console.norm"
PASS_MARKER=0
FAIL_MARKER=0
if grep -q -F 'XSPROF-VM-VERIFY-PASS' "$WORK/console.norm"; then PASS_MARKER=1; fi
if grep -q -F 'XSPROF-VM-VERIFY-FAIL' "$WORK/console.norm"; then FAIL_MARKER=1; fi
grep -F 'XSPROF-VM-OK ' "$WORK/console.norm" > "$WORK/checks.txt" 2>/dev/null || true
grep -F 'XSPROF-VM-FAIL ' "$WORK/console.norm" > "$WORK/fails.txt" 2>/dev/null || true
CHECK_COUNT=$(wc -l < "$WORK/checks.txt" | tr -d ' ')

ACCEL_OBSERVED=unknown
if grep -q -F 'XSPROF-VM-BOOT ' "$WORK/console.norm"; then
    # qemu logs an explicit fallback when KVM is unusable. Otherwise a
    # read/write /dev/kvm on the host means qemu used KVM acceleration even for
    # the TCG-labelled variant (its machine keeps accel="kvm:tcg"). The guest
    # kvm-clock line is a secondary signal only: it can be filtered by the
    # guest console loglevel, so it is not used to claim TCG on its own.
    if grep -q -i -E 'falling back to tcg|could not access kvm' "$WORK/console.norm"; then
        ACCEL_OBSERVED=tcg
    elif [ "$HOST_KVM_READABLE" -eq 1 ] && [ "$HOST_KVM_WRITABLE" -eq 1 ]; then
        ACCEL_OBSERVED=kvm
    elif grep -q -F 'kvm-clock' "$WORK/console.norm"; then
        ACCEL_OBSERVED=kvm
    else
        ACCEL_OBSERVED=tcg
    fi
fi
TCG_FALLBACK=0
if grep -q -i -F 'falling back' "$WORK/console.norm"; then TCG_FALLBACK=1; fi

# The committed evidence is a filtered excerpt (qemu accelerator fallback +
# all xsprof verification markers + the guest reset line), written by the
# result writer below from the normalized console capture.
CONSOLE_NORM="$WORK/console.norm"

RESULT=FAIL
REASON=""
if [ "$PASS_MARKER" -eq 1 ] && [ "$FAIL_MARKER" -eq 0 ] && [ "$CHECK_COUNT" -gt 0 ]; then
    RESULT=PASS
    REASON=""
elif [ "$FAIL_MARKER" -eq 1 ]; then
    RESULT=FAIL
    REASON="guest printed XSPROF-VM-VERIFY-FAIL"
elif [ "$RUNNER_RC" -eq 124 ]; then
    RESULT=FAIL
    REASON="qemu runner timed out after ${TIMEOUT}s"
elif [ "$PASS_MARKER" -eq 1 ]; then
    RESULT=FAIL
    REASON="XSPROF-VM-VERIFY-PASS marker present without any XSPROF-VM-OK checks"
else
    RESULT=FAIL
    REASON="XSPROF-VM-VERIFY-PASS marker missing (runner exit $RUNNER_RC)"
fi

write_results "$RESULT" "$REASON" "$PKG" "$RUNNER/bin/microvm-run" "$RUNNER_RC" \
    "$DURATION" "$ACCEL_OBSERVED" "$PASS_MARKER" "$FAIL_MARKER" "$TCG_FALLBACK" \
    "$LOG" "$TRIMMED" "$WORK/checks.txt" "$WORK/fails.txt" "$VARIANT" "$TIMEOUT"
echo "microvm_verify: console capture: $LOG"
echo "microvm_verify: trimmed evidence: $TRIMMED"

if [ "$RESULT" = PASS ]; then
    echo "microvm_verify: PASS (variant=$VARIANT checks=$CHECK_COUNT accel=$ACCEL_OBSERVED duration=${DURATION}s)"
    exit 0
fi
echo "microvm_verify: FAIL ($REASON)" >&2
exit 1
