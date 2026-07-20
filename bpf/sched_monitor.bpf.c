// SPDX-License-Identifier: GPL-2.0
/* sched_monitor.bpf.c — CO-RE scheduler tracing program for xsprof.
 *
 * Attaches to sched_switch and sched_wakeup tracepoints to capture
 * scheduler events. VM-lab-only: the userspace loader refuses to load
 * this on the host without an explicit VM-lab marker + audit context.
 *
 * Build (requires clang + libbpf + vmlinux.h with BTF):
 *   clang -g -O2 -target bpf -D__TARGET_ARCH_x86 \
 *     -I. -c sched_monitor.bpf.c -o sched_monitor.bpf.o
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

/* Scheduler event record pushed to userspace via ring buffer. */
struct sched_event {
	__u64 ts_ns;
	__u32 cpu;
	__s32 prev_pid;
	__s32 next_pid;
	__s32 prev_prio;
	__s32 next_prio;
	char prev_comm[16];
	char next_comm[16];
	__u8 type; /* 0 = switch, 1 = wakeup */
};

/* Ring buffer for streaming events to userspace. */
struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 256 * 1024);
} sched_events SEC(".maps");

/* Per-CPU runqueue length sample. */
struct rq_sample {
	__u64 ts_ns;
	__u32 cpu;
	__u32 nr_running;
	__u64 nr_switches;
};

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct rq_sample);
} rq_samples SEC(".maps");

SEC("tracepoint/sched/sched_switch")
int handle_sched_switch(struct trace_event_raw_sched_switch *ctx)
{
	struct sched_event *e;

	e = bpf_ringbuf_reserve(&sched_events, sizeof(*e), 0);
	if (!e)
		return 0;

	e->ts_ns = bpf_ktime_get_ns();
	e->cpu = bpf_get_smp_processor_id();
	e->prev_pid = ctx->prev_pid;
	e->next_pid = ctx->next_pid;
	e->prev_prio = ctx->prev_prio;
	e->next_prio = ctx->next_prio;
	e->type = 0;

	/* CO-RE safe reads for comm fields. */
	bpf_probe_read_kernel_str(&e->prev_comm, sizeof(e->prev_comm), ctx->prev_comm);
	bpf_probe_read_kernel_str(&e->next_comm, sizeof(e->next_comm), ctx->next_comm);

	bpf_ringbuf_submit(e, 0);
	return 0;
}

SEC("tracepoint/sched/sched_wakeup")
int handle_sched_wakeup(struct trace_event_raw_sched_wakeup *ctx)
{
	struct sched_event *e;

	e = bpf_ringbuf_reserve(&sched_events, sizeof(*e), 0);
	if (!e)
		return 0;

	e->ts_ns = bpf_ktime_get_ns();
	e->cpu = bpf_get_smp_processor_id();
	e->prev_pid = 0;
	e->next_pid = ctx->pid;
	e->prev_prio = 0;
	e->next_prio = ctx->prio;
	e->type = 1;

	bpf_probe_read_kernel_str(&e->next_comm, sizeof(e->next_comm), ctx->comm);
	__builtin_memset(e->prev_comm, 0, sizeof(e->prev_comm));

	bpf_ringbuf_submit(e, 0);
	return 0;
}
