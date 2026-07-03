#!/usr/bin/env bash
set -euo pipefail

mode=""
self_test=false
units_dir="packaging/systemd"
config="packaging/config/default.toml"
packaging_docs="packaging/README.md"
governance_docs="docs/releases/governance-gate.md"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
usage: qa/package_defaults.sh --mode inspect [--units packaging/systemd]
       qa/package_defaults.sh --self-test
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) [ "$#" -ge 2 ] || fail '--mode requires a value'; mode="$2"; shift 2 ;;
    --units) [ "$#" -ge 2 ] || fail '--units requires a value'; units_dir="$2"; shift 2 ;;
    --self-test) self_test=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

require_file() {
  [ -f "$1" ] || fail "$2 missing"
}

reject_unit_install_section() {
  local unit="$1"
  local label="$2"
  if grep -q '^WantedBy=' "$unit"; then fail "$label must not install-enable by default"; fi
  if grep -q '^\[Install\]' "$unit"; then fail "$label must not include an install section"; fi
}

reject_mutation_exec() {
  local unit="$1"
  local label="$2"
  if grep -Eq '^ExecStart=.*(sched-ext[[:space:]]+attach|controller[[:space:]]+apply|[[:space:]](load|enable|mutate|apply)([[:space:]]|$))' "$unit"; then
    fail "$label contains mutation command"
  fi
}

check_units() {
  local dir="$1"
  local preflight="$dir/zig-scheduler-preflight.service"
  local daemon="$dir/zig-scheduler-daemon.service"
  local mutation="$dir/zig-scheduler-lab-mutation.service"

  [ -d "$dir" ] || fail 'units directory missing'
  require_file "$preflight" 'preflight service'
  require_file "$daemon" 'daemon service'
  require_file "$mutation" 'mutation service'

  reject_mutation_exec "$preflight" 'preflight service'
  grep -q '^ExecStart=/usr/bin/zig-scheduler preflight --json$' "$preflight" || fail 'preflight service must use supported read-only root preflight command'

  grep -q '^ExecStart=/usr/bin/zig-scheduler-daemon --foreground --state-dir daemon$' "$daemon" || fail 'daemon service must use foreground daemon command'
  grep -q '^NoNewPrivileges=yes$' "$daemon" || fail 'daemon service must keep NoNewPrivileges'
  grep -q '^CapabilityBoundingSet=$' "$daemon" || fail 'daemon service must have empty capabilities'
  reject_unit_install_section "$daemon" 'daemon service'
  reject_mutation_exec "$daemon" 'daemon service'

  grep -q '^ConditionPathExists=/run/zig-scheduler-vm-lab.marker$' "$mutation" || fail 'mutation service missing VM marker condition'
  grep -q '^ConditionPathExists=/etc/zig-scheduler/enable-lab-mutation$' "$mutation" || fail 'mutation service missing enable-lab-mutation gate condition'
  grep -q '^ConditionPathExists=/var/lib/zig-scheduler/evidence/current/approval.json$' "$mutation" || fail 'mutation service missing evidence approval condition'
  grep -q -- '--target-cgroup /sys/fs/cgroup/zig-scheduler-lab.slice/' "$mutation" || fail 'mutation service ExecStart target cgroup is not allowlisted lab slice'
  grep -q -- '--audit-id AUD-' "$mutation" || fail 'mutation service ExecStart missing audit id argument'
  grep -q -- '--rollback-id RB-' "$mutation" || fail 'mutation service ExecStart missing rollback id argument'
  if grep -q -- '--config\|--evidence' "$mutation"; then fail 'mutation service ExecStart uses unsupported CLI arguments'; fi
  reject_unit_install_section "$mutation" 'mutation service'
}

check_config() {
  require_file "$config" 'default config'
  grep -q '^scheduler = "none"' "$config" || fail 'default scheduler must be none'
  grep -q '^auto_start_scheduler = false' "$config" || fail 'auto-start must be false'
  grep -q '^mutation_service_enabled = false' "$config" || fail 'mutation service default must be false'
  grep -q '^control_daemon_enabled = false' "$config" || fail 'daemon service default must be false'
  grep -q '^release_scope = "vm-lab-backend-only"' "$config" || fail 'release scope must be VM/lab backend only'
  grep -q '^production_ready = false' "$config" || fail 'package default must not claim production readiness'
  grep -q '^arbitrary_host_safe = false' "$config" || fail 'package default must not claim arbitrary-host safety'
}

check_docs() {
  require_file "$packaging_docs" 'packaging docs'
  require_file "$governance_docs" 'governance docs'
  grep -qi 'must not auto-start' "$packaging_docs" || fail 'packaging docs missing no auto-start wording'
  grep -qi 'read-only' "$packaging_docs" || fail 'packaging docs missing read-only default'
  grep -qi 'VM/lab backend milestone defaults only' "$packaging_docs" || fail 'packaging docs missing VM/lab backend scope'
  grep -q '/etc/zig-scheduler/enable-lab-mutation' "$packaging_docs" || fail 'packaging docs missing enable-lab-mutation gate wording'
  grep -qi 'systemd no auto-start proof' "$governance_docs" || fail 'governance docs missing systemd no auto-start proof wording'
  grep -qi 'mutation service remains gated by config, marker, and evidence' "$governance_docs" || fail 'governance docs missing mutation gate wording'
}

check_preflight_cli() {
  local tmp_json tmp_err
  tmp_json="$(mktemp)"
  tmp_err="$(mktemp)"
  if ! zig build run -- preflight --json >"$tmp_json" 2>"$tmp_err"; then
    cat "$tmp_err" >&2 || true
    rm -f "$tmp_json" "$tmp_err"
    fail 'preflight service command is not supported by root CLI'
  fi
  rm -f "$tmp_json" "$tmp_err"
}

run_inspect() {
  [ "$mode" = inspect ] || fail '--mode must be inspect'
  check_units "$units_dir"
  check_config
  check_docs
  check_preflight_cli
  printf 'PASS: package defaults are read-only; no auto-start/no mutation by default\n'
}

expect_reject() {
  local label="$1"
  local dir="$2"
  if ( check_units "$dir" ) >/dev/null 2>&1; then
    fail "self-test expected rejection: $label"
  fi
  printf 'PASS self-test rejected: %s\n' "$label"
}

run_self_test() {
  local tmp case_dir
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT

  case_dir="$tmp/missing-vm-marker"
  mkdir -p "$case_dir"
  cp -R packaging/systemd/. "$case_dir/"
  sed -i '/ConditionPathExists=\/run\/zig-scheduler-vm-lab.marker/d' "$case_dir/zig-scheduler-lab-mutation.service"
  expect_reject 'missing VM marker' "$case_dir"

  case_dir="$tmp/missing-enable-lab-mutation"
  mkdir -p "$case_dir"
  cp -R packaging/systemd/. "$case_dir/"
  sed -i '/ConditionPathExists=\/etc\/zig-scheduler\/enable-lab-mutation/d' "$case_dir/zig-scheduler-lab-mutation.service"
  expect_reject 'missing /etc/zig-scheduler/enable-lab-mutation gate' "$case_dir"

  case_dir="$tmp/unsafe-wantedby"
  mkdir -p "$case_dir"
  cp -R packaging/systemd/. "$case_dir/"
  printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$case_dir/zig-scheduler-lab-mutation.service"
  expect_reject 'unsafe WantedBy install enablement' "$case_dir"

  case_dir="$tmp/mutation-preflight"
  mkdir -p "$case_dir"
  cp -R packaging/systemd/. "$case_dir/"
  sed -i 's#^ExecStart=.*#ExecStart=/usr/bin/zig-scheduler sched-ext attach --lab#' "$case_dir/zig-scheduler-preflight.service"
  expect_reject 'mutation verb in preflight' "$case_dir"

  check_units packaging/systemd
  check_config
  check_docs
  printf 'PASS self-test accepted: canonical packaging\n'
  printf 'PASS package defaults self-test: unsafe units rejected and canonical units accepted\n'
}

if [ "$self_test" = true ]; then
  [ -z "$mode" ] || fail '--self-test cannot be combined with --mode'
  run_self_test
  exit 0
fi

run_inspect
