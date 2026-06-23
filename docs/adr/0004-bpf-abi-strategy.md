# ADR 0004: BPF ABI freeze strategy for VM-lab sched_ext evidence

## Status
Accepted for VM-lab-evidence / proof-seeking work. This is not a production-readiness claim.

## Context
The root project is fail-closed on the host. sched_ext policy loading, struct_ops attach, cgroup writes, CPU topology mutation, and scheduler mutation remain allowed only inside a marked disposable VM lab path. The current policy artifact is the minimal partial-switch `zigsched_minimal` BPF object described by `bpf/include/zigsched_common.h`, `bpf/zigsched_minimal.bpf.c`, and `tools/bpf_metadata.sh`.

The risk is nominal ABI drift: future policy work could silently change enum indexes, constants, struct_ops callbacks, switch mode, or metadata fields while tests still pass through SKIP or fixture-only evidence.

## Decision
Freeze the ABI contract before policy expansion.

Required ABI inputs:
- `bpf/include/zigsched_common.h` defines `ZIGSCHED_ABI_VERSION`, stats/event indexes, DSQ IDs, partial-switch constants, policy config, and the sched_ext `struct sched_ext_ops` skeleton used by the minimal policy.
- `bpf/zigsched_minimal.bpf.c` keeps the policy symbol `zigsched_minimal_ops` and policy name `zigsched_minimal` until a later ADR explicitly changes them.
- `tools/bpf_metadata.sh` must emit either built-object metadata (`zig-scheduler/bpf-object-metadata/v1`) or explicit SKIP metadata (`zig-scheduler/bpf-build-skip/v1`). Both modes are evidence artifacts, but only object mode can be used for verifier/attach proof.

Required metadata fields for both object and SKIP modes:
- policy name: `zigsched_minimal`.
- policy symbol: `zigsched_minimal_ops`.
- source path and source hash.
- tool versions for clang, bpftool, file, llvm-objdump, and Zig.
- target tuple with `target_arch=bpf`, `target_define=__TARGET_ARCH_x86`, host arch/release, VM contract, and `vm_required_for_attach=true`.
- struct_ops object section, expected callbacks (`init`, `enqueue`, `dispatch`), program sections, and `expected_switch_mode=SCX_OPS_SWITCH_PARTIAL`.
- prohibited switch mode `SCX_OPS_SWITCH_ALL`.
- `vm_only=true`, `vm_marker_required=/run/zig-scheduler-vm-lab.marker`, `host_mutation=false`, `host_attach_allowed=false`, and `verification_claimed=false`.

Object mode additionally requires object path, object sha256, object hash, and `expected_verifier_object` matching the canonical object.

SKIP mode additionally requires a non-empty reason, no object/hash/verifier object, `release_eligible=false`, and `skip_is_release_eligible=false`.

## Consequences
- Policy expansion is blocked until `qa/bpf_abi_freeze_check.py` passes against the header, this ADR, and the current object-or-SKIP metadata.
- A SKIP artifact is acceptable for host-safe ABI freeze evidence, but never counts as VM-required attach/runtime proof.
- A future kernel tuple that needs generated `vmlinux.h`, BTF, or libbpf evidence must extend this ADR/checker before changing the policy ABI.
- Real-host attach remains out of scope and forbidden until a later explicit approval, rollback drill, security review, and new ADR exist.
