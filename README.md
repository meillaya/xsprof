# zig-scheduler

`zig-scheduler` is a fail-closed Linux scheduler operator project. The root package focuses on read-only host preflight, dry-run control planning, disabled-safe daemon actions, and lab-gated `sched_ext` readiness work. It is a path-to-production project, not a production-ready scheduler; production claims remain blocked until the governance gate in `docs/releases/governance-gate.md` passes with evidence.

The former deterministic simulator is archived as an independently runnable package in [`simulator/`](simulator/):

```bash
cd simulator
zig build test --summary all
zig build sim -- --scenario short-vs-long --policy fcfs --format json
zig build tui -- --snapshot --scenario short-vs-long --policy fcfs --width 100 --height 30
```

## Root safety model

Root commands are intentionally conservative:

- no BPF scheduler load;
- no cgroup, cpuset, affinity, priority, or scheduler writes;
- no live host mutation command surface;
- read-only Linux preflight first;
- dry-run-only controller planning;
- disposable VM/lab gates before any future `sched_ext` work.

`zig build run` stays in that fail-closed root lane. It prints help, preflight, and dry-run guidance, but it does not launch QEMU or perform scheduler mutation.

Current root smoke commands:

```bash
zig build test --summary all
zig build linux-preflight -- --json
zig build run -- --help
zig build daemon -- --help
zig build package --summary all
```

Unsafe verbs such as `load`, `attach`, `enable`, `mutate`, and `apply` are refused by design.

## Tracked governance and worklog

The operator guidance is intentionally tracked so a clean clone has the same safety context as a local working tree:

- [`AGENTS.md`](AGENTS.md) is the future-agent source of truth for fail-closed root behavior.
- [`WORKLOG.md`](WORKLOG.md) records historical checkpoints and current posture.
- [`docs/`](docs/) contains the security, release, and runbook sources consumed by governance gates.

Ignored `.omo/` and `.omx/` files are workflow state only; future agents must not depend on them for project behavior.

## VM lab boundary

Live VM/lab work remains explicit and fail-closed. A real disposable VM run needs:

- QEMU/KVM available on the host;
- `nix` available for the busybox fetch used by the live runner;
- `bpftool`/`libbpf`;
- a sched_ext-capable kernel tuple with BTF;
- a disposable VM bundle or kernel/image inputs for the VM harness.

When prerequisites are missing, VM paths must fail closed with `SKIP` or `REFUSE` outcomes and `host_mutation=false`. These artifacts are verification evidence, not host deployment evidence. Ordinary host commands must still refuse load, attach, enable, mutate, apply, cgroup writes, affinity/priority changes, and scheduler-state writes.
