pub const version = "0.6.1";
pub const program = "xsprof";

pub fn line() []const u8 {
    return program ++ " " ++ version ++ "\n";
}

test "version line is stable" {
    try @import("std").testing.expectEqualStrings("xsprof 0.6.1\n", line());
}
