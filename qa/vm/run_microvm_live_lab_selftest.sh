#!/usr/bin/env bash
set -euo pipefail

run_microvm_live_lab_selftest_tmp=""

run_microvm_live_lab_selftest_cleanup() {
  [ -z "${run_microvm_live_lab_selftest_tmp:-}" ] || rm -rf "$run_microvm_live_lab_selftest_tmp"
}

run_microvm_live_lab_self_test() {
  local fixture="${1:-}"
  local serial stub rc
  run_microvm_live_lab_selftest_tmp="$(mktemp -d "${TMPDIR:-/tmp}/zigsched-run-microvm-selftest.XXXXXX")"
  trap run_microvm_live_lab_selftest_cleanup EXIT

  serial="$run_microvm_live_lab_selftest_tmp/preboot-ENOMEM.txt"
  printf 'qemu-system-x86_64: %s\n' "$qemu_iouring_enomem_message" > "$serial"
  qemu_serial_allows_iouring_fallback "$serial" || fail 'pre-boot io_uring ENOMEM did not allow fallback'
  printf 'PASS: pre-boot io_uring ENOMEM permits fallback\n'

  serial="$run_microvm_live_lab_selftest_tmp/postboot-ENOMEM.txt"
  printf '%s\nqemu-system-x86_64: %s\n' "$qemu_boot_event_marker" "$qemu_iouring_enomem_message" > "$serial"
  if qemu_serial_allows_iouring_fallback "$serial"; then
    fail 'post-boot io_uring ENOMEM incorrectly allowed fallback'
  fi
  printf 'PASS: post-boot io_uring ENOMEM refuses fallback\n'

  serial="$run_microvm_live_lab_selftest_tmp/other-failure.txt"
  printf 'qemu-system-x86_64: unrelated failure\n' > "$serial"
  if qemu_serial_allows_iouring_fallback "$serial"; then
    fail 'unrelated failure incorrectly allowed fallback'
  fi
  printf 'PASS: unrelated qemu failure refuses fallback\n'

  if [ -n "$fixture" ]; then
    case "$fixture" in *$'\n'*|*$'\r'*) fail '--self-test-serial must not contain newlines' ;; esac
    [ -r "$fixture" ] || fail "self-test serial fixture is not readable: $fixture"
    if qemu_serial_allows_iouring_fallback "$fixture"; then
      fail 'serial fixture unexpectedly allowed io_uring fallback'
    fi
    printf 'PASS: serial fixture refuses io_uring fallback\n'
  fi

  stub="$run_microvm_live_lab_selftest_tmp/stub-qemu.sh"
  cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'memlock=%s\n' "$(ulimit -l)"
printf 'argv=%s\n' "$*"
printf 'ZIGSCHED_JSON {"event":"boot","status":"PASS"}\n'
STUB
  chmod +x "$stub"

  qemu_run_with_mode memlock-zero "$run_microvm_live_lab_selftest_tmp/fallback-serial.txt" "$stub" -machine none
  rc="$qemu_rc"
  [ "$rc" -eq 0 ] || fail "memlock-zero stub rc=$rc"
  grep -q '^memlock=0$' "$run_microvm_live_lab_selftest_tmp/fallback-serial.txt" || fail 'memlock-zero fallback did not lower child memlock limit'
  grep -q 'ZIGSCHED_JSON {"event":"boot"' "$run_microvm_live_lab_selftest_tmp/fallback-serial.txt" || fail 'fallback stub did not emit boot marker'
  printf 'PASS: memlock-zero stub records memlock=0\n'
  printf 'PASS: run_microvm_live_lab self-test\n'
}
