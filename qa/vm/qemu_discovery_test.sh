#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source qa/vm/qemu_discovery.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

expected_canonical="${1:-}"
[ -n "$expected_canonical" ] || fail 'expected canonical qemu path required'
[ -x "$expected_canonical" ] || fail "expected canonical qemu path is not executable: $expected_canonical"
profile_qemu="$(command -v qemu-system-x86_64 2>/dev/null || true)"
[ -n "$profile_qemu" ] || fail 'expected PATH qemu discovery candidate required'

resolved_default="$(qemu_discovery_find)" || fail 'qemu discovery failed in current environment'
[ "$resolved_default" = "$expected_canonical" ] || fail "unexpected qemu discovery result: $resolved_default"

clean_env_resolved="$(
  env -i PATH=/usr/bin:/bin HOME=/tmp REPO_ROOT="$repo_root" bash -c '
    cd "$REPO_ROOT"
    source qa/vm/qemu_discovery.sh
    qemu_discovery_find
  '
)" || fail 'qemu discovery failed under clean env'
[ "$clean_env_resolved" = "$expected_canonical" ] || fail "clean-env qemu discovery selected: $clean_env_resolved"

hostile_dir="$(mktemp -d "${TMPDIR:-/tmp}/zig-scheduler-qemu-hostile.XXXXXX")"
trap 'rm -rf "$hostile_dir"' EXIT
cat >"$hostile_dir/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
printf 'hostile qemu executed\n' >&2
exit 99
EOF
chmod +x "$hostile_dir/qemu-system-x86_64"

PATH="$hostile_dir:$(dirname "$profile_qemu"):/usr/bin:/bin" resolved_hostile="$(qemu_discovery_find)" || fail 'qemu discovery failed with hostile PATH'
[ "$resolved_hostile" = "$expected_canonical" ] || fail "hostile PATH qemu was selected: $resolved_hostile"

if qemu_discovery_validate_override "$profile_qemu" >/dev/null 2>&1; then
  fail 'raw /home profile override was accepted'
fi

if qemu_discovery_validate_override "$hostile_dir/qemu-system-x86_64" >/dev/null 2>&1; then
  fail 'unsafe writable override was accepted'
fi

if qemu_discovery_validate_override "/usr/../tmp/qemu-system-x86_64" >/dev/null 2>&1; then
  fail 'unsafe traversal override was accepted'
fi

printf 'PASS: qemu discovery self-test canonical=%s\n' "$resolved_default"
