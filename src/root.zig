//! xsprof — read-only Linux scheduler and memory profiler.
//!
//! The root module intentionally contains no OS-specific code. Capture,
//! platform, and UI layers are imported by consumers that need them.

pub const json = @import("core/json.zig");
pub const version = @import("core/version.zig");
pub const cli = @import("cli/root.zig");

test {
    // Pull the declarations into the test compilation unit so their tests run.
    _ = json;
    _ = version;
    _ = cli;
}
