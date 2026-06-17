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

live_microvm_action_json() {
  local token="unsafe-matrix-$1-$$"
  printf '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"%s","run_id":"%s","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-%s"}' "$token" "$token" "$token"
}

check_live_microvm_refusal() {
  local label="$1"
  local action_json="$2"
  local state_dir=".zig-cache/tmp/zig-scheduler-unsafe-$label"
  local out rc before after reason artifact
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
    fail "$label daemon exited before live-runner refusal"
  fi
  grep -q '"action":"run_lab_microvm_live"' "$out" || {
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label did not reach live microVM action"
  }
  if grep -q '"status":"REFUSE"' "$out"; then
    grep -q '"state":"refused_host"' "$out" || {
      cat "$out" >&2 || true
      rm -rf "$state_dir" "$out"
      fail "$label live-runner refusal was not host-safe"
    }
    if grep -q 'invalid_field' "$out"; then
      cat "$out" >&2 || true
      rm -rf "$state_dir" "$out"
      fail "$label overfit to validation refusal instead of live runner"
    fi
    reason="$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$out" | tail -n 1)"
    case "$reason" in
      qemu_not_found|kvm_unavailable|kernel_unavailable|nix_busybox_unavailable|microvm_runner_refused) ;;
      *)
        cat "$out" >&2 || true
        rm -rf "$state_dir" "$out"
        fail "$label unexpected live-runner refusal reason: ${reason:-missing}"
        ;;
    esac
    artifact="$(sed -n 's/.*"artifact":"\([^"]*\)".*/\1/p' "$out" | tail -n 1)"
    case "$artifact" in
      evidence/lab/run-all/unsafe-matrix-*) rm -rf "$artifact" ;;
    esac
    if [ "$before" != "$after" ]; then
      cat "$out" >&2 || true
      rm -rf "$state_dir" "$out"
      fail "$label changed zig-out file list"
    fi
    rm -rf "$state_dir" "$out"
    printf 'PASS: %s action=run_lab_microvm_live live microVM refused reason=%s host_mutation=false\n' "$label" "$reason"
    return 0
  fi
  grep -q '"event":"incident".*"action":"run_lab_microvm_live".*"reason":"live_bundle_rejected".*"host_mutation":false' "$out" || {
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label did not record a safe live-bundle rejection incident"
  }
  if grep -q 'host_mutation":true' "$out"; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label daemon action reported host mutation"
  fi
  reason="live_bundle_rejected"
  artifact="$(sed -n 's/.*"artifact":"\([^"]*\)".*/\1/p' "$out" | tail -n 1)"
  case "$artifact" in
    evidence/lab/run-all/unsafe-matrix-*) rm -rf "$artifact" ;;
  esac
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label changed zig-out file list"
  fi
  rm -rf "$state_dir" "$out"
  printf 'PASS: %s action=run_lab_microvm_live live microVM safe incident reason=%s host_mutation=false\n' "$label" "$reason"
}

check_malformed_live_action_refusal() {
  local label="$1"
  local action_json="$2"
  local expected_reason="$3"
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
    fail "$label daemon exited before structured validation refusal"
  fi
  grep -q "$expected_reason" "$out" || {
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label missing expected validation reason $expected_reason"
  }
  if grep -q 'host_mutation":true' "$out"; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label reported host mutation"
  fi
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label changed zig-out file list"
  fi
  rm -rf "$state_dir" "$out"
  printf 'PASS: %s live action validation refused reason=%s host_mutation=false\n' "$label" "$expected_reason"
}

check_state_dir_rejected() {
  local label="$1"
  local state_dir="$2"
  local out rc before after
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-unsafe-${label}.XXXXXX")"
  before="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  set +e
  printf '%s\n' "$(live_microvm_action_json "$label")" | zig-out/bin/zig-scheduler-daemon --foreground --state-dir "$state_dir" >"$out" 2>&1
  rc=$?
  set -e
  after="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  if [ "$rc" -eq 0 ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label accepted unsafe daemon state dir $state_dir"
  fi
  if [ -e "$state_dir" ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label created unsafe daemon state dir $state_dir"
  fi
  grep -Eiq 'usage|state|invalid|foreground' "$out" || {
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label missing state-dir refusal explanation"
  }
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -f "$out"
    fail "$label changed zig-out file list"
  fi
  rm -f "$out"
  printf 'PASS: %s rejected unsafe daemon state dir host_mutation=false\n' "$label"
}

check_tui_key_flow() {
  local label="$1"
  local keys="$2"
  local expected_followup="${3:-}"
  local state_dir=".zig-cache/tmp/zig-scheduler-unsafe-tui-$label"
  local transcript=".omo/evidence/task-T21-${label}-tui-transcript.txt"
  local out rc before after journal
  out="$(mktemp "${TMPDIR:-/tmp}/zig-scheduler-unsafe-${label}.XXXXXX")"
  rm -rf "$state_dir" "$transcript"
  before="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  set +e
  python3 tools/tui_live_vm_pty_test.py \
    --tui zig-out/bin/zig-scheduler-tui \
    --daemon zig-out/bin/zig-scheduler-daemon \
    --state-dir "$state_dir" \
    --transcript "$transcript" \
    --keys "$keys" \
    --timeout-seconds 60 >"$out" 2>&1
  rc=$?
  set -e
  after="$(find zig-out -maxdepth 3 -type f 2>/dev/null | sort || true)"
  if [ "$rc" -ne 0 ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label TUI key flow failed"
  fi
  journal="$state_dir/events.jsonl"
  if [ ! -f "$journal" ]; then
    cat "$out" >&2 || true
    cat "$transcript" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label missing daemon journal"
  fi
  grep -q 'run_lab_microvm_live' "$journal" || {
    cat "$journal" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label did not dispatch live microVM action"
  }
  if [ -n "$expected_followup" ]; then
    grep -q "\"action\":\"$expected_followup\"" "$journal" || {
      cat "$journal" >&2 || true
      cat "$transcript" >&2 || true
      rm -rf "$state_dir" "$out"
      fail "$label did not dispatch expected follow-up action $expected_followup"
    }
    grep -E "\"action\":\"$expected_followup\".*\"status\":\"(REFUSE|SKIP|PASS|refused|accepted|active|queued)\"" "$journal" >/dev/null || {
      cat "$journal" >&2 || true
      cat "$transcript" >&2 || true
      rm -rf "$state_dir" "$out"
      fail "$label missing bounded status for $expected_followup"
    }
  fi
  grep -Eq '"status":"(REFUSE|SKIP|PASS|refused|accepted|active|queued)"' "$journal" || {
    cat "$journal" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label missing bounded daemon status"
  }
  if grep -q 'host_mutation":true' "$journal" "$transcript"; then
    cat "$journal" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label reported host mutation"
  fi
  if grep -Eiq 'intercepted|/bin/sh -c|bash -c|; rm|\$\(' "$journal" "$transcript"; then
    cat "$journal" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label showed shell/host command injection markers"
  fi
  if [ "$before" != "$after" ]; then
    cat "$out" >&2 || true
    rm -rf "$state_dir" "$out"
    fail "$label changed zig-out file list"
  fi
  printf 'PASS: %s TUI keys=%s dispatched run_lab_microvm_live with host_mutation=false\n' "$label" "$keys"
  rm -rf "$state_dir" "$out"
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
check_live_microvm_refusal daemon-live-microvm "$(live_microvm_action_json daemon-live-microvm)"
check_malformed_live_action_refusal malformed-live-action-id '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"bad;id","run_id":"unsafe-matrix-bad-action","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-bad-action"}' 'malformed_action'
check_malformed_live_action_refusal malformed-live-run-id '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"bad-run-id","run_id":"../escape","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB-bad-run"}' 'invalid_field'
check_malformed_live_action_refusal malformed-live-audit '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"bad-audit","run_id":"unsafe-matrix-bad-audit","audit_id":"AUD;bad","rollback_id":"RB-bad-audit"}' 'malformed_action'
check_malformed_live_action_refusal malformed-live-rollback '{"schema":"zig-scheduler/operator-action/v1","action":"run_lab_microvm_live","action_id":"bad-rollback","run_id":"unsafe-matrix-bad-rollback","audit_id":"AUD-20990101T000000Z-deadbee-abc123","rollback_id":"RB;bad"}' 'malformed_action'
check_state_dir_rejected state-dir-absolute "/tmp/zig-scheduler-unsafe-absolute-$$"
check_state_dir_rejected state-dir-traversal ".zig-cache/tmp/../zig-scheduler-unsafe-traversal"
check_tui_key_flow tui-mq mq
check_tui_key_flow tui-mbbq mbbq rollback_lab_run
check_tui_key_flow tui-mssq mssq stop_lab_run

hostile_bin="$repo_root/.omo/evidence/task-T21-hostile-bin"
hostile_qemu_sentinel="$repo_root/.omo/evidence/task-T21-hostile-qemu-sentinel.txt"
rm -rf "$hostile_bin" "$hostile_qemu_sentinel"
mkdir -p "$hostile_bin"
cat >"$hostile_bin/qemu-system-x86_64" <<SH
#!/usr/bin/env bash
printf 'hostile qemu executed\n' >"$hostile_qemu_sentinel"
exit 96
SH
chmod +x "$hostile_bin/qemu-system-x86_64"
PATH="$hostile_bin:$PATH" check_live_microvm_refusal hostile-path-qemu-live-microvm "$(live_microvm_action_json hostile-path-qemu-live-microvm)"
if [ -e "$hostile_qemu_sentinel" ]; then
  cat "$hostile_qemu_sentinel" >&2 || true
  rm -rf "$hostile_bin"
  fail 'hostile PATH qemu-system-x86_64 was executed'
fi
printf 'PASS: hostile PATH qemu-system-x86_64 sentinel absent host_mutation=false\n'
rm -rf "$hostile_bin"


home_hostile_bin="$HOME/zig-scheduler-T21-hostile-qemu-$$"
home_hostile_qemu="$home_hostile_bin/qemu-system-x86_64"
home_hostile_sentinel="$repo_root/.omo/evidence/task-T21-home-hostile-qemu-sentinel.txt"
rm -rf "$home_hostile_bin" "$home_hostile_sentinel"
mkdir -p "$home_hostile_bin"
cat >"$home_hostile_qemu" <<SH
#!/usr/bin/env bash
printf 'home hostile qemu executed\n' >"$home_hostile_sentinel"
exit 97
SH
chmod +x "$home_hostile_qemu"
ZIG_SCHEDULER_QEMU_BIN="$home_hostile_qemu" check_live_microvm_refusal hostile-home-qemu-override "$(live_microvm_action_json hostile-home-qemu-override)"
if [ -e "$home_hostile_sentinel" ]; then
  cat "$home_hostile_sentinel" >&2 || true
  rm -rf "$home_hostile_bin"
  fail 'hostile /home ZIG_SCHEDULER_QEMU_BIN was executed'
fi
printf 'PASS: hostile /home ZIG_SCHEDULER_QEMU_BIN rejected sentinel absent host_mutation=false\n'

traversal_qemu="/usr/../${home_hostile_qemu#/}"
ZIG_SCHEDULER_QEMU_BIN="$traversal_qemu" check_live_microvm_refusal hostile-traversal-qemu-override "$(live_microvm_action_json hostile-traversal-qemu-override)"
if [ -e "$home_hostile_sentinel" ]; then
  cat "$home_hostile_sentinel" >&2 || true
  rm -rf "$home_hostile_bin"
  fail 'hostile traversal ZIG_SCHEDULER_QEMU_BIN was executed'
fi
printf 'PASS: hostile traversal ZIG_SCHEDULER_QEMU_BIN rejected sentinel absent host_mutation=false\n'
rm -rf "$home_hostile_bin"

printf 'PASS: unsafe CLI matrix\n'
