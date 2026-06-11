#include "zigsched_common.h"

struct bpf_map_def zigsched_stats SEC("maps") = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(u64),
    .max_entries = ZIGSCHED_MINIMAL_NR_STATS,
};

struct bpf_map_def zigsched_events SEC("maps") = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(u64),
    .max_entries = ZIGSCHED_MINIMAL_NR_EVENTS,
};

struct bpf_map_def zigsched_policy_config SEC("maps") = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(struct zigsched_policy_config),
    .max_entries = 1,
};

static __always_inline void zigsched_counter_increment(void *map, u32 key) {
    u64 *value = bpf_map_lookup_elem(map, &key);
    if (value != 0) {
        __sync_fetch_and_add(value, 1);
    }
}

static __always_inline void zigsched_stats_increment(u32 key) {
    zigsched_counter_increment(&zigsched_stats, key);
}

static __always_inline void zigsched_event_increment(u32 key) {
    zigsched_counter_increment(&zigsched_events, key);
}

SEC("struct_ops/zigsched_minimal_init")
zigsched_s32 zigsched_minimal_init(void) {
    zigsched_s32 rc = scx_bpf_create_dsq(ZIGSCHED_DSQ_FIFO, -1);
    if (rc != 0) {
        zigsched_event_increment(ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED);
        return rc;
    }

    rc = scx_bpf_create_dsq(ZIGSCHED_DSQ_VTIME, -1);
    if (rc != 0) {
        zigsched_event_increment(ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED);
        return rc;
    }

    return 0;
}

SEC("struct_ops/zigsched_minimal_select_cpu")
zigsched_s32 zigsched_minimal_select_cpu(struct task_struct *p, zigsched_s32 prev_cpu, u64 wake_flags) {
    bool direct = 0;
    zigsched_s32 cpu;

    zigsched_stats_increment(ZIGSCHED_STAT_SELECT_CPU_CALLS);
    cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &direct);
    if (direct) {
        zigsched_stats_increment(ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS);
        scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
    }

    if (cpu >= 0) {
        return cpu;
    }

    zigsched_event_increment(ZIGSCHED_EVENT_SELECT_CPU_FALLBACK);
    if (prev_cpu >= 0) {
        return prev_cpu;
    }
    return 0;
}

SEC("struct_ops/zigsched_minimal_enqueue")
void zigsched_minimal_enqueue(struct task_struct *p, u64 enq_flags) {
    u32 key = 0;
    struct zigsched_policy_config *config = bpf_map_lookup_elem(&zigsched_policy_config, &key);
    zigsched_stats_increment(ZIGSCHED_STAT_ENQUEUE_CALLS);
    if (config != 0 && config->mode == ZIGSCHED_POLICY_MODE_FIFO) {
        zigsched_stats_increment(ZIGSCHED_STAT_FIFO_INSERTS);
        scx_bpf_dsq_insert(p, ZIGSCHED_DSQ_FIFO, SCX_SLICE_DFL, enq_flags);
        return;
    }
    zigsched_stats_increment(ZIGSCHED_STAT_VTIME_INSERTS);
    scx_bpf_dsq_insert_vtime(p, ZIGSCHED_DSQ_VTIME, SCX_SLICE_DFL, 0, enq_flags);
}

SEC("struct_ops/zigsched_minimal_dispatch")
void zigsched_minimal_dispatch(zigsched_s32 cpu, struct task_struct *prev) {
    (void)cpu;
    (void)prev;
    zigsched_stats_increment(ZIGSCHED_STAT_DISPATCH_CALLS);
    if (scx_bpf_dsq_move_to_local(ZIGSCHED_DSQ_FIFO)) {
        zigsched_stats_increment(ZIGSCHED_STAT_FIFO_DISPATCHES);
        return;
    }
    if (scx_bpf_dsq_move_to_local(ZIGSCHED_DSQ_VTIME)) {
        zigsched_stats_increment(ZIGSCHED_STAT_VTIME_DISPATCHES);
        return;
    }
    zigsched_event_increment(ZIGSCHED_EVENT_DISPATCH_EMPTY);
}

SEC("zigsched/build_probe")
int zigsched_minimal_build_probe(void *ctx) {
    (void)ctx;
    return ZIGSCHED_BUILD_PROBE_OK;
}

struct sched_ext_ops zigsched_minimal_ops SEC("struct_ops/zigsched_minimal_ops") = {
    .name = "zigsched_minimal",
    .flags = SCX_OPS_SWITCH_PARTIAL,
    .init = zigsched_minimal_init,
    .select_cpu = zigsched_minimal_select_cpu,
    .enqueue = zigsched_minimal_enqueue,
    .dispatch = zigsched_minimal_dispatch,
};

char zigsched_license[] SEC("license") = "GPL";
