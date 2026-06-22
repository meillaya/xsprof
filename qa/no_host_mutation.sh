#!/usr/bin/env bash
# SIZE_OK: single shell command gate; syscall tracing, fallback probes, and assertions must stay in one audited bash entrypoint so CI/build invocations do not depend on sourced cleanup code that could mask host-mutation failures.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

microvm_tmp_before=""
nohost_tmp_root=""

cleanup_nohost_tmp() {
  if [ -n "${microvm_tmp_before:-}" ]; then
    rm -f -- "$microvm_tmp_before" || true
  fi
  if [ -n "${nohost_tmp_root:-}" ]; then
    rm -rf -- "$nohost_tmp_root" || true
  fi
  return 0
}

allow_no_strace_dev=false

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

have_strace() {
  command -v strace >/dev/null 2>&1
}

trace_contains_denied_mutation() {
  local trace_file="$1"
  {
    grep -En 'bpf\(BPF_(PROG_LOAD|LINK_CREATE)|sched_set(affinity|scheduler)\(|(setpriority|ioprio_set)\(' "$trace_file" || true
    grep -En '"[^"]*((/proc/sys|/sys)(/|")|cpuset|cgroup\.(procs|threads|subtree_control))[^"]*"[^\n]*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|flags=[^,}]*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND))' "$trace_file" || true
    grep -En '(creat|mkdir|mkdirat|unlink|unlinkat|rename|renameat|renameat2|chmod|fchmodat)\([^\n]*"[^"]*((/proc/sys|/sys)(/|")|cpuset|cgroup\.(procs|threads|subtree_control))[^"]*"' "$trace_file" || true
  } | awk '
    /\/tmp\/zigsched-/ && $0 !~ /"\/(sys|proc\/sys)(\/|")/ && $0 !~ /<\/(sys|proc\/sys)(\/|>)/ { next }
    { print }
  ' || true
}

assert_trace_clean() {
  local label="$1"
  local trace_file="$2"
  local denied
  denied="$(trace_contains_denied_mutation "$trace_file")"
  if [[ -n "$denied" ]]; then
    printf 'FAIL: denied host mutation detected in %s\n%s\n' "$label" "$denied" >&2
    return 1
  fi
}

run_command() {
  local label="$1"
  shift
  printf 'CHECK: %s\n' "$label"
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.out.XXXXXX")"
  if have_strace; then
    local trace_file
    trace_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.XXXXXX")"
    if ! strace -f -qq -yy -s 256 \
      -e trace=open,openat,openat2,creat,mkdir,mkdirat,unlink,unlinkat,rename,renameat,renameat2,chmod,fchmodat,bpf,sched_setaffinity,sched_setscheduler,setpriority,ioprio_set \
      -o "$trace_file" -- "$@" >"$out_file" 2>&1; then
      cat "$out_file" >&2 || true
      rm -f "$trace_file" "$out_file"
      fail "$label command failed before mutation audit completed"
    fi
    if ! assert_trace_clean "$label" "$trace_file"; then
      rm -f "$trace_file" "$out_file"
      return 1
    fi
    rm -f "$trace_file" "$out_file"
  else
    if [ "$allow_no_strace_dev" != true ]; then
      fail "strace is required for no-host mutation audit: $label"
    fi
    printf 'WARN: explicit developer no-strace mode for %s; not valid for release/security gates\n' "$label" >&2
    "$@" >"$out_file" 2>&1 || {
      cat "$out_file" >&2 || true
      rm -f "$out_file"
      fail "$label command failed"
    }
    rm -f "$out_file"
  fi
}

run_refusal_command() {
  local label="$1"
  shift
  printf 'CHECK: %s\n' "$label"
  local out rc
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.out.XXXXXX")"
  set +e
  if have_strace; then
    local trace_file
    trace_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.trace.XXXXXX")"
    strace -f -qq -yy -s 256 \
      -e trace=open,openat,openat2,creat,mkdir,mkdirat,unlink,unlinkat,rename,renameat,renameat2,chmod,fchmodat,bpf,sched_setaffinity,sched_setscheduler,setpriority,ioprio_set \
      -o "$trace_file" -- "$@" >"$out" 2>&1
    rc=$?
    set -e
    if ! assert_trace_clean "$label" "$trace_file"; then
      rm -f "$trace_file" "$out"
      return 1
    fi
    rm -f "$trace_file"
  else
    "$@" >"$out" 2>&1
    rc=$?
    set -e
  fi
  if [[ "$rc" -eq 0 ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label unexpectedly succeeded"
  fi
  grep -Eiq 'refus|unsupported|unsafe|no mutation|read-only|dry-run|lab gate|audit|mutation' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label refusal text missing safety explanation"
  }
  rm -f "$out"
}


assert_required_output_patterns_in_file() {
  local label="$1"
  local required_patterns="$2"
  local out_file="$3"
  local required_pattern_line
  while IFS= read -r required_pattern_line; do
    [ -n "$required_pattern_line" ] || continue
    grep -Eiq "$required_pattern_line" "$out_file" || {
      cat "$out_file" >&2 || true
      printf 'FAIL: %s output missing required safety marker: %s\n' "$label" "$required_pattern_line" >&2
      return 1
    }
  done <<< "$required_patterns"
}

run_checked_output_command() {
  local label="$1"
  local required_pattern="$2"
  shift 2
  printf 'CHECK: %s\n' "$label"
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.out.XXXXXX")"
  if have_strace; then
    local trace_file
    trace_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.XXXXXX")"
    if ! strace -f -qq -yy -s 256 \
      -e trace=open,openat,openat2,creat,mkdir,mkdirat,unlink,unlinkat,rename,renameat,renameat2,chmod,fchmodat,bpf,sched_setaffinity,sched_setscheduler,setpriority,ioprio_set \
      -o "$trace_file" -- "$@" >"$out_file" 2>&1; then
      cat "$out_file" >&2 || true
      rm -f "$trace_file" "$out_file"
      fail "$label command failed before output audit completed"
    fi
    if ! assert_trace_clean "$label" "$trace_file"; then
      rm -f "$trace_file" "$out_file"
      return 1
    fi
    rm -f "$trace_file"
  else
    if [ "$allow_no_strace_dev" != true ]; then
      fail "strace is required for no-host mutation audit: $label"
    fi
    "$@" >"$out_file" 2>&1 || {
      cat "$out_file" >&2 || true
      rm -f "$out_file"
      fail "$label command failed"
    }
  fi
  if ! assert_required_output_patterns_in_file "$label" "$required_pattern" "$out_file"; then
    rm -f "$out_file"
    fail "$label output missing required safety marker"
  fi
  grep -q 'host_mutation":true' "$out_file" && {
    cat "$out_file" >&2 || true
    rm -f "$out_file"
    fail "$label reported host_mutation=true"
  }
  rm -f "$out_file"
}

assert_trace_rejected() {
  local label="$1"
  local trace_file="$2"
  if assert_trace_clean "$label" "$trace_file" >/tmp/zig-scheduler-nohost.self.out 2>&1; then
    cat /tmp/zig-scheduler-nohost.self.out >&2 || true
    fail "$label trace was not rejected"
  fi
  rm -f /tmp/zig-scheduler-nohost.self.out
}

self_test() {
  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/zig-scheduler-nohost.self.XXXXXX")"
  cat >"$tmp/safe.trace" <<'TRACE'
openat(AT_FDCWD, "/sys/kernel/sched_ext/state", O_RDONLY|O_CLOEXEC) = 3
write(1, "ok", 2) = 2
TRACE
  assert_trace_clean self-test-safe "$tmp/safe.trace"

  cat >"$tmp/denied-cgroup.trace" <<TRACE
openat(AT_FDCWD, "$tmp/sys/fs/cgroup/cgroup.procs", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 3
TRACE
  assert_trace_rejected self-test-denied-cgroup "$tmp/denied-cgroup.trace"

  cat >"$tmp/denied-bpf.trace" <<'TRACE'
bpf(BPF_PROG_LOAD, {prog_type=BPF_PROG_TYPE_STRUCT_OPS}, 128) = -1 EPERM (Operation not permitted)
TRACE
  assert_trace_rejected self-test-denied-bpf "$tmp/denied-bpf.trace"

  cat >"$tmp/denied-scheduler.trace" <<'TRACE'
sched_setaffinity(1234, 128, [0]) = 0
sched_setscheduler(1234, SCHED_FIFO, [1]) = 0
TRACE
  assert_trace_rejected self-test-denied-scheduler "$tmp/denied-scheduler.trace"

  cat >"$tmp/denied-priority.trace" <<'TRACE'
setpriority(PRIO_PROCESS, 1234, -10) = 0
ioprio_set(IOPRIO_WHO_PROCESS, 1234, IOPRIO_PRIO_VALUE(IOPRIO_CLASS_RT, 0)) = 0
TRACE
  assert_trace_rejected self-test-denied-priority "$tmp/denied-priority.trace"

  cat >"$tmp/denied-host-cgroup.trace" <<'TRACE'
openat(AT_FDCWD, "/sys/fs/cgroup/cgroup.procs", O_WRONLY|O_CLOEXEC) = 3
TRACE
  assert_trace_rejected self-test-denied-host-cgroup "$tmp/denied-host-cgroup.trace"

  cat >"$tmp/denied-host-cgroup-thread-subtree.trace" <<'TRACE'
openat(AT_FDCWD, "/sys/fs/cgroup/cgroup.threads", O_RDWR|O_CLOEXEC) = 3
openat(AT_FDCWD, "/sys/fs/cgroup/cgroup.subtree_control", O_WRONLY|O_APPEND|O_CLOEXEC) = 4
TRACE
  assert_trace_rejected self-test-denied-host-cgroup-thread-subtree "$tmp/denied-host-cgroup-thread-subtree.trace"

  cat >"$tmp/denied-host-cpuset.trace" <<'TRACE'
openat(AT_FDCWD, "/sys/fs/cgroup/cpuset.cpus", O_WRONLY|O_TRUNC|O_CLOEXEC) = 3
TRACE
  assert_trace_rejected self-test-denied-host-cpuset "$tmp/denied-host-cpuset.trace"

  cat >"$tmp/surrogate-cgroup.trace" <<'TRACE'
openat(AT_FDCWD, "/tmp/zigsched-rollback.abc/sys/fs/cgroup/cgroup.procs", O_WRONLY|O_CLOEXEC) = 3
unlinkat(9</tmp/zigsched-cgroup-race.abc/sys/fs/cgroup>, "cgroup.procs", 0) = 0
TRACE
  assert_trace_clean self-test-surrogate-cgroup "$tmp/surrogate-cgroup.trace"

  cat >"$tmp/mixed-evidence-host-sys.trace" <<'TRACE'
renameat2(AT_FDCWD, "/sys/fs/cgroup/cgroup.procs", AT_FDCWD, "evidence/lab/run-all/no-host-mutation/leak", 0) = -1 EXDEV (Invalid cross-device link)
TRACE
  assert_trace_rejected self-test-mixed-evidence-host-sys "$tmp/mixed-evidence-host-sys.trace"

  cat >"$tmp/mixed-zigsched-host-sys.trace" <<'TRACE'
renameat2(AT_FDCWD, "/sys/fs/cgroup/cgroup.procs", AT_FDCWD, "/tmp/zigsched-mixed/leak", 0) = -1 EXDEV (Invalid cross-device link)
TRACE
  assert_trace_rejected self-test-mixed-zigsched-host-sys "$tmp/mixed-zigsched-host-sys.trace"

  cat >"$tmp/mixed-zigsched-host-fd.trace" <<'TRACE'
unlinkat(9</sys/fs/cgroup>, "/tmp/zigsched-mixed/cgroup.procs", 0) = -1 EPERM (Operation not permitted)
TRACE
  assert_trace_rejected self-test-mixed-zigsched-host-fd "$tmp/mixed-zigsched-host-fd.trace"

  cat >"$tmp/evidence-systemd-path.trace" <<'TRACE'
openat(AT_FDCWD, "evidence/lab/run-all/no-host-mutation/cgroup-race/systemd_unit_escape.out", O_WRONLY|O_CREAT|O_TRUNC, 0666) = 3
unlinkat(AT_FDCWD, "evidence/lab/run-all/no-host-mutation/cgroup-race/systemd_unit_escape", 0) = -1 ENOENT (No such file or directory)
TRACE
  assert_trace_clean self-test-evidence-systemd-path "$tmp/evidence-systemd-path.trace"

  if have_strace; then
    mkdir -p "$tmp/sys/fs/cgroup"
    set +e
    run_command self-test-fake-write bash -c "printf x > '$tmp/sys/fs/cgroup/cgroup.procs'" >/tmp/zig-scheduler-nohost.self-strace.out 2>&1
    local rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      cat /tmp/zig-scheduler-nohost.self-strace.out >&2 || true
      fail "strace fake write was not rejected"
    fi
    rm -f /tmp/zig-scheduler-nohost.self-strace.out
  fi

  local output_fixture
  output_fixture="$tmp/desktop-output.txt"
  printf 'bridge_test method=run controller_status=accepted host_mutation=false\n' >"$output_fixture"
  if ( assert_required_output_patterns_in_file self-test-desktop-run $'bridge_test method=run controller_status=(accepted|running).*host_mutation=false\n"event":"runtime_sample"' "$output_fixture" ) >/"$tmp/desktop-run-selftest.out" 2>&1; then
    cat "$tmp/desktop-run-selftest.out" >&2 || true
    rm -rf "$tmp"
    fail 'self-test desktop run fixture unexpectedly passed without runtime_sample marker'
  fi
  if ( assert_required_output_patterns_in_file self-test-desktop-duplicate $'bridge_test method=duplicate-run controller_status=refused.*host_mutation=false\nduplicate_action_id' "$output_fixture" ) >/"$tmp/desktop-duplicate-selftest.out" 2>&1; then
    cat "$tmp/desktop-duplicate-selftest.out" >&2 || true
    rm -rf "$tmp"
    fail 'self-test desktop duplicate fixture unexpectedly passed without duplicate marker'
  fi
  if ( assert_required_output_patterns_in_file self-test-desktop-stale $'bridge_test method=stale-rollback controller_status=refused.*host_mutation=false\nstale_or_unknown_target_action_id' "$output_fixture" ) >/"$tmp/desktop-stale-selftest.out" 2>&1; then
    cat "$tmp/desktop-stale-selftest.out" >&2 || true
    rm -rf "$tmp"
    fail 'self-test desktop stale fixture unexpectedly passed without stale marker'
  fi

  local cleanup_scan_root cleanup_before
  cleanup_scan_root="$tmp/microvm-scan"
  mkdir -p "$cleanup_scan_root"
  cleanup_before="$tmp/microvm-before.txt"
  ( TMPDIR="$cleanup_scan_root"; scan_microvm_tmpdirs > "$cleanup_before" )
  mkdir -p "$cleanup_scan_root/zigsched-microvm-live.selftest"
  if ( TMPDIR="$cleanup_scan_root"; assert_no_new_microvm_tmpdirs "$cleanup_before" ) >/"$tmp/cleanup-selftest.out" 2>&1; then
    cat "$tmp/cleanup-selftest.out" >&2 || true
    rm -rf "$tmp"
    fail 'self-test cleanup residue fixture unexpectedly passed'
  fi

  rm -rf "$tmp"
  printf 'PASS: no-host-mutation self-test\n'
}


run_daemon_json_checked() {
  local label="$1"
  local required_pattern="$2"
  local state_dir="$3"
  local action_json="$4"
  rm -rf "$state_dir"
  run_checked_output_command "$label" "$required_pattern" \
    bash -c 'printf "%s\n" "$1" | zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$2"' _ "$action_json" "$state_dir"
}

run_live_daemon_json_checked() {
  local label="$1"
  local state_dir="$2"
  local action_json="$3"
  rm -rf "$state_dir"
  mkdir -p "$state_dir"
  run_checked_output_command "$label" '("action":"run_lab_microvm_live".*"status":"(REFUSE|PASS)".*"host_mutation":false|"event":"incident".*"action":"run_lab_microvm_live".*"reason":"live_bundle_rejected".*"host_mutation":false)' \
    bash -c 'printf "%s\n" "$1" | zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$2"' _ "$action_json" "$state_dir"
}

run_tui_live_key_flow() {
  local label="$1"
  local keys="$2"
  local state_dir=".zig-cache/tmp/no-host-tui-$label"
  local transcript=".omo/evidence/task-T21-no-host-${label}-transcript.txt"
  rm -rf "$state_dir" "$transcript"
  run_checked_output_command "tui-live-${label}" 'run_lab_microvm_live.*host_mutation=false|host_mutation=false.*run_lab_microvm_live' \
    bash -c 'python3 tools/tui_live_vm_pty_test.py --tui zig-out/bin/zig-scheduler-tui --daemon zig-out/bin/zig-scheduler-daemon --state-dir "$1" --transcript "$2" --keys "$3" --timeout-seconds 60 >/dev/null && test -f "$1/events.jsonl" && grep -q run_lab_microvm_live "$1/events.jsonl" && ! grep -Eq '"'"'host_mutation[\":= ]*:?[ ]*true'"'"' "$1/events.jsonl" "$2" && printf "run_lab_microvm_live keys=%s host_mutation=false\n" "$3"' _ "$state_dir" "$transcript" "$keys"
  printf 'PASS: tui-live-%s action=run_lab_microvm_live keys=%s host_mutation=false\n' "$label" "$keys"
  rm -rf "$state_dir"
}

assert_no_host_mutation_true_in_paths() {
  local label="$1"
  shift
  local found=false
  local path
  for path in "$@"; do
    if [ -e "$path" ] && grep -R -n -E 'host_mutation[":= ]*:?[ ]*true' "$path" >&2; then
      found=true
    fi
  done
  if [ "$found" = true ]; then
    fail "$label journal/action log reported host_mutation=true"
  fi
  printf 'CHECK: %s journal/action logs host_mutation_true absent\n' "$label"
}

run_desktop_bridge_fake_checked() {
  local label="$1"
  local method="$2"
  local required_pattern="$3"
  local state_dir="evidence/lab/run-all/no-host-mutation-desktop-${label}-$$"
  rm -rf "$state_dir"
  mkdir -p "$(dirname "$state_dir")"
  run_checked_output_command "desktop-fake-${label}" "$required_pattern" \
    timeout 45s zig-out/bin/zig-scheduler-live-vm-desktop \
      --state-dir "$state_dir" \
      --fake-daemon tools/tui_pty_authoritative_daemon.py \
      --bridge-test "$method"
  assert_no_host_mutation_true_in_paths "desktop-fake-${label}" "$state_dir"
  rm -rf "$state_dir"
  printf 'PASS: desktop-fake-%s method=%s host_mutation=false\n' "$label" "$method"
}

run_desktop_real_preflight_checked() {
  local state_dir="evidence/lab/run-all/no-host-mutation-desktop-real-preflight-$$"
  rm -rf "$state_dir" .omo/evidence/task-09-qemu-missing
  mkdir -p "$(dirname "$state_dir")"
  run_checked_output_command desktop-real-preflight 'bridge_test=real-lab-preflight.*host_mutation=false|SKIP.*host_mutation=false|PASS.*host_mutation=false' \
    timeout 45s zig-out/bin/zig-scheduler-live-vm-desktop \
      --state-dir "$state_dir" \
      --bridge-test real-lab-preflight \
      --force-qemu-missing
  assert_no_host_mutation_true_in_paths desktop-real-preflight "$state_dir" .omo/evidence/task-09-qemu-missing
  rm -rf "$state_dir" .omo/evidence/task-09-qemu-missing
  printf 'PASS: desktop-real-preflight force-qemu-missing host_mutation=false\n'
}

run_desktop_real_e2e_checked() {
  local state_dir="evidence/lab/run-all/no-host-mutation-desktop-real-e2e-$$"
  rm -rf "$state_dir" .omo/evidence/task-09-qemu-missing
  mkdir -p "$(dirname "$state_dir")"
  run_checked_output_command desktop-real-e2e-forced-skip 'SKIP forced qemu missing.*host_mutation=false' \
    timeout 60s python3 tools/live_vm_desktop_e2e.py \
      --app zig-out/bin/zig-scheduler-live-vm-desktop \
      --state-dir "$state_dir" \
      --force-qemu-missing
  assert_no_host_mutation_true_in_paths desktop-real-e2e-forced-skip "$state_dir" .omo/evidence/task-09-qemu-missing
  rm -rf "$state_dir" .omo/evidence/task-09-qemu-missing
  printf 'PASS: desktop-real-e2e forced-qemu-missing host_mutation=false\n'
}

cleanup_owned_live_lab_processes() {
  local scan_file pid_file term_file
  scan_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.owned-process-scan.XXXXXX")"
  pid_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.owned-process-pids.XXXXXX")"
  term_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.owned-process-term.XXXXXX")"
  ps -eo pid=,ppid=,comm=,args= >"$scan_file"
  awk '
    /zig-scheduler-microvm-live-lab/ && /qemu-system-/ { print $1 }
  ' "$scan_file" | sort -u >"$pid_file" || true
  if [ -s "$pid_file" ]; then
    printf 'CHECK: terminating tagged live-lab processes owned by no-host audit\n'
    xargs -r kill -TERM <"$pid_file" >"$term_file" 2>&1 || true
    sleep 2
    ps -eo pid=,ppid=,comm=,args= >"$scan_file"
    awk '
      /zig-scheduler-microvm-live-lab/ && /qemu-system-/ { print $1 }
    ' "$scan_file" | sort -u >"$pid_file" || true
    if [ -s "$pid_file" ]; then
      xargs -r kill -KILL <"$pid_file" >"$term_file" 2>&1 || true
      sleep 1
    fi
  fi
  rm -f "$scan_file" "$pid_file" "$term_file"
}


scan_microvm_tmpdirs() {
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'zigsched-microvm-live.*' -print 2>/dev/null | sort || true
}

assert_no_new_microvm_tmpdirs() {
  local before_file="$1"
  local after_file new_file residue_found=false
  after_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.tmp-scan.XXXXXX")"
  new_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.tmp-new.XXXXXX")"
  scan_microvm_tmpdirs > "$after_file"
  comm -13 "$before_file" "$after_file" > "$new_file" || true
  if [ -s "$new_file" ]; then
    residue_found=true
    printf 'FAIL: current no-host run left new zigsched-microvm-live temp directories:\n' >&2
    cat "$new_file" >&2
    python3 tools/tui_live_vm_cleanup.py --cleanup-owned-lab-tmpdirs >/dev/null 2>&1 || true
  fi
  rm -f "$after_file" "$new_file"
  if [ "$residue_found" = true ]; then
    fail 'current no-host run left zigsched-microvm-live temp directories'
  fi
  printf 'CHECK: temp-cleanup no current-run zigsched-microvm-live residue\n'
}

assert_no_lingering_processes() {
  local scan_file
  scan_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.process-scan.XXXXXX")"
  ps -eo pid=,ppid=,comm=,args= >"$scan_file"
  if grep -E 'zig-scheduler-(daemon|tui|live-vm-desktop|live-vm-webview-host)|qemu-system-|tui_pty_authoritative_daemon.py|live_vm_desktop_failure_daemon.py' "$scan_file" | grep -F "$repo_root" | grep -Ev 'grep|no_host_mutation|unsafe_cli_matrix' >&2; then
    rm -f "$scan_file"
    fail 'lingering repo-local daemon/TUI/QEMU process detected'
  fi
  if grep -E 'qemu-system-' "$scan_file" | grep -F 'zig-scheduler-microvm-live-lab' | grep -Ev 'grep|no_host_mutation|unsafe_cli_matrix' >&2; then
    rm -f "$scan_file"
    fail 'lingering tagged qemu-system live lab process detected after no-host audit'
  fi
  rm -f "$scan_file"
  printf 'CHECK: process-cleanup no lingering qemu/daemon/TUI processes\n'
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    return
  fi
  if [[ "${1:-}" == "--allow-no-strace-dev" ]]; then
    allow_no_strace_dev=true
    shift
  fi
  if [ "${ZIG_SCHEDULER_ALLOW_NO_STRACE:-}" = "1" ]; then
    fail 'ambient ZIG_SCHEDULER_ALLOW_NO_STRACE is not accepted; use --allow-no-strace-dev only for non-release developer diagnostics'
  fi

  printf 'audit_mode=%s\n' "$(have_strace && printf strace || printf no_strace)"
  printf 'repo_root=%s\n' "$repo_root"
  printf 'git_sha=%s\n' "$(git rev-parse HEAD)"
  printf 'worktree_status_all<<STATUS\n'
  git status --short --untracked-files=all
  printf 'STATUS\n'
  nohost_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-nohost.audit.XXXXXX")"
  export TMPDIR="$nohost_tmp_root"
  microvm_tmp_before="$(mktemp "$TMPDIR/zig-scheduler-nohost.tmp-before.XXXXXX")"
  trap cleanup_nohost_tmp EXIT
  scan_microvm_tmpdirs > "$microvm_tmp_before"

  run_command linux-preflight-json zig build linux-preflight -- --json
  run_command root-preflight-json zig build run -- preflight --json
  run_command sched-ext-preflight-json zig build run -- sched-ext preflight --json
  local scratch_id run_all_out run_all_release
  scratch_id="no-host-mutation-$$-${RANDOM:-0}"
  run_all_out="evidence/lab/run-all/$scratch_id"
  run_all_release="0.2.0-lab-runall-$scratch_id"
  rm -rf "$run_all_out" "evidence/releases/$run_all_release"
  run_command lab-run-all-host-safe bash qa/vm/run_all_lab.sh --mode host-safe --out "$run_all_out" --release-version "$run_all_release"
  if [ ! -f "$run_all_out/summary.json" ]; then
    fail 'lab run-all host-safe summary missing from no-host audit'
  fi
  RUN_ALL_SUMMARY="$run_all_out/summary.json" python3 - <<'PY'
import json
import os
from pathlib import Path
summary_path = Path(os.environ["RUN_ALL_SUMMARY"])
summary = json.loads(summary_path.read_text())
assert summary.get("host_mutation") is False
print(f"run_all_host_safe_summary={summary_path}")
PY
  rm -rf "$run_all_out" "evidence/releases/$run_all_release"

  for verb in load attach enable mutate apply; do
    run_refusal_command "refuse-$verb" zig build run -- "$verb"
  done
  run_refusal_command refuse-controller-dry-run zig build run -- controller plan --dry-run
  rm -rf .zig-cache/tmp/no-host-daemon-partial .zig-cache/tmp/no-host-daemon-rollback .zig-cache/tmp/no-host-daemon-live .omo/evidence/tui-pty-daemon-test
  run_daemon_json_checked daemon-partial-attach 'host_mutation_refused|refused_host' .zig-cache/tmp/no-host-daemon-partial \
    '{"action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-demo"}'
  run_daemon_json_checked daemon-rollback 'host_mutation_refused|refused_host' .zig-cache/tmp/no-host-daemon-rollback \
    '{"action":"rollback","rollback_id":"RB-demo"}'
  run_live_daemon_json_checked daemon-live-microvm .zig-cache/tmp/no-host-daemon-live \
    '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"no-host-live","run_id":"no-host-live","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-no-host-live"}'
  printf 'PASS: daemon-live-microvm action=run_lab_microvm_live host_mutation=false\n'
  rm -rf evidence/lab/run-all/no-host-live
  run_checked_output_command tui-daemon-verifier 'dispatched verifier action through daemon'     python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui zig-out/bin/zig-scheduler-daemon
  run_tui_live_key_flow m-m-q mmq
  run_tui_live_key_flow m-m-b-b-q mmbbq
  run_tui_live_key_flow m-m-s-s-q mmssq
  run_desktop_bridge_fake_checked run run $'bridge_test method=run controller_status=(accepted|running).*host_mutation=false
"event":"runtime_sample"'
  run_desktop_bridge_fake_checked duplicate-run duplicate-run $'bridge_test method=duplicate-run controller_status=refused.*host_mutation=false
duplicate_action_id'
  run_desktop_bridge_fake_checked stale-rollback stale-rollback $'bridge_test method=stale-rollback controller_status=refused.*host_mutation=false
stale_or_unknown_target_action_id'
  run_desktop_bridge_fake_checked stop stop $'bridge_test method=stop controller_status=accepted bridge_mode=webkitgtk-script-message host_mutation=false target_action_id=desktop-run-1 dispatched=stop_lab_run action_id_prefix=desktop-stop rollback_id=RB-desktop-run-1
stop_lab_run
desktop-stop-
host_mutation=false'
  run_desktop_real_preflight_checked
  run_desktop_real_e2e_checked
  rm -rf .zig-cache/tmp/no-host-daemon-partial .zig-cache/tmp/no-host-daemon-rollback .zig-cache/tmp/no-host-daemon-live .omo/evidence/tui-pty-daemon-test
  cleanup_owned_live_lab_processes
  assert_no_lingering_processes
  assert_no_new_microvm_tmpdirs "$microvm_tmp_before"

  printf 'PASS: no host mutation observed for root commands, live VM TUI keys, and desktop WebView live-VM bridge paths\n'
}

main "$@"
