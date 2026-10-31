//! One instanced Metal pipeline for the same draw list the CPU and WebGL
//! backends consume. No window is required for `renderOffscreen`.

const std = @import("std");
const builtin = @import("builtin");
const xsui = @import("xsui");
const objc = @import("xsui-objc");
const draw = xsui.draw;

const shader_source = @embedFile("shaders/metal/ui.metal");
const pixel_format: objc.NSUInteger = 80; // BGRA8Unorm
const atlas_format: objc.NSUInteger = 10; // R8Unorm
const Region = extern struct {
    x: usize,
    y: usize,
    z: usize,
    w: usize,
    h: usize,
    d: usize,
};
const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };

extern "c" fn MTLCreateSystemDefaultDevice() ?objc.Object;

pub const Renderer = struct {
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
    layer: objc.Object,
    atlas_texture: ?objc.Object = null,
    atlas_version: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init() !Renderer {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = objc.msg(objc.Object, device, "newCommandQueue", .{});
        errdefer objc.release(queue);
        var error_obj: ?objc.Object = null;
        const library = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{
            objc.nsString(shader_source),
            @as(?objc.Object, null),
            &error_obj,
        }) orelse return error.ShaderCompile;
        defer objc.release(library);
        const pipeline = try makePipeline(device, library);
        errdefer objc.release(pipeline);
        const layer = objc.new("CAMetalLayer");
        objc.msg(void, layer, "setDevice:", .{device});
        objc.msg(void, layer, "setPixelFormat:", .{pixel_format});
        objc.msg(void, layer, "setFramebufferOnly:", .{objc.YES});
        objc.msg(void, layer, "setOpaque:", .{objc.YES});
        return .{
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .layer = layer,
        };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.atlas_texture) |t| objc.release(t);
        objc.release(self.layer);
        objc.release(self.pipeline);
        objc.release(self.queue);
        objc.release(self.device);
    }

    /// Adapts this renderer to the public `xsui.gpu.Renderer` contract.
    pub fn interface(self: *Renderer) xsui.gpu.Renderer {
        return interfaceFor(self);
    }

    pub fn setSize(self: *Renderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        objc.msg(void, self.layer, "setContentsScale:", .{@as(f64, 1.0)});
        objc.msg(void, self.layer, "setDrawableSize:", .{objc.CGSize{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        }});
    }

    fn syncAtlas(self: *Renderer, atlas: *const draw.Atlas) !void {
        if (self.atlas_texture != null and self.atlas_version == atlas.version) return;
        if (self.atlas_texture == null) {
            const desc = objc.msg(
                objc.Object,
                objc.class("MTLTextureDescriptor"),
                "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
                .{ atlas_format, @as(objc.NSUInteger, atlas.width), @as(objc.NSUInteger, atlas.height), objc.NO },
            );
            self.atlas_texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        }
        objc.msg(void, self.atlas_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{
                .x = 0,
                .y = 0,
                .z = 0,
                .w = atlas.width,
                .h = atlas.height,
                .d = 1,
            },
            @as(objc.NSUInteger, 0),
            @as(*const anyopaque, atlas.pixels.ptr),
            @as(objc.NSUInteger, atlas.width),
        });
        self.atlas_version = atlas.version;
    }

    fn encode(
        self: *Renderer,
        command: objc.Object,
        target: objc.Object,
        instances: []const draw.Instance,
        viewport: [2]f32,
        background: draw.Color,
    ) void {
        const desc = objc.msg(objc.Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const attachments = objc.msg(objc.Object, desc, "colorAttachments", .{});
        const ca = objc.msg(objc.Object, attachments, "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setTexture:", .{target});
        objc.msg(void, ca, "setLoadAction:", .{@as(objc.NSUInteger, 2)});
        objc.msg(void, ca, "setStoreAction:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, ca, "setClearColor:", .{ClearColor{
            .r = @as(f64, @floatFromInt(background.r)) / 255.0,
            .g = @as(f64, @floatFromInt(background.g)) / 255.0,
            .b = @as(f64, @floatFromInt(background.b)) / 255.0,
            .a = 1.0,
        }});
        const encoder = objc.msg(objc.Object, command, "renderCommandEncoderWithDescriptor:", .{desc});
        if (instances.len != 0) {
            const bytes = std.mem.sliceAsBytes(instances);
            // MSL aligns the struct to 16 bytes (80 total); the shared Zig
            // instance is 72. Pad each row so the GPU sees the same fields.
            const stride = 80;
            const padded = std.heap.smp_allocator.alloc(u8, instances.len * stride) catch return;
            defer std.heap.smp_allocator.free(padded);
            @memset(padded, 0);
            for (instances, 0..) |_, index| {
                @memcpy(
                    padded[index * stride .. index * stride + @sizeOf(draw.Instance)],
                    bytes[index * @sizeOf(draw.Instance) .. (index + 1) * @sizeOf(draw.Instance)],
                );
            }
            const buffer = objc.msg(objc.Object, self.device, "newBufferWithBytes:length:options:", .{
                @as(*const anyopaque, padded.ptr),
                @as(objc.NSUInteger, padded.len),
                @as(objc.NSUInteger, 0),
            });
            objc.msg(void, encoder, "setRenderPipelineState:", .{self.pipeline});
            objc.msg(void, encoder, "setVertexBuffer:offset:atIndex:", .{
                buffer,
                @as(objc.NSUInteger, 0),
                @as(objc.NSUInteger, 0),
            });
            objc.msg(void, encoder, "setVertexBytes:length:atIndex:", .{
                @as(*const anyopaque, &viewport),
                @as(objc.NSUInteger, 8),
                @as(objc.NSUInteger, 1),
            });
            objc.msg(void, encoder, "setFragmentTexture:atIndex:", .{
                self.atlas_texture.?,
                @as(objc.NSUInteger, 0),
            });
            objc.msg(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                @as(objc.NSUInteger, 4),
                @as(objc.NSUInteger, 0),
                @as(objc.NSUInteger, 4),
                @as(objc.NSUInteger, instances.len),
            });
            objc.msg(void, encoder, "endEncoding", .{});
            objc.release(buffer);
            return;
        }
        objc.msg(void, encoder, "endEncoding", .{});
    }

    /// Draw into the window's next drawable. Returns false when no drawable
    /// is available; the caller can retry on the next tick.
    pub fn present(
        self: *Renderer,
        instances: []const draw.Instance,
        atlas: *const draw.Atlas,
        width: u32,
        height: u32,
        background: draw.Color,
    ) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.syncAtlas(atlas) catch return false;
        const drawable = objc.msg(?objc.Object, self.layer, "nextDrawable", .{}) orelse return false;
        const texture = objc.msg(objc.Object, drawable, "texture", .{});
        const command = objc.msg(objc.Object, self.queue, "commandBuffer", .{});
        self.encode(command, texture, instances, .{
            @floatFromInt(width),
            @floatFromInt(height),
        }, background);
        objc.msg(void, command, "presentDrawable:", .{drawable});
        objc.msg(void, command, "commit", .{});
        return true;
    }

    /// Render to a shared BGRA texture and read it back. No window.
    pub fn renderOffscreen(
        self: *Renderer,
        allocator: std.mem.Allocator,
        instances: []const draw.Instance,
        atlas: *const draw.Atlas,
        width: u32,
        height: u32,
        background: draw.Color,
    ) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        try self.syncAtlas(atlas);
        const desc = objc.msg(
            objc.Object,
            objc.class("MTLTextureDescriptor"),
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ pixel_format, @as(objc.NSUInteger, width), @as(objc.NSUInteger, height), objc.NO },
        );
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)});
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)});
        const texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        defer objc.release(texture);
        const command = objc.msg(objc.Object, self.queue, "commandBuffer", .{});
        self.encode(command, texture, instances, .{
            @floatFromInt(width),
            @floatFromInt(height),
        }, background);
        objc.msg(void, command, "commit", .{});
        objc.msg(void, command, "waitUntilCompleted", .{});
        const bytes = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(bytes);
        objc.msg(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, bytes.ptr),
            @as(objc.NSUInteger, width * 4),
            Region{ .x = 0, .y = 0, .z = 0, .w = width, .h = height, .d = 1 },
            @as(objc.NSUInteger, 0),
        });
        return bytes;
    }
};

/// Probes the system Metal device without creating a pipeline. A missing
/// device is SKIP, never a fabricated READY.
pub fn capability() xsui.gpu.Capability {
    const pool = objc.Pool.push();
    defer pool.pop();
    const device = MTLCreateSystemDefaultDevice() orelse return .{
        .backend = .metal,
        .status = .skip,
        .reason = "no Metal device",
    };
    objc.release(device);
    return .{ .backend = .metal, .status = .ready, .reason = "Metal device available" };
}

fn interfaceDeinit(context: *anyopaque) void {
    const self: *Renderer = @ptrCast(@alignCast(context));
    self.deinit();
}

fn interfaceResize(context: *anyopaque, target: xsui.gpu.Target) void {
    const self: *Renderer = @ptrCast(@alignCast(context));
    self.setSize(target.width, target.height);
}

fn interfaceDraw(
    context: *anyopaque,
    list: *const draw.DrawList,
    target: xsui.gpu.Target,
    background: draw.Color,
) !bool {
    const self: *Renderer = @ptrCast(@alignCast(context));
    return self.present(list.items.items, list.atlas, target.width, target.height, background);
}

fn interfaceReadback(
    context: *anyopaque,
    allocator: std.mem.Allocator,
    list: *const draw.DrawList,
    target: xsui.gpu.Target,
    background: draw.Color,
) ![]u8 {
    const self: *Renderer = @ptrCast(@alignCast(context));
    return self.renderOffscreen(
        allocator,
        list.items.items,
        list.atlas,
        target.width,
        target.height,
        background,
    );
}

const interface_vtable: xsui.gpu.Renderer.VTable = .{
    .backend = .metal,
    .deinit = interfaceDeinit,
    .resize = interfaceResize,
    .draw = interfaceDraw,
    .readback = interfaceReadback,
};

/// Adapts a concrete renderer to the public `xsui.gpu.Renderer` contract.
pub fn interfaceFor(self: *Renderer) xsui.gpu.Renderer {
    return .{ .context = self, .vtable = &interface_vtable };
}

fn makePipeline(device: objc.Object, library: objc.Object) !objc.Object {
    const vs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("vs")});
    defer objc.release(vs);
    const fs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("fs")});
    defer objc.release(fs);
    const desc = objc.new("MTLRenderPipelineDescriptor");
    defer objc.release(desc);
    objc.msg(void, desc, "setVertexFunction:", .{vs});
    objc.msg(void, desc, "setFragmentFunction:", .{fs});
    const attachments = objc.msg(objc.Object, desc, "colorAttachments", .{});
    const ca = objc.msg(objc.Object, attachments, "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, ca, "setPixelFormat:", .{pixel_format});
    objc.msg(void, ca, "setBlendingEnabled:", .{objc.YES});
    objc.msg(void, ca, "setSourceRGBBlendFactor:", .{@as(objc.NSUInteger, 4)});
    objc.msg(void, ca, "setSourceAlphaBlendFactor:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, ca, "setDestinationRGBBlendFactor:", .{@as(objc.NSUInteger, 5)});
    objc.msg(void, ca, "setDestinationAlphaBlendFactor:", .{@as(objc.NSUInteger, 5)});
    var error_obj: ?objc.Object = null;
    return objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{
        desc,
        &error_obj,
    }) orelse error.PipelineCreate;
}

fn sampleView(_: ?*anyopaque, ui: *xsui.Ui) !void {
    const theme = ui.theme;
    var root = try ui.column(.{
        .padding = xsui.Edges.all(10),
        .gap = 8,
        .bg = theme.panel,
    });
    try ui.text(.{ .text = "xsui metal parity", .size = 16, .color = theme.live, .weight = .bold });
    var row = try ui.row(.{ .height = 40, .gap = 8 });
    var a = try ui.column(.{
        .flex = 1,
        .bg = theme.raised,
        .border = theme.hairline,
        .border_width = 1,
        .radius = 4,
    });
    a.end();
    var b = try ui.column(.{ .flex = 2, .bg = theme.vm, .radius = 4 });
    b.end();
    row.end();
    try ui.text(.{ .text = "flat instance list", .size = 12, .color = theme.muted });
    root.end();
}

fn parity() !void {
    const width: u32 = 320;
    const height: u32 = 180;
    var frame: xsui.Frame = undefined;
    try frame.init(std.testing.allocator, width, height, .{});
    defer frame.deinit();
    var ui = xsui.Ui.init(&frame);
    defer ui.deinit();
    try sampleView(null, &ui);
    try ui.finish();
    const cpu = try xsui.raster.render(std.testing.allocator, width, height, &frame.list, frame.theme.bg);
    defer std.testing.allocator.free(cpu);
    var renderer = try Renderer.init();
    defer renderer.deinit();
    const renderer_interface = renderer.interface();
    try std.testing.expect(renderer_interface.supportsReadback());
    const bgra = try renderer_interface.readPixels(
        std.testing.allocator,
        &frame.list,
        .{ .width = width, .height = height },
        frame.theme.bg,
    );
    defer std.testing.allocator.free(bgra);
    var diff_sum: u64 = 0;
    var mismatches: usize = 0;
    var i: usize = 0;
    while (i < cpu.len) : (i += 4) {
        const dr = absDiff(cpu[i], bgra[i + 2]);
        const dg = absDiff(cpu[i + 1], bgra[i + 1]);
        const db = absDiff(cpu[i + 2], bgra[i]);
        diff_sum += dr + dg + db;
        if (dr > 40 or dg > 40 or db > 40) mismatches += 1;
    }
    const pixels = @as(u64, width) * height;
    const avg = @as(f64, @floatFromInt(diff_sum)) / @as(f64, @floatFromInt(pixels * 3));
    const bad_ratio = @as(f64, @floatFromInt(mismatches)) / @as(f64, @floatFromInt(pixels));
    std.debug.print("metal parity avg={d:.2} mismatches={d}/{d}\n", .{ avg, mismatches, pixels });
    try std.testing.expect(avg < 4.0);
    try std.testing.expect(bad_ratio < 0.03);
}

fn absDiff(a: u8, b: u8) u64 {
    return if (a > b) a - b else b - a;
}

test "metal offscreen matches the CPU renderer" {
    if (comptime builtin.os.tag == .macos) {
        try parity();
    } else {
        return error.SkipZigTest;
    }
}

test "metal capability reports an explicit state" {
    const cap = capability();
    try std.testing.expectEqual(xsui.gpu.Backend.metal, cap.backend);
    try std.testing.expect(cap.status == .ready or cap.status == .skip);
    try std.testing.expect(cap.reason.len != 0);
}
