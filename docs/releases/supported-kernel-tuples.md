# Supported Kernel Tuples

Status: VM/lab backend milestone only. This document does not claim distro support or arbitrary host support.

## Initial lab-supported tuple

The only initially supported tuple is:

- Linux kernel `>=6.12`;
- architecture `x86_64`;
- `CONFIG_SCHED_CLASS_EXT=y`;
- `CONFIG_BPF=y` and `CONFIG_BPF_SYSCALL=y`;
- `CONFIG_BPF_JIT=y` with BPF JIT evidence;
- `CONFIG_DEBUG_INFO_BTF=y` and BTF present at `/sys/kernel/btf/vmlinux`;
- disposable VM-only lab evidence with audit id, rollback id, and pre/post `sched_ext` state checks.
- cleanup proof for VM, tmux, temporary-root, and current-run evidence residue.

## Unsupported policy

Any tuple missing BTF, BPF JIT, `CONFIG_SCHED_CLASS_EXT`, or Linux `>=6.12` is unsupported and `unsafe_to_assume`. Unknown kernel config, hidden config, or unreadable sysctls are also `unsafe_to_assume` until VM-only evidence proves otherwise.

## Non-goals

- No distro is declared supported by name.
- No release-readiness claim is made.
- No host attach/load command is authorized by this matrix.
- No package or systemd unit may use this tuple matrix to auto-enable mutation.
