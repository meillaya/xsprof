/* vmlinux.h — minimal CO-RE type definitions for xsprof BPF programs.
 * In a full build this is generated via: bpftool btf dump file /sys/kernel/btf/vmlinux format c
 * This checked-in subset provides the struct definitions needed by the
 * scheduler and memory monitor programs. Regenerate with:
 *   bpftool btf dump file /sys/kernel/btf/vmlinux format c > bpf/vmlinux.h
 */
#ifndef __VMLINUX_H__
#define __VMLINUX_H__

typedef unsigned char __u8;
typedef short int __s16;
typedef short unsigned int __u16;
typedef int __s32;
typedef unsigned int __u32;
typedef long long int __s64;
typedef long long unsigned int __u64;
typedef __u8 u8;
typedef __s16 s16;
typedef __u16 u16;
typedef __s32 s32;
typedef __u32 u32;
typedef __s64 s64;
typedef __u64 u64;
typedef int bool;

enum {
	false = 0,
	true = 1,
};

struct task_struct {
	int pid;
	int tgid;
	char comm[16];
	int prio;
	int static_prio;
	int normal_prio;
	unsigned int policy;
	int cpu;
	struct mm_struct *mm;
} __attribute__((preserve_access_index));

struct mm_struct {
	unsigned long total_vm;
	unsigned long locked_vm;
	unsigned long pinned_vm;
	unsigned long data_vm;
	unsigned long stack_vm;
} __attribute__((preserve_access_index));

struct rq {
	unsigned int nr_running;
	u64 nr_switches;
	struct task_struct *curr;
} __attribute__((preserve_access_index));

struct sched_entity {
	u64 exec_start;
	u64 sum_exec_runtime;
	u64 vruntime;
} __attribute__((preserve_access_index));

struct trace_event_raw_sched_switch {
	struct trace_entry ent;
	char prev_comm[16];
	pid_t prev_pid;
	int prev_prio;
	long prev_state;
	char next_comm[16];
	pid_t next_pid;
	int next_prio;
} __attribute__((preserve_access_index));

struct trace_event_raw_sched_wakeup {
	struct trace_entry ent;
	char comm[16];
	pid_t pid;
	int prio;
	int success;
	int target_cpu;
} __attribute__((preserve_access_index));

struct trace_entry {
	unsigned short type;
	unsigned char flags;
	unsigned char preempt_count;
	int pid;
} __attribute__((preserve_access_index));

typedef int pid_t;

#endif /* __VMLINUX_H__ */
