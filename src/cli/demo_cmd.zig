//! `xsprof demo`: open the bundled replay in the native console. The browser
//! surface was removed in 0.5.0, so this is native-only and fails with an
//! explicit reason when no display is available; headless automation uses
//! `xsprof snapshot`, `xsprof ui --smoke`, or `xsprof capture`.

const std = @import("std");
const builtin = @import("builtin");
const render_cmd = @import("render.zig");
const state_paths = @import("../platform/state_paths.zig");

const Writer = std.Io.Writer;
const Exit = @import("exit.zig").Exit;

fn nativeDisplayAvailable(env: state_paths.Env) bool {
    if (comptime builtin.os.tag == .linux) {
        return env.get("DISPLAY") != null or env.get("WAYLAND_DISPLAY") != null;
    }
    if (comptime builtin.os.tag == .macos) return true;
    return false;
}

pub fn cmdDemo(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: state_paths.Env,
    args: []const []const u8,
    out: *Writer,
    err: *Writer,
) !Exit {
    const fixture = state_paths.demoFixtureWith(env, io, allocator) catch |fixture_error| {
        switch (fixture_error) {
            error.DemoFixtureMissing => try err.writeAll(
                "demo: bundled capture fixture is not installed beside the binary (set XSPROF_FIXTURES_DIR)\n",
            ),
            else => try err.print("demo: {s}\n", .{@errorName(fixture_error)}),
        }
        return .refuse;
    };
    defer allocator.free(fixture);

    if (!nativeDisplayAvailable(env)) {
        try err.writeAll(
            "demo: the bundled replay needs the native console (display unavailable); " ++
                "use `xsprof snapshot --replay FILE` or `xsprof ui --smoke` for headless output\n",
        );
        return .refuse;
    }

    var call_args: std.ArrayList([]const u8) = .empty;
    defer call_args.deinit(allocator);
    try call_args.appendSlice(allocator, &.{ "--demo-model", fixture });
    try call_args.appendSlice(allocator, args);
    return render_cmd.cmdUi(io, allocator, call_args.items, out, err);
}

// Checks the headless reason is explicit when no display exists. The test is
// skipped when a DISPLAY is present so no window can open in automated work.
test "demo explains headless mode without a display" {
    if (comptime builtin.os.tag != .linux) return;
    var empty_map = std.process.Environ.Map.init(std.testing.allocator);
    defer empty_map.deinit();
    const env = state_paths.Env.fromMap(&empty_map);
    if (nativeDisplayAvailable(env)) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out_buffer: [512]u8 = undefined;
    var err_buffer: [1024]u8 = undefined;
    var out = Writer.fixed(&out_buffer);
    var err = Writer.fixed(&err_buffer);
    const code = cmdDemo(std.testing.io, arena.allocator(), env, &.{}, &out, &err) catch .refuse;
    try std.testing.expectEqual(Exit.refuse, code);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "display unavailable") != null);
}
