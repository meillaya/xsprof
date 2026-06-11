#!/usr/bin/env bash
set -euo pipefail
units_dir="packaging/systemd"
mode="host-safe"
self_test=false
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: %s --self-test | --units packaging/systemd --mode host-safe\n' "$0" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --self-test) self_test=true; shift ;;
    --units) [ "$#" -ge 2 ] || fail '--units requires value'; units_dir="$2"; shift 2 ;;
    --mode) [ "$#" -ge 2 ] || fail '--mode requires value'; mode="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

check_units() {
  local dir="$1"
  local preflight="$dir/zig-scheduler-preflight.service"
  local mutation="$dir/zig-scheduler-lab-mutation.service"
  [ -f "$preflight" ] || fail 'preflight unit missing'
  [ -f "$mutation" ] || fail 'mutation unit missing'
  grep -q '^ExecStart=/usr/bin/zig-scheduler preflight --json$' "$preflight" || fail 'preflight unit must run read-only preflight'
  if grep -qE 'sched-ext attach|controller apply| load | enable | mutate ' "$preflight"; then fail 'preflight unit contains mutation verb'; fi
  grep -q '^ConditionPathExists=/run/zig-scheduler-vm-lab.marker$' "$mutation" || fail 'mutation unit missing VM marker condition'
  grep -q '^ConditionPathExists=/etc/zig-scheduler/enable-lab-mutation$' "$mutation" || fail 'mutation unit missing config gate condition'
  grep -q '^ConditionPathExists=/var/lib/zig-scheduler/evidence/current/approval.json$' "$mutation" || fail 'mutation unit missing evidence gate condition'
  grep -q -- '--target-cgroup /sys/fs/cgroup/zig-scheduler-lab.slice/' "$mutation" || fail 'mutation unit target cgroup is not allowlisted lab slice'
  grep -q -- '--audit-id AUD-' "$mutation" || fail 'mutation unit missing audit id'
  grep -q -- '--rollback-id RB-' "$mutation" || fail 'mutation unit missing rollback id'
  if grep -q '^WantedBy=' "$mutation"; then fail 'mutation unit must not auto-start or install-enable'; fi
}

if [ "$self_test" = true ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cp -R packaging/systemd/. "$tmp/"
  printf '\nWantedBy=multi-user.target\n' >> "$tmp/zig-scheduler-lab-mutation.service"
  if "$0" --units "$tmp" --mode host-safe >/dev/null 2>&1; then fail 'self-test expected WantedBy rejection'; fi
  cp -R packaging/systemd/. "$tmp/"
  sed -i '/ConditionPathExists=\/run\/zig-scheduler-vm-lab.marker/d' "$tmp/zig-scheduler-lab-mutation.service"
  if "$0" --units "$tmp" --mode host-safe >/dev/null 2>&1; then fail 'self-test expected missing marker rejection'; fi
  check_units packaging/systemd
  echo 'PASS systemd unit self-test: unsafe units rejected and canonical units accepted'
  exit 0
fi

[ "$mode" = host-safe ] || fail '--mode must be host-safe in this host checker'
case "$units_dir" in /*|*'/../'*|../*|*/..) fail 'unsafe units path' ;; esac
check_units "$units_dir"
mkdir -p evidence/lab/systemd-unit-host-safe
cat > evidence/lab/systemd-unit-host-safe/summary.json <<'JSON'
{
  "schema": "zig-scheduler/systemd-unit-check/v1",
  "mode": "host-safe",
  "status": "PASS",
  "host_mutation": false,
  "mutation_service_auto_start": false,
  "mutation_service_gated": true
}
JSON
echo 'PASS: systemd units are host-safe; mutation service gated and not auto-started'
