# xsprof wire schemas

P1 adds the canonical JSON Schema files here:

- `event.v1.schema.json`
- `preflight.v1.schema.json`
- `aggregates.v1.schema.json`
- `advisor-report.v1.schema.json`
- `capture-summary.v1.schema.json`
- `journal.v1.schema.json`
- `ui-session.v1.schema.json`
- `ui-stream.v1.schema.json`

The canonical namespace is `xsprof/*`. Legacy `zig-scheduler/*` schemas live
on `archive/cpp-0.1.0` and are not served by this rewrite.

Key ordering is lexical and compact; required fields are validated at the
boundary, and every record carries `host_mutation=false`.
