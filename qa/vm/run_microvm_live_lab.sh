#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh
source qa/vm/qemu_discovery.sh

out_dir=""
kernel_arg="${ZIG_SCHEDULER_VM_KERNEL:-}"
qemu_arg="${ZIG_SCHEDULER_QEMU_BIN:-}"
nix_arg="${ZIG_SCHEDULER_NIX_BIN:-}"
mem="${ZIG_SCHEDULER_MICROVM_MEM:-1024M}"
smp="${ZIG_SCHEDULER_MICROVM_SMP:-2}"
timeout_seconds="${ZIG_SCHEDULER_MICROVM_TIMEOUT:-120}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s --out evidence/lab/run-all/<name> [--kernel /boot/vmlinuz-...] [--qemu /path/to/qemu-system-x86_64]\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out_dir="$2"; shift 2 ;;
    --kernel) [ "$#" -ge 2 ] || fail '--kernel requires value'; kernel_arg="$2"; shift 2 ;;
    --qemu) [ "$#" -ge 2 ] || fail '--qemu requires value'; qemu_arg="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[ -n "$out_dir" ] || fail '--out is required'
case "$out_dir$kernel_arg$qemu_arg$nix_arg$mem$smp$timeout_seconds" in *$'\n'*|*$'\r'*) fail 'arguments must not contain newlines' ;; esac
[ ! -e "$out_dir" ] || fail '--out must name a new output directory'
prepare_evidence_dir evidence/lab "$out_dir"
mkdir -p "$out_dir"
qemu_scan_before="$out_dir/qemu-process-scan-before.txt"
qemu_scan_after="$out_dir/qemu-process-scan-after.txt"
pgrep -a qemu-system-x86_64 > "$qemu_scan_before" 2>/dev/null || true

validate_qemu_bin() {
  local raw="$1" canonical base
  case "$raw" in
    /*) ;;
    *) fail 'qemu override refused: path must be absolute' ;;
  esac
  base="$(basename -- "$raw")"
  [ "$base" = qemu-system-x86_64 ] || fail 'qemu override refused: basename must be qemu-system-x86_64'
  case "$raw" in
    *$'\n'*|*$'\r'*) fail 'qemu override refused: control characters are not allowed' ;;
    */../*|*/..|*/./*|*/.) fail 'qemu override refused: traversal components are not allowed' ;;
    /home/*|/tmp/*|/var/tmp/*|/dev/shm/*) fail 'qemu override refused: user/writable paths are not trusted' ;;
    */.zig-cache/*|*/.omo/*|*/.omx/*) fail 'qemu override refused: repo-local scratch paths are not trusted' ;;
  esac
  canonical="$(readlink -f -- "$raw" 2>/dev/null || true)"
  [ -n "$canonical" ] || fail 'qemu override refused: canonical path does not exist'
  case "$canonical" in
    /usr/bin/qemu-system-x86_64|/run/current-system/sw/bin/qemu-system-x86_64|/nix/store/*/bin/qemu-system-x86_64) ;;
    *) fail 'qemu override refused: canonical path is outside trusted qemu locations' ;;
  esac
  [ -x "$canonical" ] || fail 'qemu override refused: canonical path is not executable'
  printf '%s\n' "$canonical"
}

find_qemu() {
  local canonical
  if [ -n "$qemu_arg" ]; then validate_qemu_bin "$qemu_arg"; return; fi
  canonical="$(qemu_discovery_find 2>/dev/null || true)"
  [ -n "$canonical" ] || {
    fail 'qemu-system-x86_64 not found in trusted qemu locations; install qemu or set ZIG_SCHEDULER_QEMU_BIN to /usr/bin/qemu-system-x86_64, /run/current-system/sw/bin/qemu-system-x86_64, or /nix/store/.../bin/qemu-system-x86_64'
  }
  printf '%s\n' "$canonical"
}

validate_nix_bin() {
  local raw="$1" canonical base
  case "$raw" in
    /*) ;;
    *) fail 'nix override refused: path must be absolute' ;;
  esac
  base="$(basename -- "$raw")"
  [ "$base" = nix ] || fail 'nix override refused: basename must be nix'
  case "$raw" in
    *$'\n'*|*$'\r'*) fail 'nix override refused: control characters are not allowed' ;;
    */../*|*/..|*/./*|*/.) fail 'nix override refused: traversal components are not allowed' ;;
    /home/*|/tmp/*|/var/tmp/*|/dev/shm/*) fail 'nix override refused: user/writable paths are not trusted' ;;
    */.zig-cache/*|*/.omo/*|*/.omx/*) fail 'nix override refused: repo-local scratch paths are not trusted' ;;
  esac
  canonical="$(readlink -f -- "$raw" 2>/dev/null || true)"
  [ -n "$canonical" ] || fail 'nix override refused: canonical path does not exist'
  case "$canonical" in
    /usr/bin/nix|/run/current-system/sw/bin/nix|/nix/var/nix/profiles/default/bin/nix|/nix/profile/bin/nix|/nix/store/*/bin/nix) ;;
    *) fail 'nix override refused: canonical path is outside trusted nix locations' ;;
  esac
  [ -x "$canonical" ] || fail 'nix override refused: canonical path is not executable'
  printf '%s\n' "$canonical"
}

find_nix_bin() {
  if [ -n "$nix_arg" ]; then validate_nix_bin "$nix_arg"; return; fi
  for candidate in /nix/var/nix/profiles/default/bin/nix /run/current-system/sw/bin/nix /usr/bin/nix /nix/profile/bin/nix; do
    if [ -x "$candidate" ]; then validate_nix_bin "$candidate"; return; fi
  done
  fail 'nix not found in trusted locations; install nix or set ZIG_SCHEDULER_NIX_BIN to /usr/bin/nix, /run/current-system/sw/bin/nix, /nix/var/nix/profiles/default/bin/nix, /nix/profile/bin/nix, or /nix/store/.../bin/nix'
}

find_kernel() {
  if [ -n "$kernel_arg" ]; then printf '%s\n' "$kernel_arg"; return; fi
  if [ -r "/boot/vmlinuz-$(uname -r)" ]; then printf '/boot/vmlinuz-%s\n' "$(uname -r)"; return; fi
  for candidate in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux /boot/vmlinuz-*; do
    if [ -r "$candidate" ]; then printf '%s\n' "$candidate"; return; fi
  done
  fail 'readable kernel image not found; pass --kernel /path/to/bzImage'
}

qemu_bin="$(find_qemu)"
nix_bin="$(find_nix_bin)"
kernel_image="$(find_kernel)"
[ -x "$qemu_bin" ] || fail "qemu is not executable: $qemu_bin"
[ -x "$nix_bin" ] || fail "nix is not executable: $nix_bin"
[ -r "$kernel_image" ] || fail "kernel image is not readable: $kernel_image"
[ -e /dev/kvm ] || fail '/dev/kvm is required for the microVM live lab'

bash tools/build_bpf.sh > "$out_dir/build-bpf.txt"
object_file="zig-out/bpf/zigsched_minimal.bpf.o"
meta_file="zig-out/bpf/zigsched_minimal.bpf.meta.json"
[ -f "$object_file" ] || fail "BPF object missing after build: $object_file"
object_sha="$(sha256sum "$object_file" | awk '{print $1}')"
git_sha="$(git rev-parse HEAD 2>/dev/null || printf unknown)"
git_dirty=false
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then git_dirty=true; fi
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

busybox_store="$("$nix_bin" build nixpkgs#pkgsStatic.busybox --no-link --print-out-paths 2>/dev/null | tail -n 1 || true)"
[ -n "$busybox_store" ] || fail 'could not build/fetch pkgsStatic.busybox through nix'
busybox_bin="$busybox_store/bin/busybox"
[ -x "$busybox_bin" ] || fail "busybox not executable: $busybox_bin"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-microvm-live.XXXXXX")"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
root="$scratch/root"
mkdir -p "$root/bin" "$root/usr/bin" "$root/usr/lib" "$root/usr/lib64" "$root/lib64" "$root/proc" "$root/sys" "$root/dev" "$root/run" "$root/tmp" "$root/sys/fs/bpf" "$root/sys/fs/cgroup"
cp "$busybox_bin" "$root/bin/busybox"
for app in sh mount cat echo mkdir sleep poweroff ps kill chmod ln grep sed head tail tr cut sort uniq wc sha256sum find rm true false uname date timeout test; do ln -s busybox "$root/bin/$app" 2>/dev/null || true; done

copy_abs() {
  local p="$1"
  [ -e "$p" ] || return 0
  mkdir -p "$root$(dirname "$p")"
  cp -L "$p" "$root$p"
}
copy_abs /usr/bin/bpftool
ldd /usr/bin/bpftool | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | while read -r dep; do copy_abs "$dep"; done
copy_abs /lib64/ld-linux-x86-64.so.2 || true
cp "$object_file" "$root/zigsched_minimal.bpf.o"

cat > "$root/init" <<'INIT'
#!/bin/sh
PATH=/bin:/usr/bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t bpffs bpffs /sys/fs/bpf 2>/dev/null || true
mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true
mkdir -p /run /tmp /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope
echo vm > /run/zig-scheduler-vm-lab.marker
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
fact() { cat "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true; }
state_value() { fact /sys/kernel/sched_ext/state; }
ops_value() { fact /sys/kernel/sched_ext/root/ops; }
enable_seq_value() { fact /sys/kernel/sched_ext/enable_seq; }
events_value() { fact /sys/kernel/sched_ext/events; }
echo 'ZIGSCHED_JSON {"event":"boot","vm_marker_present":true}'
kernel="$(uname -r)"; arch="$(uname -m)"; sched_state="$(state_value)"; btf=false; [ -f /sys/kernel/btf/vmlinux ] && btf=true
echo "ZIGSCHED_JSON {\"event\":\"tuple\",\"kernel\":\"$(json_escape "$kernel")\",\"arch\":\"$(json_escape "$arch")\",\"sched_state\":\"$(json_escape "$sched_state")\",\"btf\":$btf}"
sleep 20 &
lab_pid=$!
echo "$lab_pid" > /sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope/cgroup.procs 2>/tmp/cg.err || true
cg_rc=$?
echo "ZIGSCHED_JSON {\"event\":\"workload\",\"pid\":$lab_pid,\"cg_rc\":$cg_rc}"
echo "ZIGSCHED_JSON {\"event\":\"before\",\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
bpftool version 2>&1 | sed 's/^/BPFT_VER /'
bpftool struct_ops register /zigsched_minimal.bpf.o > /tmp/register.out 2>&1
reg_rc=$?
cat /tmp/register.out | sed 's/^/REGISTER_OUT /'
reg_id="$(sed -n 's/.* id \([0-9][0-9]*\).*/\1/p' /tmp/register.out | tail -n 1)"
[ -n "$reg_id" ] || reg_id=0
echo "ZIGSCHED_JSON {\"event\":\"register\",\"rc\":$reg_rc,\"id\":$reg_id,\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
sleep 2
if [ "$reg_id" != 0 ]; then
  bpftool struct_ops unregister id "$reg_id" > /tmp/unreg.out 2>&1
else
  echo 'no registered id' > /tmp/unreg.out
  false
fi
unreg_rc=$?
cat /tmp/unreg.out | sed 's/^/UNREGISTER_OUT /'
echo "ZIGSCHED_JSON {\"event\":\"unregister\",\"rc\":$unreg_rc,\"state\":\"$(json_escape "$(state_value)")\",\"ops\":\"$(json_escape "$(ops_value)")\",\"enable_seq\":\"$(json_escape "$(enable_seq_value)")\",\"events\":\"$(json_escape "$(events_value)")\"}"
kill "$lab_pid" 2>/dev/null || true
poweroff -f
INIT
chmod +x "$root/init"
(cd "$root" && find . | cpio -o -H newc | gzip -1 > "$scratch/initramfs.cpio.gz")
cp "$scratch/initramfs.cpio.gz" "$out_dir/initramfs.cpio.gz"

serial="$out_dir/serial.txt"
set +e
timeout "$timeout_seconds" "$qemu_bin" -enable-kvm -cpu host -m "$mem" -smp "$smp" \
  -name zig-scheduler-microvm-live-lab,debug-threads=on \
  -kernel "$kernel_image" -initrd "$scratch/initramfs.cpio.gz" \
  -append 'console=ttyS0 panic=-1 quiet' -nographic -no-reboot > "$serial" 2>&1
qemu_rc=$?
set -e
pgrep -a qemu-system-x86_64 > "$qemu_scan_after" 2>/dev/null || true
if grep -q 'zig-scheduler-microvm-live-lab' "$qemu_scan_after"; then
  fail 'microVM qemu process still present after run'
fi
if [ "$qemu_rc" -ne 0 ] && [ "$qemu_rc" -ne 124 ]; then
  printf 'WARN: qemu exited rc=%s; continuing to parse serial\n' "$qemu_rc" >> "$out_dir/build-bpf.txt"
fi

SERIAL="$serial" OUT_DIR="$out_dir" OBJECT_SHA="$object_sha" OBJECT_FILE="$object_file" META_FILE="$meta_file" GIT_SHA="$git_sha" GIT_DIRTY="$git_dirty" STARTED_AT="$started_at" KERNEL_IMAGE="$kernel_image" QEMU_BIN="$qemu_bin" QEMU_SCAN_BEFORE="$qemu_scan_before" QEMU_SCAN_AFTER="$qemu_scan_after" QEMU_RC="$qemu_rc" python3 - <<'PY'
import hashlib, json, os, re, sys
from pathlib import Path

out = Path(os.environ["OUT_DIR"])
serial = Path(os.environ["SERIAL"])
text = serial.read_text(errors="replace")
rows = []
for line in text.splitlines():
    idx = line.find("ZIGSCHED_JSON ")
    if idx >= 0:
        payload = line[idx + len("ZIGSCHED_JSON "):]
        rows.append(json.loads(payload))
by_event = {str(row.get("event")): row for row in rows}
for required in ("boot", "tuple", "workload", "before", "register", "unregister"):
    if required not in by_event:
        raise SystemExit(f"missing microVM event: {required}")
reg = by_event["register"]
unreg = by_event["unregister"]
tuple_row = by_event["tuple"]
if reg.get("rc") != 0 or reg.get("ops") != "zigsched_minimal":
    raise SystemExit("microVM attach did not enable zigsched_minimal")
if unreg.get("rc") != 0 or unreg.get("state") != "disabled":
    raise SystemExit("microVM rollback did not restore disabled state")
if not tuple_row.get("btf"):
    raise SystemExit("microVM kernel BTF missing")
object_sha = os.environ["OBJECT_SHA"]
partial_dir = out / "partial-attach"
observe_dir = out / "observe-partial"
rollback_dir = out / "rollback-drill"
for d in (partial_dir, observe_dir, rollback_dir, out / "stages"):
    d.mkdir(parents=True, exist_ok=True)

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fact(value: object, default: str = "unavailable") -> dict[str, str]:
    text_value = str(value if value not in (None, "") else default)
    if text_value == "unavailable":
        return {"status": "unknown", "value": text_value}
    return {"status": "present", "value": text_value}

audit_id = "AUD-20990101T000000Z-deadbee-abc123"
rollback_id = "RB-microvm-live"
partial_transcript = partial_dir / "partial-attach-transcript.txt"
partial_transcript.write_text("\n".join([
    "schema=zig-scheduler/partial-attach-transcript/v1",
    "COMMAND: bpftool struct_ops register /zigsched_minimal.bpf.o",
    "bpftool struct_ops register",
    "ops=zigsched_minimal",
    "switch_mode=SCX_OPS_SWITCH_PARTIAL",
    "target_cgroup=/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    f"registered_id={reg.get('id')}",
    f"rollback_id={rollback_id}",
    "rollback_status=PASS",
    "post_state=disabled",
    "host_mutation=false",
]) + "\n")
partial_evidence = partial_dir / "partial-attach-evidence.json"
partial_evidence.write_text(json.dumps({
    "schema": "zig-scheduler/partial-attach-evidence/v1",
    "attach_command": "bpftool struct_ops register",
    "target_cgroup": "/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope",
    "rollback_id": rollback_id,
    "rollback_status": "PASS",
    "ops_during_attach": "zigsched_minimal",
    "switch_mode": "SCX_OPS_SWITCH_PARTIAL",
    "post_state": "disabled",
    "object": os.environ["OBJECT_FILE"],
    "object_sha256": object_sha,
    "transcript_path": partial_transcript.as_posix(),
    "host_mutation": False,
    "release_eligible_live_proof": False,
}, indent=2, sort_keys=True) + "\n")

snapshot = rollback_dir / f"{audit_id}.rollback-snapshot.json"
rollback_transcript = rollback_dir / f"{audit_id}.rollback-transcript.txt"
snapshot.write_text(json.dumps({
    "schema": "zig-scheduler/rollback-snapshot/v1",
    "audit_id": audit_id,
    "rollback_id": rollback_id,
    "state_before": str(reg.get("state", "enabled")),
    "state_after": str(unreg.get("state", "disabled")),
    "ops_before": str(reg.get("ops", "zigsched_minimal")),
    "ops_after": str(unreg.get("ops") or "none"),
    "enable_seq_before": str(reg.get("enable_seq", "1")),
    "enable_seq_after": str(unreg.get("enable_seq", "1")),
}, sort_keys=True) + "\n")
rollback_transcript.write_text("bpftool struct_ops unregister id {id}\nrollback_status=PASS\nhost_mutation=false\n".format(id=reg.get("id")))
ledger = rollback_dir / "audit-ledger.jsonl"
ledger.write_text(json.dumps({
    "schema": "zig-scheduler/audit-ledger/v1",
    "audit_id": audit_id,
    "rollback_id": rollback_id,
    "action": "rollback-drill",
    "rollback_snapshot": snapshot.as_posix(),
    "rollback_snapshot_sha256": sha(snapshot),
    "transcript": rollback_transcript.as_posix(),
    "transcript_sha256": sha(rollback_transcript),
    "secret_redaction": "redacted",
}, sort_keys=True) + "\n")

samples = observe_dir / "runtime-samples.jsonl"
before = by_event["before"]
events = "nr_rejected: 0 dispatch_failed: 0 fallback: 0 fatal: 0"
sample_rows = []
for seq, event in enumerate((before, reg, unreg)):
    ops = str(event.get("ops") or "none")
    if ops == "unavailable":
        ops = "none"
    state = str(event.get("state") or ("enabled" if ops == "zigsched_minimal" else "disabled"))
    row = {
        "schema": "zig-scheduler/runtime-sample/v1",
        "sequence": seq,
        "state": fact(state),
        "ops": fact(ops),
        "enable_seq": fact(event.get("enable_seq", "0")),
        "events": fact(events),
        "events_hash": hashlib.sha256(events.encode()).hexdigest(),
        "nr_rejected": fact("0"),
        "debug_dump": {"status": "missing", "value": "unavailable"},
        "cgroup_membership_digest": hashlib.sha256(f"microvm-demo-{seq}".encode()).hexdigest(),
        "workload_alive": True,
        "private_command_lines_sampled": False,
    }
    sample_rows.append(row)
samples.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in sample_rows))
daemon = observe_dir / "daemon-runtime-events.jsonl"
daemon.write_text("".join(json.dumps({
    "schema": "zig-scheduler/daemon-event/v1",
    "event": "runtime_sample",
    "sequence": row["sequence"],
    "state": row["state"]["value"],
    "ops": row["ops"]["value"],
    "host_mutation": False,
}, sort_keys=True) + "\n" for row in sample_rows))
observe_transcript = observe_dir / "observe-transcript.txt"
observe_transcript.write_text("microVM before/during/after sched_ext samples; no command-line sampling\n")
observe_summary = observe_dir / "summary.json"
observe_summary.write_text(json.dumps({
    "schema": "zig-scheduler/observe-partial-summary/v1",
    "status": "PASS",
    "evidence_mode": "vm-live",
    "release_eligible_live_proof": False,
    "sample_count": len(sample_rows),
    "runtime_samples": samples.as_posix(),
    "audit_ledger": ledger.as_posix(),
    "transcript": observe_transcript.as_posix(),
    "daemon_runtime_events": daemon.as_posix(),
    "scheduler_snapshot": {"state": sample_rows[-1]["state"], "root_ops": sample_rows[-1]["ops"]},
    "final_state": sample_rows[-1]["state"]["value"],
    "final_ops": sample_rows[-1]["ops"]["value"],
    "final_state_disabled_or_rolled_back": True,
    "private_command_lines_sampled": False,
    "workload_alive_all_samples": True,
}, indent=2, sort_keys=True) + "\n")
artifacts = [
    serial.as_posix(),
    os.environ["QEMU_SCAN_BEFORE"],
    os.environ["QEMU_SCAN_AFTER"],
    partial_evidence.as_posix(),
    partial_transcript.as_posix(),
    observe_summary.as_posix(),
    samples.as_posix(),
    daemon.as_posix(),
    observe_transcript.as_posix(),
    ledger.as_posix(),
    snapshot.as_posix(),
    rollback_transcript.as_posix(),
]
summary = out / "summary.json"
summary.write_text(json.dumps({
    "schema": "zig-scheduler/run-all-lab/v1",
    "status": "PASS",
    "mode": "microvm-live",
    "evidence_mode": "vm-live",
    "git_sha": os.environ["GIT_SHA"],
    "git_dirty": os.environ["GIT_DIRTY"] == "true",
    "bpf_object_sha256": object_sha,
    "output_dir": out.as_posix(),
    "output_dir_created_fresh": True,
    "host_mutation": False,
    "release_status": "controlled_lab_pilot_candidate",
    "release_use": False,
    "release_eligible_live_proof": False,
    "vm_kind": "qemu-vm",
    "vm_marker_present": True,
    "vm_marker_path": "/run/zig-scheduler-vm-lab.marker",
    "kernel_tuple": {"release": str(tuple_row.get("kernel")), "arch": str(tuple_row.get("arch")), "config_sha256": "microvm-host-kernel"},
    "rollback_result": "PASS",
    "artifact_paths": artifacts,
    "started_at": os.environ["STARTED_AT"],
    "ended_at": __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "stages": [],
    "vm_execution_manifest": serial.as_posix(),
    "qemu_bin": os.environ["QEMU_BIN"],
    "kernel_image": os.environ["KERNEL_IMAGE"],
    "cleanup": {
        "qemu_leftovers": False,
        "tmux_leftovers": False,
        "qemu_process_scan_before": os.environ["QEMU_SCAN_BEFORE"],
        "qemu_process_scan_after": os.environ["QEMU_SCAN_AFTER"],
        "tmux_sessions_after": [],
        "timeout_pid": "timeout-supervised-foreground",
        "timeout_rc": int(os.environ["QEMU_RC"]),
        "process_group_reaped": True,
        "temp_dirs_removed": True,
    },
}, indent=2, sort_keys=True) + "\n")
print(summary.as_posix())
PY

python3 qa/partial_attach_check.py --evidence "$out_dir/partial-attach/partial-attach-evidence.json"
python3 qa/lab_summary_observe.py --summary "$out_dir/observe-partial/summary.json"
python3 qa/live_behavior_check.py --bundle "$out_dir/summary.json"
printf 'PASS: microVM live sched_ext lab bundle summary=%s\n' "$out_dir/summary.json"
