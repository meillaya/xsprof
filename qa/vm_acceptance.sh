#!/bin/sh
# Deprecated wrapper: durable VM verification now lives in tools/vm_lab.sh.
#
# The old harness wrote evidence into docs/evidence/ (which the repo diet
# removed; committed evidence is policy-forbidden), assumed the real $HOME, and
# had no write-scope audit. tools/vm_lab.sh keeps every mutable host path under
# .vm/ and dist/vm/, pins HOME/XDG/TMPDIR for rootless podman, and records a
# canonical xsprof/vm-evidence/v1 manifest. This wrapper keeps the historical
# entry point working:
#
#   qa/vm_acceptance.sh          -> tools/vm_lab.sh gates --all
#   qa/vm_acceptance.sh --check  -> tools/vm_lab.sh probe
#   --destroy-vm                 -> accepted for compatibility (the lab always
#                                   destroys its disposable machine unless
#                                   --keep is passed to tools/vm_lab.sh)
#
# See docs/maintaining.md for the current workflow.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

case "${1:-}" in
    -h | --help)
        sed -n '2,22p' "$0"
        exit 0
        ;;
esac

CMD=gates
ALL=--all
for arg in "$@"; do
    case "$arg" in
        --check)
            CMD=probe
            ALL=
            ;;
        --destroy-vm) : ;;
        *)
            printf 'vm_acceptance: unknown argument: %s\n' "$arg" >&2
            printf 'vm_acceptance: use tools/vm_lab.sh directly for current options\n' >&2
            exit 2
            ;;
    esac
done

printf 'vm_acceptance: deprecated; forwarding to tools/vm_lab.sh %s %s\n' "$CMD" "$ALL" >&2
if [ -n "$ALL" ]; then
    exec sh "$ROOT/tools/vm_lab.sh" "$CMD" "$ALL"
fi
exec sh "$ROOT/tools/vm_lab.sh" "$CMD"
