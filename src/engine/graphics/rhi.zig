const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

/// Common RHI errors that backends may return.
pub const RhiError = error{
    /// Vulkan API call failed
    VulkanError,
    /// OpenGL error occurred
    OpenGLError,
    /// Out of memory
    OutOfMemory,
    /// Resource not found
    ResourceNotFound,
    /// Invalid operation for current state
    InvalidState,
};

/// Handle to a GPU buffer (Vertex Buffer, Index Buffer, etc.)
pub const BufferHandle = u32;
pub const InvalidBufferHandle: BufferHandle = 0;

/// Handle to a Shader pipeline/program
pub const ShaderHandle = u32;
pub const InvalidShaderHandle: ShaderHandle = 0;

/// Handle to a Texture
pub const TextureHandle = u32;
pub const InvalidTextureHandle: TextureHandle = 0;

pub const SHADOW_CASCADE_COUNT = 3;

pub const BufferUsage = enum {
    vertex,
    index,
    uniform,
};

pub const Vertex = extern struct {
    pos: [3]f32,
    color: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
    tile_id: f32,
    skylight: f32,
    blocklight: f32,
};

pub const DrawMode = enum {
    triangles,
    lines,
    points,
};

/// Sky rendering parameters
pub const SkyParams = struct {
    cam_forward: Vec3,
    cam_right: Vec3,
    cam_up: Vec3,
    aspect: f32,
    tan_half_fov: f32,
    sun_dir: Vec3,
    sky_color: Vec3,
    horizon_color: Vec3,
    sun_intensity: f32,
    moon_intensity: f32,
    time: f32,
};

/// Shadow cascade data for GPU sampling
pub const ShadowParams = struct {
    light_space_matrices: [SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [SHADOW_CASCADE_COUNT]f32,
    shadow_texel_sizes: [SHADOW_CASCADE_COUNT]f32,
};

/// RGBA color for UI rendering
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub const white = Color{ .r = 1, .g = 1, .b = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1 };
    pub const gray = Color{ .r = 0.5, .g = 0.5, .b = 0.5 };
    pub const dark_gray = Color{ .r = 0.2, .g = 0.2, .b = 0.2 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
            .a = 1.0,
        };
    }
};

/// Rectangle for UI positioning
pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    /// Check if a point is inside this rectangle
    pub fn contains(self: Rect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

pub const RHI = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Lifecycle
        init: *const fn (ctx: *anyopaque, allocator: Allocator) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,

        // Resource Management
        createBuffer: *const fn (ctx: *anyopaque, size: usize, usage: BufferUsage) BufferHandle,
        uploadBuffer: *const fn (ctx: *anyopaque, handle: BufferHandle, data: []const u8) void,
        destroyBuffer: *const fn (ctx: *anyopaque, handle: BufferHandle) void,

        // Command Recording
        beginFrame: *const fn (ctx: *anyopaque) void,
        setClearColor: *const fn (ctx: *anyopaque, color: Vec3) void,
        beginMainPass: *const fn (ctx: *anyopaque) void,
        endMainPass: *const fn (ctx: *anyopaque) void,
        endFrame: *const fn (ctx: *anyopaque) void,

        // Shadow Pass
        beginShadowPass: *const fn (ctx: *anyopaque, cascade_index: u32) void,
        endShadowPass: *const fn (ctx: *anyopaque) void,

        // Uniforms
        updateGlobalUniforms: *const fn (ctx: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32) void,
        updateShadowUniforms: *const fn (ctx: *anyopaque, params: ShadowParams) void,
        setModelMatrix: *const fn (ctx: *anyopaque, model: Mat4) void,

        // Draw Calls
        draw: *const fn (ctx: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
        drawSky: *const fn (ctx: *anyopaque, params: SkyParams) void,

        // Textures
        createTexture: *const fn (ctx: *anyopaque, width: u32, height: u32, data: []const u8) TextureHandle,
        destroyTexture: *const fn (ctx: *anyopaque, handle: TextureHandle) void,
        bindTexture: *const fn (ctx: *anyopaque, handle: TextureHandle, slot: u32) void,
        updateTexture: *const fn (ctx: *anyopaque, handle: TextureHandle, data: []const u8) void,

        getAllocator: *const fn (ctx: *anyopaque) std.mem.Allocator,

        // UI Rendering (2D orthographic)
        beginUI: *const fn (ctx: *anyopaque, screen_width: f32, screen_height: f32) void,
        endUI: *const fn (ctx: *anyopaque) void,
        drawUIQuad: *const fn (ctx: *anyopaque, rect: Rect, color: Color) void,
        drawUITexturedQuad: *const fn (ctx: *anyopaque, texture: TextureHandle, rect: Rect) void,
    };

    pub fn init(self: RHI, allocator: Allocator) !void {
        return self.vtable.init(self.ptr, allocator);
    }

    pub fn deinit(self: RHI) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn createBuffer(self: RHI, size: usize, usage: BufferUsage) BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }

    pub fn uploadBuffer(self: RHI, handle: BufferHandle, data: []const u8) void {
        self.vtable.uploadBuffer(self.ptr, handle, data);
    }

    pub fn destroyBuffer(self: RHI, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }

    pub fn beginFrame(self: RHI) void {
        self.vtable.beginFrame(self.ptr);
    }

    pub fn setClearColor(self: RHI, color: Vec3) void {
        self.vtable.setClearColor(self.ptr, color);
    }

    pub fn beginMainPass(self: RHI) void {
        self.vtable.beginMainPass(self.ptr);
    }

    pub fn endMainPass(self: RHI) void {
        self.vtable.endMainPass(self.ptr);
    }

    pub fn endFrame(self: RHI) void {
        self.vtable.endFrame(self.ptr);
    }

    pub fn beginShadowPass(self: RHI, cascade_index: u32) void {
        self.vtable.beginShadowPass(self.ptr, cascade_index);
    }

    pub fn endShadowPass(self: RHI) void {
        self.vtable.endShadowPass(self.ptr);
    }

    pub fn updateGlobalUniforms(self: RHI, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32) void {
        self.vtable.updateGlobalUniforms(self.ptr, view_proj, cam_pos, sun_dir, time, fog_color, fog_density, fog_enabled, sun_intensity, ambient);
    }

    pub fn updateShadowUniforms(self: RHI, params: ShadowParams) void {
        self.vtable.updateShadowUniforms(self.ptr, params);
    }

    pub fn setModelMatrix(self: RHI, model: Mat4) void {
        self.vtable.setModelMatrix(self.ptr, model);
    }

    pub fn draw(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }

    pub fn drawSky(self: RHI, params: SkyParams) void {
        self.vtable.drawSky(self.ptr, params);
    }

    pub fn createTexture(self: RHI, width: u32, height: u32, data: []const u8) TextureHandle {
        return self.vtable.createTexture(self.ptr, width, height, data);
    }

    pub fn destroyTexture(self: RHI, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ptr, handle);
    }

    pub fn bindTexture(self: RHI, handle: TextureHandle, slot: u32) void {
        self.vtable.bindTexture(self.ptr, handle, slot);
    }

    pub fn updateTexture(self: RHI, handle: TextureHandle, data: []const u8) void {
        self.vtable.updateTexture(self.ptr, handle, data);
    }

    pub fn getAllocator(self: RHI) std.mem.Allocator {
        return self.vtable.getAllocator(self.ptr);
    }

    // UI Rendering methods
    pub fn beginUI(self: RHI, screen_width: f32, screen_height: f32) void {
        self.vtable.beginUI(self.ptr, screen_width, screen_height);
    }

    pub fn endUI(self: RHI) void {
        self.vtable.endUI(self.ptr);
    }

    pub fn drawUIQuad(self: RHI, rect: Rect, color: Color) void {
        self.vtable.drawUIQuad(self.ptr, rect, color);
    }

    pub fn drawUITexturedQuad(self: RHI, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawUITexturedQuad(self.ptr, texture, rect);
    }
};
