// SPDX-License-Identifier: GPL-2.0
/* mem_monitor.bpf.c — CO-RE memory tracing program for xsprof.
 *
 * Attaches to page fault and memory allocation tracepoints to capture
 * memory pressure events. VM-lab-only: the userspace loader refuses to
 * load this on the host without an explicit VM-lab marker + audit context.
 *
 * Build (requires clang + libbpf + vmlinux.h with BTF):
 *   clang -g -O2 -target bpf -D__TARGET_ARCH_x86 \
 *     -I. -c mem_monitor.bpf.c -o mem_monitor.bpf.o
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

/* Memory event record pushed to userspace via ring buffer. */
struct mem_event {
	__u64 ts_ns;
	__u32 cpu;
	__s32 pid;
	__s32 tid;
	__u64 addr;
	__u64 size;
	__u8 type; /* 0 = page_fault, 1 = alloc, 2 = free */
	char comm[16];
};

/* Ring buffer for streaming memory events to userspace. */
struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} mem_events SEC(".maps");

/* Per-process memory stats (hash map keyed by tgid). */
struct mem_stats {
	__u64 total_vm;
	__u64 locked_vm;
	__u64 stack_vm;
	__u64 data_vm;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 10240);
	__type(key, __u32);
	__type(value, struct mem_stats);
} mem_stats_map SEC(".maps");

SEC("tracepoint/exceptions/page_fault_user")
int handle_page_fault(struct trace_event_raw_sched_switch *ctx)
{
	struct mem_event *e;
	__u64 pid_tgid;

	e = bpf_ringbuf_reserve(&mem_events, sizeof(*e), 0);
	if (!e)
		return 0;

	pid_tgid = bpf_get_current_pid_tgid();
	e->ts_ns = bpf_ktime_get_ns();
	e->cpu = bpf_get_smp_processor_id();
	e->pid = pid_tgid >> 32;
	e->tid = (__u32)pid_tgid;
	e->addr = 0; /* fault address from pt_regs if available */
	e->size = 0;
	e->type = 0;

	bpf_get_current_comm(&e->comm, sizeof(e->comm));

	bpf_ringbuf_submit(e, 0);
	return 0;
}

SEC("kprobe/__alloc_pages")
int handle_alloc_pages(struct pt_regs *ctx)
{
	struct mem_event *e;
	__u64 pid_tgid;
	unsigned int order;

	e = bpf_ringbuf_reserve(&mem_events, sizeof(*e), 0);
	if (!e)
		return 0;

	pid_tgid = bpf_get_current_pid_tgid();
	order = (unsigned int)PT_REGS_PARM2(ctx);

	e->ts_ns = bpf_ktime_get_ns();
	e->cpu = bpf_get_smp_processor_id();
	e->pid = pid_tgid >> 32;
	e->tid = (__u32)pid_tgid;
	e->addr = 0;
	e->size = (1ULL << order) * 4096;
	e->type = 1;

	bpf_get_current_comm(&e->comm, sizeof(e->comm));

	bpf_ringbuf_submit(e, 0);
	return 0;
}

/* Periodic memory stats sampler — called from userspace via BPF_PROG_TYPE_RAW_TRACEPOINT
 * or a perf event. Reads task_struct->mm fields via CO-RE. */
SEC("tracepoint/sched/sched_process_fork")
int handle_process_fork(struct trace_event_raw_sched_wakeup *ctx)
{
	struct task_struct *task = (struct task_struct *)bpf_get_current_task();
	struct mem_stats stats = {};
	__u32 tgid;

	if (!task)
		return 0;

	tgid = BPF_CORE_READ(task, tgid);
	stats.total_vm = BPF_CORE_READ(task, mm, total_vm);
	stats.locked_vm = BPF_CORE_READ(task, mm, locked_vm);
	stats.stack_vm = BPF_CORE_READ(task, mm, stack_vm);
	stats.data_vm = BPF_CORE_READ(task, mm, data_vm);

	bpf_map_update_elem(&mem_stats_map, &tgid, &stats, BPF_ANY);
	return 0;
}
