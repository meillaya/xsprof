//! Platform-neutral accessibility tree built from Canvas hit registrations.
//! Web mirrors this tree into a hidden DOM/ARIA tree; macOS bridges it to
//! NSAccessibility. Linux ships the JSON dump with an explicit AT-SPI SKIP.
//!
//! TODO(native-runtime): when xsui exposes Canvas.node(role,label,...) and
//! Hit.data, read those directly instead of the id catalogue + data ranges.
//! Until then this module derives labels from the frozen hit-id contract.

const std = @import("std");
const xsui = @import("xsui");
const model_mod = @import("model.zig");
const state_mod = @import("state.zig");
const route = @import("route.zig");
const hits = @import("hits.zig");
const commands = @import("commands.zig");
const capture = @import("capture.zig");
const picker = @import("picker.zig");

pub const schema = "xsprof/a11y-tree/v1";
pub const max_nodes = 320;
pub const max_label = 96;
pub const max_value = 48;

pub const Role = enum {
    window,
    tablist,
    tab,
    tabpanel,
    button,
    textbox,
    list,
    listitem,
    dialog,
    status,
    heading,
    progressbar,

    pub fn name(self: Role) []const u8 {
        return @tagName(self);
    }
};

pub const Node = struct {
    id: u32 = 0,
    role: Role = .button,
    parent: i16 = -1,
    rect: xsui.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    label: [max_label]u8 = @splat(0),
    label_len: usize = 0,
    value: [max_value]u8 = @splat(0),
    value_len: usize = 0,
    focusable: bool = true,
    selected: bool = false,
    disabled: bool = false,
    expanded: bool = true,

    pub fn labelSlice(self: *const Node) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn valueSlice(self: *const Node) []const u8 {
        return self.value[0..self.value_len];
    }
};

pub const Tree = struct {
    nodes: [max_nodes]Node = @splat(Node{}),
    len: usize = 0,
    truncated: bool = false,

    pub fn slice(self: *const Tree) []const Node {
        return self.nodes[0..self.len];
    }

    fn add(self: *Tree, node: Node) usize {
        if (self.len >= max_nodes) {
            self.truncated = true;
            return 0;
        }
        self.nodes[self.len] = node;
        self.len += 1;
        return self.len - 1;
    }

    pub fn find(self: *const Tree, id: u32) ?*const Node {
        for (self.slice()) |*node| {
            if (node.id == id) return node;
        }
        return null;
    }

    pub fn focusableCount(self: *const Tree) usize {
        var count: usize = 0;
        for (self.slice()) |node| {
            if (node.focusable) count += 1;
        }
        return count;
    }
};

const Root = struct {
    nodes: [max_nodes]Node = @splat(Node{}),
    len: usize = 0,
};

pub fn build(model: *const model_mod.Model, state: *const state_mod.State, canvas: *const xsui.Canvas, tree: *Tree) void {
    tree.* = .{};
    var root = Node{ .id = 0, .role = .window, .focusable = false, .rect = .{ .x = 0, .y = 0, .w = @floatFromInt(canvas.frame.width), .h = @floatFromInt(canvas.frame.height) } };
    setLabel(&root, "xsprof console");
    _ = tree.add(root);
    // Synthetic route group uses an id outside the hit catalogue. Do not reuse
    // the rail id here: the rail hit is added below and ids must stay unique.
    var route_group = Node{ .id = 1, .role = .tabpanel, .parent = 0, .focusable = false };
    setLabel(&route_group, state.screen.name());
    _ = tree.add(route_group);
    for (canvas.hits.items) |hit| {
        const node = nodeFor(model, state, hit.id, hit.rect) orelse continue;
        var with_parent = node;
        with_parent.parent = 0;
        _ = tree.add(with_parent);
    }
}

fn labelConst(text: []const u8) [max_label]u8 {
    var buf: [max_label]u8 = @splat(0);
    const len = @min(text.len, buf.len);
    @memcpy(buf[0..len], text[0..len]);
    return buf;
}

fn nodeFor(model: *const model_mod.Model, state: *const state_mod.State, id: u32, rect: xsui.Rect) ?Node {
    var node = Node{ .id = id, .rect = rect };
    if (route.fromRailId(id)) |target| {
        node.role = .tab;
        node.selected = state.screen == target;
        setLabel(&node, target.name());
        return node;
    }
    switch (id) {
        hits.topbar_palette => return labeled(&node, .button, "Command palette"),
        hits.topbar_theme => return labeled(&node, .button, "Appearance"),
        hits.topbar_help => return labeled(&node, .button, "Keyboard help"),
        hits.open_journal => return labeled(&node, .button, "Open journal"),
        hits.reload_fixture => return labeled(&node, .button, "Reload source"),
        hits.timeline_zoom_in => return labeled(&node, .button, "Zoom in"),
        hits.timeline_zoom_out => return labeled(&node, .button, "Zoom out"),
        hits.timeline_fit => return labeled(&node, .button, "Fit timeline"),
        hits.timeline_play => return labeled(&node, .button, "Play or pause"),
        hits.timeline_advisor => return labeled(&node, .button, "Open advisor"),
        hits.timeline_minimap => return labeled(&node, .button, "Timeline minimap"),
        hits.events_filter => return labeled(&node, .textbox, "Filter events"),
        hits.events_to_timeline => return labeled(&node, .button, "Open event in timeline"),
        hits.events_filter_task => return labeled(&node, .button, "Filter by task"),
        hits.palette_input => {
            node.role = .textbox;
            setLabel(&node, "Command query");
            setValue(&node, state.paletteQuery());
            return node;
        },
        hits.palette_esc => return labeled(&node, .button, "Close palette"),
        hits.dialog_close, hits.help_close => return labeled(&node, .button, "Close dialog"),
        hits.recorder_start => return labeled(&node, .button, "Start capture"),
        hits.recorder_stop => return labeled(&node, .button, "Stop capture"),
        hits.recorder_restart => return labeled(&node, .button, "Restart capture"),
        hits.recorder_extract => return labeled(&node, .button, "Extract window"),
        hits.recorder_attach => return labeled(&node, .button, "Attach recorder directory"),
        hits.recorder_export_journal => return labeled(&node, .button, "Export journal"),
        hits.recorder_export_trace => return labeled(&node, .button, "Export Chrome trace"),
        hits.recorder_export_report => return labeled(&node, .button, "Export report"),
        hits.recorder_export_incident => return labeled(&node, .button, "Bundle incident"),
        hits.audit_copy => return labeled(&node, .button, "Copy audit summary"),
        hits.audit_export => return labeled(&node, .button, "Export audit log"),
        hits.audit_verify => return labeled(&node, .button, "Verify audit log"),
        hits.settings_reduced_motion => return toggle(&node, state.settings.reduced_motion, "Reduced motion"),
        hits.settings_a11y_announce => return toggle(&node, state.settings.a11y_announce, "Announce state changes"),
        hits.settings_a11y_tree => return toggle(&node, state.settings.a11y_tree, "Expose accessibility tree"),
        hits.settings_capture_enabled => return toggle(&node, state.settings.capture_enabled, "Enable capture controls"),
        hits.settings_recorder_dir => return labeled(&node, .textbox, "Recorder state directory"),
        hits.settings_reset => return labeled(&node, .button, "Reset settings"),
        hits.settings_save => return labeled(&node, .button, "Save settings"),
        hits.home_live => return labeled(&node, .button, "Load live capture"),
        hits.home_replay => return labeled(&node, .button, "Load replay journal"),
        hits.home_recorder_window => return labeled(&node, .button, "Load recorder window"),
        hits.home_demo => return labeled(&node, .button, "Load bundled capture"),
        hits.home_open => return labeled(&node, .button, "Open analysis"),
        hits.home_refresh => return labeled(&node, .button, "Refresh source"),
        hits.recents_clear => return labeled(&node, .button, "Clear recents"),
        hits.onboarding_next => return labeled(&node, .button, "Onboarding next"),
        hits.onboarding_back => return labeled(&node, .button, "Onboarding back"),
        hits.onboarding_skip => return labeled(&node, .button, "Skip onboarding"),
        hits.onboarding_finish => return labeled(&node, .button, "Finish onboarding"),
        hits.confirm_yes => return labeled(&node, .button, "Confirm"),
        hits.confirm_no => return labeled(&node, .button, "Cancel"),
        hits.picker_cancel => return labeled(&node, .button, "Close picker"),
        hits.picker_up => return labeled(&node, .button, "Previous entry"),
        hits.picker_refresh => return labeled(&node, .button, "Open selected entry"),
        hits.picker_confirm => return labeled(&node, .button, "Choose entry"),
        hits.picker_filter => {
            node.role = .textbox;
            setLabel(&node, "Filter entries");
            setValue(&node, state.picker.filter.slice());
            return node;
        },
        hits.text_events_filter => return labeled(&node, .textbox, "Filter events"),
        hits.text_recorder_dir => return labeled(&node, .textbox, "Recorder state directory"),
        else => {},
    }
    if (id >= hits.home_window_base and id < hits.home_window_base + hits.home_window_max) {
        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Time frame {d}", .{id - hits.home_window_base}) catch "Time frame";
        return labeled(&node, .button, text);
    }
    if (id >= hits.recents_base and id < hits.recents_base + hits.recents_max) {
        const index = id - hits.recents_base;
        if (state.settings.recents.get(index)) |entry| {
            return labeled(&node, .listitem, entry.baseName());
        }
        return labeled(&node, .listitem, "Recent source");
    }
    if (id >= hits.palette_row_base and id < hits.palette_row_base + hits.palette_row_max) {
        if (commands.nth(state.paletteQuery(), id - hits.palette_row_base)) |command| {
            return labeled(&node, .listitem, command.label);
        }
        return null;
    }
    if (id >= hits.theme_option_base and id < hits.theme_option_base + 6) {
        const index = id - hits.theme_option_base;
        node.selected = state.theme_index == index;
        return labeled(&node, .button, xsui.themes.presets[index].name);
    }
    if (id >= hits.events_type_base and id < hits.events_type_base + hits.events_type_max) {
        return labeled(&node, .button, "Event type filter");
    }
    if (id >= hits.events_row_base and id < hits.events_row_base + hits.events_row_max) {
        const index = id - hits.events_row_base;
        if (index < model.events.len) {
            const event = model.events[index];
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} {s} pid {d}", .{ event.type, event.comm, event.pid }) catch "event row";
            node.role = .listitem;
            node.selected = state.events_selected == index;
            setLabel(&node, text);
            return node;
        }
        return null;
    }
    if (id >= hits.advisor_filter_base and id < hits.advisor_filter_base + hits.advisor_filter_max) {
        const names = [_][]const u8{ "All rules", "Warning", "Info", "Clear", "Skip" };
        return labeled(&node, .button, names[id - hits.advisor_filter_base]);
    }
    if (id >= hits.advisor_card_base and id < hits.advisor_card_base + hits.advisor_card_max) {
        const index = id - hits.advisor_card_base;
        if (index < model.advisor.len) return labeled(&node, .button, model.advisor[index].id);
        return null;
    }
    if (id >= hits.capture_copy_base and id < hits.capture_copy_base + hits.capture_copy_max) {
        const index = id - hits.capture_copy_base;
        if (index < capture.commands.len) return labeled(&node, .button, capture.commands[index][0]);
        return null;
    }
    if (id >= hits.slice_base and id < hits.slice_base + hits.slice_max) {
        const index = id - hits.slice_base;
        if (index < model.slices.len) {
            const slice = model.slices[index];
            var buf: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s} pid {d} cpu {d}", .{ slice.comm, slice.pid, slice.cpu }) catch "slice";
            node.selected = state.selected_slice == index;
            setLabel(&node, text);
            return node;
        }
        return null;
    }
    if (id >= hits.settings_theme_base and id < hits.settings_theme_base + hits.settings_theme_max) {
        return labeled(&node, .button, xsui.themes.presets[id - hits.settings_theme_base].name);
    }
    if (id >= hits.picker_row_base and id < hits.picker_row_base + picker.max_entries) {
        const index = id - hits.picker_row_base;
        if (index < state.picker.len) {
            node.role = .listitem;
            node.selected = state.picker.selected == index;
            setLabel(&node, state.picker.entries[index].nameSlice());
            return node;
        }
        return null;
    }
    return null;
}

fn labeled(node: *Node, role: Role, text: []const u8) ?Node {
    node.role = role;
    setLabel(node, text);
    return node.*;
}

fn toggle(node: *Node, value: bool, text: []const u8) ?Node {
    node.role = .button;
    node.selected = value;
    setLabel(node, text);
    return node.*;
}

pub fn setLabel(node: *Node, text: []const u8) void {
    node.label_len = @min(text.len, node.label.len);
    @memcpy(node.label[0..node.label_len], text[0..node.label_len]);
}

pub fn setValue(node: *Node, text: []const u8) void {
    node.value_len = @min(text.len, node.value.len);
    @memcpy(node.value[0..node.value_len], text[0..node.value_len]);
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\"),
            '\n' => try w.writeAll("\\n"),
            else => {
                if (byte < 0x20) try w.print("\\u00{x:0>2}", .{byte}) else try w.writeByte(byte);
            },
        }
    }
    try w.writeByte('"');
}

/// Canonical JSON for web DOM/ARIA mirroring, native bridges and golden tests.
pub fn writeJson(w: *std.Io.Writer, tree: *const Tree) !void {
    try w.writeAll("{\"host_mutation\":false,\"nodes\":[");
    for (tree.slice(), 0..) |node, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll("{\"disabled\":");
        try w.writeAll(if (node.disabled) "true" else "false");
        try w.writeAll(",\"focusable\":");
        try w.writeAll(if (node.focusable) "true" else "false");
        try w.writeAll(",\"id\":");
        try w.print("{d}", .{node.id});
        try w.writeAll(",\"label\":");
        try writeString(w, node.labelSlice());
        try w.writeAll(",\"role\":");
        try writeString(w, node.role.name());
        try w.writeAll(",\"selected\":");
        try w.writeAll(if (node.selected) "true" else "false");
        try w.writeAll(",\"value\":");
        try writeString(w, node.valueSlice());
        try w.writeByte('}');
    }
    try w.writeAll("],\"schema\":");
    try writeString(w, schema);
    try w.writeAll(",\"truncated\":");
    try w.writeAll(if (tree.truncated) "true" else "false");
    try w.writeByte('}');
}

test "a11y tree covers every rendered route with labeled focusables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    const view = @import("view.zig");
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1440, 900, .{});
    defer frame.deinit();
    for (route.order) |target| {
        var state = state_mod.State{ .screen = target };
        frame.list.clear();
        var canvas = xsui.Canvas.init(&frame);
        defer canvas.deinit();
        try view.view(&model, &state, &canvas);
        var tree = Tree{};
        build(&model, &state, &canvas, &tree);
        try std.testing.expect(tree.len > 1);
        try std.testing.expect(tree.focusableCount() > 0);
        var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
        defer seen.deinit();
        for (tree.slice()) |node| {
            if (node.focusable) try std.testing.expect(node.label_len > 0);
            if (node.id != 0) {
                const already = try seen.fetchPut(node.id, {});
                try std.testing.expect(already == null);
            }
        }
    }
}

test "a11y json is canonical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const model = try model_mod.loadDemo(std.testing.io, arena.allocator(), "fixtures/ui/design/demo.json");
    var state = state_mod.State{ .screen = .overview };
    var frame: xsui.frame.Frame = undefined;
    try frame.init(std.testing.allocator, 1280, 720, .{});
    defer frame.deinit();
    var canvas = xsui.Canvas.init(&frame);
    defer canvas.deinit();
    const view = @import("view.zig");
    try view.view(&model, &state, &canvas);
    var tree = Tree{};
    build(&model, &state, &canvas, &tree);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(&writer, &tree);
    const text = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"host_mutation\":false,\"nodes\":["));
    try std.testing.expect(std.mem.endsWith(u8, text, "}"));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"xsprof/a11y-tree/v1\"") != null);
}
