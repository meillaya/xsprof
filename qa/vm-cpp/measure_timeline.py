#!/usr/bin/env python3
"""Measure wall time + peak RSS of `xsprof timeline` on a large journal."""
import subprocess, resource, time, sys
BIN = "/tmp/xsprof-build2/xsprof"
JOURNAL = "evidence/lab/large-capture/journal.jsonl"
chunk = sys.argv[1] if len(sys.argv) > 1 else "100000"
cmd = [BIN, "timeline", "--input", JOURNAL, "--chunk-size", chunk]
start = time.time()
p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
elapsed = time.time() - start
ru = resource.getrusage(resource.RUSAGE_CHILDREN)
print(f"exit={p.returncode} elapsed={elapsed:.1f}s peak_rss_mb={ru.ru_maxrss/1024:.1f} chunk_size={chunk}")
