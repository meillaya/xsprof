#!/bin/sh
# KVM podman VM acceptance harness for the three root-only xsprof gates:
#   qa/live_smoke.sh, qa/service_smoke.sh, qa/retention_bench.sh 600000 0 2G yes
#
# It provisions a disposable KVM podman machine (Fedora CoreOS), builds the
# committed HEAD binary in a clean git worktree (so concurrent edits in the
# working tree cannot leak into the acceptance run), stages the binary with
# qa/fixtures/schemas into /var/tmp/xsprof, runs the gates as root, and writes
# real logs plus a machine-readable summary to docs/evidence/v0.5.0-vm/.
#
# The harness fails closed: a gate only counts as PASS when its exit code is 0
# and it printed its own PASS marker. It never fabricates a PASS.
#
# Usage: qa/vm_acceptance.sh [--check] [--destroy-vm]
#   --check       provision, build, stage and run the doctor probe, but do not
#                 run the three gates (no gate PASS is implied).
#   --destroy-vm  remove the podman machine at the end.
#
# Environment:
#   XSPROF_BIN              use this binary instead of building committed HEAD
#   XSPROF_VM_MACHINE       podman machine name (default xsprof-vm)
#   XSPROF_VM_EVIDENCE      evidence directory (default docs/evidence/v0.5.0-vm)
#   XSPROF_VM_RUN_DIR       work dir under HOME (default .cache/vm-run)
#   XSPROF_VM_CPUS          vCPUs (default 4)
#   XSPROF_VM_MEMORY        MiB RAM (default 4096)
#   XSPROF_VM_DISK          GiB disk (default 24)
#   XSPROF_VM_DESTROY=1     same as --destroy-vm
#
# Requirements: Linux with /dev/kvm readable+writable, podman >= 5, and
# qemu-system-x86_64/qemu-img/gvproxy/virtiofsd on PATH (podman 5.8.7 has no
# --provider flag; the qemu provider is inferred). Helper binaries are found in
# /nix/store when they are not on PATH. The machine mounts HOME, so the run
# directory must stay under HOME.
set -e
set +u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MACHINE="$XSPROF_VM_MACHINE"; [ -n "$MACHINE" ] || MACHINE=xsprof-vm
EVIDENCE="$XSPROF_VM_EVIDENCE"; [ -n "$EVIDENCE" ] || EVIDENCE="$ROOT/docs/evidence/v0.5.0-vm"
RUN="$XSPROF_VM_RUN_DIR"; [ -n "$RUN" ] || RUN="$ROOT/.cache/vm-run"
CPUS="$XSPROF_VM_CPUS"; [ -n "$CPUS" ] || CPUS=4
MEMORY="$XSPROF_VM_MEMORY"; [ -n "$MEMORY" ] || MEMORY=4096
DISK="$XSPROF_VM_DISK"; [ -n "$DISK" ] || DISK=24
BIN_OVERRIDE="$XSPROF_BIN"
DESTROY="$XSPROF_VM_DESTROY"
CHECK=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;;
        --destroy-vm) DESTROY=1 ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        *) printf 'vm_acceptance: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done
set -u

say() { printf 'vm_acceptance: %s\n' "$*"; }
fail() { say "FAIL: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "Linux only (KVM podman machine)"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || fail "/dev/kvm must be readable and writable"
command -v podman >/dev/null 2>&1 || fail "podman is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required on the host for evidence parsing"
mkdir -p "$EVIDENCE" "$RUN/runtime" "$RUN/tmp" "$RUN/logs" "$RUN/remote"
mkdir -p "$EVIDENCE/retention-artifacts"
chmod 700 "$RUN/runtime"
export XDG_RUNTIME_DIR="$RUN/runtime"
export TMPDIR="$RUN/tmp"

discover() { # tool store-name-substring
    command -v "$1" >/dev/null 2>&1 && return 0
    for d in /nix/store/*-"$2"*/bin; do
        if [ -x "$d/$1" ]; then
            PATH="$d:$PATH"
            export PATH
            return 0
        fi
    done
    fail "missing $1; put the qemu/gvproxy/virtiofsd helper binaries on PATH"
}
discover qemu-system-x86_64 qemu
discover qemu-img qemu
discover gvproxy gvproxy
discover virtiofsd virtiofsd

# ---------------------------------------------------------------- provisioning
PROV="$EVIDENCE/01-provisioning.log"
{
    printf '# KVM podman machine provisioning (qa/vm_acceptance.sh)\n'
    printf 'date=%s\n' "$(date -Is)"
    printf 'host=%s kernel=%s\n' "$(hostname)" "$(uname -r)"
    printf 'podman=%s\n' "$(podman --version)"
    printf 'qemu=%s\n' "$(qemu-system-x86_64 --version | head -1)"
    printf 'gvproxy=%s\n' "$(command -v gvproxy)"
    printf 'virtiofsd=%s\n' "$(command -v virtiofsd)"
    printf 'kvm=%s\n' "$(ls -l /dev/kvm)"
    printf 'nproc=%s\n' "$(nproc)"
    printf 'XDG_RUNTIME_DIR=%s\nTMPDIR=%s\n' "$XDG_RUNTIME_DIR" "$TMPDIR"
} > "$PROV"
say "provisioning podman machine $MACHINE (cpus=$CPUS memory=$MEMORY disk=$DISK)"
if ! podman machine inspect "$MACHINE" >/dev/null 2>&1; then
    {
        printf '\n===== podman machine init %s --cpus %s --memory %s --disk-size %s =====\n' "$MACHINE" "$CPUS" "$MEMORY" "$DISK"
        printf 'note: podman 5.8.7 rejects --provider qemu (unknown flag); qemu is inferred on Linux\n'
    } >> "$PROV"
    podman machine init "$MACHINE" --cpus "$CPUS" --memory "$MEMORY" --disk-size "$DISK" >> "$PROV" 2>&1 ||
        fail "podman machine init failed (see $PROV)"
else
    printf '\n===== machine %s already exists =====\n' "$MACHINE" >> "$PROV"
fi
MSTATE=$(podman machine inspect "$MACHINE" --format '{{.State}}' 2>/dev/null || true)
if [ "$MSTATE" != running ]; then
    printf '\n===== podman machine start %s =====\n' "$MACHINE" >> "$PROV"
    podman machine start "$MACHINE" >> "$PROV" 2>&1 || fail "podman machine start failed (see $PROV)"
fi
podman machine ssh "$MACHINE" 'echo VM_SSH_OK' 2>/dev/null | grep -q VM_SSH_OK || fail "cannot ssh into machine $MACHINE"
printf '\n===== podman machine inspect =====\n' >> "$PROV"
podman machine inspect "$MACHINE" >> "$PROV" 2>&1 || true

# ------------------------------------------------------------ committed binary
if [ -n "$BIN_OVERRIDE" ]; then
    BIN="$BIN_OVERRIDE"
    SRC_ROOT="$ROOT"
    printf '\n===== binary: XSPROF_BIN override =====\n%s\n' "$BIN" >> "$PROV"
else
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$ROOT is not a git work tree"
    HEAD=$(git -C "$ROOT" rev-parse HEAD)
    WT="$RUN/src-head"
    NEED_ADD=0
    [ -e "$WT/.git" ] || NEED_ADD=1
    if [ "$NEED_ADD" = 0 ] && [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)" != "$HEAD" ]; then
        NEED_ADD=1
    fi
    if [ "$NEED_ADD" = 1 ]; then
        rm -rf "$WT"
        git -C "$ROOT" worktree prune
        git -C "$ROOT" worktree add --detach "$WT" "$HEAD" >> "$PROV" 2>&1 || fail "git worktree add failed (see $PROV)"
    fi
    ln -sfn "$ROOT/.tools" "$WT/.tools"
    say "building committed HEAD $HEAD in $WT (dirty working tree cannot leak in)"
    ( cd "$WT" && ./tools/zig build ) >> "$PROV" 2>&1 || fail "committed-HEAD build failed (see $PROV)"
    BIN="$WT/zig-out/bin/xsprof"
    SRC_ROOT="$WT"
fi
[ -x "$BIN" ] || fail "not executable: $BIN"
BIN_SHA=$(sha256sum "$BIN" | cut -d' ' -f1)
BIN_VER=$("$BIN" --version 2>&1 | head -1)
{
    printf '\n===== binary =====\n'
    printf 'source=%s\nsha256=%s\nversion=%s\n' "$BIN" "$BIN_SHA" "$BIN_VER"
} >> "$PROV"

# --------------------------------------------------------------- VM staging
STAGE="$RUN/remote/stage.sh"
case "$STAGE" in
    "$HOME"/*) : ;;
    *) fail "XSPROF_VM_RUN_DIR must be under HOME; the machine mounts HOME" ;;
esac
cat > "$STAGE" <<EOF
#!/bin/sh
set -eu
BIN="$BIN"
SRC="$SRC_ROOT"
echo "host_binary_sha256=\$(sha256sum "\$BIN" | cut -d' ' -f1)"
sudo -n rm -rf /var/tmp/xsprof
sudo -n mkdir -p /var/tmp/xsprof/zig-out/bin
sudo -n cp -p "\$BIN" /var/tmp/xsprof/zig-out/bin/xsprof
for d in qa fixtures schemas; do
    sudo -n cp -a "\$SRC/\$d" "/var/tmp/xsprof/\$d"
done
sudo -n chown -R root:root /var/tmp/xsprof
sudo -n chmod 0755 /var/tmp/xsprof/zig-out/bin/xsprof
echo "vm_binary_sha256=\$(sudo -n sha256sum /var/tmp/xsprof/zig-out/bin/xsprof | cut -d' ' -f1)"
sudo -n /var/tmp/xsprof/zig-out/bin/xsprof --version
echo "--- doctor --json ---"
sudo -n /var/tmp/xsprof/zig-out/bin/xsprof doctor --json
EOF
say "staging binary + qa/fixtures/schemas into the VM (/var/tmp/xsprof)"
if ! podman machine ssh "$MACHINE" "sh $STAGE" > "$EVIDENCE/02-vm-setup.log" 2>&1; then
    fail "VM staging failed (see $EVIDENCE/02-vm-setup.log)"
fi
VM_SHA=$(sed -n 's/^vm_binary_sha256=//p' "$EVIDENCE/02-vm-setup.log" | head -1)
[ "$VM_SHA" = "$BIN_SHA" ] || fail "staged binary sha mismatch: host $BIN_SHA vm $VM_SHA"
grep -q '"name":"perf","reason":"[^"]*","state":"READY"' "$EVIDENCE/02-vm-setup.log" ||
    fail "perf is not READY in the VM (see $EVIDENCE/02-vm-setup.log)"
sed -n '/"checks":/p' "$EVIDENCE/02-vm-setup.log" | head -1 > "$EVIDENCE/02c-doctor.json"
say "VM staged binary sha verified: $VM_SHA"

if [ "$CHECK" = 1 ]; then
    say "CHECK OK: provisioned, built, staged and doctor is READY (gates not run; no PASS implied)"
    exit 0
fi

# ------------------------------------------------------------------- gates
FAILED=0
run_gate() { # id log marker remote-command
    gid="$1"
    glog="$2"
    marker="$3"
    cmd="$4"
    out="$EVIDENCE/$glog"
    {
        printf '# %s gate - real VM run\n' "$gid"
        printf 'date=%s\n' "$(date -Is)"
        printf 'machine=%s\n' "$MACHINE"
        printf 'binary_sha256=%s\n' "$BIN_SHA"
        printf 'command: %s\n' "$cmd"
        printf -- '----------------------------------------\n'
    } > "$out"
    rc=0
    podman machine ssh "$MACHINE" "$cmd" >> "$out" 2>&1 || rc=$?
    {
        printf -- '----------------------------------------\n'
        printf '%s_EXIT=%s\n' "$gid" "$rc"
    } >> "$out"
    if [ "$rc" -ne 0 ]; then
        say "FAIL: $gid exited $rc (see $out)"
        return 1
    fi
    if ! grep -Fq "$marker" "$out"; then
        say "FAIL: $gid did not print its PASS marker (see $out)"
        return 1
    fi
    say "$gid PASS"
    return 0
}

say "running live_smoke"
if ! run_gate live_smoke 03-live-smoke.log "live_smoke: PASS" \
    'sudo -n sh /var/tmp/xsprof/qa/live_smoke.sh'; then
    FAILED=1
fi
say "running service_smoke"
if ! run_gate service_smoke 04-service-smoke.log "service_smoke: PASS" \
    'sudo -n sh /var/tmp/xsprof/qa/service_smoke.sh'; then
    FAILED=1
fi
say "running retention_bench (600000 ms, 0 workers, 2G)"
if ! run_gate retention_bench 05-retention-bench.log "retention_bench: PASS" \
    'sudo -n env KEEP=1 sh /var/tmp/xsprof/qa/retention_bench.sh 600000 0 2G yes'; then
    FAILED=1
fi

# ------------------------------------------- retention artifacts + ratio check
RET_LOG="$EVIDENCE/05-retention-bench.log"
RET_STATE=$(sed -n 's/.* state=\([^ ]*\).*/\1/p' "$RET_LOG" | head -1)
if [ -z "$RET_STATE" ]; then
    say "FAIL: retention gate did not report a state path (see $RET_LOG)"
    FAILED=1
fi
if [ -n "$RET_STATE" ]; then
    say "copying retention artifacts from $RET_STATE"
    {
        printf '# retention artifacts from %s\n' "$RET_STATE"
        printf 'date=%s\n' "$(date -Is)"
        for f in manifest.json daemon-result.json history-result.json markers.ndjson sample.ndjson daemon.err; do
            podman machine ssh "$MACHINE" "sudo -n cat $RET_STATE/$f" > "$EVIDENCE/retention-artifacts/$f" 2>/dev/null || true
            printf '%-24s %s bytes\n' "$f" "$(wc -c < "$EVIDENCE/retention-artifacts/$f" | tr -d ' ')"
        done
        SEGS=$(podman machine ssh "$MACHINE" "sudo -n find $RET_STATE/segments -maxdepth 1 -type f -name '*.xsraw' | wc -l" 2>/dev/null || printf 'unknown')
        printf 'segment_files=%s\n' "$SEGS"
    } > "$EVIDENCE/05b-retention-artifacts.log"
fi

CANON="$RUN/remote/canonical-ratio.sh"
if [ -n "$RET_STATE" ]; then
cat > "$CANON" <<EOF
#!/bin/sh
set -eu
BIN=/var/tmp/xsprof/zig-out/bin/xsprof
STATE="$RET_STATE"
echo "=== canonical/compact ratio evidence \$(date -Is) ==="
echo "binary=\$BIN"
sudo -n sha256sum "\$BIN"
echo "gate_sample_bytes=\$(sudo -n stat -c %s "\$STATE/sample.ndjson")"
echo "why: qa/retention_bench.sh samples canonical events after the daemon"
echo "stopped, so its capture --last 1s window is empty and the script's own"
echo "ratio check is skipped (canonical_bytes_per_event=0.0). The samples below"
echo "are independent same-VM 1 s record runs used to recompute the ratio."
for n in 1 2; do
    out=/tmp/canon-ratio-\$n.ndjson
    sudo -n "\$BIN" record --duration 1s --output "\$out" 2>/dev/null
    printf 'record_%s_sha256=' "\$n"; sudo -n sha256sum "\$out" | cut -d' ' -f1
    printf 'record_%s_lines=' "\$n"; sudo -n wc -l < "\$out"
    printf 'record_%s_bytes=' "\$n"; sudo -n stat -c %s "\$out"
done
sudo -n python3 - "\$STATE" <<'PY'
import json, sys, pathlib
state = pathlib.Path(sys.argv[1])
samples = []
for n in (1, 2):
    data = pathlib.Path(f"/tmp/canon-ratio-{n}.ndjson").read_bytes().splitlines()
    samples.append((len(data), sum(len(row) + 1 for row in data)))
canonical = [total / count if count else 0.0 for count, total in samples]
manifest = json.loads((state / "manifest.json").read_text())
retained_bytes = sum(int(s.get("bytes", 0)) for s in manifest.get("segments", []))
retained_events = sum(int(s.get("events", 0)) for s in manifest.get("segments", []))
compact = retained_bytes / retained_events if retained_events else 0.0
mean = sum(canonical) / len(canonical)
print(json.dumps({
    "schema": "xsprof/canonical-ratio/v1",
    "gate_sample_bytes": (state / "sample.ndjson").stat().st_size,
    "canonical_samples": [
        {"lines": count, "bytes": total, "bytes_per_event": round(ratio, 3)}
        for (count, total), ratio in zip(samples, canonical)
    ],
    "canonical_bytes_per_event": round(mean, 3),
    "compact_bytes_per_event": round(compact, 3),
    "compact_ratio": round(mean / compact, 2) if compact else 0.0,
    "compact_ratio_status": "recomputed; gate own sample.ndjson was empty",
    "retained_bytes": retained_bytes,
    "retained_events": retained_events,
}, sort_keys=True))
PY
EOF
say "recomputing canonical/compact ratio in the same VM"
if podman machine ssh "$MACHINE" "sh $CANON" > "$EVIDENCE/06-canonical-ratio.log" 2>&1; then
    RATIO=$(python3 -c 'import json,sys
for line in open(sys.argv[1], errors="replace"):
    line = line.strip()
    if line.startswith("{") and "canonical-ratio/v1" in line:
        print(json.loads(line)["compact_ratio"]); break
else:
    print("0")' "$EVIDENCE/06-canonical-ratio.log")
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4.0 else 1)' "$RATIO"; then
        say "canonical/compact ratio $RATIO >= 4x (recomputed)"
    else
        say "FAIL: canonical/compact ratio $RATIO < 4x (see $EVIDENCE/06-canonical-ratio.log)"
        FAILED=1
    fi
else
    say "FAIL: canonical ratio recomputation failed (see $EVIDENCE/06-canonical-ratio.log)"
    FAILED=1
fi
fi

# ------------------------------------------------------------------- summary
python3 - "$EVIDENCE" "$BIN_SHA" "$BIN_VER" "$MACHINE" > "$EVIDENCE/07-results.json" <<'PY'
import json, pathlib, re, sys
evd = pathlib.Path(sys.argv[1])
sha, version, machine = sys.argv[2], sys.argv[3], sys.argv[4]
def text(name):
    try:
        return (evd / name).read_text(errors="replace")
    except FileNotFoundError:
        return ""
def gate(log, marker, exit_name):
    body = text(log)
    match = re.search(exit_name + r"=(\d+)", body)
    return {"log": log, "exit": int(match.group(1)) if match else None,
            "pass_marker": marker in body}
def find_json(name, token):
    for line in text(name).splitlines():
        line = line.strip()
        if line.startswith("{") and token in line:
            try:
                return json.loads(line)
            except Exception:
                continue
    return None
summary = {
    "schema": "xsprof/vm-acceptance-harness/v1",
    "machine": machine,
    "binary": {"sha256": sha, "version": version},
    "gates": {
        "live_smoke": gate("03-live-smoke.log", "live_smoke: PASS", "live_smoke_EXIT"),
        "service_smoke": gate("04-service-smoke.log", "service_smoke: PASS", "service_smoke_EXIT"),
        "retention_bench": gate("05-retention-bench.log", "retention_bench: PASS", "retention_bench_EXIT"),
    },
    "retention": find_json("05-retention-bench.log", "bytes_per_event"),
    "canonical_ratio": find_json("06-canonical-ratio.log", "canonical-ratio/v1"),
}
gates = summary["gates"]
ok = all(g["exit"] == 0 and g["pass_marker"] for g in gates.values())
ratio = summary["canonical_ratio"]
if ratio is not None:
    ok = ok and float(ratio.get("compact_ratio", 0)) >= 4.0
summary["acceptance"] = "PASS" if ok else "FAIL"
print(json.dumps(summary, indent=2, sort_keys=True))
PY

if [ "$FAILED" -ne 0 ]; then
    say "FAIL: one or more gates did not pass; see $EVIDENCE"
    exit 1
fi
say "PASS: live_smoke, service_smoke, retention_bench (binary $BIN_SHA)"
if [ -n "$DESTROY" ]; then
    podman machine rm -f "$MACHINE" >/dev/null 2>&1 || true
    say "machine $MACHINE removed"
else
    say "machine $MACHINE left running; remove with: podman machine rm -f $MACHINE"
fi
exit 0
