#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

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
  grep -Eiq "$required_pattern" "$out_file" || {
    cat "$out_file" >&2 || true
    rm -f "$out_file"
    fail "$label output missing required safety marker"
  }
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

  rm -rf "$tmp"
  printf 'PASS: no-host-mutation self-test\n'
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
  rm -rf .zig-cache/tmp/no-host-daemon-partial .zig-cache/tmp/no-host-daemon-rollback .omo/evidence/tui-pty-daemon-test
  run_checked_output_command daemon-partial-attach 'host_mutation_refused|refused_host' \
    bash -c "printf '%s\n' '{\"action\":\"partial_attach\",\"target_cgroup\":\"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope\",\"audit_id\":\"AUD-20990101T000000Z-deadbee-abc123\",\"rollback_id\":\"RB-demo\"}' | zig-out/bin/zig-scheduler-daemon --foreground --state-dir .zig-cache/tmp/no-host-daemon-partial"
  run_checked_output_command daemon-rollback 'host_mutation_refused|refused_host' \
    bash -c "printf '%s\n' '{\"action\":\"rollback\",\"rollback_id\":\"RB-demo\"}' | zig-out/bin/zig-scheduler-daemon --foreground --state-dir .zig-cache/tmp/no-host-daemon-rollback"
  run_checked_output_command tui-daemon-verifier 'dispatched verifier action through daemon' \
    python3 tools/tui_pty_exit_test.py zig-out/bin/zig-scheduler-tui zig-out/bin/zig-scheduler-daemon
  rm -rf .zig-cache/tmp/no-host-daemon-partial .zig-cache/tmp/no-host-daemon-rollback .omo/evidence/tui-pty-daemon-test

  printf 'PASS: no host mutation observed for root commands\n'
}

main "$@"
