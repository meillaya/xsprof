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

`zig build run` stays in that fail-closed root lane. It prints help, preflight, and dry-run guidance, but it does not launch QEMU or perform scheduler mutation.

The first-class live lab entrypoints are separate:

- `zig build tui-live-vm` opens the live VM lab TUI with the daemon wired to `.omo/evidence/tui-live-vm`.
- `zig build tui -- --interactive --screen vm-lab --width 120 --height 30 --daemon-state-dir ".omo/evidence/tui-live-vm" --daemon-bin "./zig-out/bin/zig-scheduler-daemon"` is the lower-level interactive form.
- `zig build live-vm-web` serves the browser-only reference UI for the VM-gated live microVM lab.
- `zig build live-vm-desktop` opens the VM-lab-only system WebView desktop shell. It is not a production install and it does not repoint `zig build run`.

Current root smoke commands:

```bash
zig build test --summary all
zig build linux-preflight -- --json
zig build run -- --help
zig build tui-live-vm -- --help
zig build live-vm-desktop -- --smoke
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

The intended operator path is TUI-driven through the local disabled-safe daemon. The TUI keeps the simulator-era dense terminal look, but the actions are Linux lab concepts only.

### Live VM prerequisites

An actual live VM run, including the desktop WebView shell, needs a disposable VM host with:

- QEMU/KVM available on the host;
- `nix` available for the busybox fetch used by the live runner;
- `bpftool`/`libbpf`;
- a sched_ext-capable kernel tuple with BTF;
- a disposable VM bundle or kernel/image inputs for the VM harness.

When any of those prerequisites are missing, the live VM path must fail closed. Expected outcomes include `SKIP: qemu unavailable`, `SKIP: kvm unavailable`, `REFUSE: VM_CONFIG_INVALID`, `REFUSE: VM_CONFIG_AMBIGUOUS`, and `REFUSE: nix_busybox_unavailable`. Every refusal keeps `host_mutation=false`.

The system WebView desktop shell adds host UI prerequisites on top of that VM tuple:

- Linux: GTK plus WebKitGTK packages, typically `libgtk-3-dev libwebkit2gtk-4.1-dev` on Debian/Ubuntu, `gtk3-devel webkit2gtk4.1-devel` on Fedora, or the matching distro WebKitGTK package on Arch;
- macOS: the system WebKit framework from the platform SDK;
- Windows: the Microsoft Edge WebView2 runtime/SDK.

If those UI dependencies are missing, `zig build desktop-webview-probe --summary all` must print `SKIP webview dependency unavailable` and keep the build fail closed.

### Live VM launch commands

Build the binaries first:

```bash
zig build install
```

Inspect the fail-closed root CLI:

```bash
zig build run -- --help
```

Open the first-class live VM TUI:

```bash
zig build tui-live-vm
```

Launch the desktop shell in its lab-only smoke mode:

```bash
zig build live-vm-desktop -- --smoke
```

Or launch the lower-level interactive screen directly:

```bash
zig build tui -- --interactive --screen vm-lab --width 120 --height 30 --daemon-state-dir ".omo/evidence/tui-live-vm" --daemon-bin "./zig-out/bin/zig-scheduler-daemon"
```

### Live VM key map

- `m`: request a fresh disposable microVM lab run through the daemon;
- `s`: request a safe stop;
- `b`: confirm rollback for the current target;
- stale or duplicate target ids refuse instead of mutating host state;
- `q`: quit.

### Evidence and artifacts

The daemon event journal for the live TUI session is written under the selected `--daemon-state-dir`. The TUI-launched live VM run also writes a bundle under `evidence/lab/run-all/microvm-live-<run-id>/summary.json`.

That bundle records the freshness and cleanup evidence used by the live checks:

- `artifact_paths` for runtime samples, daemon runtime events, rollback audit ledgers, and the cleanup/process-scan files;
- `host_mutation=false`;
- `vm_marker_present=true` and `/run/zig-scheduler-vm-lab.marker`;
- `cleanup` data showing QEMU and tmux leftovers were absent and the process group/temp roots were reaped.

These are verification artifacts, not host deployment evidence. Ordinary host commands must still refuse load, attach, enable, mutate, apply, cgroup writes, affinity/priority changes, and scheduler-state writes.

### Cleanup receipts

Every live VM or desktop run should end with a cleanup receipt that confirms the host is still clean:

```bash
pgrep -af 'zig-scheduler-live-vm-desktop|zig-scheduler-daemon|qemu|Xvfb|zigsched-microvm-live' || true
```

The expected result is either no matching process or only the `pgrep`/`grep` command itself. The live VM evidence bundle must still report `host_mutation=false`, and no current-run `zigsched-microvm-live.*` residue should remain after cleanup.
