const std = @import("std");

pub const default_task_weight: u32 = 1024;
pub const max_task_weight: u32 = 4096;
pub const CoreId = u32;

pub const PolicyKind = enum {
    fcfs,
    round_robin,
    cfs_like,

    pub fn displayName(self: PolicyKind) []const u8 {
        return switch (self) {
            .fcfs => "FCFS",
            .round_robin => "Round Robin",
            .cfs_like => "CFS-inspired",
        };
    }
};

pub const PolicyName = PolicyKind;

pub const TraceEventKind = enum {
    arrival,
    dispatch,
    tick,
    preempt,
    block,
    wakeup,
    complete,
    idle,
};

pub const TaskState = enum {
    pending,
    ready,
    running,
    blocked,
    complete,
};

pub const ValidationError = error{
    EmptyScenarioName,
    NoTasks,
    InvalidQuantum,
    InvalidCoreCount,
    EmptyTaskId,
    ZeroBurstTicks,
    DuplicateTaskId,
    MissingName,
    InvalidLine,
    InvalidTaskLine,
    InvalidInteger,
    InvalidZon,
    InvalidWeight,
    InvalidSleepAfterTicks,
    InvalidSleepDuration,
    ScenarioNameMismatch,
    UnknownScenario,
};

pub const TaskSpec = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    weight: u32 = default_task_weight,
    sleep_after_ticks: ?u32 = null,
    sleep_duration: u32 = 0,
    input_order: u32 = 0,
    order: u32 = 0,

    pub fn validate(self: TaskSpec) ValidationError!void {
        if (self.id.len == 0) return error.EmptyTaskId;
        if (self.burst_ticks == 0) return error.ZeroBurstTicks;
        if (self.weight == 0) return error.InvalidWeight;
        if (self.weight > max_task_weight) return error.InvalidWeight;

        if (self.sleep_after_ticks) |sleep_after_ticks| {
            if (sleep_after_ticks == 0 or sleep_after_ticks >= self.burst_ticks) return error.InvalidSleepAfterTicks;
            if (self.sleep_duration == 0) return error.InvalidSleepDuration;
        } else if (self.sleep_duration != 0) {
            return error.InvalidSleepDuration;
        }
    }
};

pub const ScenarioOwned = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    round_robin_quantum: u32 = 1,
    core_count: u32 = 1,
    tasks: []TaskSpec,

    pub fn deinit(self: *ScenarioOwned) void {
        for (self.tasks) |task| {
            self.allocator.free(task.id);
        }
        self.allocator.free(self.tasks);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn validate(self: *const ScenarioOwned) ValidationError!void {
        if (self.name.len == 0) return error.EmptyScenarioName;
        if (self.round_robin_quantum == 0) return error.InvalidQuantum;
        if (self.core_count == 0) return error.InvalidCoreCount;
        if (self.tasks.len == 0) return error.NoTasks;

        for (self.tasks, 0..) |task, index| {
            try task.validate();
            for (self.tasks[index + 1 ..]) |other| {
                if (std.mem.eql(u8, task.id, other.id)) return error.DuplicateTaskId;
            }
        }
    }
};

pub const Scenario = ScenarioOwned;

pub const TraceEntry = struct {
    tick: u32,
    kind: TraceEventKind,
    task_id: ?[]const u8,
    core_id: ?CoreId = null,
};

pub const TaskMetrics = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    weight: u32,
    sleep_after_ticks: ?u32,
    sleep_duration: u32,
    input_order: u32,
    first_dispatch_tick: u32,
    completion_time: u32,
    turnaround_time: u32,
    waiting_time: u32,
    blocked_time: u32,
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
    core_count: u32 = 1,
    trace: []TraceEntry,
    tasks: []TaskMetrics,
    completion_order: []usize,
    aggregate: AggregateMetrics,
    final_tick: u32,

    pub fn deinit(self: *SimulationResult) void {
        self.allocator.free(self.scenario_name);
        for (self.tasks) |task| {
            self.allocator.free(task.id);
        }
        self.allocator.free(self.tasks);
        self.allocator.free(self.trace);
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
