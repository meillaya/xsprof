const std = @import("std");
const linux = @import("linux_scheduler");

const protocol = linux.control.protocol;

pub const Kind = enum {
    quit,
    help,
    home,
    theme,
    run_vm_lab,
    rollback_lab,
    stop_lab,
    run_host_safe,
    verifier_only,
    partial_attach,
    observe,
    incident_drill,
};

pub const Binding = struct {
    key: u8,
    kind: Kind,
    label: []const u8,
    advertised: bool = true,
};

pub const bindings = [_]Binding{
    .{ .key = 'm', .kind = .run_vm_lab, .label = "m live vm" },
    .{ .key = 'b', .kind = .rollback_lab, .label = "b rollback" },
    .{ .key = 's', .kind = .stop_lab, .label = "s stop" },
    .{ .key = 'h', .kind = .home, .label = "h home" },
    .{ .key = '?', .kind = .help, .label = "? help" },
    .{ .key = 'w', .kind = .theme, .label = "w theme" },
    .{ .key = 'q', .kind = .quit, .label = "q quit" },
    .{ .key = 'r', .kind = .run_host_safe, .label = "r host lab", .advertised = false },
    .{ .key = 'v', .kind = .verifier_only, .label = "v verifier", .advertised = false },
    .{ .key = 'p', .kind = .partial_attach, .label = "p partial", .advertised = false },
    .{ .key = 'o', .kind = .observe, .label = "o observe", .advertised = false },
    .{ .key = 'i', .kind = .incident_drill, .label = "i incident", .advertised = false },
};

pub fn bindingForKey(key: u8) ?Binding {
    for (bindings) |binding| {
        if (binding.key == key) return binding;
    }
    return null;
}

pub fn actionKindForKey(key: u8) ?protocol.ActionKind {
    const binding = bindingForKey(key) orelse return null;
    return switch (binding.kind) {
        .run_host_safe => .run_lab_host_safe,
        .verifier_only => .verifier_only,
        .partial_attach => .partial_attach,
        .observe => .observe,
        .incident_drill => .incident_drill,
        else => null,
    };
}

pub fn advertisedKeys(buffer: []u8) []const u8 {
    var count: usize = 0;
    for (bindings) |binding| {
        if (!binding.advertised) continue;
        buffer[count] = binding.key;
        count += 1;
    }
    return buffer[0..count];
}

pub fn writeFooter(writer: anytype, width: usize) !usize {
    const full_labels = width >= 120;
    const separator = if (width >= 140) "  " else " ";
    var cells: usize = 0;
    var first = true;
    for (bindings) |binding| {
        if (!binding.advertised) continue;
        if (!first) {
            try writer.writeAll(separator);
            cells += separator.len;
        }
        if (full_labels) {
            try writer.writeAll("▣ ");
            try writer.writeAll(binding.label);
            cells += 2 + labelCells(binding.label);
        } else {
            try writer.writeAll(binding.label[0..1]);
            cells += 1;
        }
        first = false;
    }
    const suffix = if (width >= 140) "  ↵ select" else " ↵";
    try writer.writeAll(suffix);
    cells += std.unicode.utf8CountCodepoints(suffix) catch suffix.len;
    return cells;
}

fn labelCells(label: []const u8) usize {
    return std.unicode.utf8CountCodepoints(label) catch label.len;
}

pub fn statusForUi(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .quit => "QUIT requested",
        .help => "HELP open help",
        .home => "HOME dashboard",
        .theme => "theme black ▸ w",
        else => null,
    };
}

test "advertised action keys are unique and routed" {
    var seen = [_]bool{false} ** 256;
    var buffer: [bindings.len]u8 = undefined;
    const keys = advertisedKeys(&buffer);
    try std.testing.expect(keys.len > 0);
    for (keys) |key| {
        try std.testing.expect(!seen[key]);
        seen[key] = true;
        try std.testing.expect(bindingForKey(key) != null);
    }
}

test "footer text is generated from advertised registry keys" {
    inline for (.{ 80, 120, 165 }) |width| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(std.testing.allocator);
        var writer = std.Io.Writer.Allocating.fromArrayList(std.testing.allocator, &list);
        _ = try writeFooter(&writer.writer, width);
        list = writer.toArrayList();
        const text = try list.toOwnedSlice(std.testing.allocator);
        defer std.testing.allocator.free(text);

        var buffer: [bindings.len]u8 = undefined;
        for (advertisedKeys(&buffer)) |key| {
            const needle = [_]u8{key};
            try std.testing.expect(std.mem.indexOf(u8, text, &needle) != null);
        }
    }
}

test "hidden queue keys still map to typed actions" {
    try std.testing.expectEqual(protocol.ActionKind.run_lab_host_safe, actionKindForKey('r').?);
    try std.testing.expectEqual(protocol.ActionKind.verifier_only, actionKindForKey('v').?);
    try std.testing.expect(actionKindForKey('!') == null);
}
