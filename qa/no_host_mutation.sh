#!/bin/sh
# Static/no-write host gate. It fails on direct scheduler-policy syscalls and
# on writes to /proc or /sys; VM-gated BPF lives only in capture/bpf.zig.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=${XSPROF_BIN:-"$ROOT/zig-out/bin/xsprof"}
fail=0

scan() { # pattern label
    if grep -RInE --include='*.zig' "$1" "$ROOT/src" >/tmp/xsprof_no_mutation.$$ 2>/dev/null; then
        # The advisor's recommendation strings are documentation, not calls.
        if grep -v 'advisor.zig' /tmp/xsprof_no_mutation.$$ | grep -q .; then
            echo "no_host_mutation: $2" >&2
            grep -v 'advisor.zig' /tmp/xsprof_no_mutation.$$ >&2
            fail=1
        fi
    fi
    rm -f /tmp/xsprof_no_mutation.$$
}

scan 'std\.(os\.linux|posix)\.(sched_setaffinity|sched_setscheduler|sched_setattr|setpriority|ioprio_set|capset)\(' "direct scheduler/capability mutation syscall"
scan 'createFileAbsolute\([^)]*"/sys|createFileAbsolute\([^)]*"/proc' "write path under /proc or /sys"
scan 'openFileAbsolute\([^)]*"/sys[^"]*"[^)]*WRITE|openFileAbsolute\([^)]*"/proc[^"]*"[^)]*WRITE' "writable /proc or /sys handle"

# The only BPF syscall is the VM-marker-gated gate; forbid it outside that file.
if grep -RIn --include='*.zig' 'linux\.bpf' "$ROOT/src" 2>/dev/null |
    grep -v 'capture/bpf.zig' | grep -q .; then
    echo "no_host_mutation: BPF syscall outside the VM gate" >&2
    fail=1
fi

# Optional runtime assertion where strace is available. A short snapshot writes
# its own output file only; no /proc or /sys write may appear.
if command -v strace >/dev/null 2>&1 && [ -x "$BIN" ]; then
    TMP=$(mktemp -d)
    if strace -f -e trace=openat,open,creat,sched_setaffinity,sched_setscheduler,setpriority,bpf \
        -o "$TMP/trace" "$BIN" doctor --json >/dev/null 2>&1; then
        if grep -E 'O_WRONLY|O_RDWR' "$TMP/trace" | grep -E '"/proc/|"/sys/' >/dev/null; then
            echo "no_host_mutation: runtime write to /proc or /sys" >&2
            fail=1
        fi
        if grep -E 'sched_setaffinity|sched_setscheduler|setpriority|bpf\(' "$TMP/trace" >/dev/null; then
            echo "no_host_mutation: runtime mutation syscall" >&2
            fail=1
        fi
    fi
    rm -rf "$TMP"
fi

[ "$fail" -eq 0 ] || exit 1
echo "no_host_mutation: PASS"
