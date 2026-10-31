//! xsprof — read-only Linux scheduler and memory profiler.
//!
//! The root module intentionally contains no UI code. Capture, platform, and
//! UI layers are imported by consumers that need them.

pub const json = @import("core/json.zig");
pub const version = @import("core/version.zig");
pub const event = @import("core/event.zig");
pub const privacy = @import("core/privacy.zig");
pub const safety = @import("core/safety.zig");
pub const proc = @import("os/linux/proc.zig");
pub const cli = @import("cli/root.zig");

test {
    // Pull the declarations into the test compilation unit so their tests run.
    _ = json;
    _ = version;
    _ = event;
    _ = privacy;
    _ = safety;
    _ = proc;
    _ = cli;
}
