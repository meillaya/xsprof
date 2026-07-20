#!/usr/bin/env bash
# Independent code review via the local claude CLI (a distinct model/instance
# that did not write this code). Concatenates the safety-critical sources and
# asks for a concrete, critical review against the fail-closed safety contract.
set -uo pipefail
cd /home/mei/projects/exasphere
mkdir -p .omx/artifacts
OUT=".omx/artifacts/ask-claude-code-review-$(date +%s).md"
{
  cat <<'PROMPT'
You are an INDEPENDENT code reviewer. You did NOT write this code. Review the following C++ from xsprof, a Linux scheduler/memory profiler.

The project's safety contract (must hold): fail-closed read-only by default; host_mutation=false on every record; unsafe verbs (load/attach/enable/mutate/apply) refuse with non-zero exit; mutation is VM-lab-only (audit-id + rollback-id + lab marker); capability-gated collectors SKIP when unprivileged and never auto-elevate; privacy filtering excludes argv/env/secrets from runtime samples; advisor recommendations are printed, never auto-applied.

Report CONCRETE findings, each with file:line and severity (critical/high/medium/low):
(1) correctness bugs; (2) safety-invariant violations; (3) resource leaks (fd/mmap/memory); (4) error-handling gaps; (5) security issues (buffer overflow, untrusted-input parsing, integer overflow).
Then give an overall verdict: APPROVE / APPROVE WITH COMMENTS / REQUEST CHANGES. Be specific and critical; do not rubber-stamp. If you find no issues in a category, say so.

PROMPT
  for f in src/collectors/live_capture.cpp src/safety/safety.cpp src/core/privacy.cpp \
           src/daemon/daemon.cpp src/sched/collector.cpp src/memory/collector.cpp \
           src/cli/main.cpp src/viz/chrome_trace.cpp src/advisor/advisor.cpp; do
    echo "// ===== FILE: $f ====="
    cat "$f"
    echo ""
  done
} | claude -p > "$OUT" 2>&1
echo "REVIEW_ARTIFACT=$OUT"
