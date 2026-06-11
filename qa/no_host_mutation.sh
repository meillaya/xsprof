#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

have_strace() {
  command -v strace >/dev/null 2>&1
}

trace_contains_denied_mutation() {
  local trace_file="$1"
  grep -En 'bpf\(BPF_(PROG_LOAD|LINK_CREATE)|sched_set(affinity|scheduler)\(' "$trace_file" || true
  grep -En '"[^"]*(/proc/sys|/sys|/sys/fs/cgroup|cpuset|cgroup\.(procs|threads|subtree_control))[^"]*"[^\n]*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND|flags=[^,}]*(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC|O_APPEND))' "$trace_file" || true
  grep -En '(creat|mkdir|mkdirat|unlink|unlinkat|rename|renameat|renameat2|chmod|fchmodat)\([^\n]*"[^"]*(/proc/sys|/sys|/sys/fs/cgroup|cpuset|cgroup\.(procs|threads|subtree_control))[^"]*"' "$trace_file" || true
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
  if have_strace; then
    local trace_file
    trace_file="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-nohost.${label//[^A-Za-z0-9_.-]/_}.XXXXXX")"
    if ! strace -f -qq -s 256 \
      -e trace=open,openat,openat2,creat,mkdir,mkdirat,unlink,unlinkat,rename,renameat,renameat2,chmod,fchmodat,bpf,sched_setaffinity,sched_setscheduler \
      -o "$trace_file" -- "$@" >/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out 2>&1; then
      cat "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out" >&2 || true
      rm -f "$trace_file" "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out"
      fail "$label command failed before mutation audit completed"
    fi
    if ! assert_trace_clean "$label" "$trace_file"; then
      rm -f "$trace_file" "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out"
      return 1
    fi
    rm -f "$trace_file" "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out"
  else
    if [ "${ZIG_SCHEDULER_ALLOW_NO_STRACE:-}" != "1" ]; then
      fail "strace is required for no-host mutation audit: $label"
    fi
    printf 'WARN: explicit developer no-strace mode for %s; not valid for release/security gates\n' "$label" >&2
    "$@" >/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out 2>&1 || {
      cat "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out" >&2 || true
      rm -f "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out"
      fail "$label command failed"
    }
    rm -f "/tmp/zig-scheduler-nohost-${label//[^A-Za-z0-9_.-]/_}.out"
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
    strace -f -qq -s 256 \
      -e trace=open,openat,openat2,creat,mkdir,mkdirat,unlink,unlinkat,rename,renameat,renameat2,chmod,fchmodat,bpf,sched_setaffinity,sched_setscheduler \
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

  printf 'audit_mode=%s\n' "$(have_strace && printf strace || printf no_strace)"
  printf 'repo_root=%s\n' "$repo_root"
  printf 'git_sha=%s\n' "$(git rev-parse HEAD)"
  printf 'worktree_status_all<<STATUS\n'
  git status --short --untracked-files=all
  printf 'STATUS\n'

  run_command linux-preflight-json zig build linux-preflight -- --json
  run_command root-preflight-json zig build run -- preflight --json
  run_command sched-ext-preflight-json zig build run -- sched-ext preflight --json

  for verb in load attach enable mutate apply; do
    run_refusal_command "refuse-$verb" zig build run -- "$verb"
  done
  run_refusal_command refuse-controller-dry-run zig build run -- controller plan --dry-run

  printf 'PASS: no host mutation observed for root commands\n'
}

main "$@"
