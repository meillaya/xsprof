# xsprof memory collector module (Phase 3 — story G003).
# Memory collectors: software page faults, HW_CACHE dTLB and LLC misses,
# AMD IBS ibs_op path, hugepages, buddyinfo, and numa_maps pollers.
set(XSPROF_MEMORY_SOURCES
  src/memory/collector.cpp
)
