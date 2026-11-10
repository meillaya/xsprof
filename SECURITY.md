# Security policy

`xsprof` is a read-only scheduler flight recorder. It does not write scheduler
or memory policy, `/proc`, `/sys`, tracefs, or cgroups, and every serialized
record carries `host_mutation=false`.

## Reporting

Report suspected vulnerabilities through the repository's private security
advisory channel (GitHub "Report a vulnerability"), not a public issue. Include
the command, the kernel version, and a minimal sanitized input. Never attach
argv, environment variables, tokens, secrets, or unredacted operator paths.

## Boundary

- **No network surface.** The product ships no server, listener, HTTP/SSE
  bridge, browser asset lane, telemetry, external fonts/CDNs, or outbound
  requests. There is nothing to expose remotely.
- **No privileged writes.** Capture opens perf tracepoints and reads
  `/proc`/`/sys`/tracefs only. Capability probes return READY/DEGRADED/SKIP/
  REFUSE with a reason and never elevate or suggest elevation.
- **No mutation verbs.** `load`, `attach`, `enable`, `mutate`, `apply`,
  `sched-ext-attach`, `setaffinity`, `setpriority`, and `bind` refuse non-zero
  before dispatch. BPF stays VM-marker-gated and host-refused.
- **Bounded untrusted input.** Journals, manifests, sidecars, and compact
  segments are validated for schema, `host_mutation=false`, bounds, and safe
  relative paths before use. Malformed data becomes an explicit incident or
  loss marker; it never crashes the process or silently disappears.
- **Privacy.** Runtime samples never include argv, environment, secrets, or
  tokens. `comm` is bounded to 15 bytes; sensitive `key: value`/`key=value`
  material is redacted at serialization; control characters are sanitized
  before rendering/embedding.
- **Advisor is advice.** Findings are printed or copied, never applied.
  xsprof has no syscall path that applies a recommendation.
- **Viewer surfaces are local.** Accessibility bridges (macOS NSAccessibility,
  canonical tree JSON on Linux) expose only already-rendered labels/values.
  Settings and audit records contain no argv, environment, tokens, or raw event
  detail. Automated work never opens or captures a real window.
- **Capabilities are operator-owned.** Enabling live capture needs
  `CAP_PERFMON`/readable tracefs or `perf_event_paranoid <= 1`. xsprof documents
  the options (`docs/guides/capture-permissions.md`) and never changes kernel
  policy.
- **Unsigned viewer builds.** macOS viewer builds from source are ad-hoc
  signed and not notarized; no signed macOS artifact is published. Treat a
  locally built binary as untrusted software, not as a vendor-signed release.
