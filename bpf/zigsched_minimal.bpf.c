#include "zigsched_common.h"

struct bpf_map_def zigsched_stats SEC("maps") = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(struct zigsched_stats),
    .max_entries = ZIGSCHED_MINIMAL_NR_STATS,
};

struct bpf_map_def zigsched_policy_config SEC("maps") = {
    .type = BPF_MAP_TYPE_ARRAY,
    .key_size = sizeof(u32),
    .value_size = sizeof(struct zigsched_policy_config),
    .max_entries = 1,
};

SEC("struct_ops/zigsched_minimal_select_cpu")
u32 zigsched_minimal_select_cpu(struct task_struct *p, zigsched_s32 prev_cpu, u64 wake_flags) {
    (void)p;
    (void)wake_flags;
    if (prev_cpu < 0) {
        return 0;
    }
    return (u32)prev_cpu;
}

SEC("struct_ops/zigsched_minimal_enqueue")
void zigsched_minimal_enqueue(struct task_struct *p, u64 enq_flags) {
    u32 key = 0;
    struct zigsched_policy_config *config = bpf_map_lookup_elem(&zigsched_policy_config, &key);
    if (config != 0 && config->mode == ZIGSCHED_POLICY_MODE_FIFO) {
        scx_bpf_dsq_insert(p, ZIGSCHED_DSQ_FIFO, SCX_SLICE_DFL, enq_flags);
        return;
    }
    scx_bpf_dsq_insert_vtime(p, ZIGSCHED_DSQ_VTIME, SCX_SLICE_DFL, 0, enq_flags);
}

SEC("struct_ops/zigsched_minimal_dispatch")
void zigsched_minimal_dispatch(zigsched_s32 cpu, struct task_struct *prev) {
    (void)cpu;
    (void)prev;
}

SEC("zigsched/build_probe")
int zigsched_minimal_build_probe(void *ctx) {
    (void)ctx;
    return ZIGSCHED_BUILD_PROBE_OK;
}

struct sched_ext_ops zigsched_minimal_ops SEC("struct_ops/zigsched_minimal_ops") = {
    .name = "zigsched_minimal",
    .flags = SCX_OPS_SWITCH_PARTIAL,
    .select_cpu = zigsched_minimal_select_cpu,
    .enqueue = zigsched_minimal_enqueue,
    .dispatch = zigsched_minimal_dispatch,
};

char zigsched_license[] SEC("license") = "GPL";
