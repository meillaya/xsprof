#!/usr/bin/env bash
set -euo pipefail
mode=""
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires a value'; mode="$2"; shift 2 ;;
    --help|-h) echo 'usage: qa/package_defaults.sh --mode inspect'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[ "$mode" = inspect ] || fail '--mode must be inspect'
preflight=packaging/systemd/zig-scheduler-preflight.service
mutation=packaging/systemd/zig-scheduler-lab-mutation.service
config=packaging/config/default.toml
[ -f "$preflight" ] || fail 'preflight service missing'
[ -f "$mutation" ] || fail 'mutation service missing'
[ -f "$config" ] || fail 'default config missing'
grep -q '^ExecStart=/usr/bin/zig-scheduler preflight --json$' "$preflight" || fail 'preflight service must use supported root preflight command'
zig build run -- preflight --json >/tmp/zig-scheduler-package-preflight.json 2>/tmp/zig-scheduler-package-preflight.err || {
  cat /tmp/zig-scheduler-package-preflight.err >&2 || true
  rm -f /tmp/zig-scheduler-package-preflight.json /tmp/zig-scheduler-package-preflight.err
  fail 'preflight service command is not supported by root CLI'
}
rm -f /tmp/zig-scheduler-package-preflight.json /tmp/zig-scheduler-package-preflight.err
if grep -qE 'sched-ext attach|controller apply| load | enable | mutate ' "$preflight"; then fail 'preflight service contains mutation command'; fi
grep -q '^scheduler = "none"' "$config" || fail 'default scheduler must be none'
grep -q '^auto_start_scheduler = false' "$config" || fail 'auto-start must be false'
grep -q '^mutation_service_enabled = false' "$config" || fail 'mutation service default must be false'
grep -q 'ConditionPathExists=/run/zig-scheduler-vm-lab.marker' "$mutation" || fail 'mutation service missing VM marker condition'
grep -q 'ConditionPathExists=/var/lib/zig-scheduler/evidence/current/approval.json' "$mutation" || fail 'mutation service missing evidence approval condition'
if grep -q '^WantedBy=' "$mutation"; then fail 'mutation service must not install-enable by default'; fi

grep -q -- '--target-cgroup /sys/fs/cgroup/zig-scheduler-lab.slice/' "$mutation" || fail 'mutation service ExecStart missing supported --target-cgroup shape'
grep -q -- '--audit-id AUD-' "$mutation" || fail 'mutation service ExecStart missing audit id argument'
grep -q -- '--rollback-id RB-' "$mutation" || fail 'mutation service ExecStart missing rollback id argument'
if grep -q -- '--config\|--evidence' "$mutation"; then fail 'mutation service ExecStart uses unsupported CLI arguments'; fi
grep -qi 'must not auto-start' packaging/README.md || fail 'packaging docs missing no auto-start wording'
grep -qi 'read-only' packaging/README.md || fail 'packaging docs missing read-only default'
printf 'PASS: package defaults are read-only; no auto-start/no mutation by default\n'
