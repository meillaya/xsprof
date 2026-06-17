const std = @import("std");
const linux = @import("linux_scheduler");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args = argv[1..];

    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) {
        var stdout_buffer: [2048]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
        try linux.writeHelp(&stdout_writer.interface, "zig-scheduler");
        try stdout_writer.interface.flush();
        return;
    }

    if (linux.isUnsafeCommand(args[0])) {
        try writeRefusal(args[0]);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "preflight")) {
        try runPreflight(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, args[0], "sched-ext")) {
        if (args.len == 3 and std.mem.eql(u8, args[1], "preflight") and std.mem.eql(u8, args[2], "--json")) {
            try runPreflight(allocator, args[2..]);
            return;
        }
        if (args.len > 1 and std.mem.eql(u8, args[1], "attach")) {
            try runSchedExtAttach(allocator, args[2..]);
            return;
        }
        try writeRefusal("sched-ext mutation");
        std.process.exit(1);
    }

    if (std.mem.eql(u8, args[0], "controller")) {
        try writeControllerDryRun(allocator, args[1..]);
        return;
    }

    try writeRefusal(args[0]);
    std.process.exit(1);
}

fn runPreflight(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1 or !std.mem.eql(u8, args[0], "--json")) {
        try writeRefusal("preflight expects --json and remains read-only");
        std.process.exit(2);
    }
    var report = try linux.collectPreflight(allocator);
    defer report.deinit();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try linux.writePreflightJson(&stdout_writer.interface, report);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

const SchedExtAttachArgs = struct {
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
};

fn runSchedExtAttach(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    _ = parseSchedExtAttachArgs(args) catch {
        try writeRefusal("sched-ext attach requires --lab --partial --target-cgroup <allowlisted> --audit-id <id> --rollback-id <id>");
        std.process.exit(2);
    };
    try writeRefusal("sched-ext attach is disabled in the root operator; run qa/vm/partial_attach.sh inside a disposable lab VM with signed release approval instead");
    std.process.exit(1);
}

fn parseSchedExtAttachArgs(args: []const []const u8) !SchedExtAttachArgs {
    if (args.len != 8) return error.InvalidSchedExtAttachArgs;
    if (!std.mem.eql(u8, args[0], "--lab")) return error.InvalidSchedExtAttachArgs;
    if (!std.mem.eql(u8, args[1], "--partial")) return error.InvalidSchedExtAttachArgs;
    if (!std.mem.eql(u8, args[2], "--target-cgroup")) return error.InvalidSchedExtAttachArgs;
    if (!std.mem.eql(u8, args[4], "--audit-id")) return error.InvalidSchedExtAttachArgs;
    if (!std.mem.eql(u8, args[6], "--rollback-id")) return error.InvalidSchedExtAttachArgs;
    return .{
        .target_cgroup = args[3],
        .audit_id = args[5],
        .rollback_id = args[7],
    };
}

const ControllerDryRunArgs = struct {
    config_path: []const u8,
    target_cgroup: []const u8,
    audit_id: []const u8,
    rollback_id: []const u8,
};

fn writeControllerDryRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const parsed_args = parseControllerDryRunArgs(args) catch {
        try writeRefusal("controller plan requires --dry-run --config <file> --target-cgroup <abs-path> --audit-id <id> --rollback-id <id>");
        std.process.exit(2);
    };

    const config_source = std.Io.Dir.cwd().readFileAlloc(
        std.Io.Threaded.global_single_threaded.io(),
        parsed_args.config_path,
        allocator,
        .unlimited,
    ) catch {
        try writeRefusal("controller config file could not be read");
        std.process.exit(1);
    };
    defer allocator.free(config_source);

    var parsed_config = linux.config.parseRootConfig(allocator, config_source) catch {
        try writeRefusal("controller config failed strict validation");
        std.process.exit(1);
    };
    defer parsed_config.deinit(allocator);

    const plan = linux.controller.buildScopedDryRunPlan(.{
        .config = parsed_config,
        .dry_run = true,
        .target_cgroup = parsed_args.target_cgroup,
        .audit_id = parsed_args.audit_id,
        .rollback_id = parsed_args.rollback_id,
    }) catch {
        try writeRefusal("controller dry-run failed lab allowlist, audit id, rollback id, or dry-run validation");
        std.process.exit(1);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    try linux.controller.writeScopedDryRunPlanJson(&stdout_writer.interface, plan);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn parseControllerDryRunArgs(args: []const []const u8) !ControllerDryRunArgs {
    if (args.len != 10) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[0], "plan")) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[1], "--dry-run")) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[2], "--config")) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[4], "--target-cgroup")) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[6], "--audit-id")) return error.InvalidControllerArgs;
    if (!std.mem.eql(u8, args[8], "--rollback-id")) return error.InvalidControllerArgs;
    return .{
        .config_path = args[3],
        .target_cgroup = args[5],
        .audit_id = args[7],
        .rollback_id = args[9],
    };
}

fn writeRefusal(command: []const u8) !void {
    var message_buffer: [1024]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "refused unsafe or unsupported command '{s}': root is read-only/preflight-first; no mutation, attach, enable, load, cgroup write, affinity write, or BPF load path exists\n",
        .{command},
    );
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), message);
}

test "help identifies Linux scheduler operator surface" {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(std.testing.allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &buffer);
    try linux.writeHelp(&writer.writer, "zig-scheduler");
    buffer = writer.toArrayList();
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "Linux scheduler") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "simulator/") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "zig build tui-live-vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "unsafe host mutation is refused") != null);
}
