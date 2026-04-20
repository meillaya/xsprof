pub const PolicyName = enum {
    fcfs,
    round_robin,
    cfs_like,
};

pub const TraceEventKind = enum {
    arrival,
    dispatch,
    tick,
    preempt,
    complete,
    idle,
};

pub const ValidationError = error{
    EmptyScenarioName,
    EmptyDescription,
    NoTasks,
    InvalidQuantum,
    EmptyTaskId,
    ZeroBurstTicks,
    DuplicateTaskId,
};

pub const TaskSpec = struct {
    id: []const u8,
    arrival_tick: u32,
    burst_ticks: u32,
    order: u32 = 0,

    pub fn validate(self: TaskSpec) ValidationError!void {
        if (self.id.len == 0) return error.EmptyTaskId;
        if (self.burst_ticks == 0) return error.ZeroBurstTicks;
    }
};

pub const Scenario = struct {
    name: []const u8,
    description: []const u8,
    quantum: u32 = 1,
    tasks: []TaskSpec,

    pub fn validate(self: Scenario) ValidationError!void {
        if (self.name.len == 0) return error.EmptyScenarioName;
        if (self.description.len == 0) return error.EmptyDescription;
        if (self.quantum == 0) return error.InvalidQuantum;
        if (self.tasks.len == 0) return error.NoTasks;

        for (self.tasks) |task| {
            try task.validate();
        }
    }
};
