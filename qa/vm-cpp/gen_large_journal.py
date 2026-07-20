#!/usr/bin/env python3
"""Generate a large synthetic xsprof event journal to stress-test timeline chunking."""
import sys, json, random
n = int(sys.argv[1]) if len(sys.argv) > 1 else 2_000_000
out = sys.argv[2] if len(sys.argv) > 2 else "evidence/lab/large-capture/journal.jsonl"
comms = ["swapper/0","kworker/0:1","ksoftirqd/0","rcu_sched","xsprof","python3","nginx","node","java","stress-ng"]
import os
os.makedirs(os.path.dirname(out), exist_ok=True)
ts = 0
with open(out, "w") as f:
    for i in range(n):
        ts += random.randint(500, 5000)
        kind = random.choice(["sched_switch","sched_switch","sched_switch","sched_wakeup","page_fault"])
        e = {"schema":"xsprof/event/v1","event":kind,"ts_ns":ts,
             "cpu":random.randint(0,15),"pid":random.randint(0,4000),"tid":random.randint(0,4000),
             "a":random.randint(0,4000),"b":random.randint(0,4000),"c":0,
             "comm":random.choice(comms),"host_mutation":False}
        f.write(json.dumps(e, separators=(",",":")) + "\n")
print(f"wrote {n} events to {out}")
