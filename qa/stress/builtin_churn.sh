#!/usr/bin/env bash
set -euo pipefail
workers="${1:-4}"
case "$workers" in [1-9]|[1-9][0-9]) ;; *) echo 'FAIL: workers must be 1-99' >&2; exit 1 ;; esac
pids=""
cleanup() {
  for pid in $pids; do kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT
for i in $(seq 1 "$workers"); do
  ( end=$((SECONDS + 1)); n=0; while [ "$SECONDS" -lt "$end" ]; do n=$((n + 1)); :; done; echo "worker=$i iterations=$n" ) &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
pids=""
echo 'PASS: built-in CPU/process churn completed'
