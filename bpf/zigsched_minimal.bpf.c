#include "zigsched_common.h"

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, ZIGSCHED_MINIMAL_NR_STATS);
    __type(key, u32);
    __type(value, u64);
} zigsched_stats SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, ZIGSCHED_MINIMAL_NR_EVENTS);
    __type(key, u32);
    __type(value, u64);
} zigsched_events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct zigsched_policy_config);
} zigsched_policy_config SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct zigsched_cgroup_policy);
} zigsched_cgroup_policy SEC(".maps");

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

static __always_inline void zigsched_record_cgroup_knobs(struct zigsched_cgroup_policy *policy) {
    policy->callback_observed_knobs = ZIGSCHED_CGROUP_KNOB_WEIGHT_OBSERVED;
    policy->observed_knobs = ZIGSCHED_CGROUP_KNOB_CPUSET_OBSERVED | ZIGSCHED_CGROUP_KNOB_PRESSURE_OBSERVED;
    policy->deferred_knobs = ZIGSCHED_CGROUP_KNOB_CPU_MAX_DEFERRED | ZIGSCHED_CGROUP_KNOB_UCLAMP_DEFERRED;
}

SEC("struct_ops/zigsched_minimal_select_cpu")
zigsched_s32 BPF_PROG(zigsched_minimal_select_cpu, struct task_struct *p, zigsched_s32 prev_cpu, u64 wake_flags) {
    bool direct = 0;
    zigsched_s32 cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &direct);
    zigsched_stats_increment(ZIGSCHED_STAT_SELECT_CPU_CALLS);
    if (direct) {
        zigsched_stats_increment(ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS);
    } else {
        zigsched_event_increment(ZIGSCHED_EVENT_SELECT_CPU_FALLBACK);
    }
    return cpu;
}

SEC("struct_ops.s/zigsched_minimal_init")
zigsched_s32 BPF_PROG(zigsched_minimal_init) {
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

SEC("struct_ops/zigsched_minimal_cgroup_init")
zigsched_s32 BPF_PROG(zigsched_minimal_cgroup_init, struct cgroup *cgrp, struct scx_cgroup_init_args *args) {
    u32 key = 0;
    struct zigsched_cgroup_policy *policy = bpf_map_lookup_elem(&zigsched_cgroup_policy, &key);
    (void)cgrp;
    (void)args;
    zigsched_stats_increment(ZIGSCHED_STAT_CGROUP_INIT_CALLS);
    if (policy != 0) {
        zigsched_record_cgroup_knobs(policy);
    }
    return 0;
}

SEC("struct_ops/zigsched_minimal_cgroup_exit")
void BPF_PROG(zigsched_minimal_cgroup_exit, struct cgroup *cgrp) {
    (void)cgrp;
    zigsched_stats_increment(ZIGSCHED_STAT_CGROUP_EXIT_CALLS);
}

SEC("struct_ops/zigsched_minimal_cgroup_prep_move")
zigsched_s32 BPF_PROG(zigsched_minimal_cgroup_prep_move, struct task_struct *p, struct cgroup *from, struct cgroup *to) {
    (void)p;
    (void)from;
    (void)to;
    zigsched_stats_increment(ZIGSCHED_STAT_CGROUP_MOVE_CALLS);
    zigsched_event_increment(ZIGSCHED_EVENT_CGROUP_MOVE_OBSERVED);
    return 0;
}

SEC("struct_ops/zigsched_minimal_cgroup_move")
void BPF_PROG(zigsched_minimal_cgroup_move, struct task_struct *p, struct cgroup *from, struct cgroup *to) {
    u32 key = 0;
    struct zigsched_cgroup_policy *policy = bpf_map_lookup_elem(&zigsched_cgroup_policy, &key);
    (void)p;
    (void)from;
    (void)to;
    if (policy != 0) {
        __sync_fetch_and_add(&policy->move_generation, 1);
    }
}

SEC("struct_ops/zigsched_minimal_cgroup_cancel_move")
void BPF_PROG(zigsched_minimal_cgroup_cancel_move, struct task_struct *p, struct cgroup *from, struct cgroup *to) {
    (void)p;
    (void)from;
    (void)to;
    zigsched_event_increment(ZIGSCHED_EVENT_CGROUP_MOVE_OBSERVED);
}

SEC("struct_ops/zigsched_minimal_cgroup_set_weight")
void BPF_PROG(zigsched_minimal_cgroup_set_weight, struct cgroup *cgrp, zigsched_u32 weight) {
    u32 key = 0;
    struct zigsched_cgroup_policy *policy = bpf_map_lookup_elem(&zigsched_cgroup_policy, &key);
    (void)cgrp;
    zigsched_stats_increment(ZIGSCHED_STAT_CGROUP_SET_WEIGHT_CALLS);
    zigsched_event_increment(ZIGSCHED_EVENT_CGROUP_WEIGHT_OBSERVED);
    if (policy != 0) {
        policy->last_weight = weight;
        __sync_fetch_and_add(&policy->weight_generation, 1);
        zigsched_record_cgroup_knobs(policy);
        zigsched_stats_increment(ZIGSCHED_STAT_CGROUP_WEIGHT_OBSERVED);
    }
}

SEC("struct_ops/zigsched_minimal_enqueue")
void BPF_PROG(zigsched_minimal_enqueue, struct task_struct *p, u64 enq_flags) {
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
void BPF_PROG(zigsched_minimal_dispatch, zigsched_s32 cpu, struct task_struct *prev) {
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

struct sched_ext_ops zigsched_minimal_ops SEC(".struct_ops") = {
    .name = "zigsched_minimal",
    .flags = SCX_OPS_SWITCH_PARTIAL,
    .select_cpu = (void *)zigsched_minimal_select_cpu,
    .init = (void *)zigsched_minimal_init,
    .cgroup_init = (void *)zigsched_minimal_cgroup_init,
    .cgroup_exit = (void *)zigsched_minimal_cgroup_exit,
    .cgroup_prep_move = (void *)zigsched_minimal_cgroup_prep_move,
    .cgroup_move = (void *)zigsched_minimal_cgroup_move,
    .cgroup_cancel_move = (void *)zigsched_minimal_cgroup_cancel_move,
    .cgroup_set_weight = (void *)zigsched_minimal_cgroup_set_weight,
    .enqueue = (void *)zigsched_minimal_enqueue,
    .dispatch = (void *)zigsched_minimal_dispatch,
};

char zigsched_license[] SEC("license") = "GPL";
