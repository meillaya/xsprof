const std = @import("std");
const xsprof = @import("xsprof");

pub fn main(init: std.process.Init) !void {
    const code = try xsprof.cli.run(init);
    if (code != 0) std.process.exit(code);
}
