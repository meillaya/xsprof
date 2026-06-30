#ifndef ZIGSCHED_COMMON_H
#define ZIGSCHED_COMMON_H

typedef unsigned char __u8;
typedef unsigned short __u16;
typedef unsigned int __u32;
typedef unsigned long long __u64;
typedef signed int __s32;
typedef signed long long __s64;
typedef __u16 __be16;
typedef __u32 __be32;
typedef __u32 __wsum;
typedef unsigned char zigsched_u8;
typedef unsigned int zigsched_u32;
typedef unsigned long long zigsched_u64;
typedef zigsched_u32 u32;
typedef zigsched_u64 u64;
typedef int s32;
typedef int zigsched_s32;
#ifndef __cplusplus
typedef _Bool bool;
#endif

#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define ZIGSCHED_ABI_VERSION 3u
#define ZIGSCHED_BUILD_PROBE_OK 0
#define ZIGSCHED_MINIMAL_NR_STATS 13u
#define ZIGSCHED_MINIMAL_NR_EVENTS 6u
#define ZIGSCHED_DSQ_FIFO 0x5a195f1f0ULL
#define ZIGSCHED_DSQ_VTIME 0x5a195f1f1ULL
#define ZIGSCHED_STARVATION_NS_MAX 50000000ULL
#define ZIGSCHED_POLICY_MODE_FIFO 1ULL
#define ZIGSCHED_POLICY_MODE_VTIME 2ULL
#define ZIGSCHED_CGROUP_KNOB_WEIGHT_OBSERVED 1ULL
#define ZIGSCHED_CGROUP_KNOB_CPU_MAX_DEFERRED 2ULL
#define ZIGSCHED_CGROUP_KNOB_CPUSET_OBSERVED 4ULL
#define ZIGSCHED_CGROUP_KNOB_PRESSURE_OBSERVED 8ULL
#define ZIGSCHED_CGROUP_KNOB_UCLAMP_DEFERRED 16ULL
#define SCX_OPS_SWITCH_PARTIAL 8ULL
#define SCX_DSQ_LOCAL 9223372036854775808ULL
#define SCX_DSQ_GLOBAL 9223372036854775809ULL
#define SCX_SLICE_DFL 20000000ULL
#define BPF_MAP_TYPE_ARRAY 2u

struct task_struct {
    zigsched_u8 __opaque;
};
struct cpumask;
struct scx_cpu_acquire_args;
struct scx_cpu_release_args;
struct scx_init_task_args;
struct scx_exit_task_args;
struct scx_dump_ctx;
struct cgroup;
struct scx_cgroup_init_args;
struct scx_exit_info;

extern zigsched_s32 scx_bpf_select_cpu_dfl(struct task_struct *p, zigsched_s32 prev_cpu, u64 wake_flags, bool *direct) __weak __ksym;
extern zigsched_s32 scx_bpf_create_dsq(u64 dsq_id, zigsched_s32 node) __weak __ksym;
extern void scx_bpf_dsq_insert(struct task_struct *p, u64 dsq_id, u64 slice, u64 enq_flags) __weak __ksym;
extern void scx_bpf_dsq_insert_vtime(struct task_struct *p, u64 dsq_id, u64 slice, u64 vtime, u64 enq_flags) __weak __ksym;
extern bool scx_bpf_dsq_move_to_local(u64 dsq_id) __weak __ksym;

enum zigsched_stat_index {
    ZIGSCHED_STAT_SELECT_CPU_CALLS = 0,
    ZIGSCHED_STAT_ENQUEUE_CALLS = 1,
    ZIGSCHED_STAT_DISPATCH_CALLS = 2,
    ZIGSCHED_STAT_LOCAL_DIRECT_INSERTS = 3,
    ZIGSCHED_STAT_FIFO_INSERTS = 4,
    ZIGSCHED_STAT_VTIME_INSERTS = 5,
    ZIGSCHED_STAT_FIFO_DISPATCHES = 6,
    ZIGSCHED_STAT_VTIME_DISPATCHES = 7,
    ZIGSCHED_STAT_CGROUP_INIT_CALLS = 8,
    ZIGSCHED_STAT_CGROUP_EXIT_CALLS = 9,
    ZIGSCHED_STAT_CGROUP_MOVE_CALLS = 10,
    ZIGSCHED_STAT_CGROUP_SET_WEIGHT_CALLS = 11,
    ZIGSCHED_STAT_CGROUP_WEIGHT_OBSERVED = 12,
};

enum zigsched_event_index {
    ZIGSCHED_EVENT_SELECT_CPU_FALLBACK = 0,
    ZIGSCHED_EVENT_DISPATCH_EMPTY = 1,
    ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED = 2,
    ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED = 3,
    ZIGSCHED_EVENT_CGROUP_MOVE_OBSERVED = 4,
    ZIGSCHED_EVENT_CGROUP_WEIGHT_OBSERVED = 5,
};

struct zigsched_build_probe_event {
    zigsched_u32 abi_version;
    zigsched_u32 reserved;
    zigsched_u64 sequence;
};

struct zigsched_stats {
    zigsched_u64 select_cpu_calls;
    zigsched_u64 enqueue_calls;
    zigsched_u64 dispatch_calls;
    zigsched_u64 local_direct_inserts;
    zigsched_u64 fifo_inserts;
    zigsched_u64 vtime_inserts;
    zigsched_u64 fifo_dispatches;
    zigsched_u64 vtime_dispatches;
    zigsched_u64 cgroup_init_calls;
    zigsched_u64 cgroup_exit_calls;
    zigsched_u64 cgroup_move_calls;
    zigsched_u64 cgroup_set_weight_calls;
    zigsched_u64 cgroup_weight_observed;
};

struct zigsched_policy_config {
    zigsched_u64 fifo_dsq;
    zigsched_u64 vtime_dsq;
    zigsched_u64 starvation_ns_max;
    zigsched_u64 mode;
    zigsched_u64 cgroup_knob_support;
};

struct zigsched_cgroup_policy {
    zigsched_u64 last_weight;
    zigsched_u64 weight_generation;
    zigsched_u64 move_generation;
    zigsched_u64 callback_observed_knobs;
    zigsched_u64 observed_knobs;
    zigsched_u64 deferred_knobs;
};

struct sched_ext_ops {
    zigsched_s32 (*select_cpu)(struct task_struct *p, zigsched_s32 prev_cpu, zigsched_u64 wake_flags);
    void (*enqueue)(struct task_struct *p, zigsched_u64 enq_flags);
    void (*dequeue)(struct task_struct *p, zigsched_u64 deq_flags);
    void (*dispatch)(zigsched_s32 cpu, struct task_struct *prev);
    void (*tick)(struct task_struct *p);
    void (*runnable)(struct task_struct *p, zigsched_u64 enq_flags);
    void (*running)(struct task_struct *p);
    void (*stopping)(struct task_struct *p, bool runnable);
    void (*quiescent)(struct task_struct *p, zigsched_u64 deq_flags);
    bool (*yield)(struct task_struct *from, struct task_struct *to);
    bool (*core_sched_before)(struct task_struct *a, struct task_struct *b);
    void (*set_weight)(struct task_struct *p, zigsched_u32 weight);
    void (*set_cpumask)(struct task_struct *p, const struct cpumask *cpumask);
    void (*update_idle)(zigsched_s32 cpu, bool idle);
    void (*cpu_acquire)(zigsched_s32 cpu, struct scx_cpu_acquire_args *args);
    void (*cpu_release)(zigsched_s32 cpu, struct scx_cpu_release_args *args);
    zigsched_s32 (*init_task)(struct task_struct *p, struct scx_init_task_args *args);
    void (*exit_task)(struct task_struct *p, struct scx_exit_task_args *args);
    void (*enable)(struct task_struct *p);
    void (*disable)(struct task_struct *p);
    void (*dump)(struct scx_dump_ctx *ctx);
    void (*dump_cpu)(struct scx_dump_ctx *ctx, zigsched_s32 cpu, bool idle);
    void (*dump_task)(struct scx_dump_ctx *ctx, struct task_struct *p);
    zigsched_s32 (*cgroup_init)(struct cgroup *cgrp, struct scx_cgroup_init_args *args);
    void (*cgroup_exit)(struct cgroup *cgrp);
    zigsched_s32 (*cgroup_prep_move)(struct task_struct *p, struct cgroup *from, struct cgroup *to);
    void (*cgroup_move)(struct task_struct *p, struct cgroup *from, struct cgroup *to);
    void (*cgroup_cancel_move)(struct task_struct *p, struct cgroup *from, struct cgroup *to);
    void (*cgroup_set_weight)(struct cgroup *cgrp, zigsched_u32 weight);
    void (*cgroup_set_bandwidth)(struct cgroup *cgrp, zigsched_u64 period, zigsched_u64 quota, zigsched_u64 burst);
    void (*cgroup_set_idle)(struct cgroup *cgrp, bool idle);
    void (*cpu_online)(zigsched_s32 cpu);
    void (*cpu_offline)(zigsched_s32 cpu);
    zigsched_s32 (*init)(void);
    void (*exit)(struct scx_exit_info *ei);
    zigsched_u32 dispatch_max_batch;
    zigsched_u64 flags;
    zigsched_u32 timeout_ms;
    zigsched_u32 exit_dump_len;
    zigsched_u64 hotplug_seq;
    char name[128];
    void *priv;
};

#endif
