# SAFETY — Preserving the Fail-Closed, Evidence-Led Posture in C++

Research deliverable for mission `cpp-sched-mem-profiler`. The Zig project's defining property is
that it is **fail-closed**: read-only by default, mutation refused on the host, evidence-led, and
privacy-preserving. The C++ rewrite must preserve this exactly.

## 1. Invariants carried over from the Zig source

Source: `src/control/protocol.zig` (the `DaemonEvent` writer hardcodes `"host_mutation":false`),
`src/main.zig` (unsafe verbs `load/attach/enable/mutate/apply` are refused with non-zero exit),
`qa/no_host_mutation.sh`, `qa/unsafe_cli_matrix.sh`.

Carried-over invariants:
1. **Read-only by default.** Observation collectors may open tracepoints/perf FDs/`/proc`/`/sys`
   for reading only. No collector writes scheduler or memory policy.
2. **`host_mutation=false` on every read-only record.** The C++ journal writer emits this field on
   every observation event, mirroring the Zig `DaemonEvent`.
3. **Unsafe verbs refuse.** CLI verbs `load`, `attach`, `enable`, `mutate`, `apply` (and sched-ext
   attach) print a refusal and exit non-zero on the host.
4. **VM-lab-only mutation.** Real sched_ext load/attach happens only inside a disposable VM with a
   marker, audit id, rollback id, pre/post state, rollback proof, and cleanup proof. The host build
   refuses these paths.
5. **Privacy filtering.** Runtime samples never expose argv, environment, secrets, API keys, tokens,
   or passwords.
6. **No production claim.** Lab evidence proves readiness gates, not production readiness.

## 2. Capability gate (`safety` module)

```cpp
enum class Mutation { SchedAffinity, SchedPriority, CgroupWrite, SchedExtLoad, NumaBind };
struct GateDecision { bool allowed; std::string reason; };

class SafetyGate {
  // Default: refuse every mutation on the host.
  GateDecision decide(Mutation, const AuditContext&) const;
};
```

`decide()` returns `{false, "refused: <reason>"}` unless an explicit, audited opt-in is present
(`--allow-mutate` + audit id + rollback id + VM-lab marker). A refused mutation is recorded as an
`incident`/`refusal` event with `host_mutation=false` and a non-zero CLI exit, exactly like the Zig
`writeRefusal` path.

## 3. Live host permission posture (evidence)

Probed on the target host (kernel `7.1.3-2-cachyos`, AMD Ryzen 7 5700X):
- `/sys/kernel/tracing/events/sched/` -> **Permission denied** for the unprivileged user.
- `/proc/sys/kernel/perf_event_paranoid` = **2**; `/proc/sys/kernel/kptr_restrict` = **2**.
- tracefs is mounted `rw` at `/sys/kernel/tracing`; PMUs `cpu`, `software`, `ibs_op`, `ibs_fetch`
  exist under `/sys/bus/event_source/devices`.
- `CONFIG_SCHED_CLASS_EXT=y`, `CONFIG_DEBUG_INFO_BTF=y`, BTF at `/sys/kernel/btf/vmlinux`,
  `/sys/kernel/sched_ext` present.

Consequence (fail-closed): unprivileged collection of sched tracepoints and most PMU counters is
**not** available on this host. Collectors must `probe()` and return `SKIP`/`REFUSE` with the exact
errno/permission reason rather than failing silently or escalating. The framework therefore:
- always works for `/proc`-derived read-only facts (cpu utilization, meminfo, buddyinfo, numa_maps
  for own process, schedstat where readable);
- reports `SKIP (perf_event_paranoid=2)` for PMU/tracepoint collectors unless run with
  `CAP_PERFMON`/`CAP_SYS_ADMIN` or `perf_event_paranoid<=1`;
- never auto-elevates.

## 4. Path & socket safety

Mirroring `src/control/daemon.zig` `parseArgs`: daemon state/socket paths must be relative and safe;
the UDS socket lives under `--state-dir`. Path traversal (`..`, absolute paths escaping the state
dir) is rejected. The C++ `safety` module provides a single `SafePath::under(root, candidate)`
validator used by every file-writing sink.

## 5. Privacy filter

A single `PrivacyFilter` is applied at the collector edge and again before any sink:
- drop argv/env entirely from runtime samples;
- bound and optionally pseudonymize comm;
- redact values whose key or content matches `secret|api[_-]?key|token|password|credential|auth`.
This mirrors `src/control/stream.zig` (`appendRuntimeFile`) and `qa/runtime_sample_*` checks.

## 6. QA gates the rewrite must keep (or re-express)

- `no_host_mutation` — no observation record may carry `host_mutation=true`.
- `unsafe_cli_matrix` — every unsafe verb refuses non-zero on the host.
- `path_safety` — daemon paths confined to the state dir.
- `runtime_sample` privacy — no secrets/argv/env in samples.
- schema/fixture lockstep — JSON schemas, fixtures, and the C++ protocol enums stay in sync.

## 7. Evidence vs. inference

Grounded: invariants are quoted from the Zig sources and QA scripts named above; the permission
posture is from live probes. Assumption (labeled): raising collection fidelity by lowering
`perf_event_paranoid` or granting `CAP_PERFMON` is an operator decision made outside the framework;
the framework documents and respects the current setting instead of changing it.
