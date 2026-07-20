# xsprof sched collector module (Phase 2 — story G002).
# Scheduler collectors: sched_switch, sched_wakeup, sched_migrate_task via
# perf_event_open, run-queue sampling from procfs schedstat, and
# wakeup-to-switch correlation.
set(XSPROF_SCHED_SOURCES
  src/sched/collector.cpp
)
