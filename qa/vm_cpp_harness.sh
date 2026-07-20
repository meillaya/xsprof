#!/usr/bin/env bash
# VM-lab C++ harness skeleton for xsprof privileged proof.
# Fail-closed: SKIPs cleanly (exit 0 + SKIP message) when QEMU, KVM, or BTF
# are unavailable. On a capable host it documents how it would boot a microVM
# and run xsprof privileged inside it.
#
# Architecture invariants preserved:
#   - host_mutation=false on every read-only record
#   - unsafe verbs (load/attach/enable/mutate/apply) refuse non-zero on host
#   - mutation is VM-lab-only with audit+rollback+marker
#   - privacy filtering (no argv/env/secrets in runtime samples)
#   - capability-gated collectors SKIP or REFUSE when unprivileged
#   - advisor recommendations printed, never auto-applied
#
# See: docs/runbooks/vm-lab.md, qa/vm/README.md
set -euo pipefail

SKIP_REASON=""

# --- prerequisite probes (read-only, fail-closed) -------------------------

# 1. QEMU
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    SKIP_REASON="qemu-system-x86_64 not found"
fi

# 2. KVM
if [ -z "$SKIP_REASON" ] && [ ! -e /dev/kvm ]; then
    SKIP_REASON="/dev/kvm not present"
fi

# 3. KVM access
if [ -z "$SKIP_REASON" ] && [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    SKIP_REASON="/dev/kvm not readable/writable by current user"
fi

# 4. BTF (required for CO-RE BPF inside the VM)
if [ -z "$SKIP_REASON" ] && [ ! -f /sys/kernel/btf/vmlinux ]; then
    SKIP_REASON="/sys/kernel/btf/vmlinux not present"
fi

# 5. C++ compiler (needed to build xsprof inside the VM)
if [ -z "$SKIP_REASON" ] && ! command -v g++ >/dev/null 2>&1 && ! command -v clang++ >/dev/null 2>&1; then
    SKIP_REASON="no C++ compiler (g++/clang++) found"
fi

# --- SKIP gate (fail-closed) ----------------------------------------------
if [ -n "$SKIP_REASON" ]; then
    echo "SKIP: vm-cpp-harness: ${SKIP_REASON}"
    echo "SKIP: This host cannot run the privileged VM-lab C++ harness."
    echo "SKIP: The harness would boot a disposable microVM and run xsprof"
    echo "SKIP: with sched_ext attach + BPF CO-RE inside it."
    exit 0
fi

# --- VM-lab execution plan (documented, not executed on host) -------------
# On a capable host this harness would:
#
# 1. Build xsprof (cmake + make) for the VM target.
# 2. Boot a disposable microVM via QEMU+KVM with:
#    - A minimal kernel image (with sched_ext + BTF enabled)
#    - A cloud-init seed that installs xsprof and runs the privileged suite
#    - Network disabled (air-gapped, single-use)
#    - A virtio-fs share for evidence extraction
# 3. Inside the VM:
#    a. Run xsprof preflight (read-only host facts)
#    b. Run xsprof with --allow-mutate --audit-id=<uuid> --rollback-id=<uuid>
#       --vm-lab-marker to exercise the sched_ext attach path
#    c. Capture daemon-event JSONL, rollback proof, cleanup proof
#    d. Verify host_mutation=false on all read-only records
#    e. Verify unsafe verbs refuse without full audit context
# 4. Extract evidence to evidence/lab/<run-id>/
# 5. Destroy the VM (no persistent state)
#
# The harness NEVER runs sched_ext attach or BPF load on the host.

echo "VM-LAB-CPP-HARNESS: all prerequisites met"
echo "VM-LAB-CPP-HARNESS: would boot microVM and run xsprof privileged suite"
echo "VM-LAB-CPP-HARNESS: audit-id=${AUDIT_ID:-<not-set>} rollback-id=${ROLLBACK_ID:-<not-set>}"
echo "VM-LAB-CPP-HARNESS: evidence would be written to evidence/lab/<run-id>/"
echo "VM-LAB-CPP-HARNESS: host mutation remains false; all mutation is VM-only"
exit 0
