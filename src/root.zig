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
pub const aggregates = @import("analyze/aggregates.zig");
pub const advisor = @import("analyze/advisor.zig");
pub const journal = @import("stream/journal.zig");
pub const chrome_trace = @import("viz/chrome_trace.zig");
pub const session = @import("stream/session.zig");
pub const serve = @import("serve/server.zig");
pub const live = @import("capture/live.zig");
pub const ttf = @import("ui/ttf.zig");
pub const ui_frame = @import("ui/frame.zig");
pub const ui_layout = @import("ui/layout.zig");
pub const ui_tester = @import("ui/tester.zig");
pub const demo = @import("app/demo.zig");
pub const gallery = @import("app/gallery.zig");
pub const app = @import("app/app.zig");
pub const cli = @import("cli/root.zig");

test {
    // Pull the declarations into the test compilation unit so their tests run.
    _ = json;
    _ = version;
    _ = event;
    _ = privacy;
    _ = safety;
    _ = proc;
    _ = aggregates;
    _ = advisor;
    _ = journal;
    _ = chrome_trace;
    _ = session;
    _ = serve;
    _ = live;
    _ = ttf;
    _ = ui_frame;
    _ = ui_layout;
    _ = ui_tester;
    _ = demo;
    _ = gallery;
    _ = app;
    _ = cli;
}
