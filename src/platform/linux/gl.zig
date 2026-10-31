//! OpenGL 3.3 renderer loaded at runtime through GLX. No build-time link to
//! libGL; the X11 surface owns the context and swap.

const std = @import("std");
const draw = @import("../../ui/draw.zig");

const GL = struct {
    lib: std.DynLib,
    get_proc: *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,

    clear_color: *const fn (f32, f32, f32, f32) callconv(.c) void,
    clear: *const fn (u32) callconv(.c) void,
    viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    enable: *const fn (u32) callconv(.c) void,
    disable: *const fn (u32) callconv(.c) void,
    blend_func_separate: *const fn (u32, u32, u32, u32) callconv(.c) void,
    gen_vertex_arrays: *const fn (i32, *u32) callconv(.c) void,
    bind_vertex_array: *const fn (u32) callconv(.c) void,
    gen_buffers: *const fn (i32, *u32) callconv(.c) void,
    bind_buffer: *const fn (u32, u32) callconv(.c) void,
    buffer_data: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.c) void,
    enable_vertex_attrib_array: *const fn (u32) callconv(.c) void,
    vertex_attrib_pointer: *const fn (u32, i32, u32, u8, i32, usize) callconv(.c) void,
    vertex_attrib_ip_pointer: *const fn (u32, i32, u32, i32, usize) callconv(.c) void,
    vertex_attrib_divisor: *const fn (u32, u32) callconv(.c) void,
    create_shader: *const fn (u32) callconv(.c) u32,
    shader_source: *const fn (u32, i32, *const [*]const u8, ?*const i32) callconv(.c) void,
    compile_shader: *const fn (u32) callconv(.c) void,
    get_shader_iv: *const fn (u32, u32, *i32) callconv(.c) void,
    get_shader_info_log: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void,
    create_program: *const fn () callconv(.c) u32,
    attach_shader: *const fn (u32, u32) callconv(.c) void,
    link_program: *const fn (u32) callconv(.c) void,
    get_program_iv: *const fn (u32, u32, *i32) callconv(.c) void,
    get_program_info_log: *const fn (u32, i32, ?*i32, [*]u8) callconv(.c) void,
    use_program: *const fn (u32) callconv(.c) void,
    get_uniform_location: *const fn (u32, [*:0]const u8) callconv(.c) i32,
    uniform_1i: *const fn (i32, i32) callconv(.c) void,
    uniform_2f: *const fn (i32, f32, f32) callconv(.c) void,
    gen_textures: *const fn (i32, *u32) callconv(.c) void,
    bind_texture: *const fn (u32, u32) callconv(.c) void,
    active_texture: *const fn (u32) callconv(.c) void,
    tex_parameter_i: *const fn (u32, u32, i32) callconv(.c) void,
    tex_image_2d: *const fn (u32, i32, i32, i32, i32, i32, u32, u32, ?*const anyopaque) callconv(.c) void,
    pixel_store_i: *const fn (u32, i32) callconv(.c) void,
    draw_arrays_instanced: *const fn (u32, i32, i32, i32) callconv(.c) void,

    fn load() !GL {
        var lib = std.DynLib.open("libGL.so.1") catch return error.NoGL;
        errdefer lib.close();
        const get_proc = lib.lookup(*const fn ([*:0]const u8) callconv(.c) ?*anyopaque, "glXGetProcAddress") orelse
            return error.NoGLX;
        var self: GL = .{
            .lib = lib,
            .get_proc = get_proc,
            .clear_color = undefined,
            .clear = undefined,
            .viewport = undefined,
            .enable = undefined,
            .disable = undefined,
            .blend_func_separate = undefined,
            .gen_vertex_arrays = undefined,
            .bind_vertex_array = undefined,
            .gen_buffers = undefined,
            .bind_buffer = undefined,
            .buffer_data = undefined,
            .enable_vertex_attrib_array = undefined,
            .vertex_attrib_pointer = undefined,
            .vertex_attrib_ip_pointer = undefined,
            .vertex_attrib_divisor = undefined,
            .create_shader = undefined,
            .shader_source = undefined,
            .compile_shader = undefined,
            .get_shader_iv = undefined,
            .get_shader_info_log = undefined,
            .create_program = undefined,
            .attach_shader = undefined,
            .link_program = undefined,
            .get_program_iv = undefined,
            .get_program_info_log = undefined,
            .use_program = undefined,
            .get_uniform_location = undefined,
            .uniform_1i = undefined,
            .uniform_2f = undefined,
            .gen_textures = undefined,
            .bind_texture = undefined,
            .active_texture = undefined,
            .tex_parameter_i = undefined,
            .tex_image_2d = undefined,
            .pixel_store_i = undefined,
            .draw_arrays_instanced = undefined,
        };
        try self.bind("glClearColor", @ptrCast(&self.clear_color));
        try self.bind("glClear", @ptrCast(&self.clear));
        try self.bind("glViewport", @ptrCast(&self.viewport));
        try self.bind("glEnable", @ptrCast(&self.enable));
        try self.bind("glDisable", @ptrCast(&self.disable));
        try self.bind("glBlendFuncSeparate", @ptrCast(&self.blend_func_separate));
        try self.bind("glGenVertexArrays", @ptrCast(&self.gen_vertex_arrays));
        try self.bind("glBindVertexArray", @ptrCast(&self.bind_vertex_array));
        try self.bind("glGenBuffers", @ptrCast(&self.gen_buffers));
        try self.bind("glBindBuffer", @ptrCast(&self.bind_buffer));
        try self.bind("glBufferData", @ptrCast(&self.buffer_data));
        try self.bind("glEnableVertexAttribArray", @ptrCast(&self.enable_vertex_attrib_array));
        try self.bind("glVertexAttribPointer", @ptrCast(&self.vertex_attrib_pointer));
        try self.bind("glVertexAttribIPointer", @ptrCast(&self.vertex_attrib_ip_pointer));
        try self.bind("glVertexAttribDivisor", @ptrCast(&self.vertex_attrib_divisor));
        try self.bind("glCreateShader", @ptrCast(&self.create_shader));
        try self.bind("glShaderSource", @ptrCast(&self.shader_source));
        try self.bind("glCompileShader", @ptrCast(&self.compile_shader));
        try self.bind("glGetShaderiv", @ptrCast(&self.get_shader_iv));
        try self.bind("glGetShaderInfoLog", @ptrCast(&self.get_shader_info_log));
        try self.bind("glCreateProgram", @ptrCast(&self.create_program));
        try self.bind("glAttachShader", @ptrCast(&self.attach_shader));
        try self.bind("glLinkProgram", @ptrCast(&self.link_program));
        try self.bind("glGetProgramiv", @ptrCast(&self.get_program_iv));
        try self.bind("glGetProgramInfoLog", @ptrCast(&self.get_program_info_log));
        try self.bind("glUseProgram", @ptrCast(&self.use_program));
        try self.bind("glGetUniformLocation", @ptrCast(&self.get_uniform_location));
        try self.bind("glUniform1i", @ptrCast(&self.uniform_1i));
        try self.bind("glUniform2f", @ptrCast(&self.uniform_2f));
        try self.bind("glGenTextures", @ptrCast(&self.gen_textures));
        try self.bind("glBindTexture", @ptrCast(&self.bind_texture));
        try self.bind("glActiveTexture", @ptrCast(&self.active_texture));
        try self.bind("glTexParameteri", @ptrCast(&self.tex_parameter_i));
        try self.bind("glTexImage2D", @ptrCast(&self.tex_image_2d));
        try self.bind("glPixelStorei", @ptrCast(&self.pixel_store_i));
        try self.bind("glDrawArraysInstanced", @ptrCast(&self.draw_arrays_instanced));
        return self;
    }

    fn bind(self: *GL, comptime name: [:0]const u8, target: *anyopaque) !void {
        const address = self.get_proc(name) orelse self.lib.lookup(*anyopaque, name) orelse
            return error.MissingGL;
        const dest: *?*anyopaque = @ptrCast(@alignCast(target));
        dest.* = address;
    }
};

pub const Renderer = struct {
    gl: GL,
    program: u32 = 0,
    vao: u32 = 0,
    vbo: u32 = 0,
    atlas_texture: u32 = 0,
    atlas_version: u32 = 0,
    viewport_loc: i32 = -1,

    pub fn init() !Renderer {
        var gl = try GL.load();
        errdefer gl.lib.close();
        var self = Renderer{ .gl = gl };
        try self.createPipeline();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.gl.lib.close();
    }

    fn createPipeline(self: *Renderer) !void {
        const vs = try self.compile(0x8B31, @embedFile("ui.vert.glsl"));
        const fs = try self.compile(0x8B30, @embedFile("ui.frag.glsl"));
        const program = self.gl.create_program();
        self.gl.attach_shader(program, vs);
        self.gl.attach_shader(program, fs);
        self.gl.link_program(program);
        var status: i32 = 0;
        self.gl.get_program_iv(program, 0x8B82, &status);
        if (status == 0) {
            var log: [1024]u8 = undefined;
            self.gl.get_program_info_log(program, log.len, null, &log);
            std.debug.print("gl link: {s}\n", .{std.mem.sliceTo(&log, 0)});
            return error.ShaderLink;
        }
        self.program = program;
        self.gl.use_program(program);
        self.gl.gen_vertex_arrays(1, &self.vao);
        self.gl.bind_vertex_array(self.vao);
        self.gl.gen_buffers(1, &self.vbo);
        self.gl.bind_buffer(0x8892, self.vbo);
        self.gl.enable(0x0BE2);
        self.gl.blend_func_separate(0x0302, 0x0303, 1, 0x0303);
        self.gl.disable(0x0B71);
        const stride: i32 = @sizeOf(draw.Instance);
        inline for ([_]struct { loc: u32, size: i32, offset: usize, integer: bool }{
            .{ .loc = 0, .size = 4, .offset = 0, .integer = false },
            .{ .loc = 1, .size = 4, .offset = 16, .integer = false },
            .{ .loc = 2, .size = 4, .offset = 32, .integer = false },
            .{ .loc = 3, .size = 1, .offset = 48, .integer = true },
            .{ .loc = 4, .size = 1, .offset = 52, .integer = true },
            .{ .loc = 5, .size = 1, .offset = 56, .integer = false },
            .{ .loc = 6, .size = 1, .offset = 60, .integer = false },
            .{ .loc = 7, .size = 1, .offset = 64, .integer = true },
        }) |attr| {
            self.gl.enable_vertex_attrib_array(attr.loc);
            if (attr.integer) {
                self.gl.vertex_attrib_ip_pointer(attr.loc, attr.size, 0x1405, stride, attr.offset);
            } else {
                self.gl.vertex_attrib_pointer(attr.loc, attr.size, 0x1406, 0, stride, attr.offset);
            }
            self.gl.vertex_attrib_divisor(attr.loc, 1);
        }
        self.gl.gen_textures(1, &self.atlas_texture);
        self.gl.active_texture(0x84C0);
        self.gl.bind_texture(0x0DE1, self.atlas_texture);
        self.gl.tex_parameter_i(0x0DE1, 0x2801, 0x2600);
        self.gl.tex_parameter_i(0x0DE1, 0x2802, 0x2600);
        self.gl.pixel_store_i(0x0CF5, 1);
        self.viewport_loc = self.gl.get_uniform_location(program, "u_viewport");
        self.gl.uniform_1i(self.gl.get_uniform_location(program, "u_atlas"), 0);
    }

    fn compile(self: *Renderer, kind: u32, source: []const u8) !u32 {
        const shader = self.gl.create_shader(kind);
        var ptr: [*]const u8 = source.ptr;
        var len: i32 = @intCast(source.len);
        self.gl.shader_source(shader, 1, &ptr, &len);
        self.gl.compile_shader(shader);
        var status: i32 = 0;
        self.gl.get_shader_iv(shader, 0x8B81, &status);
        if (status == 0) {
            var log: [1024]u8 = undefined;
            self.gl.get_shader_info_log(shader, log.len, null, &log);
            std.debug.print("gl compile: {s}\n", .{std.mem.sliceTo(&log, 0)});
            return error.ShaderCompile;
        }
        return shader;
    }

    pub fn paint(self: *Renderer, instances: []const draw.Instance, atlas: *const draw.Atlas, width: u32, height: u32, background: draw.Color) void {
        self.gl.viewport(0, 0, @intCast(width), @intCast(height));
        self.gl.clear_color(
            @as(f32, @floatFromInt(background.r)) / 255.0,
            @as(f32, @floatFromInt(background.g)) / 255.0,
            @as(f32, @floatFromInt(background.b)) / 255.0,
            1,
        );
        self.gl.clear(0x4000);
        if (self.atlas_version != atlas.version) {
            self.gl.bind_texture(0x0DE1, self.atlas_texture);
            self.gl.tex_image_2d(
                0x0DE1,
                0,
                0x8229,
                @intCast(atlas.width),
                @intCast(atlas.height),
                0,
                0x1903,
                0x1401,
                atlas.pixels.ptr,
            );
            self.atlas_version = atlas.version;
        }
        if (instances.len == 0) return;
        self.gl.use_program(self.program);
        self.gl.bind_vertex_array(self.vao);
        self.gl.bind_buffer(0x8892, self.vbo);
        const bytes = std.mem.sliceAsBytes(instances);
        self.gl.buffer_data(0x8892, @intCast(bytes.len), bytes.ptr, 0x88E8);
        self.gl.uniform_2f(self.viewport_loc, @floatFromInt(width), @floatFromInt(height));
        self.gl.active_texture(0x84C0);
        self.gl.bind_texture(0x0DE1, self.atlas_texture);
        self.gl.draw_arrays_instanced(5, 0, 4, @intCast(instances.len));
    }
};
