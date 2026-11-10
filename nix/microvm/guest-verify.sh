#!/usr/bin/env bash
# xsprof disposable microVM verification script.
#
# Runs once as root at boot inside the microvm.nix guest (see
# nix/microvm/configuration.nix), prints strict markers to the qemu serial
# console, then reboots the disposable VM. Every xsprof invocation is a
# read-only CLI verb; the only guest writes are temporary files under
# $TMPDIR. host_mutation=false is asserted from the tool's own canonical JSON
# records, never assumed.
#
# Markers parsed by qa/microvm_verify.sh:
#   XSPROF-VM-BOOT ...                 one informational boot line
#   XSPROF-VM-OK <check> [detail...]   one per passing check
#   XSPROF-VM-FAIL <check> [reason]    one per failing check
#   XSPROF-VM-VERIFY-PASS ...          all checks passed
#   XSPROF-VM-VERIFY-FAIL ...          at least one check failed
#
# Deliberately NOT run here: `xsprof demo --smoke` / `xsprof ui --smoke` need
# an X11/Wayland display (the guest has none), and the root perf/live/service/
# retention gates need more privileges than this read-only lane claims. The
# headless UI gate is the deterministic CPU snapshot plus the accessibility
# tree and the documented `xsprof lab` headless scenario runner.
set +e

failures=0
checks=0

ok() { checks=$((checks + 1)); printf 'XSPROF-VM-OK %s\n' "$*"; }
bad() { failures=$((failures + 1)); printf 'XSPROF-VM-FAIL %s\n' "$*"; }

finish() {
  if [ "$failures" -eq 0 ] && [ "$checks" -gt 0 ]; then
    printf 'XSPROF-VM-VERIFY-PASS checks=%d variant=%s\n' \
      "$checks" "${XSPROF_VARIANT:-unknown}"
  else
    printf 'XSPROF-VM-VERIFY-FAIL checks=%d failures=%d variant=%s\n' \
      "$checks" "$failures" "${XSPROF_VARIANT:-unknown}"
  fi
  sync 2>/dev/null || true
  sleep 1
  # The microvm machine type has no ACPI power button and the qemu runner
  # passes -no-reboot, so a kernel reset terminates the disposable VM. This is
  # the same shutdown path microvm.nix's own qemu checks use.
  systemctl reboot --force 2>/dev/null || reboot -f 2>/dev/null || true
}
trap finish EXIT

variant=${XSPROF_VARIANT:-unknown}
fixtures=${XSPROF_FIXTURES_DIR:-}
scenario=${XSPROF_SCENARIO:-}
expected=${XSPROF_EXPECTED_VERSION:-0.5.0}

printf 'XSPROF-VM-BOOT variant=%s kernel=%s cpus=%s\n' \
  "$variant" "$(uname -r)" "$(nproc)"

work=$(mktemp -d "${TMPDIR:-/tmp}/xsprof-vm.XXXXXX")
if [ -z "$work" ] || [ ! -d "$work" ]; then
  bad "tmpdir unavailable"
  exit 1
fi
export XSPROF_STATE_DIR="$work/state"
export HOME="$work/home"
mkdir -p "$XSPROF_STATE_DIR" "$HOME"

# Read-only canonical-JSON validators. A malformed record, a missing
# schema, or host_mutation != false is a hard failure: the lane never
# converts "could not verify" into "passed".
cat > "$work/check-json.py" <<'PY'
import json
import sys

STATES = ("READY", "DEGRADED", "SKIP", "REFUSE")
ROLES = (
    "window", "tabpanel", "tab", "button", "textbox", "list", "listitem",
    "dialog", "status", "heading", "progressbar",
)


def fail(reason):
    print(f"invalid={reason}")
    raise SystemExit(1)


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as exc:
        fail(f"unparseable:{exc}")


def require_mutation_false(record, label="record"):
    if not isinstance(record, dict) or record.get("host_mutation") is not False:
        fail(f"{label}-host_mutation")


def doctor(path):
    record = load(path)
    if not isinstance(record, dict):
        fail("not-object")
    if record.get("schema") != "xsprof/doctor/v1":
        fail("schema")
    require_mutation_false(record)
    status = record.get("status")
    if status not in STATES:
        fail("status")
    entries = record.get("checks")
    if not isinstance(entries, list) or not entries:
        fail("checks")
    print(f"status={status} checks={len(entries)} host_mutation=false")


def capabilities(path):
    record = load(path)
    if not isinstance(record, list) or not record:
        fail("not-array")
    states = set()
    for item in record:
        if not isinstance(item, dict):
            fail("item")
        name = item.get("name")
        state = item.get("state")
        if not isinstance(name, str) or not name:
            fail("name")
        if state not in STATES:
            fail("state")
        if item.get("host_mutation") is not False:
            fail("host_mutation")
        states.add(state)
    print(f"probes={len(record)} states={','.join(sorted(states))} host_mutation=false")


def preflight(path):
    record = load(path)
    if not isinstance(record, dict):
        fail("not-object")
    if record.get("schema") != "xsprof/preflight/v1":
        fail("schema")
    require_mutation_false(record)
    probes = record.get("capabilities")
    if not isinstance(probes, list) or not probes:
        fail("capabilities")
    for item in probes:
        if not isinstance(item, dict) or item.get("host_mutation") is not False:
            fail("capability-host_mutation")
    facts = record.get("facts")
    if not isinstance(facts, dict) or facts.get("host_mutation") is not False:
        fail("facts")
    print(f"schema=xsprof/preflight/v1 capabilities={len(probes)} host_mutation=false")


def a11y(path):
    record = load(path)
    if not isinstance(record, dict):
        fail("not-object")
    if record.get("schema") != "xsprof/a11y-tree/v1":
        fail("schema")
    require_mutation_false(record)
    nodes = record.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        fail("nodes")
    roles = set()
    for node in nodes:
        if not isinstance(node, dict):
            fail("node")
        role = node.get("role")
        if role not in ROLES:
            fail(f"role:{role}")
        roles.add(role)
    print(f"schema=xsprof/a11y-tree/v1 nodes={len(nodes)} roles={len(roles)} host_mutation=false")


def lab(path):
    record = load(path)
    if not isinstance(record, dict):
        fail("not-object")
    if record.get("schema") != "xsprof/lab-run/v1":
        fail("schema")
    require_mutation_false(record)
    if record.get("status") != "passed":
        fail(f"status:{record.get('status')}")
    assertions = record.get("assertions")
    if not isinstance(assertions, list) or not assertions:
        fail("assertions")
    for assertion in assertions:
        if not isinstance(assertion, dict) or assertion.get("passed") is not True:
            fail("assertion-failed")
    print(
        f"scenario={record.get('scenario')} steps={record.get('steps')} "
        f"events={record.get('events')} status=passed"
    )


KINDS = {
    "doctor": doctor,
    "capabilities": capabilities,
    "preflight": preflight,
    "a11y": a11y,
    "lab": lab,
}


def main(argv):
    if len(argv) != 3 or argv[1] not in KINDS:
        print("usage: check-json.py KIND FILE")
        return 2
    KINDS[argv[1]](argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
PY

if ! command -v xsprof >/dev/null 2>&1; then
  bad "binary-xsprof-not-on-path"
  exit 1
fi

if [ -n "$fixtures" ] && [ -s "$fixtures/healthy.ndjson" ]; then
  ok "fixtures path=$fixtures/healthy.ndjson"
else
  bad "fixtures-missing path=${fixtures:-unset}/healthy.ndjson"
fi

version_output=$(xsprof version 2>&1)
if [ "$version_output" = "xsprof $expected" ]; then
  ok "version expected=$expected"
else
  bad "version expected=xsprof-$expected actual=${version_output:-no-output}"
fi

if help_output=$(xsprof help 2>&1); then
  if printf '%s\n' "$help_output" | grep -q '^USAGE:'; then
    ok "help exit=0"
  else
    bad "help missing-USAGE-marker"
  fi
else
  bad "help exit-failure"
fi

if xsprof doctor --json >"$work/doctor.json" 2>"$work/doctor.err"; then
  if detail=$(python3 "$work/check-json.py" doctor "$work/doctor.json" 2>&1); then
    ok "doctor-json $detail"
  else
    bad "doctor-json $detail"
  fi
else
  bad "doctor-json exit-failure stderr=$(head -n 1 "$work/doctor.err")"
fi

if xsprof capabilities --json >"$work/capabilities.json" 2>"$work/capabilities.err"; then
  if detail=$(python3 "$work/check-json.py" capabilities "$work/capabilities.json" 2>&1); then
    ok "capabilities-json $detail"
  else
    bad "capabilities-json $detail"
  fi
else
  bad "capabilities-json exit-failure stderr=$(head -n 1 "$work/capabilities.err")"
fi

if xsprof preflight --json >"$work/preflight.json" 2>"$work/preflight.err"; then
  if detail=$(python3 "$work/check-json.py" preflight "$work/preflight.json" 2>&1); then
    ok "preflight-json $detail"
  else
    bad "preflight-json $detail"
  fi
else
  bad "preflight-json exit-failure stderr=$(head -n 1 "$work/preflight.err")"
fi

snapshot() {
  xsprof snapshot --replay "$fixtures/healthy.ndjson" --out "$1" \
    --width 480 --height 320 --theme "$2" >/dev/null 2>"$1.err"
}

if snapshot "$work/snapshot-a.png" warm-dark \
  && snapshot "$work/snapshot-b.png" warm-dark; then
  sha_a=$(sha256sum "$work/snapshot-a.png" | cut -d ' ' -f 1)
  sha_b=$(sha256sum "$work/snapshot-b.png" | cut -d ' ' -f 1)
  if [ -n "$sha_a" ] && [ "$sha_a" = "$sha_b" ] && [ -s "$work/snapshot-a.png" ]; then
    ok "snapshot-deterministic sha256=$sha_a width=480 height=320"
  else
    bad "snapshot-deterministic sha256-a=${sha_a:-none} sha256-b=${sha_b:-none}"
  fi
else
  bad "snapshot-deterministic exit-failure stderr=$(head -n 1 "$work/snapshot-a.err" 2>/dev/null)"
fi

if snapshot "$work/snapshot-paper.png" paper && [ -s "$work/snapshot-paper.png" ]; then
  ok "snapshot-theme-paper theme=paper bytes=$(stat -c %s "$work/snapshot-paper.png")"
else
  bad "snapshot-theme-paper theme=paper"
fi

if xsprof snapshot --replay "$fixtures/healthy.ndjson" --out "$work/a11y.png" \
  --a11y "$work/a11y.json" --width 480 --height 320 \
  >"$work/a11y.out" 2>"$work/a11y.err"; then
  if detail=$(python3 "$work/check-json.py" a11y "$work/a11y.json" 2>&1); then
    ok "ui-smoke-a11y $detail"
  else
    bad "ui-smoke-a11y $detail"
  fi
else
  bad "ui-smoke-a11y exit-failure stderr=$(head -n 1 "$work/a11y.err")"
fi

if [ -n "$scenario" ] && [ -s "$scenario" ]; then
  mkdir -p "$work/lab/fixtures/ui"
  ln -sf "$fixtures/healthy.ndjson" "$work/lab/fixtures/ui/healthy.ndjson"
  # The committed scenario refers to fixtures/ui/healthy.ndjson relative to the
  # working directory; stage that layout instead of rewriting the fixture.
  if ( cd "$work/lab" && xsprof lab --scenario "$scenario" \
    --out "$work/lab-out" --json >"$work/lab.json" 2>"$work/lab.err" ); then
    if detail=$(python3 "$work/check-json.py" lab "$work/lab.json" 2>&1); then
      ok "ui-smoke-lab $detail"
    else
      bad "ui-smoke-lab $detail"
    fi
  else
    bad "ui-smoke-lab exit-failure stderr=$(head -n 1 "$work/lab.err")"
  fi
else
  bad "ui-smoke-lab scenario-missing path=${scenario:-unset}"
fi

exit 0
