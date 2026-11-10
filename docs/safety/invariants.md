# Safety invariants

These are release-blocking, not aspirational.

## Host

1. Read-only: no writes to `/proc`, `/sys`, tracefs, cgroups, affinities,
   priorities, or scheduler policy.
2. `host_mutation=false` appears on every serialized record.
3. Nine unsafe verbs and unknown verbs refuse non-zero before dispatch.
4. No privilege elevation, no `sudo`, no setuid, no capability acquisition.
5. BPF load refuses on the host; the VM lane requires a marker file plus
   audit/rollback identity, and SKIPs when BTF/libbpf is absent.
6. Advisor recommendations are printed/copied only; no syscall path applies
   them.
7. There is no network surface: no server, listener, HTTP/SSE bridge, browser
   asset lane, telemetry, or external request. The optional viewer may
   start/stop its own read-only capture/recorder after the perf probe is READY
   and the Settings opt-in is set; it writes only its own state, export, audit,
   and settings directories and never changes host policy. External recorders
   are attach-only.

## Privacy

1. Never collect argv or environment.
2. `comm` is bounded to 15 bytes.
3. Sensitive `key=value` / `key: value` material is redacted; value markers are
   detected case-insensitively.
4. Control characters are sanitized before rendering or embedding in JSON.
5. The UI renders already-sanitized text; it does not fetch or reveal paths,
   command lines, or secrets.
6. No telemetry, external fonts/CDNs, or external network requests.
7. The accessibility tree contains only labels/values already rendered by the
   console; no raw event detail, argv, environment, or secrets.
8. Settings and the audit ring are bounded canonical records and store no
   argv, environment, tokens, or raw event detail.

## Data integrity

1. Canonical JSON: keys strictly ascending, compact separators, stable
   formatting; NaN/inf serialize as `null`.
2. Untrusted input is bounded by line size, event count, nesting depth, and
   field length.
3. Malformed rows become explicit incidents or counted malformed rows; they
   never crash the process or silently disappear.
4. Lost samples are explicit markers, never interpolation.
5. Replay rejects wrong schema, missing/`true` `host_mutation`, malformed rows,
   oversized lines, and deeply nested JSON. Legacy cross-ring timestamp skew is
   tolerated and counted in `metrics.out_of_order`; new capture batches are
   sorted before journaling.
6. `SafePath` confines daemon/state outputs; manifests/sidecars validate
   relative paths, schema, and `host_mutation`; output-open failures are errors.
7. Capability SKIP/REFUSE is surfaced with the exact reason; unavailable data
   is never rendered as zero.

## Automated gates

Run by `./tools/zig build check` (fast, tool-light) and `check-ci` (adds
platform/media lanes, repo-size and docs-links; a missing tool fails instead of
skipping):

- `qa/unsafe_cli_matrix.sh` — refusal matrix and exit codes.
- `qa/no_host_mutation.sh` — static scan plus optional runtime trace.
- `qa/privacy_scan.sh` — seeded secrets must not appear in output.
- `qa/cli_parity.sh` — process-level read-only CLI behavior and exit codes.
- `qa/compact_roundtrip.sh` — compact segment decode/verify, corruption,
  truncation, and mixed legacy state.
- `qa/a11y_smoke.sh` — canonical accessibility tree, focus order, deterministic
  bytes (no window).
- Unit/integration/fuzz tests plus `tests/schema.zig` — canonical wire bytes,
  schema conformance, bounded parsers.
- `qa/lines.sh` — 1,000-line responsibility limit; generated files and tests
  exempt.
- `qa/version_sync.sh`, `qa/script_syntax.sh` — version lockstep and shell
  syntax.
- `qa/repo_size.sh`, `qa/docs_links.sh` — tracked-tree size budgets and
  markdown link integrity.
- Platform smokes (`qa/xvfb_smoke.sh`, `qa/native_live_smoke.sh`,
  `qa/macos_smoke.sh`) and `tools/screenshots.sh --check` — hidden-window
  rendering and committed-still provenance; never a real window.
- Root-only `qa/live_smoke.sh`, `qa/service_smoke.sh`, and
  `qa/retention_bench.sh` — run via `./tools/zig build check-vm` in a
  disposable Linux VM only.
