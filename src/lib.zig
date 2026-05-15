//! Narrow public embedder facade for the simulator laboratory.
//!
//! The stable surface is intentionally smaller than `zig_scheduler_internal`.
//! Allocator-owning values returned through this facade remain caller-owned:
//! callers pass the allocator at construction time and must later call the
//! documented `deinit` method or matching SDK free helper exactly once.

pub const sdk_api_version: u32 = 1;

pub const model = @import("sdk/model.zig");
pub const scenario_io = @import("sdk/scenario_io.zig");
pub const simulate = @import("zig_scheduler_internal").simulate;
pub const report = @import("sdk/report.zig");

test {
    _ = @import("tests/library_sdk_test.zig");
}
