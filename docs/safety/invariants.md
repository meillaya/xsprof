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
7. The UI and web server expose no mutation endpoint.

## Privacy

1. Never collect argv or environment.
2. `comm` is bounded to 15 bytes.
3. Sensitive `key=value` / `key: value` material is redacted; value markers are
   detected case-insensitively.
4. Control characters are sanitized before rendering or embedding in JSON.
5. The UI renders already-sanitized text; it does not fetch or reveal paths,
   command lines, or secrets.
6. No telemetry, external fonts/CDNs, or external network requests.

## Data integrity

1. Canonical JSON: keys strictly ascending, compact separators, stable
   formatting; NaN/inf serialize as `null`.
2. Untrusted input is bounded by line size, event count, nesting depth, and
   field length.
3. Malformed rows become explicit incidents; they never crash the process or
   silently disappear.
4. Lost samples are explicit markers, never interpolation.
5. Replay rejects wrong schema, `host_mutation=true`, malformed/non-monotonic
   stream sequences, and invalid required fields.
6. `SafePath` confines daemon/state outputs; output-open failures are errors.
7. Capability SKIP/REFUSE is surfaced with the exact reason; unavailable data
   is never rendered as zero.

## Automated gates

- `qa/unsafe_cli_matrix.sh` — refusal matrix and exit codes.
- `qa/no_host_mutation.sh` — static scan and optional runtime trace.
- `qa/privacy_scan.sh` — seeded secrets must not appear in output/snapshots.
- `qa/vendor_hash.sh` — offline reference integrity.
- Golden bytes and UI snapshots — determinism.
- Linux fail-closed tests; VM tests marked separately.
