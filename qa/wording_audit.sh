#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_paths() {
  local path
  for path in "$@"; do
    [ -e "$path" ] || fail "scan path does not exist: $path"
  done
}

scan_paths() {
  local pattern="$1"
  shift
  [ "$#" -gt 0 ] || fail 'no scan paths provided'
  require_paths "$@"
  grep -RInE --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.omo --exclude-dir=.zig-cache --exclude-dir=zig-out -- "$pattern" "$@" || true
}

scan_paths_i() {
  local pattern="$1"
  shift
  [ "$#" -gt 0 ] || fail 'no scan paths provided'
  require_paths "$@"
  grep -RInEi --exclude-dir=.git --exclude-dir=.omx --exclude-dir=.omo --exclude-dir=.zig-cache --exclude-dir=zig-out -- "$pattern" "$@" || true
}

is_production_guard_phrase() {
  local lower="$1"
  case "$lower" in
    *"must not claim to be production-ready"*|*"must not claim"*|*"not claim"*|*"not a production-ready"*|*"disallowed before the governance gate: production-ready scheduler"*|*"disallowed before the governance gate: safe for production"*|*"disallowed before the governance gate: safe for arbitrary production hosts"*|*"disallowed before the governance gate"*|*"blocked until"*|*"before the governance gate"*|*"no unguarded production"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_guarded_production_line() {
  local lower="$1"
  local residual="$lower"
  is_production_guard_phrase "$lower" || return 1
  residual="${residual//must not claim to be production-ready, safe for production, or safe for arbitrary production hosts/}"
  residual="${residual//must not claim to be production-ready/}"
  residual="${residual//must not claim/}"
  residual="${residual//not claim/}"
  residual="${residual//not a production-ready/}"
  residual="${residual//disallowed before the governance gate: production-ready scheduler/}"
  residual="${residual//disallowed before the governance gate: safe for production/}"
  residual="${residual//disallowed before the governance gate: safe for arbitrary production hosts/}"
  residual="${residual//disallowed before the governance gate/}"
  residual="${residual//blocked until/}"
  residual="${residual//before the governance gate/}"
  residual="${residual//no unguarded production/}"
  case "$residual" in
    *"production-ready"*|*"safe for production"*|*"safe for arbitrary production hosts"*|*"arbitrary production hosts"*) return 1 ;;
    *) return 0 ;;
  esac
}

audit_production_claims() {
  local paths=("$@")
  local matches line lower
  matches="$(scan_paths 'production-ready|safe for production|safe for arbitrary production hosts|arbitrary production hosts' "${paths[@]}")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    if ! is_guarded_production_line "$lower"; then
      fail "unguarded production claim: $line"
    fi
  done <<< "$matches"
}

is_simulator_guard_phrase() {
  local lower="$1"
  case "$lower" in
    *"not production proof"*|*"not linux proof"*|*"not proof for linux"*|*"not real linux performance proof"*|*"design intuition only"*|*"educational/offline only"*|*"offline only; not"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_guarded_simulator_line() {
  local lower="$1"
  local residual="$lower"
  is_simulator_guard_phrase "$lower" || return 1
  residual="${residual//not production proof/}"
  residual="${residual//not linux proof/}"
  residual="${residual//not proof for linux/}"
  residual="${residual//not real linux performance proof/}"
  residual="${residual//design intuition only/}"
  residual="${residual//educational\/offline only/}"
  residual="${residual//offline only; not/}"
  case "$residual" in
    *"linux fidelity"*|*"production proof"*|*"production readiness"*|*"real linux performance"*|*"kernel-equivalent"*|*"kernel equivalent"*|*"linux performance proof"*) return 1 ;;
    *) return 0 ;;
  esac
}

audit_simulator_claims() {
  local paths=("$@")
  local matches line lower
  matches="$(scan_paths_i 'linux fidelity|production proof|production readiness|real linux performance|kernel-equivalent|kernel equivalent|linux performance proof' "${paths[@]}")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    if ! is_guarded_simulator_line "$lower"; then
      fail "simulator wording may imply Linux production/fidelity proof: $line"
    fi
  done <<< "$matches"
}

print_context() {
  local mode="$1"
  local status_file
  status_file="${TMPDIR:-/tmp}/zig-scheduler-wording-audit-status.$$"
  printf 'audit_mode=%s
' "$mode"
  printf 'repo_root=%s
' "$root"
  printf 'git_sha=%s
' "$(git -C "$root" rev-parse --short HEAD 2>/dev/null || printf unknown)"
  git -C "$root" status --short --untracked-files=all > "$status_file" 2>/dev/null || true
  printf 'worktree_status_all=%s
' "$(wc -l < "$status_file" | tr -d ' ')"
  sed 's/^/status: /' "$status_file"
  rm -f "$status_file"
}

if [ "${1:-}" = "--scan-production" ]; then
  shift
  print_context scan-production
  audit_production_claims "$@"
  printf 'PASS: production wording scan paths=%s\n' "$*"
  exit 0
fi

if [ "${1:-}" = "--scan-simulator" ]; then
  shift
  print_context scan-simulator
  audit_simulator_claims "$@"
  printf 'PASS: simulator wording scan paths=%s
' "$*"
  exit 0
fi

if [ "${1:-}" = "--self-test" ]; then
  tmp="${TMPDIR:-/tmp}/zig-scheduler-wording-audit-self-test.$$"
  mkdir -p "$tmp"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/bad.md" <<'BAD'
This scheduler is production-ready and safe for production.
BAD
  if "$0" --scan-production "$tmp" >/tmp/zig-scheduler-wording-audit-self-test.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-self-test.out >&2
    fail 'self-test expected rejected wording'
  fi
  grep -q 'unguarded production claim' /tmp/zig-scheduler-wording-audit-self-test.out
  cat > "$tmp/ambiguous.md" <<'AMBIG'
This scheduler is production-ready, not merely experimental; safe for production.
AMBIG
  if "$0" --scan-production "$tmp/ambiguous.md" >/tmp/zig-scheduler-wording-audit-ambiguous.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-ambiguous.out >&2
    fail 'self-test expected ambiguous not wording rejection'
  fi
  grep -q 'unguarded production claim' /tmp/zig-scheduler-wording-audit-ambiguous.out
  cat > "$tmp/contradictory-production.md" <<'PRODCONTRA'
This is not a production-ready prototype anymore; it is production-ready and safe for production.
PRODCONTRA
  if "$0" --scan-production "$tmp/contradictory-production.md" >/tmp/zig-scheduler-wording-audit-prod-contradictory.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-prod-contradictory.out >&2
    fail 'self-test expected contradictory production wording rejection'
  fi
  grep -q 'unguarded production claim' /tmp/zig-scheduler-wording-audit-prod-contradictory.out
  if "$0" --scan-production "$tmp/missing.md" >/tmp/zig-scheduler-wording-audit-missing.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-missing.out >&2
    fail 'self-test expected missing path rejection'
  fi
  grep -q 'scan path does not exist' /tmp/zig-scheduler-wording-audit-missing.out
  if "$0" --scan-production >/tmp/zig-scheduler-wording-audit-zero.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-zero.out >&2
    fail 'self-test expected zero path rejection'
  fi
  grep -q 'no scan paths provided' /tmp/zig-scheduler-wording-audit-zero.out
  (cd "$tmp" && printf 'This scheduler is production-ready and safe for production.\n' > ./-bad.md)
  if (cd "$tmp" && "$root/qa/wording_audit.sh" --scan-production ./-bad.md) >/tmp/zig-scheduler-wording-audit-hyphen.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-hyphen.out >&2
    fail 'self-test expected hyphen path bad wording rejection'
  fi
  grep -q 'unguarded production claim' /tmp/zig-scheduler-wording-audit-hyphen.out
  cat > "$tmp/bad-simulator.md" <<'SIMBAD'
Simulator results are production proof for real Linux performance.
SIMBAD
  if "$0" --scan-simulator "$tmp/bad-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-bad.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-sim-bad.out >&2
    fail 'self-test expected simulator proof wording rejection'
  fi
  grep -q 'simulator wording may imply' /tmp/zig-scheduler-wording-audit-sim-bad.out
  cat > "$tmp/cannot-bypass-simulator.md" <<'SIMCANNOT'
Simulator output cannot be questioned: it is production proof for real Linux performance.
SIMCANNOT
  if "$0" --scan-simulator "$tmp/cannot-bypass-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-cannot.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-sim-cannot.out >&2
    fail 'self-test expected cannot-bypass simulator proof rejection'
  fi
  cat > "$tmp/mustnot-bypass-simulator.md" <<'SIMMUST'
Users must not doubt the simulator: it is production proof for real Linux performance.
SIMMUST
  if "$0" --scan-simulator "$tmp/mustnot-bypass-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-mustnot.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-sim-mustnot.out >&2
    fail 'self-test expected must-not-bypass simulator proof rejection'
  fi
  cat > "$tmp/contradictory-simulator.md" <<'SIMCONTRA'
Simulator comparisons are not production proof, but they are real Linux performance proof.
Users must not doubt the simulator: not production proof is outdated; it is production proof for real Linux performance.
SIMCONTRA
  if "$0" --scan-simulator "$tmp/contradictory-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-contradictory.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-sim-contradictory.out >&2
    fail 'self-test expected contradictory guarded-positive simulator proof rejection'
  fi
  cat > "$tmp/case-bypass-simulator.md" <<'SIMCASE'
Simulator comparisons are not real Linux performance proof, but this is real Linux performance proof.
SIMCASE
  if "$0" --scan-simulator "$tmp/case-bypass-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-case.out 2>&1; then
    cat /tmp/zig-scheduler-wording-audit-sim-case.out >&2
    fail 'self-test expected mixed-case residual simulator proof rejection'
  fi
  cat > "$tmp/good-simulator.md" <<'SIMGUARD'
Simulator comparisons are design intuition only and not production proof for Linux.
SIMGUARD
  "$0" --scan-simulator "$tmp/good-simulator.md" >/tmp/zig-scheduler-wording-audit-sim-good.out 2>&1
  printf 'PASS: self-test rejected bad wording, ambiguous guard, missing path, zero paths, hyphen path, simulator proof wording, contradictory simulator proof wording, and mixed-case simulator proof wording
'
  exit 0
fi

cd "$root"
print_context repo
audit_production_claims README.md AGENTS.md docs
audit_simulator_claims simulator README.md docs
printf 'PASS: wording audit paths=README.md AGENTS.md docs simulator\n'
