//! Legacy compile-only canary for the `webview/webview` C ABI.
//!
//! The production live VM desktop host currently uses the explicit
//! WebKitGTK helper in `linux_webview_host.c`; these declarations are kept
//! only as a non-authoritative dependency comparison/probe surface.

const std = @import("std");

pub const Webview = opaque {};
pub const Handle = ?*Webview;

pub const SizeHint = enum(c_int) {
    none = 0,
    min = 1,
    max = 2,
    fixed = 3,
};

pub extern fn webview_create(debug: c_int, window: ?*anyopaque) Handle;
pub extern fn webview_destroy(webview: Handle) void;
pub extern fn webview_run(webview: Handle) void;
pub extern fn webview_terminate(webview: Handle) void;
pub extern fn webview_set_title(webview: Handle, title: [*:0]const u8) void;
pub extern fn webview_set_size(webview: Handle, width: c_int, height: c_int, hints: SizeHint) void;
pub extern fn webview_set_html(webview: Handle, html: [*:0]const u8) void;
pub extern fn webview_navigate(webview: Handle, url: [*:0]const u8) void;

pub const abi_name = "legacy webview/webview C ABI canary (not product runtime)";

pub fn dependencyGuidance() []const u8 {
    return "Linux: install GTK 3 and WebKitGTK development packages " ++
        "(Debian/Ubuntu: libgtk-3-dev libwebkit2gtk-4.1-dev, fallback libwebkit2gtk-4.0-dev; " ++
        "Fedora: gtk3-devel webkit2gtk4.1-devel or webkit2gtk4.0-devel; " ++
        "Arch: gtk3 webkit2gtk-4.1 or webkit2gtk). " ++
        "macOS: WebKit is provided by the system SDK. " ++
        "Windows: install the Microsoft Edge WebView2 Runtime/SDK.";
}

test "legacy webview C ABI declarations are pointer-sized" {
    try std.testing.expectEqual(@sizeOf(?*anyopaque), @sizeOf(Handle));
    try std.testing.expect(@intFromEnum(SizeHint.none) == 0);
}
