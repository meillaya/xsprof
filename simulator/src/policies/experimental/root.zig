const lottery = @import("lottery.zig");

pub const ExperimentalPolicyDescriptor = struct {
    key: []const u8,
    display_name: []const u8,
    module_path: []const u8,
    unstable_label: []const u8,
    summary: []const u8,
    promotion_rule: []const u8,
};

const descriptors = [_]ExperimentalPolicyDescriptor{
    .{
        .key = lottery.experimental_key,
        .display_name = lottery.experimental_display_name,
        .module_path = "src/policies/experimental/lottery.zig",
        .unstable_label = "experimental-only",
        .summary = lottery.experimental_summary,
        .promotion_rule = "Requires an explicit ADR promotion decision before entering the supported policy set.",
    },
};

pub const lottery_policy = lottery;

pub fn listExperimentalPolicyDescriptors() []const ExperimentalPolicyDescriptor {
    return descriptors[0..];
}
