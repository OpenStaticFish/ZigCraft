const std = @import("std");
const Allocator = std.mem.Allocator;

/// Handle to a GPU buffer (Vertex Buffer, Index Buffer, etc.)
pub const BufferHandle = u32;
pub const InvalidBufferHandle: BufferHandle = 0;

/// Handle to a Shader pipeline/program
pub const ShaderHandle = u32;
pub const InvalidShaderHandle: ShaderHandle = 0;

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
        endFrame: *const fn (ctx: *anyopaque) void,

        // Draw Calls
        draw: *const fn (ctx: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
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

    pub fn endFrame(self: RHI) void {
        self.vtable.endFrame(self.ptr);
    }

    pub fn draw(self: RHI, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }
};
