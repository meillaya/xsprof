# BPF gate (VM-only)

The BPF lane is a **gate**, not a host feature. `bpf-gate` refuses every host
before any BPF syscall. It runs only when an explicit hypervisor marker is
present in `/sys/class/dmi/id/product_name`, `sys_vendor`, or
`/sys/hypervisor/type` (QEMU/KVM, Virtual, VMware, Xen, Hyper-V).

## What it does

1. Reads the VM marker; absent → `REFUSE` with `host_mutation:false`.
2. Optionally `dlopen`s `libbpf.so.1` and reports whether the API is present.
3. Loads a two-instruction, verifier-safe `BPF_PROG_TYPE_TRACEPOINT` program
   (`r0 = 0; exit`) with `BPF_PROG_LOAD`.
4. Opens `sched_switch` as a disabled perf tracepoint, attaches the program
   with `PERF_EVENT_IOC_SET_BPF`, enables it for 200 ms, then disables and
   closes everything.
5. Serializes `xsprof/bpf-gate/v1` with `host_mutation:false`.

The program reads nothing, writes nothing, and exports no events. It proves
the load/attach path under the VM gate without changing scheduler behavior.

The unsafe `bpf` verb remains refused by the safety matrix; the read-only gate
is named `bpf-gate`. The lane is a proof of the load/attach path, not a data
source: perf remains the event path, and the BPF gate is not part of the happy
path for users.

## Verification

The gate was validated once in a disposable Fedora aarch64 podman VM with a
hypervisor marker, libbpf present, and tracefs mounted: `READY`,
`attached:true`, `libbpf:true`, `host_mutation:false`. That run's evidence is
attached to the release, not committed to git. On macOS/Linux hosts without a
hypervisor marker the same command returns `capability:"SKIP"` or `"REFUSE"` and
exits 1.

## Limits

- No BPF event extraction yet; the perf collector remains the data path.
- Requires a VM marker, tracefs, CAP_BPF/perfmon, and a permissive kernel.
- No elevation or sysctl changes are performed by the tool.
