#include "xsprof/pipeline.hpp"

namespace xsprof::pipeline {

json::Value Aggregates::to_json() const {
    json::Value v = json::Value::make_object();
    v.set("schema", json::Value("xsprof/aggregates/v1"));
    // NUMA / placement
    v.set("remote_fault_ratio", json::Value(remote_fault_ratio));
    v.set("dominant_node", json::Value(dominant_node));
    v.set("task_cpu_node", json::Value(task_cpu_node));
    // scheduler
    v.set("migrations", json::Value(migrations));
    v.set("cross_llc_migration", json::Value(cross_llc_migration));
    v.set("llc_domains", json::Value(llc_domains));
    v.set("wakeups", json::Value(wakeups));
    v.set("unnecessary_wakeups", json::Value(unnecessary_wakeups));
    v.set("lock_contentions", json::Value(lock_contentions));
    v.set("avg_lock_wait_ms", json::Value(avg_lock_wait_ms));
    // cache / memory
    v.set("llc_misses", json::Value(llc_misses));
    v.set("tlb_misses", json::Value(tlb_misses));
    v.set("page_faults", json::Value(page_faults));
    v.set("remote_hitm", json::Value(remote_hitm));
    // allocator
    v.set("buddy_fragmentation", json::Value(buddy_fragmentation));
    v.set("small_alloc_churn", json::Value(small_alloc_churn));
    // priority inversion
    v.set("priority_inversion_observed", json::Value(priority_inversion_observed));
    // capability context
    v.set("pmu_collected", json::Value(pmu_collected));
    v.set("sched_collected", json::Value(sched_collected));
    // read-only invariant
    v.set("host_mutation", json::Value(false));
    return v;
}

} // namespace xsprof::pipeline
