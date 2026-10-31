//! Incremental scheduler metrics: wakeup-to-run latency, off-CPU time, CPU
//! busy, migrations, and page faults. Quantiles are bounded log histograms.

const std = @import("std");
const event = @import("../core/event.zig");
const json = @import("../core/json.zig");

const max_cpus = 256;
const bucket_count = 64;

pub const Histogram = struct {
    buckets: [bucket_count]u64 = @splat(0),
    count: u64 = 0,
    total_us: u64 = 0,
    max_us: u64 = 0,

    pub fn observe(self: *Histogram, us_value: u64) void {
        const bucket: usize = if (us_value <= 1) 0 else @min(bucket_count - 1, 63 - @clz(us_value));
        self.buckets[bucket] += 1;
        self.count += 1;
        self.total_us +|= us_value;
        self.max_us = @max(self.max_us, us_value);
    }

    pub fn quantileUpper(self: *const Histogram, permille: u64) u64 {
        if (self.count == 0) return 0;
        const target = @max(1, (self.count * permille + 999) / 1000);
        var seen: u64 = 0;
        for (self.buckets, 0..) |count, index| {
            seen += count;
            if (seen >= target) {
                const shift: u6 = @intCast(@min(63, index + 1));
                return @as(u64, 1) << shift;
            }
        }
        return self.max_us;
    }
};

pub const TaskMetric = struct {
    pid: i32,
    comm: []const u8,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    wait_samples: u64 = 0,
    wait_p50_us: u64 = 0,
    wait_p95_us: u64 = 0,
    wait_p99_us: u64 = 0,
    wait_max_us: u64 = 0,
    offcpu_p95_us: u64 = 0,
    last_cpu: i32 = -1,
};

pub const CpuMetric = struct {
    cpu: u8,
    busy_us: u64 = 0,
    idle_us: u64 = 0,
    switches: u64 = 0,
    faults: u64 = 0,
};

pub const Metrics = struct {
    first_us: u64 = 0,
    last_us: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    lost: u64 = 0,
    wait: Histogram = .{},
    offcpu: Histogram = .{},
    cpus: []const CpuMetric = &.{},
    tasks: []const TaskMetric = &.{},
};

const Task = struct {
    pid: i32,
    comm: []const u8 = "",
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    wait: Histogram = .{},
    offcpu: Histogram = .{},
    last_cpu: i32 = -1,
    runnable_since_ns: ?u64 = null,
    sleep_since_ns: ?u64 = null,
};

const Cpu = struct {
    busy_us: u64 = 0,
    idle_us: u64 = 0,
    switches: u64 = 0,
    faults: u64 = 0,
    active_since_ns: ?u64 = null,
    active_pid: i32 = -1,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    tasks: std.AutoHashMap(i32, Task),
    names: std.heap.ArenaAllocator,
    cpu: [max_cpus]Cpu = @splat(.{}),
    first_us: u64 = std.math.maxInt(u64),
    last_us: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    migrations: u64 = 0,
    faults_minor: u64 = 0,
    faults_major: u64 = 0,
    lost: u64 = 0,
    wait: Histogram = .{},
    offcpu: Histogram = .{},

    pub fn init(allocator: std.mem.Allocator) Index {
        return .{
            .allocator = allocator,
            .tasks = std.AutoHashMap(i32, Task).init(allocator),
            .names = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Index) void {
        self.tasks.deinit();
        self.names.deinit();
    }

    fn getTask(self: *Index, pid: i32) !*Task {
        if (self.tasks.getPtr(pid)) |value| return value;
        try self.tasks.put(pid, .{ .pid = pid });
        return self.tasks.getPtr(pid).?;
    }

    pub fn append(self: *Index, events: []const event.RawEvent) !void {
        for (events) |entry| {
            const us = entry.ts_ns / 1000;
            self.first_us = @min(self.first_us, us);
            self.last_us = @max(self.last_us, us);
            switch (entry.kind) {
                .sched_switch => try self.onSwitch(entry),
                .sched_wakeup => {
                    self.wakeups += 1;
                    const pid: i32 = @intCast(@min(entry.a, std.math.maxInt(i32)));
                    const task = try self.getTask(pid);
                    task.wakeups += 1;
                    if (task.runnable_since_ns == null) {
                        task.runnable_since_ns = entry.ts_ns;
                    }
                },
                .sched_migrate => {
                    self.migrations += 1;
                    if (entry.pid >= 0) {
                        const task = try self.getTask(entry.pid);
                        task.migrations += 1;
                    }
                },
                .page_fault => {
                    if (entry.b == 1) self.faults_major += 1 else self.faults_minor += 1;
                    if (entry.pid >= 0) {
                        const task = try self.getTask(entry.pid);
                        if (entry.b == 1) task.faults_major += 1 else task.faults_minor += 1;
                    }
                    if (entry.cpu >= 0 and entry.cpu < max_cpus) {
                        self.cpu[@intCast(entry.cpu)].faults += 1;
                    }
                },
                .marker => {
                    if (std.mem.indexOf(u8, entry.detail, "sample_loss") != null or
                        std.mem.indexOf(u8, entry.detail, "lost") != null)
                    {
                        self.lost += event.lossMagnitude(entry.detail);
                    }
                },
                else => {},
            }
        }
    }

    fn onSwitch(self: *Index, entry: event.RawEvent) !void {
        self.switches += 1;
        const now = entry.ts_ns;
        if (entry.cpu >= 0 and entry.cpu < max_cpus) {
            const cpu = &self.cpu[@intCast(entry.cpu)];
            if (cpu.active_since_ns) |started| {
                const delta = (now -| started) / 1000;
                if (cpu.active_pid == 0) cpu.idle_us +|= delta else cpu.busy_us +|= delta;
            }
            cpu.active_since_ns = now;
            cpu.active_pid = @intCast(@min(entry.a, std.math.maxInt(i32)));
            cpu.switches += 1;
        }

        const outgoing_pid: i32 = @intCast(@min(entry.b, std.math.maxInt(i32)));
        {
            const outgoing = try self.getTask(outgoing_pid);
            outgoing.last_cpu = entry.cpu;
            outgoing.sleep_since_ns = if (entry.c == 0) null else now;
            if (entry.c == 0) outgoing.runnable_since_ns = now;
        }
        {
            const incoming = try self.getTask(@intCast(@min(entry.a, std.math.maxInt(i32))));
            incoming.switches += 1;
            incoming.last_cpu = entry.cpu;
            if (entry.comm.len != 0 and
                (incoming.comm.len == 0 or !std.mem.eql(u8, incoming.comm, entry.comm)))
            {
                incoming.comm = try self.names.allocator().dupe(u8, entry.comm);
            }
            if (incoming.runnable_since_ns) |started| {
                const wait_us = (now -| started) / 1000;
                incoming.wait.observe(wait_us);
                self.wait.observe(wait_us);
                incoming.runnable_since_ns = null;
            }
            if (incoming.sleep_since_ns) |started| {
                const offcpu_us = (now -| started) / 1000;
                incoming.offcpu.observe(offcpu_us);
                self.offcpu.observe(offcpu_us);
                incoming.sleep_since_ns = null;
            }
        }
    }

    pub fn snapshot(self: *Index, allocator: std.mem.Allocator) !Metrics {
        var task_list: std.ArrayList(TaskMetric) = .empty;
        errdefer task_list.deinit(allocator);
        var iterator = self.tasks.iterator();
        while (iterator.next()) |item| {
            const task = item.value_ptr;
            try task_list.append(allocator, .{
                .pid = task.pid,
                .comm = try allocator.dupe(u8, task.comm),
                .switches = task.switches,
                .wakeups = task.wakeups,
                .migrations = task.migrations,
                .faults_minor = task.faults_minor,
                .faults_major = task.faults_major,
                .wait_samples = task.wait.count,
                .wait_p50_us = task.wait.quantileUpper(500),
                .wait_p95_us = task.wait.quantileUpper(950),
                .wait_p99_us = task.wait.quantileUpper(990),
                .wait_max_us = task.wait.max_us,
                .offcpu_p95_us = task.offcpu.quantileUpper(950),
                .last_cpu = task.last_cpu,
            });
        }
        std.mem.sortUnstable(TaskMetric, task_list.items, {}, struct {
            fn less(_: void, a: TaskMetric, b: TaskMetric) bool {
                if (a.wait_p95_us != b.wait_p95_us) return a.wait_p95_us > b.wait_p95_us;
                if (!std.mem.eql(u8, a.comm, b.comm)) return std.mem.order(u8, a.comm, b.comm) == .lt;
                return a.pid < b.pid;
            }
        }.less);

        var cpu_list: std.ArrayList(CpuMetric) = .empty;
        errdefer cpu_list.deinit(allocator);
        for (self.cpu, 0..) |cpu, index| {
            if (cpu.switches == 0 and cpu.faults == 0) continue;
            try cpu_list.append(allocator, .{
                .cpu = @intCast(index),
                .busy_us = cpu.busy_us,
                .idle_us = cpu.idle_us,
                .switches = cpu.switches,
                .faults = cpu.faults,
            });
        }
        return .{
            .first_us = if (self.last_us == 0) 0 else self.first_us,
            .last_us = self.last_us,
            .switches = self.switches,
            .wakeups = self.wakeups,
            .migrations = self.migrations,
            .faults_minor = self.faults_minor,
            .faults_major = self.faults_major,
            .lost = self.lost,
            .wait = self.wait,
            .offcpu = self.offcpu,
            .cpus = try cpu_list.toOwnedSlice(allocator),
            .tasks = try task_list.toOwnedSlice(allocator),
        };
    }
};

// Checks wakeup-to-run and preemption waits with exact synthetic timestamps.
test "metrics measure waits and preemption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 100_000, .cpu = 0, .a = 1, .comm = "a" },
        .{ .kind = .sched_switch, .ts_ns = 300_000, .cpu = 0, .a = 1, .b = 2, .c = 1, .comm = "a" },
        .{ .kind = .sched_wakeup, .ts_ns = 320_000, .cpu = 0, .a = 2, .comm = "b" },
        .{ .kind = .sched_switch, .ts_ns = 350_000, .cpu = 0, .a = 2, .b = 1, .c = 0, .comm = "b" },
    };
    try index.append(&events);
    const metrics = try index.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 3), metrics.switches);
    var found_a = false;
    var found_b = false;
    for (metrics.tasks) |task| {
        if (std.mem.eql(u8, task.comm, "a")) {
            found_a = task.wait_samples == 1;
            try std.testing.expect(task.wait_p95_us >= 200);
        }
        if (std.mem.eql(u8, task.comm, "b")) {
            found_b = task.wait_samples == 1;
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
    try std.testing.expect(metrics.cpus.len == 1);
    try std.testing.expect(metrics.cpus[0].busy_us >= 50);
}

// Checks that the index owns task names instead of borrowing caller buffers.
test "metrics own comm strings" {
    var names_buf = [_]u8{ 'w', 'o', 'r', 'k', 'e', 'r' };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var index = Index.init(arena.allocator());
    const events = [_]event.RawEvent{
        .{ .kind = .sched_switch, .ts_ns = 0, .cpu = 0, .a = 1, .b = 0, .c = 1, .comm = &names_buf },
    };
    try index.append(&events);
    @memset(&names_buf, 'x');
    const metrics = try index.snapshot(arena.allocator());
    index.deinit();
    var found = false;
    for (metrics.tasks) |task| {
        if (task.pid == 1) {
            found = true;
            try std.testing.expectEqualStrings("worker", task.comm);
        }
    }
    try std.testing.expect(found);
}

pub fn writeJson(w: *std.Io.Writer, metrics: Metrics, top: usize) !void {
    const allocator = std.heap.smp_allocator;
    const task_count = @min(metrics.tasks.len, top);
    var task_values = try allocator.alloc(json.Value, task_count);
    defer allocator.free(task_values);
    var task_entries = try allocator.alloc([]json.Entry, task_count);
    defer {
        for (task_entries) |entries| allocator.free(entries);
        allocator.free(task_entries);
    }
    for (metrics.tasks[0..task_count], 0..) |task, index| {
        const entries = try allocator.alloc(json.Entry, 14);
        entries[0] = .{ .key = "comm", .value = .{ .string = task.comm } };
        entries[1] = .{ .key = "faults_major", .value = .{ .unsigned = task.faults_major } };
        entries[2] = .{ .key = "faults_minor", .value = .{ .unsigned = task.faults_minor } };
        entries[3] = .{ .key = "last_cpu", .value = .{ .integer = task.last_cpu } };
        entries[4] = .{ .key = "migrations", .value = .{ .unsigned = task.migrations } };
        entries[5] = .{ .key = "offcpu_p95_us", .value = .{ .unsigned = task.offcpu_p95_us } };
        entries[6] = .{ .key = "pid", .value = .{ .integer = task.pid } };
        entries[7] = .{ .key = "switches", .value = .{ .unsigned = task.switches } };
        entries[8] = .{ .key = "wait_max_us", .value = .{ .unsigned = task.wait_max_us } };
        entries[9] = .{ .key = "wait_p50_us", .value = .{ .unsigned = task.wait_p50_us } };
        entries[10] = .{ .key = "wait_p95_us", .value = .{ .unsigned = task.wait_p95_us } };
        entries[11] = .{ .key = "wait_p99_us", .value = .{ .unsigned = task.wait_p99_us } };
        entries[12] = .{ .key = "wait_samples", .value = .{ .unsigned = task.wait_samples } };
        entries[13] = .{ .key = "wakeups", .value = .{ .unsigned = task.wakeups } };
        task_entries[index] = entries;
        task_values[index] = .{ .object = entries };
    }

    var cpu_values = try allocator.alloc(json.Value, metrics.cpus.len);
    defer allocator.free(cpu_values);
    var cpu_entries = try allocator.alloc([]json.Entry, metrics.cpus.len);
    defer {
        for (cpu_entries) |entries| allocator.free(entries);
        allocator.free(cpu_entries);
    }
    for (metrics.cpus, 0..) |cpu, index| {
        const entries = try allocator.alloc(json.Entry, 5);
        entries[0] = .{ .key = "busy_us", .value = .{ .unsigned = cpu.busy_us } };
        entries[1] = .{ .key = "cpu", .value = .{ .unsigned = cpu.cpu } };
        entries[2] = .{ .key = "faults", .value = .{ .unsigned = cpu.faults } };
        entries[3] = .{ .key = "idle_us", .value = .{ .unsigned = cpu.idle_us } };
        entries[4] = .{ .key = "switches", .value = .{ .unsigned = cpu.switches } };
        cpu_entries[index] = entries;
        cpu_values[index] = .{ .object = entries };
    }

    try json.write(w, .{ .object = &.{
        .{ .key = "cpus", .value = .{ .array = cpu_values } },
        .{ .key = "faults_major", .value = .{ .unsigned = metrics.faults_major } },
        .{ .key = "faults_minor", .value = .{ .unsigned = metrics.faults_minor } },
        .{ .key = "first_us", .value = .{ .unsigned = metrics.first_us } },
        .{ .key = "host_mutation", .value = .{ .boolean = false } },
        .{ .key = "last_us", .value = .{ .unsigned = metrics.last_us } },
        .{ .key = "lost", .value = .{ .unsigned = metrics.lost } },
        .{ .key = "migrations", .value = .{ .unsigned = metrics.migrations } },
        .{ .key = "quantiles", .value = .{ .object = &.{
            .{ .key = "approximate", .value = .{ .boolean = true } },
            .{ .key = "method", .value = .{ .string = "log2_histogram_1us" } },
        } } },
        .{ .key = "schema", .value = .{ .string = "xsprof/metrics/v1" } },
        .{ .key = "switches", .value = .{ .unsigned = metrics.switches } },
        .{ .key = "tasks", .value = .{ .array = task_values } },
        .{ .key = "wakeups", .value = .{ .unsigned = metrics.wakeups } },
    } });
}
