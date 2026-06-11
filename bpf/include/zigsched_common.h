#ifndef ZIGSCHED_COMMON_H
#define ZIGSCHED_COMMON_H

#define SEC(name) __attribute__((section(name), used))
#define __ksym __attribute__((section(".ksyms")))
#define __weak __attribute__((weak))

#define ZIGSCHED_ABI_VERSION 1u
#define ZIGSCHED_BUILD_PROBE_OK 0
#define ZIGSCHED_MINIMAL_NR_STATS 4u
#define ZIGSCHED_DSQ_FIFO 0x5a195f1f0ULL
#define ZIGSCHED_DSQ_VTIME 0x5a195f1f1ULL
#define ZIGSCHED_STARVATION_NS_MAX 50000000ULL
#define ZIGSCHED_POLICY_MODE_FIFO 1ULL
#define ZIGSCHED_POLICY_MODE_VTIME 2ULL
#define SCX_OPS_SWITCH_PARTIAL 8ULL
#define SCX_DSQ_GLOBAL 9223372036854775809ULL
#define SCX_SLICE_DFL 20000000ULL
#define BPF_MAP_TYPE_ARRAY 2u

typedef unsigned char zigsched_u8;
typedef unsigned int zigsched_u32;
typedef unsigned long long zigsched_u64;

typedef zigsched_u32 u32;
typedef zigsched_u64 u64;
typedef int zigsched_s32;

struct task_struct;

extern void *bpf_map_lookup_elem(void *map, const void *key) __weak __ksym;
extern void scx_bpf_dsq_insert(struct task_struct *p, u64 dsq_id, u64 slice, u64 enq_flags) __weak __ksym;
extern void scx_bpf_dsq_insert_vtime(struct task_struct *p, u64 dsq_id, u64 slice, u64 vtime, u64 enq_flags) __weak __ksym;

struct zigsched_build_probe_event {
    zigsched_u32 abi_version;
    zigsched_u32 reserved;
    zigsched_u64 sequence;
};

struct zigsched_stats {
    zigsched_u64 select_cpu_calls;
    zigsched_u64 enqueue_calls;
    zigsched_u64 dispatch_calls;
    zigsched_u64 bounded_starvation_ns;
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
    zigsched_u32 (*select_cpu)(struct task_struct *p, zigsched_s32 prev_cpu, zigsched_u64 wake_flags);
    void (*enqueue)(struct task_struct *p, zigsched_u64 enq_flags);
    void (*dispatch)(zigsched_s32 cpu, struct task_struct *prev);
};

#endif
