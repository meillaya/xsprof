# v0.5.0 KVM VM acceptance evidence

Real output from a disposable KVM podman machine running the three root-only
gates on the committed 0.4.0 binary (HEAD `6b3c490`). Nothing here is
synthesised: every `.log` is captured stdout+stderr of the exact command in its
header, including the exit code.

## Environment

| item | value |
|---|---|
| host | Linux x86_64, kernel 7.3.1-1-cachyos, 16 CPU, /dev/kvm r/w |
| podman | 5.8.7 (provider qemu, `-accel kvm -cpu host`, 4 vCPU / 4096 MiB / 24 GiB) |
| VM | Fedora CoreOS 44.20260928.3.2, kernel 7.2.7-200.fc44.x86_64, systemd PID 1 |
| VM clock | `perf_event_paranoid=2` with CAP_PERFMON as root; tracefs rw at /sys/kernel/tracing |
| binary | committed HEAD `6b3c490b4fa0955e5fcd93fd19b50a9bb048a0eb`, `xsprof 0.4.0` |
| sha256 | `cc438d08aeb9e1e94e0ebb9f9a7c30471800ff58baf504b99ef379136777c3dd` |
| staging | binary + `qa/` + `fixtures/` + `schemas/` under `/var/tmp/xsprof` (sha verified in-VM) |

The live working tree was dirty with concurrent v0.5.0 edits, so the binary was
built in an isolated `git worktree` detached at HEAD; see
[00b-committed-binary.log](00b-committed-binary.log).

## Gates

| gate | command | result |
|---|---|---|
| live_smoke | `sudo -n sh /var/tmp/xsprof/qa/live_smoke.sh` | **PASS** — 93,534 rows, minor faults 1,914, SIGTERM clean, BPF READY (VM marker) |
| service_smoke | `sudo -n sh /var/tmp/xsprof/qa/service_smoke.sh` | **PASS** — 3 compact segments, 421,068 extracted lines, lock refusal + SIGKILL recovery |
| retention_bench | `sudo -n env KEEP=1 sh /var/tmp/xsprof/qa/retention_bench.sh 600000 0 2G yes` | **PASS** — 51,912,224 retained events, 12.06 B/event, covered 600.01 s, 0 lost, 10 sidecars |

Retention acceptance: bytes/event `12.06 <= 25.6`, covered_s `600.01 >= 590`,
retained loss `0`, history loss `0`, canonical/compact ratio `13.28x >= 4`
(recomputed — see caveat), byte budget projected 2,058.55 s but the 600 s age
cap bound first.

Machine-readable summary: [07-results.json](07-results.json).

## Files

| file | contents |
|---|---|
| `00-host-facts.txt` | host kernel, CPU, memory, KVM, podman/QEMU versions, cached FCOS image |
| `00b-committed-binary.log` | HEAD provenance, clean-worktree build, binary sha, dirty-tree note |
| `00c-gate-provenance.log` | qa script sha256 host-vs-VM, fixture/schema counts |
| `01-provisioning.log` | exact `--provider` probe failure, `podman machine init/start`, inspect JSON, qemu/gvproxy/virtiofsd processes |
| `02-vm-setup.log` | in-VM staging, sha verification, `xsprof --version`, `doctor --json` |
| `02b-vm-probe.log` | VM prerequisite probe (tools, tracefs, perf, network) |
| `02c-doctor.json` | full doctor JSON (all perf/tracefs checks READY) |
| `03-live-smoke.log` | live_smoke gate output + exit code |
| `04-service-smoke.log` | service_smoke gate output + exit code |
| `05-retention-bench.log` | retention_bench gate output (JSON metrics line + PASS) + exit code |
| `05b-retention-artifacts.log` | retention state summary + artifact tarball sha |
| `06-canonical-ratio.log` | empty gate sample diagnosis + two same-VM canonical 1 s samples (160.10 B/event, 13.28x) |
| `07-results.json` | provisional machine-readable acceptance summary |
| `retention-artifacts/` | real `manifest.json`, `daemon-result.json`, `history-result.json`, `markers.ndjson`, `sample.ndjson` from the retained state |

## Caveats (honest limits)

- `qa/retention_bench.sh` samples canonical events with `capture --last 1s`
  **after** the daemon has stopped; that wall-clock window is empty, so the
  script reports `canonical_bytes_per_event: 0.0` and skips its conditional
  ratio check. The 13.28x ratio in `06-canonical-ratio.log` is recomputed from
  two independent same-VM 1 s `xsprof record` samples and is labelled
  supplemental; it is not the script's own output. The other retention hard
  criteria were reported by the gate itself.
- podman 5.8.7 has no `--provider` flag. The literal task command
  `podman machine init ... --provider qemu` fails with `unknown flag:
  --provider` (captured in 01-provisioning.log); init was rerun without it
  (provider is inferred as qemu on Linux).
- `retention_bench.sh 600000 0 2G yes` was run with 0 workers as specified:
  86,517 events/s is the VM's idle/housekeeping rate, not a synthetic load.
- The VM was left running for inspection. Remove it with
  `podman machine rm -f xsprof-vm`; the retained state lives in the VM at
  `/var/tmp/xsprof-retention.*`.

## Reproduction

`qa/vm_acceptance.sh` automates exactly this: workspace
`XDG_RUNTIME_DIR`/`TMPDIR`, QEMU/gvproxy/virtiofsd PATH discovery, podman
machine init/start, committed-HEAD worktree build, staging, all three gates,
and evidence collection into this directory. It fails closed on a missing
PASS marker and recomputes the canonical ratio itself.

## Cleanup and harness validation

The machine was removed after the evidence was copied:
'podman machine rm -f xsprof-vm' (exit 0, 'podman machine list' empty, a
comm-based process check finds no qemu/gvproxy/virtiofsd left -
[08-cleanup.log](08-cleanup.log)). A 0-byte
~/.config/containers/podman/machine/qemu/xsprof-vm.lock is normal podman
bookkeeping.

'qa/vm_acceptance.sh' was exercised in '--check' mode end to end (provision ->
build committed HEAD -> stage with in-VM sha verification -> doctor READY).
A full end-to-end harness trial was started and aborted mid 'service_smoke' at
the Lead's cleanup request; it is not claimed here as a full harness PASS. The
gate evidence above comes from the direct documented commands.
