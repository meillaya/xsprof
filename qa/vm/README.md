# QEMU VM Lab Harness

This directory contains the disposable VM-only lab skeleton for future sched_ext evidence.

Current behavior is intentionally fail-closed:

- `qa/vm/run_lab.sh --mode read-only-smoke --out <dir>` exits 0 with `SKIP: qemu unavailable` when QEMU is not installed.
- If QEMU exists but no boot image is configured, the script also exits 0 with an explicit skip manifest.
- The script does not attach sched_ext, load BPF, write cgroups, change affinity, or mutate host scheduler state.
- Any future VM boot path must preserve VM-only markers and emit a manifest containing kernel release, arch, git SHA, Zig version, and BTF status.

The cloud-init files are placeholders for a future disposable VM image. They mark the VM as a read-only smoke environment only.
