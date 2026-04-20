const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{
    InvalidScenarioFormat,
    MissingScenarioName,
    MissingTasks,
    InvalidQuantum,
};

pub fn loadScenarioByName(allocator: std.mem.Allocator, name: []const u8) !types.ScenarioOwned {
    const path = try std.fmt.allocPrint(allocator, "scenarios/basic/{s}.zon", .{name});
    defer allocator.free(path);
    return loadScenarioFile(allocator, path);
}

pub fn loadScenarioFile(allocator: std.mem.Allocator, path: []const u8) !types.ScenarioOwned {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(source);

    const fallback_name = std.fs.path.stem(path);
    return parseScenarioText(allocator, source, fallback_name);
}

pub fn parseScenarioText(allocator: std.mem.Allocator, source: []const u8, fallback_name: []const u8) !types.ScenarioOwned {
    var name_slice: ?[]const u8 = null;
    var quantum: u32 = 2;
    var tasks: std.ArrayList(types.TaskSpec) = .empty;
    errdefer {
        for (tasks.items) |task| allocator.free(task.id);
        tasks.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, source, '\n');
    var order: u32 = 0;
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "name:")) {
            name_slice = std.mem.trim(u8, line[5..], " \t\r");
            continue;
        }

        if (std.mem.startsWith(u8, line, "rr_quantum:")) {
            const value_text = std.mem.trim(u8, line[11..], " \t\r");
            quantum = try std.fmt.parseInt(u32, value_text, 10);
            if (quantum == 0) return ParseError.InvalidQuantum;
            continue;
        }

        if (std.mem.startsWith(u8, line, "task:")) {
            const task_spec = try parseTaskLine(allocator, line[5..], order);
            try tasks.append(allocator, task_spec);
            order += 1;
            continue;
        }

        return ParseError.InvalidScenarioFormat;
    }

    if (tasks.items.len == 0) return ParseError.MissingTasks;

    const final_name = if (name_slice) |value| value else fallback_name;
    return .{
        .allocator = allocator,
        .name = try allocator.dupe(u8, final_name),
        .round_robin_quantum = quantum,
        .tasks = try tasks.toOwnedSlice(allocator),
    };
}

fn parseTaskLine(allocator: std.mem.Allocator, task_line: []const u8, input_order: u32) !types.TaskSpec {
    var parts = std.mem.tokenizeAny(u8, task_line, " \t\r");
    const id = parts.next() orelse return ParseError.InvalidScenarioFormat;
    const arrival_text = parts.next() orelse return ParseError.InvalidScenarioFormat;
    const burst_text = parts.next() orelse return ParseError.InvalidScenarioFormat;
    if (parts.next() != null) return ParseError.InvalidScenarioFormat;

    return .{
        .id = try allocator.dupe(u8, id),
        .arrival_tick = try std.fmt.parseInt(u32, arrival_text, 10),
        .burst_ticks = try std.fmt.parseInt(u32, burst_text, 10),
        .input_order = input_order,
    };
}
