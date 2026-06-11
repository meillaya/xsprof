#ifndef ZIGSCHED_COMMON_H
#define ZIGSCHED_COMMON_H

#define SEC(name) __attribute__((section(name), used))
#define __ksym __attribute__((section(".ksyms")))
#define __weak __attribute__((weak))
#define __always_inline inline __attribute__((always_inline))

#define ZIGSCHED_ABI_VERSION 1u
#define ZIGSCHED_BUILD_PROBE_OK 0
#define ZIGSCHED_MINIMAL_NR_STATS 8u
#define ZIGSCHED_MINIMAL_NR_EVENTS 4u
#define ZIGSCHED_DSQ_FIFO 0x5a195f1f0ULL
#define ZIGSCHED_DSQ_VTIME 0x5a195f1f1ULL
#define ZIGSCHED_STARVATION_NS_MAX 50000000ULL
#define ZIGSCHED_POLICY_MODE_FIFO 1ULL
#define ZIGSCHED_POLICY_MODE_VTIME 2ULL
#define SCX_OPS_SWITCH_PARTIAL 8ULL
#define SCX_DSQ_LOCAL 9223372036854775808ULL
#define SCX_DSQ_GLOBAL 9223372036854775809ULL
#define SCX_SLICE_DFL 20000000ULL
#define BPF_MAP_TYPE_ARRAY 2u

typedef unsigned char zigsched_u8;
typedef unsigned int zigsched_u32;
typedef unsigned long long zigsched_u64;

typedef zigsched_u32 u32;
typedef zigsched_u64 u64;
typedef int zigsched_s32;
#ifndef __cplusplus
typedef unsigned char bool;
#endif

struct task_struct;

extern void *bpf_map_lookup_elem(void *map, const void *key) __weak __ksym;
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
};

enum zigsched_event_index {
    ZIGSCHED_EVENT_SELECT_CPU_FALLBACK = 0,
    ZIGSCHED_EVENT_DISPATCH_EMPTY = 1,
    ZIGSCHED_EVENT_INIT_FIFO_DSQ_FAILED = 2,
    ZIGSCHED_EVENT_INIT_VTIME_DSQ_FAILED = 3,
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
};

struct zigsched_policy_config {
    zigsched_u64 fifo_dsq;
    zigsched_u64 vtime_dsq;
    zigsched_u64 starvation_ns_max;
    zigsched_u64 mode;
};

struct bpf_map_def {
    zigsched_u32 type;
    zigsched_u32 key_size;
    zigsched_u32 value_size;
    zigsched_u32 max_entries;
};

struct sched_ext_ops {
    char name[128];
    zigsched_u64 flags;
    zigsched_s32 (*init)(void);
    zigsched_s32 (*select_cpu)(struct task_struct *p, zigsched_s32 prev_cpu, zigsched_u64 wake_flags);
    void (*enqueue)(struct task_struct *p, zigsched_u64 enq_flags);
    void (*dispatch)(zigsched_s32 cpu, struct task_struct *prev);
};

#endif
