#!/bin/sh
# Durable, write-scoped VM verification lab for xsprof.
#
# Privileged gates (live perf capture, recorder service, retention benchmark,
# latency/stack live smokes) need root and readable tracefs, so they run in a
# disposable VM provisioned by rootless podman. The harness keeps every mutable
# host path inside this repository:
#
#   $ROOT/.vm/                 podman machine HOME/XDG dirs, caches, staging
#   $ROOT/dist/vm/evidence/    one immutable-ish evidence directory per run
#
# The user's real $HOME/XDG dirs and /tmp are never used: HOME, XDG_*, TMPDIR,
# CONTAINERS_* and PODMAN_* are pinned into $ROOT/.vm before podman is invoked,
# and the podman machine mounts only the scoped HOME. The harness refuses to run
# as root, never calls host sudo (privileges stay inside the disposable VM) and
# records every run as canonical `xsprof/vm-evidence/v1` JSON plus per-gate logs.
# Evidence is a QA artifact: gitignored, attached to releases by hash, never
# committed. There is no telemetry and no external request beyond the one-time
# pinned machine-image pull from the container registry.
#
# Backends:
#   kvm-machine      rootless podman client + disposable KVM VM (needs /dev/kvm
#                    and qemu-system-x86_64/gvproxy/virtiofsd on PATH or in the
#                    Nix store). Runs every privileged gate.
#   podman-container rootless container only (no KVM). Runs the unprivileged
#                    container lane; explicit privileged lanes are recorded as
#                    REFUSE with the exact reason and fail closed.
#
# Failure policy: a gate PASS requires exit 0, its own marker line, and the
# lane's postconditions. Missing prerequisites are REFUSE/precondition errors,
# never silent SKIPs. Gate commands are never retried; only the machine image
# pull may be retried (logged).
#
# Usage:
#   sh tools/vm_lab.sh probe            [options]   # provision + VM readiness
#   sh tools/vm_lab.sh gates            [options]   # run lanes (default: probe)
#   sh tools/vm_lab.sh audit-writes     [options]   # probe + write-scope audit
#   sh tools/vm_lab.sh clean [--evidence]           # remove this lab's state
#   sh tools/vm_lab.sh selftest                     # offline harness regression
#
# Options: --backend auto|kvm-machine|podman-container
#          --all | --lanes probe,live,service,retention[,latency,stacks,studies]
#          --keep                    keep the podman machine (debugging)
#          --bundle                  package evidence for release attachment
#          --audit-writes            inventory writes outside $ROOT
#          --offline                 never pull; fail if not provisioned
#          --json                    print the manifest path/JSON summary
#          --help
#
# Exit: 0 PASS, 1 gate FAIL/REFUSE, 2 precondition/usage.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$ROOT/build.zig.zon" | head -1)
[ -n "$VERSION" ] || {
    echo "vm_lab: cannot read version from build.zig.zon" >&2
    exit 2
}

REAL_HOME=${HOME:-}
VM_ROOT=${XSPROF_VM_ROOT:-$ROOT/.vm}
EVIDENCE_ROOT=${XSPROF_VM_EVIDENCE_ROOT:-$ROOT/dist/vm/evidence}

CMD=
BACKEND=auto
LANES=
ALL_LANES=0
KEEP=0
BUNDLE=0
AUDIT_WRITES=0
OFFLINE=0
JSON_OUT=0
EVIDENCE_ONLY=0
RETENTION_MS=${XSPROF_VM_RETENTION_MS:-600000}
CPUS=${XSPROF_VM_CPUS:-4}
MEMORY=${XSPROF_VM_MEMORY:-4096}
DISK=${XSPROF_VM_DISK:-24}
CONTAINER_IMAGE=${XSPROF_CONTAINER_IMAGE:-docker.io/library/debian:12-slim}

RUN_ID=
EVIDENCE=
MACHINE=
MACHINE_CREATED=0
MACHINE_DESTROYED=0
LOCK_DIR=
BIN=
BIN_SHA=
BIN_VERSION=
SRC_ROOT=
STAGE=
GIT_HEAD=
STARTED_UTC=
AUDIT_START=0
AUDIT_MODES=0
CONTAINER_PODMAN_SCOPED=0
CONTAINER_DIGEST=
ZIG_TARGET=

say() { printf 'vm_lab: %s\n' "$*"; }
warn() { printf 'vm_lab: WARN: %s\n' "$*" >&2; }
fail() {
    printf 'vm_lab: FAIL: %s\n' "$*" >&2
    # Provisioning/build/staging failures must still leave a manifest behind so
    # a failed run is as auditable as a passing one. main() writes the manifest
    # on normal completion; this path covers functions that exit directly.
    if [ -n "${EVIDENCE:-}" ] && [ -d "${EVIDENCE:-}" ]; then
        meta run_failure "$*" 2>/dev/null || true
        meta exit_code 1 2>/dev/null || true
        write_manifest 1 >/dev/null 2>&1 || true
        if [ "${JSON_OUT:-0}" = 1 ] && [ -f "$EVIDENCE/manifest.json" ]; then
            cat "$EVIDENCE/manifest.json"
        fi
    fi
    exit 1
}
usage() {
    sed -n '2,52p' "$0"
}

usage_error() {
    printf 'vm_lab: %s\n' "$*" >&2
    usage >&2
    exit 2
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

canonical_dir() {
    (CDPATH= cd -- "$1" && pwd -P)
}

# ensure_inside_repo DIR: resolve DIR without creating anything, refuse it when
# it escapes the repository, then create it. Normalization uses python3 (a hard
# prerequisite) so a path like $ROOT/../escape is rejected before any mkdir.
ensure_inside_repo() {
    target=$1
    resolved=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")
    case "$resolved" in
        "$ROOT" | "$ROOT"/*) ;;
        *) fail "refusing path outside the repository: $target ($resolved)" ;;
    esac
    mkdir -p "$resolved"
    printf '%s\n' "$resolved"
}

meta() { # KEY VALUE
    printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >>"$EVIDENCE/meta.tsv"
}

record_gate() { # ID STATUS EXIT LOG MARKER
    log=$EVIDENCE/$4
    log_sha=-
    if [ -f "$log" ]; then log_sha=$(sha256_of "$log"); fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$log_sha" >>"$EVIDENCE/gates.tsv"
}

# Count gates recorded as anything other than PASS. Used both by the run
# aggregator (defense in depth against clobbered shell globals) and by
# `selftest`, which proves the aggregation is fail-closed.
gates_bad_count() { # GATES_TSV
    awk -F'\t' '$2 != "PASS" { count++ } END { print count + 0 }' "$1"
}

record_refuse() { # ID REASON
    log="$EVIDENCE/refuse-$1.log"
    printf 'REFUSE %s: %s\n' "$1" "$2" >"$log"
    record_gate "$1" REFUSE - "refuse-$1.log" -
    say "REFUSE $1 ($2)"
}

parse_args() {
    [ "$#" -gt 0 ] || usage_error "a command is required"
    CMD=$1
    shift
    case "$CMD" in
        probe | gates | audit-writes | clean | selftest | help | -h | --help) ;;
        *) usage_error "unknown command: $CMD" ;;
    esac
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backend)
                BACKEND=${2:-}
                shift 2
                ;;
            --lanes)
                LANES=${2:-}
                shift 2
                ;;
            --all)
                ALL_LANES=1
                shift
                ;;
            --keep)
                KEEP=1
                shift
                ;;
            --bundle)
                BUNDLE=1
                shift
                ;;
            --audit-writes)
                AUDIT_WRITES=1
                shift
                ;;
            --offline)
                OFFLINE=1
                shift
                ;;
            --json)
                JSON_OUT=1
                shift
                ;;
            --evidence)
                EVIDENCE_ONLY=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage_error "unknown argument: $1"
                ;;
        esac
    done
    case "$BACKEND" in
        auto | kvm-machine | podman-container) ;;
        *) usage_error "invalid --backend: $BACKEND" ;;
    esac
    if [ -n "$LANES" ] && [ "$ALL_LANES" = 1 ]; then
        usage_error "--lanes and --all are mutually exclusive"
    fi
}

setup_scoped_env() {
    export HOME="$VM_ROOT/home"
    export XDG_CONFIG_HOME="$VM_ROOT/config"
    export XDG_DATA_HOME="$VM_ROOT/data"
    export XDG_CACHE_HOME="$VM_ROOT/cache"
    export XDG_STATE_HOME="$VM_ROOT/state"
    export XDG_RUNTIME_DIR="$VM_ROOT/runtime"
    export TMPDIR="$VM_ROOT/tmp"
    export CONTAINERS_CACHE_DIR="$VM_ROOT/cache/containers"
    export CONTAINERS_TMP_DIR="$VM_ROOT/tmp/containers"
    unset SSH_AUTH_SOCK
    umask 077
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" \
        "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" \
        "$VM_ROOT/run" "$VM_ROOT/src-head" "$VM_ROOT/containers/storage" \
        "$VM_ROOT/containers/runroot"
    chmod 700 "$HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"
}

discover_tool() { # NAME STORE_HINT
    command -v "$1" >/dev/null 2>&1 && return 0
    for dir in /nix/store/*-"$2"*/bin /nix/store/*"$2"*/bin; do
        [ -d "$dir" ] || continue
        if [ -x "$dir/$1" ]; then
            PATH="$dir:$PATH"
            export PATH
            return 0
        fi
    done
    return 1
}

kvm_prereqs() {
    [ "$(uname -s)" = Linux ] || return 1
    [ -r /dev/kvm ] && [ -w /dev/kvm ] || return 1
    command -v podman >/dev/null 2>&1 || return 1
    discover_tool qemu-system-x86_64 qemu || return 1
    discover_tool qemu-img qemu || return 1
    discover_tool gvproxy gvproxy || return 1
    discover_tool virtiofsd virtiofsd || return 1
    return 0
}

select_backend() {
    case "$BACKEND" in
        auto)
            if kvm_prereqs; then
                BACKEND=kvm-machine
            else
                BACKEND=podman-container
                warn "auto backend selected podman-container (missing /dev/kvm or VM helpers)"
            fi
            ;;
        kvm-machine)
            kvm_prereqs || fail "kvm-machine backend prerequisites missing (/dev/kvm rw, podman, qemu-system-x86_64/qemu-img/gvproxy/virtiofsd)"
            ;;
        podman-container) ;;
    esac
    say "backend=$BACKEND"
}

preflight() {
    [ "$(id -u)" != 0 ] || fail "refusing to run as root: privilege stays inside the disposable VM"
    command -v podman >/dev/null 2>&1 || fail "podman is required"
    command -v python3 >/dev/null 2>&1 || fail "python3 is required on the host for evidence manifests"
    [ -n "$REAL_HOME" ] || fail "HOME is unset"
    VM_ROOT=$(ensure_inside_repo "$VM_ROOT")
    EVIDENCE_ROOT=$(ensure_inside_repo "$EVIDENCE_ROOT")
    setup_scoped_env
    LOCK_DIR="$VM_ROOT/lab.lock"
    mkdir "$LOCK_DIR" 2>/dev/null || fail "another vm_lab run is active ($LOCK_DIR); remove it if stale"
    trap cleanup EXIT HUP INT TERM
}

make_run() {
    STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    base=$(date -u +%Y%m%dT%H%M%SZ)
    GIT_HEAD=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')
    short=${GIT_HEAD%%.*}
    short=$(printf '%s' "$short" | cut -c1-8)
    RUN_ID="$base-$short"
    EVIDENCE="$EVIDENCE_ROOT/$RUN_ID"
    n=1
    while [ -e "$EVIDENCE" ]; do
        n=$((n + 1))
        EVIDENCE="$EVIDENCE_ROOT/$RUN_ID-$n"
    done
    mkdir -p "$EVIDENCE"
    : >"$EVIDENCE/meta.tsv"
    : >"$EVIDENCE/gates.tsv"
    meta run_id "$(basename -- "$EVIDENCE")"
    meta command "$CMD"
    meta started_utc "$STARTED_UTC"
    meta host_kernel "$(uname -r)"
    meta host_arch "$(uname -m)"
    meta host_nproc "$(nproc 2>/dev/null || printf '?')"
    meta host_podman "$(podman --version 2>/dev/null || printf 'unknown')"
    meta host_root "$ROOT"
    meta host_vm_root "$VM_ROOT"
    meta git_head "$GIT_HEAD"
    if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -n 1)" ]; then
        meta git_dirty true
    else
        meta git_dirty false
    fi
    say "evidence=$EVIDENCE"
}

# ---------------------------------------------------------------- kvm backend
write_containers_conf() { # MODE: machine|container
    mode=$1
    podman_real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v podman)")
    prefix=$(dirname -- "$(dirname -- "$podman_real")")
    helper_dirs=
    for candidate in "$prefix/libexec/podman" "$prefix/lib/podman" "$prefix/libexec"; do
        [ -d "$candidate" ] || continue
        case " $helper_dirs " in
            *" $candidate "*) ;;
            *) helper_dirs="$helper_dirs $candidate" ;;
        esac
    done
    if [ "$mode" = machine ]; then
        for tool in qemu-system-x86_64 qemu-img gvproxy virtiofsd; do
            command -v "$tool" >/dev/null 2>&1 || continue
            dir=$(dirname -- "$(command -v "$tool")")
            case " $helper_dirs " in
                *" $dir "*) ;;
                *) helper_dirs="$helper_dirs $dir" ;;
            esac
        done
    fi
    mkdir -p "$XDG_CONFIG_HOME/containers"
    {
        printf '[engine]\nhelper_binaries_dir = ['
        sep=
        for dir in $helper_dirs; do
            printf '%s"%s"' "$sep" "$dir"
            sep=,
        done
        printf ']\n'
        if [ "$mode" = container ]; then
            # Rootless storage stays inside the scoped HOME; vfs needs no
            # fuse-overlayfs and is deterministic (slow, but this lane runs a
            # tiny binary). The helper dir above supplies crun/conmon/netavark.
            printf '[storage]\ndriver = "vfs"\n'
        fi
    } >"$XDG_CONFIG_HOME/containers/containers.conf"
    chmod 600 "$XDG_CONFIG_HOME/containers/containers.conf"
    export CONTAINERS_CONF="$XDG_CONFIG_HOME/containers/containers.conf"
}

prepare_kvm() {
    discover_tool qemu-system-x86_64 qemu || fail "missing qemu-system-x86_64"
    discover_tool qemu-img qemu || fail "missing qemu-img"
    discover_tool gvproxy gvproxy || fail "missing gvproxy"
    discover_tool virtiofsd virtiofsd || fail "missing virtiofsd"

    # podman machine looks for gvproxy/virtiofsd/qemu in its own libexec dirs,
    # not on PATH. Point [engine].helper_binaries_dir at the discovered
    # directories via the scoped containers.conf (never the host config).
    write_containers_conf machine

    MACHINE="xsprof-lab-$(date -u +%Y%m%d%H%M%S)"
    meta machine "$MACHINE"
    init_log="$EVIDENCE/01-provisioning.log"
    {
        printf '# VM lab provisioning\n'
        printf 'date=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'machine=%s cpus=%s memory=%s disk=%s\n' "$MACHINE" "$CPUS" "$MEMORY" "$DISK"
        printf 'qemu=%s\n' "$(qemu-system-x86_64 --version | head -n 1)"
        printf 'gvproxy=%s\nvirtiofsd=%s\n' "$(command -v gvproxy)" "$(command -v virtiofsd)"
        printf 'image=%s\n' "${XSPROF_VM_IMAGE:-<podman default>}"
    } >"$init_log"
    if [ "$OFFLINE" = 1 ] && ! podman machine inspect "$MACHINE" >/dev/null 2>&1; then
        fail "offline: podman machine $MACHINE is not provisioned"
    fi
    if ! podman machine inspect "$MACHINE" >/dev/null 2>&1; then
        set -- machine init "$MACHINE" --cpus "$CPUS" --memory "$MEMORY" --disk-size "$DISK"
        if [ -n "${XSPROF_VM_IMAGE:-}" ]; then
            set -- "$@" --image "$XSPROF_VM_IMAGE"
        fi
        say "provisioning podman machine $MACHINE (one-time image pull, may retry)"
        attempt=1
        while :; do
            if podman "$@" >>"$init_log" 2>&1; then
                break
            fi
            if [ "$attempt" -ge 3 ] || [ "$OFFLINE" = 1 ]; then
                fail "podman machine init failed (see $init_log)"
            fi
            warn "machine init failed (attempt $attempt); retrying"
            attempt=$((attempt + 1))
            sleep 3
        done
    fi
    MACHINE_CREATED=1
    state=$(podman machine inspect "$MACHINE" --format '{{.State}}' 2>/dev/null || printf 'unknown')
    if [ "$state" != running ]; then
        podman machine start "$MACHINE" >>"$init_log" 2>&1 || fail "podman machine start failed (see $init_log)"
    fi
    podman machine ssh "$MACHINE" 'printf VM_SSH_OK' 2>/dev/null | grep -q VM_SSH_OK ||
        fail "cannot ssh into machine $MACHINE"
    podman machine inspect "$MACHINE" >"$EVIDENCE/01-machine.json" 2>>"$init_log" || true
    {
        printf 'vm_uname=%s\n' "$(podman machine ssh "$MACHINE" 'uname -r' 2>/dev/null || printf '?')"
        printf 'vm_perf_event_paranoid=%s\n' "$(podman machine ssh "$MACHINE" 'cat /proc/sys/kernel/perf_event_paranoid' 2>/dev/null || printf '?')"
        printf 'vm_tracefs=%s\n' "$(podman machine ssh "$MACHINE" 'grep -c tracefs /proc/mounts' 2>/dev/null || printf '?')"
        printf 'vm_uid=%s\n' "$(podman machine ssh "$MACHINE" 'id -u' 2>/dev/null || printf '?')"
        printf 'vm_os=%s\n' "$(podman machine ssh "$MACHINE" '. /etc/os-release 2>/dev/null; printf "%s" "${PRETTY_NAME:-unknown}"' 2>/dev/null || printf '?')"
    } >"$EVIDENCE/01-vm.txt"
    meta vm_kernel "$(sed -n 's/^vm_uname=//p' "$EVIDENCE/01-vm.txt")"
    meta vm_perf_event_paranoid "$(sed -n 's/^vm_perf_event_paranoid=//p' "$EVIDENCE/01-vm.txt")"
    meta vm_tracefs "$(sed -n 's/^vm_tracefs=//p' "$EVIDENCE/01-vm.txt")"
    meta vm_os "$(sed -n 's/^vm_os=//p' "$EVIDENCE/01-vm.txt")"
    # podman machine inspect does not expose the booted image reference; record
    # the operator pin when supplied, otherwise the podman-resolved default.
    meta vm_image_digest "${XSPROF_VM_IMAGE:-podman-machine-default-pull}"
}

prepare_binary() {
    if [ -n "${XSPROF_BIN:-}" ]; then
        BIN=$XSPROF_BIN
        SRC_ROOT=$ROOT
        meta binary_source override
        return
    fi
    GIT_HEAD=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || fail "not a git work tree: $ROOT"
    WT="$VM_ROOT/src-head"
    if [ ! -d "$WT/.git" ] || [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)" != "$GIT_HEAD" ]; then
        rm -rf "$WT"
        git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
        git -C "$ROOT" worktree add --detach "$WT" "$GIT_HEAD" >>"$EVIDENCE/00-build.log" 2>&1 ||
            fail "git worktree add failed for committed HEAD (see 00-build.log)"
    fi
    ln -sfn "$ROOT/.tools" "$WT/.tools"
    SRC_ROOT=$WT
    build_args=
    out_dir="$WT/zig-out"
    case "$BACKEND" in
        kvm-machine) ;;
        podman-container)
            case "$(uname -m)" in
                x86_64 | amd64) ZIG_TARGET=x86_64-linux-gnu ;;
                aarch64 | arm64) ZIG_TARGET=aarch64-linux-gnu ;;
                *) fail "unsupported container host architecture: $(uname -m)" ;;
            esac
            out_dir="$VM_ROOT/container-prefix"
            build_args="-Doptimize=ReleaseSafe -Dcpu=baseline -Dtarget=$ZIG_TARGET --prefix $out_dir"
            ;;
    esac
    say "building committed HEAD $GIT_HEAD (dirty worktree cannot leak in)"
    (
        cd "$WT" || exit 1
        export ZIG_GLOBAL_CACHE_DIR="$ROOT/.zig-cache/global"
        export ZIG_LOCAL_CACHE_DIR="$ROOT/.zig-cache"
        ./tools/zig build $build_args
    ) >>"$EVIDENCE/00-build.log" 2>&1 || fail "committed-HEAD build failed (see 00-build.log)"
    BIN="$out_dir/bin/xsprof"
    meta binary_source "committed HEAD $GIT_HEAD"
}

stage_workspace() {
    [ -x "$BIN" ] || fail "binary missing after build: $BIN"
    BIN_SHA=$(sha256_of "$BIN")
    BIN_VERSION=$("$BIN" version 2>/dev/null | head -n 1) || fail "cannot run $BIN version"
    [ "$BIN_VERSION" = "xsprof $VERSION" ] ||
        fail "binary version mismatch: got '$BIN_VERSION', expected 'xsprof $VERSION'"
    meta binary_sha256 "$BIN_SHA"
    meta binary_version "$BIN_VERSION"
    STAGE="$VM_ROOT/run/stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/zig-out/bin" "$STAGE/qa" "$STAGE/fixtures" "$STAGE/schemas"
    cp "$BIN" "$STAGE/zig-out/bin/xsprof"
    cp -a "$SRC_ROOT/qa/." "$STAGE/qa/"
    cp -a "$SRC_ROOT/fixtures/." "$STAGE/fixtures/"
    cp -a "$SRC_ROOT/schemas/." "$STAGE/schemas/"
    chmod 755 "$STAGE/zig-out/bin/xsprof"
    meta stage_dir "$STAGE"
}

stage_kvm() {
    say "staging binary + qa/fixtures/schemas into the VM"
    ( cd "$STAGE" && tar -cf - . ) |
        podman machine ssh "$MACHINE" 'sudo -n rm -rf /var/tmp/xsprof && sudo -n mkdir -p /var/tmp/xsprof && sudo -n tar -xf - -C /var/tmp/xsprof' \
            >>"$EVIDENCE/02-vm-setup.log" 2>&1 || fail "staging into VM failed (see 02-vm-setup.log)"
    vm_sha=$(podman machine ssh "$MACHINE" 'sudo -n sha256sum /var/tmp/xsprof/zig-out/bin/xsprof' 2>/dev/null | cut -d' ' -f1)
    [ "$vm_sha" = "$BIN_SHA" ] || fail "staged binary sha mismatch: host $BIN_SHA vm $vm_sha"
    printf 'host_binary_sha256=%s\nvm_binary_sha256=%s\n' "$BIN_SHA" "$vm_sha" >>"$EVIDENCE/02-vm-setup.log"
    say "staged binary sha verified: $vm_sha"
}

kvm_probe() {
    id=probe
    log_name=02-probe.log
    log="$EVIDENCE/$log_name"
    command='sudo -n /var/tmp/xsprof/zig-out/bin/xsprof version && sudo -n /var/tmp/xsprof/zig-out/bin/xsprof doctor --json'
    {
        printf '# gate=%s\ncommand=%s\n---\n' "$id" "$command"
    } >"$log"
    rc=0
    podman machine ssh "$MACHINE" "$command" >>"$log" 2>&1 || rc=$?
    printf -- '\n---\nexit=%s\n' "$rc" >>"$log"
    status=FAIL
    reason=
    if [ "$rc" -ne 0 ]; then
        reason="command exited $rc"
    elif ! grep -Fq "xsprof $VERSION" "$log"; then
        reason="version line missing or wrong"
    fi
    if [ -z "$reason" ]; then
        perf_state=$(python3 - "$log" <<'PY'
import json
import sys

text = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        data = json.loads(line)
    except ValueError:
        continue
    if data.get("schema") != "xsprof/doctor/v1":
        continue
    for check in data.get("checks", []):
        if check.get("name") == "perf":
            print(check.get("state", ""))
            raise SystemExit(0)
raise SystemExit(1)
PY
) || perf_state=
        if [ "$perf_state" != READY ]; then
            reason="perf probe is not READY (state=${perf_state:-missing})"
        elif ! grep -Fq '"host_mutation":false' "$log"; then
            reason="doctor output missing host_mutation=false"
        fi
    fi
    [ -n "$reason" ] || status=PASS
    printf 'status=%s\nreason=%s\n' "$status" "$reason" >>"$log"
    record_gate "$id" "$status" "$rc" "$log_name" "vm readiness"
    say "$status $id${reason:+ ($reason)}"
    [ "$status" = PASS ]
}

kvm_gate() { # ID LOG MARKER COMMAND
    id=$1
    log_name=$2
    marker=$3
    command=$4
    log="$EVIDENCE/$log_name"
    {
        printf '# gate=%s\ndate=%s\ncommand=%s\n---\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$command"
    } >"$log"
    rc=0
    podman machine ssh "$MACHINE" "$command" >>"$log" 2>&1 || rc=$?
    printf -- '\n---\nfinished_utc=%s\nexit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >>"$log"
    status=FAIL
    if [ "$rc" -eq 0 ] && grep -Fq -- "$marker" "$log"; then
        status=PASS
    fi
    record_gate "$id" "$status" "$rc" "$log_name" "$marker"
    say "$status $id (exit $rc)"
    [ "$status" = PASS ]
}

kvm_run_lane() { # LANE
    lane=$1
    case "$lane" in
        probe) kvm_probe ;;
        live)
            kvm_gate live 03-live-smoke.log "live_smoke: PASS" \
                'sudo -n sh /var/tmp/xsprof/qa/live_smoke.sh'
            ;;
        service)
            kvm_gate service 04-service-smoke.log "service_smoke: PASS" \
                'sudo -n sh /var/tmp/xsprof/qa/service_smoke.sh'
            ;;
        retention)
            kvm_gate retention 05-retention-bench.log "retention_bench: PASS" \
                "sudo -n env KEEP=1 sh /var/tmp/xsprof/qa/retention_bench.sh $RETENTION_MS 0 2G yes"
            ;;
        latency)
            if [ ! -f "$STAGE/qa/latency_smoke.sh" ]; then
                record_refuse latency "qa/latency_smoke.sh is not present in this tree"
                return 1
            fi
            kvm_gate latency 06-latency-smoke.log "latency_smoke: PASS" \
                'sudo -n sh /var/tmp/xsprof/qa/latency_smoke.sh --live'
            ;;
        stacks)
            if [ ! -f "$STAGE/qa/stack_smoke.sh" ]; then
                record_refuse stacks "qa/stack_smoke.sh is not present in this tree"
                return 1
            fi
            kvm_gate stacks 07-stack-smoke.log "stack_smoke: PASS" \
                'sudo -n sh /var/tmp/xsprof/qa/stack_smoke.sh --live'
            ;;
        studies)
            if [ ! -f "$STAGE/qa/studies/run_studies.sh" ]; then
                record_refuse studies "qa/studies/run_studies.sh is not present in this tree"
                return 1
            fi
            kvm_gate studies 08-studies.log "run_studies: PASS" \
                'sudo -n env XSPROF_STUDY_VM_CONFIRM=1 sh /var/tmp/xsprof/qa/studies/run_studies.sh --out /var/tmp/xsprof-studies' || return 1
            # Copy only regular study outputs into the evidence directory: the
            # in-VM work/state dirs hold FIFOs and raw recorder segments that
            # must never enter a release-attachable archive.
            mkdir -p "$EVIDENCE/studies-artifacts"
            if podman machine ssh "$MACHINE" "sudo -n tar -C /var/tmp --exclude='xsprof-studies/*/work/*' --exclude='xsprof-studies/*/state/*' -cf - xsprof-studies" 2>"$EVIDENCE/08b-studies-copy.log" |
                tar -C "$EVIDENCE/studies-artifacts" -xf - 2>>"$EVIDENCE/08b-studies-copy.log"; then
                special=$(find "$EVIDENCE/studies-artifacts" ! -type f ! -type d -print 2>/dev/null | head -n 1)
                if [ -n "$special" ]; then
                    warn "studies copy contains a non-regular file: $special"
                    return 1
                fi
                {
                    printf '# studies artifact inventory\n'
                    find "$EVIDENCE/studies-artifacts" -type f | LC_ALL=C sort | while IFS= read -r artifact; do
                        printf '%s  %s\n' "$(sha256_of "$artifact")" "${artifact#"$EVIDENCE/"}"
                    done
                } >"$EVIDENCE/08c-studies-inventory.txt"
                say "studies artifacts captured: $(find "$EVIDENCE/studies-artifacts" -type f | wc -l | tr -d ' ') files"
            else
                warn "could not copy studies artifacts out of the VM (see 08b-studies-copy.log)"
                return 1
            fi
            ;;
        *)
            usage_error "unknown lane: $lane"
            ;;
    esac
}

# ------------------------------------------------------------ container backend
container_podman() {
    if [ "$CONTAINER_PODMAN_SCOPED" = 1 ]; then
        podman --root "$VM_ROOT/containers/storage" \
            --runroot "$VM_ROOT/containers/runroot" \
            --storage-driver=vfs "$@"
    else
        podman "$@"
    fi
}

prepare_container() {
    write_containers_conf container
    # containers.conf points podman at the scoped config dir, so a signature
    # policy must exist there too. Prefer the host policy; otherwise accept the
    # pinned public QA image (the actually-pulled digest is recorded in the
    # evidence manifest).
    mkdir -p "$XDG_CONFIG_HOME/containers"
    policy="$XDG_CONFIG_HOME/containers/policy.json"
    if [ ! -f "$policy" ]; then
        for candidate in /etc/containers/policy.json /usr/share/containers/policy.json; do
            if [ -r "$candidate" ]; then
                cp "$candidate" "$policy"
                break
            fi
        done
    fi
    if [ ! -f "$policy" ]; then
        printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' >"$policy"
    fi
    chmod 600 "$policy"
    if podman --root "$VM_ROOT/containers/storage" --runroot "$VM_ROOT/containers/runroot" \
        --storage-driver=vfs info >/dev/null 2>&1; then
        CONTAINER_PODMAN_SCOPED=1
    else
        warn "rootless podman does not accept scoped --root/--runroot here; using scoped HOME storage"
    fi
    say "pulling pinned container image $CONTAINER_IMAGE (first run may take a while)"
    if [ "$OFFLINE" = 1 ]; then
        fail "offline: container image must already be present"
    fi
    container_podman pull "$CONTAINER_IMAGE" >>"$EVIDENCE/01-provisioning.log" 2>&1 ||
        fail "container image pull failed (see 01-provisioning.log)"
    CONTAINER_DIGEST=$(container_podman image inspect --format '{{.Digest}}' "$CONTAINER_IMAGE" 2>/dev/null || printf 'unknown')
    meta container_image "$CONTAINER_IMAGE"
    meta container_digest "$CONTAINER_DIGEST"
    [ -d "$STAGE" ] || fail "container stage missing: $STAGE"
}

container_lane() {
    id=container
    log_name=03-container-lane.log
    log="$EVIDENCE/$log_name"
    probe_script="$STAGE/container-probe.sh"
    cat >"$probe_script" <<'CONTAINER_PROBE'
set -eu
cd /stage
bin=/stage/zig-out/bin/xsprof
$bin version
$bin help >/dev/null
$bin why --json --input /stage/fixtures/ui/healthy.ndjson > /evidence/container-why.json
grep -q '"schema":"xsprof/why/v1"' /evidence/container-why.json
grep -q '"host_mutation":false' /evidence/container-why.json
$bin snapshot --replay /stage/fixtures/ui/healthy.ndjson --out /evidence/container-snapshot.png --width 320 --height 240
[ -s /evidence/container-snapshot.png ]
echo container_lane: PASS
CONTAINER_PROBE
    chmod 755 "$probe_script"
    {
        printf '# gate=%s\ndate=%s\nimage=%s\n---\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CONTAINER_IMAGE"
    } >"$log"
    rc=0
    container_podman run --rm --read-only --network=none --userns=keep-id \
        --cap-drop=all --security-opt=no-new-privileges \
        --tmpfs /tmp:rw,size=64m \
        -v "$STAGE:/stage:ro" -v "$EVIDENCE:/evidence:rw" \
        "$CONTAINER_IMAGE" sh /stage/container-probe.sh >>"$log" 2>&1 || rc=$?
    printf -- '\n---\nexit=%s\n' "$rc" >>"$log"
    status=FAIL
    if [ "$rc" -eq 0 ] &&
        grep -Fq "container_lane: PASS" "$log" &&
        grep -Fq "xsprof $VERSION" "$log"; then
        status=PASS
    fi
    record_gate "$id" "$status" "$rc" "$log_name" "container_lane: PASS"
    say "$status $id (exit $rc)"
    [ "$status" = PASS ]
}

container_analysis_lane() {
    id=container-analysis
    log_name=04-container-analysis.log
    log="$EVIDENCE/$log_name"
    analysis_script="$STAGE/container-analysis.sh"
    cat >"$analysis_script" <<'CONTAINER_ANALYSIS'
set -eu
cd /stage
bin=/stage/zig-out/bin/xsprof
$bin metrics --json --input /stage/fixtures/ui/healthy.ndjson > /evidence/container-metrics.json
grep -q '"schema":"xsprof/metrics/v1"' /evidence/container-metrics.json
grep -q '"host_mutation":false' /evidence/container-metrics.json
$bin validate --schema event.v1 --file /stage/fixtures/ui/healthy.ndjson
echo container_analysis: PASS
CONTAINER_ANALYSIS
    chmod 755 "$analysis_script"
    {
        printf '# gate=%s\ndate=%s\nimage=%s\n---\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CONTAINER_IMAGE"
    } >"$log"
    rc=0
    container_podman run --rm --read-only --network=none --userns=keep-id \
        --cap-drop=all --security-opt=no-new-privileges \
        --tmpfs /tmp:rw,size=64m \
        -v "$STAGE:/stage:ro" -v "$EVIDENCE:/evidence:rw" \
        "$CONTAINER_IMAGE" sh /stage/container-analysis.sh >>"$log" 2>&1 || rc=$?
    printf -- '\n---\nexit=%s\n' "$rc" >>"$log"
    status=FAIL
    if [ "$rc" -eq 0 ] && grep -Fq "container_analysis: PASS" "$log"; then
        status=PASS
    fi
    record_gate "$id" "$status" "$rc" "$log_name" "container_analysis: PASS"
    say "$status $id (exit $rc)"
    [ "$status" = PASS ]
}

# ------------------------------------------------------------------ write audit
audit_begin() {
    AUDIT_MODES=1
    AUDIT_START=$(date -u +%s)
    : >"$EVIDENCE/audit-violations.txt"
    : >"$EVIDENCE/audit.log"
    printf 'start_utc=%s\nreal_home=%s\nvm_root=%s\nroot=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REAL_HOME" "$VM_ROOT" "$ROOT" >>"$EVIDENCE/audit.log"
}

audit_end() {
    [ "$AUDIT_MODES" = 1 ] || return 0
    # Full inventory of user-visible locations newer than the run start. /tmp is
    # deliberately excluded: it is a shared, system-wide namespace with
    # unrelated writers, so a post-hoc inventory cannot attribute writes; TMPDIR
    # is pinned to $ROOT/.vm instead. The inventory is informational because a
    # desktop/live agent session writes to $HOME concurrently.
    : >"$EVIDENCE/audit-inventory.txt"
    for dir in "$REAL_HOME" /var/tmp "/run/user/$(id -u)"; do
        [ -d "$dir" ] || continue
        find "$dir" -xdev -newermt "@$AUDIT_START" \( -type f -o -type l \) -print 2>/dev/null
    done | while IFS= read -r path; do
        case "$path" in
            "$ROOT" | "$ROOT"/*) ;;
            *) printf '%s\n' "$path" >>"$EVIDENCE/audit-inventory.txt" ;;
        esac
    done
    # Hard violations: locations only this lab's tooling (podman, qemu, gvproxy,
    # virtiofsd, xsprof-lab state) would create. These prove the scoped
    # HOME/XDG/TMPDIR pinning held; unrelated desktop/session writes do not.
    # Pre-existing container state directories are only violations when the run
    # touched them, and the agent session store under .dsh is unrelated (its
    # path embeds the workspace name, so a plain substring match would misfire).
    {
        grep -Ei '(/containers/|podman|qemu|gvproxy|virtiofsd|xsprof-lab)' \
            "$EVIDENCE/audit-inventory.txt" 2>/dev/null |
            grep -v -F "$REAL_HOME/.dsh/" || true
        for tool_path in \
            "$REAL_HOME/.local/share/containers" \
            "$REAL_HOME/.config/containers" \
            "$REAL_HOME/.cache/containers" \
            "$REAL_HOME/.ssh/podman-machine-default" ; do
            [ -e "$tool_path" ] || continue
            if [ -n "$(find "$tool_path" -xdev -newermt "@$AUDIT_START" -print -quit 2>/dev/null)" ]; then
                printf '%s\n' "$tool_path"
            fi
        done
    } | sort -u >"$EVIDENCE/audit-violations.txt"
    violations=$(wc -l <"$EVIDENCE/audit-violations.txt" | tr -d ' ')
    inventory_count=$(wc -l <"$EVIDENCE/audit-inventory.txt" | tr -d ' ')
    if [ "$violations" -eq 0 ]; then
        audit_status=PASS
    else
        audit_status=FAIL
    fi
    {
        printf 'method=inventory(newer-than-start) with tool-owned hard checks\n'
        printf 'allowlist=%s\n' "$ROOT"
        printf 'inventory_count=%s (informational; shared desktop/session writes)\n' "$inventory_count"
        printf 'status=%s\nviolations=%s\n' "$audit_status" "$violations"
        printf -- '--- hard violations ---\n'
        cat "$EVIDENCE/audit-violations.txt"
        printf -- '--- full inventory (first 100) ---\n'
        head -n 100 "$EVIDENCE/audit-inventory.txt"
    } >>"$EVIDENCE/audit.log"
    meta audit_status "$audit_status"
    meta audit_method "inventory+tool-paths"
    meta audit_violations "$violations"
    say "$audit_status audit-writes (hard violations=$violations; inventory=$inventory_count)"
    [ "$audit_status" = PASS ]
}

# ---------------------------------------------------------------------- engine
write_manifest() { # EXIT_CODE
    exit_code=$1
    meta finished_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    meta exit_code "$exit_code"
    python3 - "$EVIDENCE" <<'PY'
import json
import sys

ev = sys.argv[1]
meta = {}
with open(ev + "/meta.tsv", "r", encoding="utf-8") as handle:
    for line in handle:
        key, _, value = line.rstrip("\n").partition("\t")
        meta[key] = value
gates = []
try:
    with open(ev + "/gates.tsv", "r", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) != 6:
                continue
            exit_value = int(fields[2]) if fields[2].lstrip("-").isdigit() else None
            gates.append({
                "exit": exit_value,
                "id": fields[0],
                "log": fields[3],
                "log_sha256": fields[5],
                "marker": fields[4],
                "status": fields[1],
            })
except FileNotFoundError:
    pass


def as_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# The manifest must never claim success while a recorded gate is not PASS.
all_gates_pass = bool(gates) and all(gate.get("status") == "PASS" for gate in gates)
exit_code = as_int(meta.get("exit_code"), 1)
if gates and not all_gates_pass:
    exit_code = 1

manifest = {
    "all_gates_pass": all_gates_pass,
    "audit": {
        "method": meta.get("audit_method", "none"),
        "status": meta.get("audit_status", "SKIP"),
        "violations": as_int(meta.get("audit_violations"), 0),
    },
    "backend": meta.get("backend", "unknown"),
    "binary": {
        "sha256": meta.get("binary_sha256", ""),
        "source": meta.get("binary_source", ""),
        "version": meta.get("binary_version", ""),
    },
    "command": meta.get("command", ""),
    "exit_code": exit_code,
    "finished_utc": meta.get("finished_utc", ""),
    "gates": gates,
    "git": {
        "dirty": meta.get("git_dirty", "false") == "true",
        "head": meta.get("git_head", ""),
    },
    "host": {
        "arch": meta.get("host_arch", ""),
        "kernel": meta.get("host_kernel", ""),
        "nproc": as_int(meta.get("host_nproc"), 0),
        "podman": meta.get("host_podman", ""),
    },
    "host_mutation": False,
    "run_id": meta.get("run_id", ""),
    "schema": "xsprof/vm-evidence/v1",
    "started_utc": meta.get("started_utc", ""),
    "vm": {
        "image_digest": meta.get("vm_image_digest", ""),
        "guest_os": meta.get("vm_os", ""),
        "kernel": meta.get("vm_kernel", ""),
        "machine": meta.get("machine", ""),
        "perf_event_paranoid": meta.get("vm_perf_event_paranoid", ""),
        "tracefs": meta.get("vm_tracefs", ""),
    },
}
if manifest["backend"] == "podman-container":
    manifest["container"] = {
        "digest": meta.get("container_digest", ""),
        "image": meta.get("container_image", ""),
    }
canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
with open(ev + "/manifest.json", "w", encoding="utf-8") as handle:
    handle.write(canonical)
print(ev + "/manifest.json")
PY
    say "manifest=$EVIDENCE/manifest.json"
}

bundle_evidence() {
    # Defense in depth: never package a run as release evidence unless the
    # manifest is green and every recorded gate is PASS.
    if ! python3 - "$EVIDENCE/manifest.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if data.get("exit_code") != 0:
    raise SystemExit("bundle: manifest exit_code is not 0")
for gate in data.get("gates", []):
    if gate.get("status") != "PASS":
        raise SystemExit("bundle: gate %s is %s" % (gate.get("id"), gate.get("status")))
PY
    then
        warn "refusing to bundle a run whose manifest is not all-PASS"
        return 1
    fi
    if sh "$ROOT/tools/vm_evidence.sh" bundle --run "$EVIDENCE" >"$EVIDENCE/bundle.log" 2>&1; then
        bundle_path=$(tail -n 1 "$EVIDENCE/bundle.log")
        say "bundled evidence: $bundle_path"
    else
        warn "evidence bundle failed (see bundle.log)"
        return 1
    fi
}

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$MACHINE_CREATED" = 1 ] && [ "$MACHINE_DESTROYED" = 0 ] && [ "$KEEP" != 1 ]; then
        podman machine rm -f "$MACHINE" >/dev/null 2>&1 ||
            warn "could not remove podman machine $MACHINE; run: podman machine rm -f $MACHINE"
    fi
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    exit "$rc"
}

cmd_clean() {
    [ "$(id -u)" != 0 ] || fail "refusing to run as root"
    command -v podman >/dev/null 2>&1 || fail "podman is required to clean machine state"
    VM_ROOT=$(ensure_inside_repo "$VM_ROOT")
    EVIDENCE_ROOT=$(ensure_inside_repo "$EVIDENCE_ROOT")
    setup_scoped_env
    if [ -d "$VM_ROOT/lab.lock" ]; then
        fail "another vm_lab run appears active ($VM_ROOT/lab.lock); refusing to clean"
    fi
    if [ -d "$VM_ROOT" ]; then
        for name in $(podman machine ls --format '{{.Name}}' 2>/dev/null | grep -E '^xsprof-lab-' || true); do
            say "removing podman machine $name"
            podman machine rm -f "$name" >/dev/null 2>&1 || warn "could not remove machine $name"
        done
    fi
    if [ "$EVIDENCE_ONLY" = 1 ]; then
        rm -rf "$EVIDENCE_ROOT"
        say "removed evidence root $EVIDENCE_ROOT"
    fi
    rm -rf "$VM_ROOT"
    say "removed lab root $VM_ROOT"
}

cmd_selftest() {
    # Offline regression for the release-evidence fail-closed invariants. No
    # podman, no VM, no network: only the gate-aggregation and bundling guards.
    tmp_root="$ROOT/.vm/tmp"
    mkdir -p "$tmp_root"
    tmp=$(mktemp -d "$tmp_root/vm-lab-selftest.XXXXXX") || fail "selftest: cannot create a temp dir"
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    mkdir -p "$tmp/evidence"
    : >"$tmp/evidence/gates.tsv"
    printf 'probe\tPASS\t0\t02-probe.log\tvm readiness\t-\n' >>"$tmp/evidence/gates.tsv"
    [ "$(gates_bad_count "$tmp/evidence/gates.tsv")" -eq 0 ] ||
        fail "selftest: all-PASS table was counted as failing"
    printf 'stacks\tFAIL\t1\t07-stack-smoke.log\tstack_smoke: PASS\t-\n' >>"$tmp/evidence/gates.tsv"
    [ "$(gates_bad_count "$tmp/evidence/gates.tsv")" -eq 1 ] ||
        fail "selftest: a FAIL row was not counted"
    printf 'studies\tREFUSE\t-\trefuse-studies.log\t-\t-\n' >>"$tmp/evidence/gates.tsv"
    [ "$(gates_bad_count "$tmp/evidence/gates.tsv")" -eq 2 ] ||
        fail "selftest: a REFUSE row was not counted"
    # A manifest that claims exit_code=0 while a gate is FAIL must be refused by
    # the bundling guard (this is exactly the class of false-PASS bug the
    # full-lane integration run caught).
    python3 - "$tmp/evidence/manifest.json" <<'PY'
import json
import sys

data = {
    "all_gates_pass": False,
    "exit_code": 0,
    "gates": [{"exit": 1, "id": "stacks", "status": "FAIL"}],
    "host_mutation": False,
    "run_id": "selftest",
    "schema": "xsprof/vm-evidence/v1",
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
PY
    saved_evidence=$EVIDENCE
    EVIDENCE="$tmp/evidence"
    if bundle_evidence >/dev/null 2>&1; then
        EVIDENCE=$saved_evidence
        fail "selftest: bundle guard accepted a manifest with a FAIL gate"
    fi
    EVIDENCE=$saved_evidence
    if [ -e "$tmp/evidence/bundle.log" ]; then
        fail "selftest: bundle guard still attempted to run vm_evidence"
    fi
    say "selftest: PASS (gate aggregation and bundle guard fail closed)"
}

do_probe() {
    prepare_kvm
    prepare_binary
    stage_workspace
    stage_kvm
    if [ "$AUDIT_WRITES" = 1 ]; then audit_begin; fi
    rc=0
    kvm_probe || rc=$?
    if [ "$AUDIT_WRITES" = 1 ]; then
        audit_end || rc=1
    fi
    if [ "$rc" -eq 0 ]; then say "PASS probe (backend=$BACKEND)"; fi
    return "$rc"
}

do_container_probe() {
    prepare_binary
    stage_workspace
    prepare_container
    if [ "$AUDIT_WRITES" = 1 ]; then audit_begin; fi
    rc=0
    container_lane || rc=$?
    if [ "$AUDIT_WRITES" = 1 ]; then
        audit_end || rc=1
    fi
    if [ "$rc" -eq 0 ]; then say "PASS probe (backend=$BACKEND)"; fi
    return "$rc"
}

do_gates() {
    case "$BACKEND" in
        kvm-machine)
            prepare_kvm
            prepare_binary
            stage_workspace
            stage_kvm
            if [ "$AUDIT_WRITES" = 1 ]; then audit_begin; fi
            # Functions share the shell's global variables, so never read `rc`
            # after a lane helper ran; derive the status from the helper itself.
            if run_lanes_kvm; then rc=0; else rc=1; fi
            if [ "$AUDIT_WRITES" = 1 ]; then
                audit_end || rc=1
            fi
            if [ "$rc" -eq 0 ]; then say "PASS gates (backend=$BACKEND)"; fi
            return "$rc"
            ;;
        podman-container)
            prepare_binary
            stage_workspace
            prepare_container
            if [ "$AUDIT_WRITES" = 1 ]; then audit_begin; fi
            if run_lanes_container; then rc=0; else rc=1; fi
            if [ "$AUDIT_WRITES" = 1 ]; then
                audit_end || rc=1
            fi
            if [ "$rc" -eq 0 ]; then say "PASS gates (backend=$BACKEND)"; fi
            return "$rc"
            ;;
    esac
}

run_lanes_kvm() {
    if [ "$ALL_LANES" = 1 ]; then
        lanes="probe live service retention"
        if [ -f "$SRC_ROOT/qa/latency_smoke.sh" ]; then lanes="$lanes latency"; fi
        if [ -f "$SRC_ROOT/qa/stack_smoke.sh" ]; then lanes="$lanes stacks"; fi
        if [ -f "$SRC_ROOT/qa/studies/run_studies.sh" ]; then lanes="$lanes studies"; fi
    else
        lanes=${LANES:-probe}
    fi
    overall=0
    for lane in $(printf '%s' "$lanes" | tr ',' ' '); do
        kvm_run_lane "$lane" || overall=1
    done
    return "$overall"
}

run_lanes_container() {
    desired=${LANES:-container}
    if [ "$ALL_LANES" = 1 ]; then
        desired=container
    fi
    overall=0
    for lane in $(printf '%s' "$desired" | tr ',' ' '); do
        case "$lane" in
            container | container-lane | probe | live | service | retention | latency | stacks | studies)
                case "$lane" in
                    container | container-lane) container_lane || overall=1 ;;
                    *)
                        record_refuse "$lane" "gate '$lane' needs root and readable tracefs; use --backend kvm-machine"
                        rc=1
                        ;;
                esac
                ;;
            container-analysis) container_analysis_lane || overall=1 ;;
            *)
                usage_error "unknown lane: $lane"
                ;;
        esac
    done
    return "$overall"
}

main() {
    parse_args "$@"
    case "$CMD" in
        help | -h | --help)
            usage
            exit 0
            ;;
        clean)
            cmd_clean
            exit 0
            ;;
        selftest)
            cmd_selftest
            exit 0
            ;;
    esac
    preflight
    make_run
    select_backend
    meta backend "$BACKEND"
    rc=0
    case "$CMD" in
        probe)
            if [ "$BACKEND" = kvm-machine ]; then
                do_probe || rc=$?
            else
                do_container_probe || rc=$?
            fi
            ;;
        gates)
            do_gates || rc=$?
            ;;
        audit-writes)
            AUDIT_WRITES=1
            if [ "$BACKEND" = kvm-machine ]; then
                do_probe || rc=$?
            else
                do_container_probe || rc=$?
            fi
            ;;
    esac
    # Defense in depth: the lane helpers share the shell's global variables, so
    # derive the final status from the recorded gate table as well as the return
    # codes. A FAIL row always fails the run and blocks bundling.
    if [ -f "$EVIDENCE/gates.tsv" ]; then
        bad_gates=$(gates_bad_count "$EVIDENCE/gates.tsv")
        if [ "$bad_gates" -gt 0 ]; then
            warn "gate table records ${bad_gates} non-PASS gate(s); marking the run failed"
            rc=1
        fi
    fi
    if ! write_manifest "$rc" >/dev/null; then
        warn "could not write evidence manifest"
        rc=1
    fi
    if [ "$JSON_OUT" = 1 ]; then
        cat "$EVIDENCE/manifest.json" 2>/dev/null || true
    fi
    if [ "$BUNDLE" = 1 ] && [ "$rc" -eq 0 ]; then
        bundle_evidence || rc=1
    fi
    say "evidence=$EVIDENCE"
    exit "$rc"
}

main "$@"
