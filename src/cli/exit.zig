//! CLI exit codes.
//!
//! One vocabulary for every command. The numeric values are stable because
//! `qa/cli_parity.sh` and operator scripts check them:
//!
//! | code | name     | meaning                                                        |
//! |------|----------|----------------------------------------------------------------|
//! | 0    | ok       | success; canonical output was written                          |
//! | 1    | refuse   | fail-closed refusal or runtime failure (unsafe verb, missing   |
//! |      |          | capability, corrupt state, failed validation/write)            |
//! | 2    | usage    | bad invocation: unknown flag, missing required arg, removed    |
//! |      |          | verb, unsupported shell                                         |
//! | 3    | internal | a reportable internal failure category (compare regression     |
//! |      |          | threshold breach); never a crash or a silent success            |
//!
//! Handlers return `Exit`; `main` converts it with `code()` exactly once.

const std = @import("std");

pub const Exit = enum(u8) {
    ok = 0,
    refuse = 1,
    usage = 2,
    internal = 3,

    pub fn code(self: Exit) u8 {
        return @backingInt(self);
    }

    /// Lossless-in-practice inverse used at the `main` boundary and in tests.
    /// Values outside the enum are treated as `internal` rather than trapping.
    pub fn fromCode(value: u8) Exit {
        return switch (value) {
            0 => .ok,
            1 => .refuse,
            2 => .usage,
            else => .internal,
        };
    }

    pub fn isOk(self: Exit) bool {
        return self == .ok;
    }
};

test "exit codes keep their documented numeric values" {
    try std.testing.expectEqual(@as(u8, 0), Exit.ok.code());
    try std.testing.expectEqual(@as(u8, 1), Exit.refuse.code());
    try std.testing.expectEqual(@as(u8, 2), Exit.usage.code());
    try std.testing.expectEqual(@as(u8, 3), Exit.internal.code());
    try std.testing.expectEqual(Exit.usage, Exit.fromCode(2));
    try std.testing.expectEqual(Exit.internal, Exit.fromCode(255));
}
