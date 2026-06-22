#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -f simulator/build.zig ]] || fail "simulator/build.zig missing; simulator package is not independently runnable"
[[ -f simulator/build.zig.zon ]] || fail "simulator/build.zig.zon missing"
[[ -d simulator/src/sim ]] || fail "simulator/src/sim missing"

sim_json="$(cd simulator && zig build sim -- --scenario short-vs-long --policy fcfs --format json)"
printf '%s' "$sim_json" | grep -F '"schema":"zig-scheduler/report"' >/dev/null || fail "simulator JSON schema missing"
printf '%s' "$sim_json" | grep -F '"completion_order":["L","S1","S2"]' >/dev/null || fail "simulator completion_order drifted"

preflight_json="$(zig build linux-preflight -- --json)"
printf '%s' "$preflight_json" | grep -F '"schema":"zig-scheduler/linux-preflight"' >/dev/null || fail "root preflight JSON schema missing"
printf '%s' "$preflight_json" | grep -F '"sched_ext"' >/dev/null || fail "root preflight JSON missing sched_ext facts"
printf '%s' "$preflight_json" | grep -F '"cgroup_v2"' >/dev/null || fail "root preflight JSON missing cgroup_v2 facts"
printf '%s' "$preflight_json" | grep -F '"capabilities"' >/dev/null || fail "root preflight JSON missing capability facts"

zig build linux-preflight -- --json >/dev/null
if zig-out/bin/zig-scheduler-linux-preflight --apply >/tmp/zig-scheduler-unsafe-apply.out 2>&1; then
  fail "unsafe --apply unexpectedly succeeded"
fi
grep -Ei 'refus|unsafe|read-only|read.only|no mutation|dry-run|mutation' /tmp/zig-scheduler-unsafe-apply.out >/dev/null || fail "unsafe --apply did not explain refusal"

for verb in load attach enable mutate apply; do
  out="/tmp/zig-scheduler-${verb}.out"
  if zig build run -- "$verb" >"$out" 2>&1; then
    fail "unsafe $verb command unexpectedly succeeded"
  fi
  grep -Ei 'refus|unsupported|unsafe|no mutation|preflight|mutation' "$out" >/dev/null || fail "unsafe $verb command did not explain refusal"
done
if zig build run -- controller plan --dry-run >/tmp/zig-scheduler-controller.out 2>&1; then
  fail "controller dry-run without lab/audit gates unexpectedly succeeded"
fi
grep -Ei 'refus|dry-run|lab gate|audit|no mutation|mutation' /tmp/zig-scheduler-controller.out >/dev/null || fail "controller dry-run refusal missing gate explanation"


# root_import_boundary: root Linux operator must not import simulator package or use simulator evidence as Linux proof.
if grep -RInE '@import\("simulator(/|")|@import\("[^"]*\.\./simulator|\.\./simulator|simulator/src|simulator/build\.zig' src build.zig 2>/dev/null; then
  fail "root import boundary violated: root source/build imports or builds simulator"
fi
if grep -RInE 'kernel-equivalent|kernel equivalent|Linux fidelity|production proof' src README.md docs 2>/dev/null; then
  fail "root fidelity-proof wording leaked into root"
fi
[ ! -d src/tui ] || fail "root TUI implementation directory still exists"
[ ! -d src/desktop ] || fail "root desktop implementation directory still exists"
[ ! -d web ] || fail "root WebView/browser implementation directory still exists"
if zig build --help | grep -E 'tui|TUI|webview|WebView|desktop' >/dev/null; then
  fail "root build graph still advertises removed UI surfaces"
fi
bash qa/wording_audit.sh --self-test >/dev/null
bash qa/wording_audit.sh --scan-simulator simulator/README.md README.md docs >/dev/null
if ! grep -RInE 'offline|teaching|deterministic' simulator/README.md 2>/dev/null | grep -Eiq 'offline|teaching|deterministic'; then
  fail "simulator educational/offline boundary wording missing"
fi

printf 'PASS: restructure checks\n'
