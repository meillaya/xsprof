const std = @import("std");
const args = @import("args.zig");
const bridge_cli = @import("bridge_cli.zig");
const bridge_gui = @import("bridge_gui.zig");
const helpers = @import("bridge_helpers.zig");
const bridge_real_lab = @import("bridge_real_lab.zig");

const Options = args.Options;

pub fn isMethodAllowed(method: []const u8) bool {
    inline for (.{ "status", "run", "rollback", "stop", "subscribe" }) |allowed| {
        if (std.mem.eql(u8, method, allowed)) return true;
    }
    return false;
}

pub fn write(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, out: *std.Io.Writer, options: Options, method: []const u8) !void {
    if (try bridge_real_lab.write(allocator, io, environ, out, options, method)) return;
    if (try bridge_gui.write(allocator, io, out, options, method)) return;
    if (try bridge_cli.write(allocator, io, out, options, method)) return;
    if (isMethodAllowed(method)) {
        try out.print(
            "bridge_test method={s} accepted=true bridge_mode=webkitgtk-script-message host_mutation=false contract=status,run,rollback,stop,subscribe\n",
            .{method},
        );
        return;
    }
    if (std.mem.eql(u8, method, "unsupported-method")) {
        inline for (.{ "eval", "shell", "argv", "rawAction" }) |hostile| {
            try helpers.writeBridgeRefusal(out, hostile);
        }
    }
    try helpers.writeBridgeRefusal(out, method);
}

test "desktop bridge contract only accepts named methods" {
    inline for (.{ "status", "run", "rollback", "stop", "subscribe" }) |method| {
        try std.testing.expect(isMethodAllowed(method));
    }
    inline for (.{ "eval", "shell", "argv", "rawAction", "run_lab_microvm_live" }) |method| {
        try std.testing.expect(!isMethodAllowed(method));
    }
}

test "desktop bridge-test parses method without payload passthrough" {
    const options = try args.parse(&.{ "--bridge-test", "unsupported-method" });
    try std.testing.expectEqualStrings("unsupported-method", options.bridge_test.?);
    try std.testing.expect(!isMethodAllowed(options.bridge_test.?));
}
