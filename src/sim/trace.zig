const types = @import("types.zig");

pub fn eventLabel(kind: types.TraceEventKind) []const u8 {
    return switch (kind) {
        .arrival => "arrival",
        .dispatch => "dispatch",
        .tick => "tick",
        .preempt => "preempt",
        .complete => "complete",
        .idle => "idle",
    };
}
