#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Source the production retry helpers without entering the runner argument parser.
source <(sed -n '/^qemu_iouring_enomem_message=/,/^while \[ "\$#" -gt 0 \]; do/p' qa/vm/run_microvm_live_lab.sh | sed '$d')

tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-qemu-retry-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

serial="$tmp/preboot-ENOMEM.txt"
printf 'qemu-system-x86_64: %s\n' "$qemu_iouring_enomem_message" > "$serial"
qemu_serial_allows_iouring_fallback "$serial" || fail 'pre-boot io_uring ENOMEM did not allow fallback'

serial="$tmp/postboot-ENOMEM.txt"
printf '%s\nqemu-system-x86_64: %s\n' "$qemu_boot_event_marker" "$qemu_iouring_enomem_message" > "$serial"
if qemu_serial_allows_iouring_fallback "$serial"; then
  fail 'post-boot io_uring ENOMEM incorrectly allowed fallback'
fi

serial="$tmp/other-failure.txt"
printf 'qemu-system-x86_64: unrelated failure\n' > "$serial"
if qemu_serial_allows_iouring_fallback "$serial"; then
  fail 'unrelated failure incorrectly allowed fallback'
fi

stub="$tmp/stub-qemu.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'memlock=%s\n' "$(ulimit -l)"
printf 'argv=%s\n' "$*"
printf 'ZIGSCHED_JSON {"event":"boot","status":"PASS"}\n'
STUB
chmod +x "$stub"

qemu_run_with_mode memlock-zero "$tmp/fallback-serial.txt" "$stub" -machine none
rc="$qemu_rc"
[ "$rc" -eq 0 ] || fail "memlock-zero stub rc=$rc"
grep -q '^memlock=0$' "$tmp/fallback-serial.txt" || fail 'memlock-zero fallback did not lower child memlock limit'
grep -q 'ZIGSCHED_JSON {"event":"boot"' "$tmp/fallback-serial.txt" || fail 'fallback stub did not emit boot marker'

printf 'PASS: qemu io_uring fallback selftest\n'
