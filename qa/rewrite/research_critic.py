#!/usr/bin/env python3
"""Professor-critic gate for the C++ rewrite research mission.

Grades the seven research deliverables against rubric criteria A-G.
Exits 0 only when every deliverable exists, is substantive, and each
criterion's required evidence keywords are present. This is a gate, not
a promise: PASS here means the research artifact is internally complete
and grounded, not that the project is production ready.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs" / "rewrite"

# deliverable -> minimum bytes
DELIVERABLES = {
    "ARCHITECTURE.md": 1500,
    "IMPLEMENTATION_PLAN.md": 1500,
    "NIX_DEV_ENV.md": 1200,
    "COLLECTORS.md": 1500,
    "ADVISOR.md": 1500,
    "VISUALIZATION.md": 1200,
    "SAFETY.md": 1200,
}

# criterion -> (required substrings across the whole docs/rewrite corpus)
CRITERIA = {
    "A_scope_fidelity": [
        "context switch", "wakeup", "migration", "NUMA", "run queue",
        "priority inversion", "lock contention", "page fault", "TLB",
        "huge page", "cache miss", "allocator fragmentation", "malloc",
        "false sharing", "sched_setaffinity",
    ],
    "B_kernel_grounding": [
        "sched_switch", "sched_wakeup", "perf_event_open", "sched_ext",
        "/proc", "PMU",
    ],
    "C_build_reproducibility": [
        "nix", "cmake", "ninja", "libbpf", "clang",
    ],
    "D_safety_preservation": [
        "fail-closed", "read-only", "host_mutation", "opt-in", "privacy",
    ],
    "E_testability": [
        "test", "golden", "fixture", "fail closed",
    ],
    "F_implementability": [
        "milestone", "phase", "compile", "read-only",
    ],
    "G_evidence_vs_inference": [
        "evidence", "assumption", "source",
    ],
}


def main() -> int:
    failures: list[str] = []
    corpus_parts: list[str] = []

    for name, min_bytes in DELIVERABLES.items():
        path = DOCS / name
        if not path.exists():
            failures.append(f"DELIVERABLE MISSING: {name}")
            continue
        data = path.read_text(encoding="utf-8", errors="replace")
        corpus_parts.append(data)
        if len(data.encode("utf-8")) < min_bytes:
            failures.append(f"DELIVERABLE TOO SHORT: {name} < {min_bytes} bytes")

    corpus = "\n".join(corpus_parts).lower()

    for criterion, needles in CRITERIA.items():
        missing = [n for n in needles if n.lower() not in corpus]
        if missing:
            failures.append(f"CRITERION {criterion} MISSING EVIDENCE: {', '.join(missing)}")

    if failures:
        print("RESEARCH CRITIC VERDICT: FAIL")
        for f in failures:
            print(f"  - {f}")
        return 1

    print("RESEARCH CRITIC VERDICT: PASS")
    print(f"  deliverables: {len(DELIVERABLES)} present and substantive")
    print(f"  criteria: {len(CRITERIA)} satisfied with grounded keywords")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
