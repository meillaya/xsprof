# Security policy

`xsprof` is a read-only profiler. It does not write scheduler or memory policy,
`/proc`, `/sys`, or tracefs. Every serialized record carries
`host_mutation=false`.

## Reporting

Please report suspected vulnerabilities through the repository's private
security advisory channel (GitHub "Report a vulnerability") rather than a public
issue. Include the command, kernel, and a minimal sanitized input.

## Boundary

- The web console binds only `127.0.0.1`/`::1` and requires a random token.
  The token is printed in the URL fragment; query-token compatibility remains.
- Static assets are an explicit whitelist; there is no path traversal.
- API responses are `no-store`, `nosniff`, and covered by a restrictive CSP.
- Journals, manifests, and sidecars are validated for schema,
  `host_mutation=false`, and safe relative paths before use.
- Privacy redaction runs at serialization and on replay detail before display.
- The unsafe verb matrix refuses before dispatch; BPF remains VM-marker-gated
  and host-refused.
- No telemetry, external fonts/CDNs, or external network requests.
