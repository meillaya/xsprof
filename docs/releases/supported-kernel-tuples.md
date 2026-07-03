# Supported Kernel Tuples

Status: VM/lab backend milestone only. This document does not claim distro support or arbitrary host support.

## Lab-supported tuples

The Linux 6.12+ upstream-family tuple is:

- Linux kernel `>=6.12`;
- architecture `x86_64`;
- `CONFIG_SCHED_CLASS_EXT=y`;
- `CONFIG_BPF=y` and `CONFIG_BPF_SYSCALL=y`;
- `CONFIG_BPF_JIT=y` with BPF JIT evidence;
- `CONFIG_DEBUG_INFO_BTF=y` and BTF present at `/sys/kernel/btf/vmlinux`;
- disposable VM-only lab evidence with audit id, rollback id, and pre/post `sched_ext` state checks.
- cleanup proof for VM, tmux, temporary-root, and current-run evidence residue.

## Protected downstream tuple

The protected runner tuples `linux-7.1.1-2-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only` and `linux-7.1.2-3-cachyos-x86_64-sched_ext-bpf-bpf_jit-btf-vm_lab_only` are allowed only for the reviewer-gated manual VM proof lane when the runner preflight proves `/dev/kvm`, `/sys/kernel/sched_ext`, `/sys/kernel/btf/vmlinux`, QEMU KVM acceleration, non-placeholder kernel config metadata, and the unchanged VM-only fail-closed constraints. This is not distro-wide support and does not authorize host attach.

## Unsupported policy

Any tuple missing BTF, BPF JIT, `CONFIG_SCHED_CLASS_EXT`, or Linux `>=6.12` is unsupported and `unsafe_to_assume`. Unknown kernel config, hidden config, or unreadable sysctls are also `unsafe_to_assume` until VM-only evidence proves otherwise.

## Non-goals

- No distro is declared supported by name.
- Other CachyOS releases and arbitrary downstream kernels remain out of scope until a future tuple-expansion governance milestone adds exact evidence and validators.
- No release-readiness claim is made.
- No host attach/load command is authorized by this matrix.
- No package or systemd unit may use this tuple matrix to auto-enable mutation.
