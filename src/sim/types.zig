const std = @import("std");

pub const PolicyKind = enum {
    fcfs,
    round_robin,
    cfs_like,

    pub fn parse(text: []const u8) ?PolicyKind {
        if (std.mem.eql(u8, text, "fcfs") or std.mem.eql(u8, text, "fifo")) return .fcfs;
        if (std.mem.eql(u8, text, "rr") or std.mem.eql(u8, text, "round-robin") or std.mem.eql(u8, text, "round_robin")) return .round_robin;
        if (std.mem.eql(u8, text, "cfs") or std.mem.eql(u8, text, "cfs-like") or std.mem.eql(u8, text, "cfs_like")) return .cfs_like;
        return null;
    }

    pub fn displayName(self: PolicyKind) []const u8 {
        return switch (self) {
            .fcfs => "FCFS/FIFO",
            .round_robin => "Round Robin",
            .cfs_like => "Simplified CFS-inspired",
        };
    }

    pub fn shortName(self: PolicyKind) []const u8 {
        return switch (self) {
            .fcfs => "fcfs",
            .round_robin => "rr",
            .cfs_like => "cfs",
        };
    }
};

pub const TraceEventKind = enum {
    arrival,
    dispatch,
    tick,
    preempt,
    complete,
    idle,
};

pub const TaskState = enum {
    pending,
    ready,
    running,
    complete,
};

pub const TaskSpec = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    input_order: u32,
};

pub const ScenarioOwned = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    round_robin_quantum: u32,
    tasks: []TaskSpec,

    pub fn deinit(self: *ScenarioOwned) void {
        for (self.tasks) |task| self.allocator.free(task.id);
        self.allocator.free(self.tasks);
        self.allocator.free(self.name);
        self.* = undefined;
    }
};

pub const TraceEntry = struct {
    tick: u32,
    kind: TraceEventKind,
    task_id: ?[]const u8,
};

pub const TaskMetrics = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    input_order: u32,
    first_dispatch_tick: ?u32,
    completion_time: u32,
    turnaround_time: u32,
    waiting_time: u32,
    response_time: u32,
    total_executed: u32,
};

pub const AggregateMetrics = struct {
    average_waiting_time: f64,
    average_response_time: f64,
    throughput: f64,
    throughput_numerator: u32,
    throughput_denominator: u32,
    waiting_time_spread: u32,
};

pub const SimulationResult = struct {
    allocator: std.mem.Allocator,
    scenario_name: []const u8,
    policy: PolicyKind,
    quantum: u32,
    trace: []TraceEntry,
    tasks: []TaskMetrics,
    completion_order: []usize,
    aggregate: AggregateMetrics,
    final_tick: u32,

    pub fn deinit(self: *SimulationResult) void {
        self.allocator.free(self.scenario_name);
        for (self.tasks) |task| self.allocator.free(task.id);
        self.allocator.free(self.trace);
        self.allocator.free(self.tasks);
        self.allocator.free(self.completion_order);
        self.* = undefined;
    }

    pub fn taskById(self: *const SimulationResult, id: []const u8) ?*const TaskMetrics {
        for (self.tasks) |*task| {
            if (std.mem.eql(u8, task.id, id)) return task;
        }
        return null;
    }

    pub fn completionTaskId(self: *const SimulationResult, index: usize) []const u8 {
        return self.tasks[self.completion_order[index]].id;
    }
};
