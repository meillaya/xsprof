const std = @import("std");
const dashboard = @import("dashboard_root");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const rendered = try dashboard.renderMarkdown(allocator);
    defer allocator.free(rendered);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(rendered);
    try stdout.flush();
}
