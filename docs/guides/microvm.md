# Disposable microVM verification (microvm.nix)

`qa/microvm_verify.sh` boots the **Nix-packaged** `xsprof` binary in a
throwaway [microvm.nix](https://github.com/microvm-nix/microvm.nix) qemu guest,
runs a fixed read-only verification script inside it, parses strict markers
from the serial console, and writes canonical evidence under
`docs/evidence/microvm/`. The guest is discarded after the run: no host state is
touched, no window is opened, and every `xsprof` record keeps
`host_mutation=false`.

This lane complements `qa/vm_acceptance.sh`. It is the cheap, repeatable
"does the packaged binary still boot and behave" gate; `vm_acceptance.sh` is
the expensive root-gate lane and still needs a KVM-capable podman host.

## Quick start

```sh
# Auto-select the variant: KVM if /dev/kvm is readable+writable, else TCG.
sh qa/microvm_verify.sh

# Force the software-emulated lane (works in containers/CI without /dev/kvm).
sh qa/microvm_verify.sh --variant tcg

# Force the hardware-accelerated lane (SKIPs with a reason without /dev/kvm).
sh qa/microvm_verify.sh --variant kvm

# Run the guest directly; it boots, verifies, prints markers, and reboots.
nix run .#xsprof-microvm-tcg

# Build (but do not boot) the runner packages.
nix build .#xsprof-microvm --no-link --print-out-paths
nix build .#xsprof-microvm-tcg --no-link --print-out-paths
```

`qa/microvm_verify.sh` exports workspace-local `XDG_CACHE_HOME`/`TMPDIR`
defaults (`$PWD/.cache/nix`, `$PWD/.cache/tmp`), because some container hosts
deny the default Nix cache/temp locations. It builds with
`nix build --no-link --print-out-paths`, so no `result` symlink is left in the
checkout.

## Flake outputs (Linux only)

These outputs exist on `x86_64-linux` and `aarch64-linux`; the Darwin package
set is unchanged. They are deliberately **not** part of `nix flake check`
(the check gate stays build-only, fast, and KVM-free).

| output | meaning |
|---|---|
| `nixosConfigurations.xsprof-verify-<system>` | qemu guest, KVM variant (`microvm.cpu = null`) |
| `nixosConfigurations.xsprof-verify-<system>-tcg` | qemu guest, TCG variant (`microvm.cpu = "max"`) |
| `packages.<system>.xsprof-microvm` | `microvm.declaredRunner` package for the KVM guest |
| `packages.<system>.xsprof-microvm-tcg` | `microvm.declaredRunner` package for the TCG guest |
| `apps.<system>.xsprof-microvm` / `.xsprof-microvm-tcg` | `microvm-run` entry points, so `nix run` works |

## What the guest verifies

The guest (`nix/microvm/configuration.nix` + `nix/microvm/guest-verify.sh`) is a
NixOS system with `microvm.nixosModules.microvm`, 2 vCPU / 1024 MiB, no
networking, no display server, and one root oneshot that runs after
`multi-user.target`, prints markers on the serial console, and reboots the
disposable VM.

| check | verifies |
|---|---|
| `fixtures` | the packaged `share/xsprof/fixtures/healthy.ndjson` exists |
| `version` | `xsprof version` equals the version parsed from `build.zig.zon` |
| `help` | `xsprof help` exits 0 and prints its `USAGE:` block |
| `doctor-json` | `doctor --json` parses, `schema=xsprof/doctor/v1`, `host_mutation=false`; the observed READY/DEGRADED/SKIP/REFUSE status is recorded, never asserted |
| `capabilities-json` | `capabilities --json` parses as a non-empty array, valid states, `host_mutation=false` per probe |
| `preflight-json` | `preflight --json` parses, `schema=xsprof/preflight/v1`, capabilities and facts keep `host_mutation=false` |
| `snapshot-deterministic` | two CPU snapshots of the packaged replay fixture are byte-identical (`sha256` equality); the headless UI gate |
| `snapshot-theme-paper` | a `--theme paper` (light) snapshot renders and is non-empty |
| `ui-smoke-a11y` | `snapshot --a11y` emits a non-empty `xsprof/a11y-tree/v1` tree with known roles and `host_mutation=false` |
| `ui-smoke-lab` | the committed `scenarios/healthy.json` runs through the documented `xsprof lab` headless scenario runner; every assertion passes and the run status is `passed` |

Each pass prints `XSPROF-VM-OK <check> [detail...]`; the run ends with either
`XSPROF-VM-VERIFY-PASS` or `XSPROF-VM-VERIFY-FAIL` plus per-check
`XSPROF-VM-FAIL` lines. The host harness requires the PASS marker, at least one
`XSPROF-VM-OK` line, and the absence of any FAIL marker; otherwise the result is
FAIL.

### What it deliberately does not verify

- `xsprof demo --smoke` and `xsprof ui --smoke` are **not** used: they require
  an X11/Wayland display (the guest has none), so they would fail for
  environmental reasons instead of testing the package. The headless UI gates
  are the deterministic CPU snapshot, the accessibility tree, and `xsprof lab`.
- The root-only `perf`/live/BPF/service/retention gates are **not** run here.
  They stay with `qa/vm_acceptance.sh` on a KVM + podman host
  (`qa/live_smoke.sh`, `qa/service_smoke.sh`, `qa/retention_bench.sh`); the
  guest still reports capability states honestly (commonly SKIP/DEGRADED without
  `CAP_PERFMON`).
- No KVM claim is made for a TCG run. The results JSON records the host's
  `/dev/kvm` facts, the requested variant, and the accelerator observed from
  the qemu/guest console: qemu's `falling back to tcg` line means emulation,
  while a readable+writable `/dev/kvm` without a fallback line means KVM
  acceleration (the `kvm-clock` guest line is only a secondary signal because
  the console loglevel can filter it).
- No host mutation: the guest writes only temporary files under its own
  `$TMPDIR` and reboots its disposable VM.

## KVM vs TCG

`microvm.nix` builds the qemu command line with machine `accel="kvm:tcg"`, so
qemu tries KVM first and falls back to TCG when `/dev/kvm` is unavailable.

- **KVM variant** (`microvm.cpu = null`): the runner adds `-enable-kvm` and
  expects real hardware acceleration. `--variant kvm` on a host without a
  readable+writable `/dev/kvm` is reported as **SKIP** with that reason.
- **TCG variant** (`microvm.cpu = "max"` on the standard **q35** machine): an
  explicit emulated CPU makes the runner omit `-enable-kvm`; qemu falls back to
  TCG automatically (`-M q35,accel=kvm:tcg,...`). This is the lane that runs in
  containers and CI runners without `/dev/kvm`. It is real emulation (slower
  boot and slower verification), not a mocked pass. The KVM variant keeps the
  lighter `microvm` machine type; under TCG that machine type wedges this NixOS
  kernel in early KASLR ("Poking KASLR" with no further console output), so the
  TCG guest uses q35, which boots the same closure normally.

## Evidence and results JSON

`qa/microvm_verify.sh` writes to `docs/evidence/microvm/` by default (override
with `--out-dir`):

- `console-<variant>.log` — full serial console capture (kernel boot + guest
  output), teed while the VM runs; committed next to the filtered excerpt so the
  evidence can be audited verbatim.
- `console-<variant>.trimmed.log` — the human-readable evidence: a filtered
  excerpt (ANSI sequences stripped) with the qemu accelerator-fallback line,
  every `XSPROF-VM-*` marker line, and the guest reset line.
- `results-<variant>.json` — canonical JSON (sorted keys, compact separators,
  `schema=xsprof/microvm-verify/v1`) with:

```text
schema, result (PASS|FAIL|SKIP), reason,
host { hostname, kernel, system, nix, python3, container_hint,
       kvm_device_present/readable/writable },
lane { flake_output, variant, runner, qemu_machine_accel,
       accelerator_observed, tcg_fallback_observed },
run  { timeout_seconds, duration_seconds, runner_exit, pass_marker,
       fail_marker, console_log, trimmed_console_log },
checks [ { name, detail } ], failures [ ... ],
host_mutation=false, read_only=true
```

Exit status: `0` PASS or SKIP (SKIP reason in the JSON), `1` FAIL, `2` usage
error. A missing `XSPROF-VM-VERIFY-PASS` marker is always FAIL; a PASS is never
fabricated. SKIP covers: non-Linux host, `nix`/`timeout`/`tail` missing,
`python3` missing (one-line fallback JSON is written), or an explicitly
requested KVM lane on a host without usable `/dev/kvm`.

## Costs and timeouts

- First build: qemu, the guest kernel/initrd, and the guest system closure are
  substituted from `cache.nixos.org`; the local work is the store-disk image,
  the Nix-packaged `xsprof`, and the guest toplevel. Expect several minutes on
  a cold store and much less once warm. The runner and the guest are cached per
  source revision, so source-only changes rebuild `xsprof` and the disk image.
- Boot + verification: a few seconds under KVM; tens of seconds to a couple of
  minutes under TCG (software emulation). The harness default timeout is 1200 s
  (`--timeout`), and the runner is terminated early once the final marker is
  seen and the disposable VM has had a short grace period to reboot.
- The evidence files are small: the full serial console log, its trimmed
  excerpt, and the results JSON are all committed; the TCG run's three files
  total about 21 KB.

## Committed reference run

`docs/evidence/microvm/` holds a real TCG run from a container host with no
`/dev/kvm`: `console-tcg.log` (full serial capture), `console-tcg.trimmed.log`
(markers + qemu fallback excerpt), and `results-tcg.json` (`result: "PASS"`,
`checks: 10`, `duration_seconds: 50`, `accelerator_observed: "tcg"`,
`tcg_fallback_observed: true`, `host_mutation: false`). The console shows qemu
reporting `falling back to tcg` before the guest markers, so the evidence never
claims hardware acceleration it did not get.

## Troubleshooting

- `ReadOnlyFileSystem` from Nix: `qa/microvm_verify.sh` probes the inherited
  `XDG_CACHE_HOME`/`TMPDIR` for writability and falls back to workspace-local
  `.cache/nix` and `.cache/tmp`; if a sandbox still reports a read-only path,
  export the workspace dirs explicitly:
  `mkdir -p .cache/nix .cache/tmp && export XDG_CACHE_HOME=$PWD/.cache/nix TMPDIR=$PWD/.cache/tmp`.
- `nix build` says a path is not tracked by Git: the flake source only sees
  tracked files, so stage new files with `git add -N <path>` (intent-to-add)
  when iterating locally.
- Boot hangs: run `nix run .#xsprof-microvm-tcg` directly to watch the serial
  console, then check the raw `console-<variant>.log` and the qemu accelerator
  warnings. `falling back to tcg` means emulation; a usable `/dev/kvm` without
  that line means KVM acceleration.
- `microvm_verify: SKIP`: read `results-<variant>.json` `reason`; the lane never
  upgrades a skip to a pass. Auto selects `tcg` on a host without `/dev/kvm`.
