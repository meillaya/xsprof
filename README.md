# zig-scheduler

`zig-scheduler` is being re-chartered as a fail-closed Linux scheduler operator project. The root package now focuses on read-only host preflight, dry-run control planning, and lab-gated `sched_ext` readiness work. It is a path-to-production project, not a production-ready scheduler; production claims are blocked until the governance gate in `docs/releases/governance-gate.md` passes with evidence.

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
- no live mutation command surface;
- read-only Linux preflight first;
- dry-run-only controller planning;
- disposable VM/lab gates before any future `sched_ext` work.

Current root smoke commands:

```bash
zig build test --summary all
zig build linux-preflight -- --json
zig build run -- --help
zig build tui -- --snapshot --screen preflight --width 100 --height 30
zig build tui -- --snapshot --screen sched-ext --width 100 --height 30
```

Unsafe verbs such as `load`, `attach`, `enable`, `mutate`, and `apply` are refused by design.

## Tracked governance and worklog

The operator guidance is intentionally tracked so a clean clone has the same safety context as a local working tree:

- [`AGENTS.md`](AGENTS.md) is the future-agent source of truth for fail-closed root behavior.
- [`WORKLOG.md`](WORKLOG.md) records historical checkpoints and current `controlled_lab_pilot_candidate` posture.
- [`docs/`](docs/) contains the security, release, and runbook sources consumed by governance gates.

Ignored `.omo/` and `.omx/` files are workflow state only; future agents must not depend on them for project behavior.

## TUI-driven controlled lab workflow

The intended operator path is now TUI-driven through the local disabled-safe daemon. The TUI keeps the simulator-era dense terminal look, but the actions are Linux lab concepts only.

Build the binaries first:

```bash
zig build install
```

Host-safe interactive smoke, with no scheduler mutation:

```bash
printf 'rviq' | ./zig-out/bin/zig-scheduler-tui \
  --interactive --test-mode \
  --fixture fixtures/lab/preflight-ready.json \
  --screen sched-ext --width 120 --height 30 \
  --daemon-bin ./zig-out/bin/zig-scheduler-daemon \
  --daemon-state-dir .omo/evidence/tui-daemon-state \
  > .omo/evidence/tui-driven-transcript.txt
```

Key map for current lab actions:

- `r`: host-safe run-all harness;
- `v`: verifier-only path, refused outside the VM marker or recorded as VM lab evidence;
- `p`: partial attach path, VM/lab gated;
- `o`: runtime observe path;
- `i`: incident drill showing `INCIDENT` plus rollback/fallback evidence;
- `m`: arm the VM lab action id for stop/rollback controls;
- `s` then `s`: confirm safe stop in test mode;
- `b` then `b`: confirm rollback in test mode;
- `q`: quit.

The daemon event journal for these scenarios is written under the selected `--daemon-state-dir`; lab summaries are written under `evidence/lab/<stage>/<run-id>/summary.json`. These are verification artifacts, not host deployment evidence. Ordinary host commands must still refuse load, attach, enable, mutate, apply, cgroup writes, affinity/priority changes, and scheduler-state writes.
