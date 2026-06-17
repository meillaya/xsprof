#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

check_refusal() {
  local label="$1"
  shift
  local out rc before after
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-unsafe-${label}.XXXXXX")"
  before="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  set +e
  "$@" >"$out" 2>&1
  rc=$?
  set -e
  after="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  if [ "$rc" -eq 0 ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label unexpectedly succeeded"
  fi
  grep -Eiq 'refus|unsupported|unsafe|read-only|no mutation|dry-run|mutation|preflight-first' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label missing refusal explanation"
  }
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label changed zig-out file list"
  fi
  rm -f "$out"
  printf 'PASS: %s refused rc=%s\n' "$label" "$rc"
}

check_daemon_event_refusal() {
  local label="$1"
  local action_json="$2"
  local state_dir=".zig-cache/tmp/zig-scheduler-unsafe-$label"
  local out rc before after
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-unsafe-${label}.XXXXXX")"
  rm -rf "$state_dir"
  before="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  set +e
  printf '%s\n' "$action_json" | zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$state_dir" >"$out" 2>&1
  rc=$?
  set -e
  after="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  if [ "$rc" -ne 0 ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label daemon exited before structured refusal"
  fi
  grep -Eiq 'host_mutation_refused|refused_host' "$out" || {
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label daemon action missing host-safe refusal"
  }
  if grep -q 'host_mutation":true' "$out"; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label daemon action reported host mutation"
  fi
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label changed zig-out file list"
  fi
  rm -rf "$state_dir" "$out"
  printf 'PASS: %s daemon refused host mutation\n' "$label"
}

zig build --summary all >/dev/null

for verb in load attach enable mutate apply; do
  check_refusal "raw-$verb" zig-out/bin/zig-scheduler "$verb"
done
check_refusal sched-ext-load zig-out/bin/zig-scheduler sched-ext load
check_refusal sched-ext-attach zig-out/bin/zig-scheduler sched-ext attach
check_refusal controller-apply zig-out/bin/zig-scheduler controller apply
check_refusal controller-mutate zig-out/bin/zig-scheduler controller mutate
check_refusal scheduler-enable zig-out/bin/zig-scheduler scheduler enable
check_daemon_event_refusal daemon-partial-attach '{"action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-demo"}'
check_daemon_event_refusal daemon-rollback '{"action":"rollback","rollback_id":"RB-demo"}'
check_daemon_event_refusal daemon-live-microvm '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"unsafe-matrix-live"}'

hostile_bin=".omo/evidence/task-T14-hostile-bin"
rm -rf "$hostile_bin"
mkdir -p "$hostile_bin"
cat >"$hostile_bin/zig-scheduler-daemon" <<'SH'
#!/usr/bin/env bash
echo intercepted-daemon >&2
exit 97
SH
chmod +x "$hostile_bin/zig-scheduler-daemon"
PATH="$hostile_bin:$PATH" check_daemon_event_refusal hostile-path-daemon-partial '{"action":"partial_attach","target_cgroup":"/sys/fs/cgroup/zig-scheduler-lab.slice/demo.scope","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-demo"}'
PATH="$hostile_bin:$PATH" check_daemon_event_refusal hostile-path-daemon-live-microvm '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","run_id":"unsafe-matrix-live"}'
rm -rf "$hostile_bin"

printf 'PASS: unsafe CLI matrix\n'
