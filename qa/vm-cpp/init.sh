#!/bin/busybox sh
# xsprof microVM init — runs as PID 1 (root) inside the disposable VM.
# Lowers perf_event_paranoid so the capability-gated collectors can open
# tracepoints/PMU, then runs a live capture to prove real event collection.
/bin/busybox mkdir -p /proc /sys /dev /tmp
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sys /sys
/bin/busybox mount -t tracefs tracefs /sys/kernel/tracing
/bin/busybox echo "=== xsprof VM-lab live capture proof ==="
/bin/busybox echo -n "kernel: "
/bin/busybox uname -r
/bin/busybox echo "paranoid before:"
/bin/busybox cat /proc/sys/kernel/perf_event_paranoid
/bin/busybox printf '%s' '-1' | /bin/busybox tee /proc/sys/kernel/perf_event_paranoid
/bin/busybox echo ""
/bin/busybox echo "paranoid after:"
/bin/busybox cat /proc/sys/kernel/perf_event_paranoid
/bin/busybox echo "=== capabilities (expect READY, not SKIP) ==="
/bin/xsprof capabilities --json
/bin/busybox echo "=== live record for 2 seconds ==="
/bin/xsprof record --duration 2000 --output /journal
/bin/busybox echo "=== captured journal line count ==="
/bin/busybox wc -l /journal
/bin/busybox echo "=== first 3 captured events ==="
/bin/busybox head -3 /journal
/bin/busybox echo "=== timeline reconstruction from the live journal ==="
/bin/xsprof timeline --input /journal | /bin/busybox head -c 300
/bin/busybox echo ""
/bin/busybox echo "=== XSProf VM LIVE VALIDATION DONE ==="
/bin/busybox poweroff -f
