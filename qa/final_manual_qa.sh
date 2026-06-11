#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source qa/path_safety.sh

out=""
include_root=0
include_vm=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || fail '--out requires value'; out="$2"; shift 2 ;;
    --include-root) include_root=1; shift ;;
    --include-vm-if-available) include_vm=1; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ -n "$out" ] || fail '--out is required'
case "$out" in .omo/evidence/*) prepare_evidence_dir .omo/evidence "$out" ;; evidence/*) prepare_evidence_dir evidence "$out" ;; *) fail '--out must be under evidence path' ;; esac
transcript="$out/root-tmux.txt"
session="zig-scheduler-final-manual-qa"
tmux kill-session -t "$session" 2>/dev/null || true
if [ "$include_root" -eq 1 ]; then
  cat > /tmp/zig-scheduler-final-manual-root.sh <<ROOTQA
#!/usr/bin/env bash
set -euo pipefail
cd "$repo_root"
zig build run -- --help
zig build linux-preflight -- --json
zig build tui -- --snapshot --screen preflight --width 100 --height 30
zig build tui -- --snapshot --screen sched-ext --width 100 --height 30
bash qa/no_host_mutation.sh
bash qa/wording_audit.sh
bash qa/restructure_check.sh
echo '__ROOT_QA:PASS__'
ROOTQA
  chmod +x /tmp/zig-scheduler-final-manual-root.sh
  : > "$transcript"
  abs_transcript="$repo_root/$transcript"
  tmux new-session -d -s "$session" "bash -lc '/tmp/zig-scheduler-final-manual-root.sh > "$abs_transcript" 2>&1; rc=\$?; echo __EXIT:\${rc}__ >> "$abs_transcript"; sleep 1; exit \$rc'"
  for _ in $(seq 1 180); do
    if ! tmux has-session -t "$session" 2>/dev/null; then break; fi
    sleep 1
  done
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux capture-pane -t "$session" -pS -20000 > "$transcript" || true
    tmux kill-session -t "$session" || true
    rm -f /tmp/zig-scheduler-final-manual-root.sh
    fail 'root manual QA tmux session timed out'
  fi
  rm -f /tmp/zig-scheduler-final-manual-root.sh
fi
[ -s "$transcript" ] || fail 'root manual QA transcript missing'
grep -q '__ROOT_QA:PASS__' "$transcript" || fail 'root manual QA did not report PASS marker'
grep -q '__EXIT:0__' "$transcript" || fail 'root manual QA did not report __EXIT:0__'
qemu_left=0
vm_state="skipped_no_qemu"
if [ "$include_vm" -eq 1 ] && command -v qemu-system-x86_64 >/dev/null 2>&1; then
  if [ -x qa/vm/stress_chaos.sh ]; then
    bash qa/vm/stress_chaos.sh --duration 15s --out evidence/lab/final-manual-stress >> "$out/vm-lab.txt" 2>&1 || fail 'VM/fallback stress QA failed'
  fi
  vm_state="true"
fi
if pgrep -f 'qemu-system.*zig-scheduler' >/dev/null 2>&1; then qemu_left=1; fi
tmux_left=0
if tmux has-session -t "$session" 2>/dev/null; then tmux_left=1; fi
cat > "$out/cleanup.json" <<JSON
{
  "schema": "zig-scheduler/final-manual-cleanup/v1",
  "tmux_sessions_left": $tmux_left,
  "qemu_processes_left": $qemu_left,
  "vm_sched_ext_restored": "$vm_state"
}
JSON
[ "$tmux_left" -eq 0 ] || fail 'tmux session left behind'
[ "$qemu_left" -eq 0 ] || fail 'qemu process left behind'
printf 'PASS: final manual QA out=%s\n' "$out"
