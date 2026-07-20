#!/usr/bin/env bash
# Compile the xsprof CO-RE BPF objects. Generates a full vmlinux.h from the
# running kernel's BTF (so the tracepoint structs are available for CO-RE) and
# compiles each bpf/*.bpf.c with clang -target bpf. Run inside `nix develop`
# (provides clang, bpftool, libbpf headers).
set -euo pipefail
cd /home/mei/projects/exasphere
OUT="${1:-bpf-objects}"
mkdir -p "$OUT"
echo "generating vmlinux.h from /sys/kernel/btf/vmlinux ..."
bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$OUT/vmlinux.h"
echo "vmlinux.h: $(wc -l < "$OUT/vmlinux.h") lines"
LIBBPF_INC="$(pkg-config --variable=includedir libbpf 2>/dev/null || true)"
# Pick a clang that does not inject nix hardening flags (unsupported for bpf).
BPF_CLANG="${BPF_CLANG:-}"
if [ -z "$BPF_CLANG" ]; then
  for c in /usr/bin/clang /usr/bin/clang-19 /usr/bin/clang-18 "$(command -v clang || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then BPF_CLANG="$c"; break; fi
  done
fi
echo "using BPF clang: $BPF_CLANG ($($BPF_CLANG --version | head -1))"
INCS=(-I"$OUT")
[ -n "$LIBBPF_INC" ] && INCS+=(-I"$LIBBPF_INC")
for prog in sched_monitor mem_monitor; do
  "$BPF_CLANG" -g -O2 -target bpf -D__TARGET_ARCH_x86 -include "$OUT/vmlinux.h" "${INCS[@]}" \
    -c "bpf/$prog.bpf.c" -o "$OUT/$prog.bpf.o"
  echo "built $OUT/$prog.bpf.o ($(du -h "$OUT/$prog.bpf.o" | cut -f1))"
done
echo "=== programs in sched_monitor.bpf.o ==="
bpftool prog show pinned 2>/dev/null || llvm-objdump -h "$OUT/sched_monitor.bpf.o" 2>/dev/null | grep -E "tracepoint|maps" | head
