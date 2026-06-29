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
- `qa/bpf_abi_freeze_check.py` must derive the source-owned ABI from `bpf/zigsched_minimal.bpf.c` instead of trusting hard-coded metadata alone. The source-contract extraction is intentionally narrow and documented: after stripping C comments, it reads `struct { ... } <name> SEC(".maps");` declarations, BPF program `SEC("...")` sections outside `.maps`/`.struct_ops`/`license`, and the designated initializer fields of `struct sched_ext_ops zigsched_minimal_ops SEC(".struct_ops")`.

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

## v1 compatibility contract
Current v1 freezes the lab-observable ABI exactly as follows:

- `ZIGSCHED_ABI_VERSION` is `1u`; any stats, events, map, policy config, or project-used `struct_ops` change without an accepted version change is ABI drift.
- Counter map layout is fixed: `zigsched_stats` is an array map with `u32` keys, `u64` values, and `ZIGSCHED_MINIMAL_NR_STATS=8u` entries; `zigsched_events` is an array map with `u32` keys, `u64` values, and `ZIGSCHED_MINIMAL_NR_EVENTS=4u` entries.
- Policy config map layout is fixed: `zigsched_policy_config` is a single-entry array map keyed by `u32` with value `struct zigsched_policy_config`.
- `struct zigsched_policy_config` fields are, in order, `fifo_dsq`, `vtime_dsq`, `starvation_ns_max`, and `mode`, all `zigsched_u64`.
- Stats enum indexes are frozen in order: select CPU calls, enqueue calls, dispatch calls, local direct inserts, FIFO inserts, vtime inserts, FIFO dispatches, and vtime dispatches.
- Event enum indexes are frozen in order: select CPU fallback, dispatch empty, FIFO DSQ init failure, and vtime DSQ init failure.
- The project-used `sched_ext_ops` fields are `name`, `flags`, `init`, `enqueue`, and `dispatch`; the policy remains named `zigsched_minimal`, symbolized as `zigsched_minimal_ops`, and partial-switch only.
- Metadata must carry an `abi_contract` block recording ABI version, header hash, source hash, frozen defines, map layouts, counter/event counts, enum names, policy config fields, and project-used `struct_ops` fields. The ABI freeze check rejects stale metadata/header/source/object hash mismatches.
- Source-derived map declarations must exactly match the three v1 maps above. Adding another `SEC(".maps")` declaration or changing a map layout is an ABI change even when metadata and hashes are updated.
- Source-derived BPF program sections must exactly match `struct_ops.s/zigsched_minimal_init`, `struct_ops/zigsched_minimal_enqueue`, and `struct_ops/zigsched_minimal_dispatch`. Adding another BPF `SEC("...")` program is an ABI/capability expansion and is rejected under v1.
- Source-derived `zigsched_minimal_ops` designated fields must exactly match `name`, `flags`, `init`, `enqueue`, and `dispatch`; metadata must agree with that source-derived field list and callback list. This prevents hard-coded `struct_ops` metadata from hiding source usage drift.

Policy expansion is blocked unless this v1 contract still passes or the change follows the v2 rules below. SKIP mode still has to carry the same ABI contract and hashes so a missing local compiler cannot hide unversioned ABI drift.

## v2 requires
A future v2 requires an explicit compatibility decision before expanding counters/config or changing maps:

1. Bump `ZIGSCHED_ABI_VERSION` and update this ADR with the new stable contract and migration notes.
2. Update `tools/bpf_metadata.sh` to emit the new `abi_contract` version and all new map/config/counter/event fields.
3. Update `qa/bpf_abi_freeze_check.py` self-tests and failure fixtures so v1 metadata cannot silently pass as v2.
4. Preserve VM-only attach boundaries, host refusal evidence, rollback/cleanup proof requirements, and `host_attach_allowed=false` unless a separate security-approved ADR changes that boundary.
5. Treat v2 lab PASS evidence as VM-lab evidence only; it is still not a production-readiness claim.
