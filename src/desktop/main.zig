const std = @import("std");
const args = @import("args.zig");
const assets = @import("assets.zig");
const bridge_test = @import("bridge_test.zig");
const linux_webview = @import("linux_webview.zig");

const app_title = "zig-scheduler · live microVM lab";

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const options = args.parse(argv[1..]) catch |err| {
        try args.writeUsageAndRefusal(err);
        std.process.exit(2);
    };
    linux_webview.validateStateDirForWrite(init.io, options.state_dir) catch |err| {
        try args.writeUsageAndRefusal(err);
        std.process.exit(2);
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (options.dump_html) {
        try out.writeAll(assets.bundled_html);
        try stdout_writer.interface.flush();
        return;
    }

    if (options.smoke) {
        try writeSafetyLine(out, options, "smoke");
        try stdout_writer.interface.flush();
        return;
    }

    if (options.bridge_test) |method| {
        try bridge_test.write(init.gpa, init.io, init.minimal.environ, out, options, method);
        try stdout_writer.interface.flush();
        return;
    }

    if (options.headless_test) {
        try writeSafetyLine(out, options, "headless-test");
        try out.print("desktop_title={s} gui=not-started placeholder=true\n", .{app_title});
        try stdout_writer.interface.flush();
        return;
    }

    const runtime_html = try buildRuntimeHtml(init.gpa, init.io, options);
    defer init.gpa.free(runtime_html);

    try writeSafetyLine(out, options, "desktop-webview");
    try out.print("desktop_title={s} gui=starting runtime=linux-webkitgtk-system-webview\n", .{app_title});
    try stdout_writer.interface.flush();

    linux_webview.run(init.gpa, init.io, argv[0], options.state_dir, options.fake_daemon_path orelse options.daemon_bin, app_title, runtime_html) catch |err| {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        try stderr_writer.interface.print("SKIP system WebView runtime unavailable: {s}; mode=vm-lab-only host_mutation=false production_ready=false runtime=linux-webkitgtk-system-webview\n", .{@errorName(err)});
        try stderr_writer.interface.flush();
        std.process.exit(3);
    };
}

fn buildRuntimeHtml(allocator: std.mem.Allocator, io: std.Io, options: args.Options) ![]u8 {
    _ = io;
    var chunk: std.ArrayList(u8) = .empty;
    errdefer chunk.deinit(allocator);
    var writer = std.Io.Writer.Allocating.fromArrayList(allocator, &chunk);
    try writer.writer.writeAll(
        "\n<section id=\"desktop-qa-state\" aria-label=\"desktop controller state\" style=\"position:fixed;left:18px;right:18px;bottom:18px;z-index:9999;border:2px solid #34c8e8;border-radius:14px;background:rgba(5,7,10,.96);color:#d6ecff;padding:12px;font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;box-shadow:0 16px 50px rgba(0,0,0,.5)\">\n" ++
            "  <b id=\"qa-heading\">desktop controller bridge pending</b>\n" ++
            "  <div id=\"qa-summary\">qa_state=hero bridge_mode=webkitgtk-script-message controller_source=not_started mode=vm-lab-only host_mutation=false production_ready=false fake_daemon=",
    );
    try writer.writer.writeAll(if (options.fake_daemon) "true" else "false");
    try writer.writer.writeAll(" visible=live microVM lab daemon event stream FAIL-CLOSED</div><pre id=\"qa-events\" style=\"max-height:9em;overflow:hidden;white-space:pre-wrap;margin:.5em 0 0\">controller_event_history=awaiting_gui_action host_mutation=false</pre></section>\n");
    const dynamic = try writer.toOwnedSlice();
    errdefer allocator.free(dynamic);
    if (std.mem.indexOf(u8, assets.bundled_html, "</body>")) |body_index| {
        return std.mem.concat(allocator, u8, &.{ assets.bundled_html[0..body_index], dynamic, assets.bundled_html[body_index..] });
    }
    return std.mem.concat(allocator, u8, &.{ assets.bundled_html, dynamic });
}

fn writeSafetyLine(out: *std.Io.Writer, options: args.Options, command_mode: []const u8) !void {
    try out.print("{s} command_mode={s} title=\"{s}\" state_dir={s} daemon_bin={s} fake_daemon={any}", .{
        args.safety_markers,
        command_mode,
        app_title,
        options.state_dir,
        options.daemon_bin,
        options.fake_daemon,
    });
    if (options.fake_daemon_path) |path| try out.print(" fake_daemon_path={s}", .{path});
    try out.writeByte('\n');
}

test "desktop bundled html preserves offline visual contract" {
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "live microVM lab") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "FAIL-CLOSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "https://unpkg.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "fonts.googleapis.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "http://") == null);
    try std.testing.expect(std.mem.indexOf(u8, assets.bundled_html, "https://") == null);
}
