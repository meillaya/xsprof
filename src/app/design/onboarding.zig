//! First-run onboarding state: four steps, bounded, persisted as a version in
//! the UI settings. The renderer lives in overlays.zig.

const std = @import("std");

pub const version: u32 = 2;

pub const Step = enum {
    welcome,
    read_only,
    capabilities,
    source,

    pub fn index(self: Step) u8 {
        return @backingInt(self);
    }

    pub fn title(self: Step) []const u8 {
        return switch (self) {
            .welcome => "WELCOME",
            .read_only => "READ-ONLY CONTRACT",
            .capabilities => "HOST CAPABILITIES",
            .source => "CHOOSE A SOURCE",
        };
    }
};

pub const State = struct {
    completed_version: u32 = 0,
    active: bool = false,
    step: Step = .welcome,
    skipped: bool = false,

    pub fn beginIfDue(self: *State) void {
        if (self.completed_version < version) {
            self.active = true;
            self.step = .welcome;
            self.skipped = false;
        }
    }

    pub fn next(self: *State) void {
        self.step = switch (self.step) {
            .welcome => .read_only,
            .read_only => .capabilities,
            .capabilities => .source,
            .source => .source,
        };
    }

    pub fn back(self: *State) void {
        self.step = switch (self.step) {
            .welcome => .welcome,
            .read_only => .welcome,
            .capabilities => .read_only,
            .source => .capabilities,
        };
    }

    pub fn finish(self: *State) void {
        self.completed_version = version;
        self.active = false;
        self.skipped = false;
    }

    pub fn skip(self: *State) void {
        self.completed_version = version;
        self.active = false;
        self.skipped = true;
    }

    pub fn isLast(self: *const State) bool {
        return self.step == .source;
    }
};

test "onboarding walks four steps and persists a version" {
    var state = State{};
    state.beginIfDue();
    try std.testing.expect(state.active);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const before = state.step.index();
        state.next();
        try std.testing.expectEqual(before + 1, state.step.index());
    }
    try std.testing.expect(state.isLast());
    state.finish();
    try std.testing.expect(!state.active);
    try std.testing.expectEqual(version, state.completed_version);
    state.beginIfDue();
    try std.testing.expect(!state.active);
}
