//! RenderDevice - GPU Resource Lifetime Management
//!
//! This module provides a unified abstraction for managing GPU resources
//! (buffers, textures, shaders) separate from rendering commands.
//!
//! ## Architecture
//! - RenderDevice owns all GPU resources and manages their lifetime
//! - Pools provide handle-based resource allocation with free list management
//! - Garbage collection support for deferred resource cleanup
//! - Clear ownership semantics: RenderDevice owns, RHI borrows for rendering
//!
//! ## Usage
//! ```zig
//! var device = try RenderDevice.init(allocator, backend_type);
//! defer device.deinit();
//!
//! const buffer = device.createBuffer(size, usage);
//! defer device.destroyBuffer(buffer);
//!
//! // In rendering:
//! rhi.draw(buffer, count, mode);
//!
//! // Periodic cleanup:
//! device.gc();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const rhi = @import("rhi.zig");

pub const RenderDevice = struct {
    allocator: Allocator,
    buffers: BufferPool,
    textures: TexturePool,
    shaders: ShaderCache,

    pub fn init(allocator: Allocator) !RenderDevice {
        return .{
            .allocator = allocator,
            .buffers = try BufferPool.init(allocator),
            .textures = try TexturePool.init(allocator),
            .shaders = try ShaderCache.init(allocator),
        };
    }

    pub fn deinit(self: *RenderDevice) void {
        self.buffers.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.shaders.deinit(self.allocator);
    }

    pub fn createBuffer(self: *RenderDevice, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
        return self.buffers.create(size, usage);
    }

    pub fn destroyBuffer(self: *RenderDevice, handle: rhi.BufferHandle) void {
        self.buffers.destroy(handle);
    }

    pub fn getBufferInfo(self: *RenderDevice, handle: rhi.BufferHandle) ?BufferInfo {
        return self.buffers.getInfo(handle);
    }

    pub fn createTexture(
        self: *RenderDevice,
        width: u32,
        height: u32,
        format: rhi.TextureFormat,
        config: rhi.TextureConfig,
        data: ?[]const u8,
    ) rhi.TextureHandle {
        return self.textures.create(width, height, format, config, data);
    }

    pub fn destroyTexture(self: *RenderDevice, handle: rhi.TextureHandle) void {
        self.textures.destroy(handle);
    }

    pub fn getTextureInfo(self: *RenderDevice, handle: rhi.TextureHandle) ?TextureInfo {
        return self.textures.getInfo(handle);
    }

    pub fn createShader(
        self: *RenderDevice,
        vertex_src: [*c]const u8,
        fragment_src: [*c]const u8,
    ) RhiError!rhi.ShaderHandle {
        return self.shaders.create(vertex_src, fragment_src);
    }

    pub fn destroyShader(self: *RenderDevice, handle: rhi.ShaderHandle) void {
        self.shaders.destroy(handle);
    }

    pub fn gc(self: *RenderDevice) void {
        self.buffers.gc();
        self.textures.gc();
        self.shaders.gc();
    }

    pub fn getStats(self: *RenderDevice) Stats {
        return .{
            .buffer_count = self.buffers.activeCount(),
            .texture_count = self.textures.activeCount(),
            .shader_count = self.shaders.activeCount(),
            .total_buffer_memory = self.buffers.totalMemory(),
            .total_texture_memory = self.textures.totalMemory(),
        };
    }
};

pub const BufferInfo = struct {
    size: usize,
    usage: rhi.BufferUsage,
    creation_frame: u64,
    last_used_frame: u64,
};

pub const TextureInfo = struct {
    width: u32,
    height: u32,
    format: rhi.TextureFormat,
    mip_levels: u32,
    creation_frame: u64,
    last_used_frame: u64,
};

pub const Stats = struct {
    buffer_count: u32,
    texture_count: u32,
    shader_count: u32,
    total_buffer_memory: usize,
    total_texture_memory: usize,
};

const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayListUnmanaged(BufferEntry),
    free_indices: std.ArrayListUnmanaged(usize),
    next_handle: rhi.BufferHandle,
    frame: u64,

    const BufferEntry = struct {
        size: usize,
        usage: rhi.BufferUsage,
        creation_frame: u64,
        last_used_frame: u64,
        backend_data: ?*anyopaque,
        alive: bool = true,
    };

    fn init(allocator: Allocator) !BufferPool {
        return .{
            .allocator = allocator,
            .buffers = .empty,
            .free_indices = .empty,
            .next_handle = 1,
            .frame = 0,
        };
    }

    fn deinit(self: *BufferPool, allocator: Allocator) void {
        self.buffers.deinit(allocator);
        self.free_indices.deinit(allocator);
    }

    fn create(self: *BufferPool, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
        const handle = self.next_handle;
        self.next_handle += 1;

        if (self.free_indices.popOrNull()) |idx| {
            self.buffers.items[idx] = .{
                .size = size,
                .usage = usage,
                .creation_frame = self.frame,
                .last_used_frame = self.frame,
                .backend_data = null,
                .alive = true,
            };
            return handle;
        }

        self.buffers.append(self.allocator, .{
            .size = size,
            .usage = usage,
            .creation_frame = self.frame,
            .last_used_frame = self.frame,
            .backend_data = null,
            .alive = true,
        }) catch {
            return rhi.InvalidBufferHandle;
        };
        return handle;
    }

    fn destroy(self: *BufferPool, handle: rhi.BufferHandle) void {
        if (handle == 0) return;
        const idx = handle - 1;
        if (idx < self.buffers.items.len) {
            const entry = &self.buffers.items[idx];
            if (entry.alive) {
                entry.alive = false;
                entry.last_used_frame = self.frame;
                self.free_indices.append(self.allocator, idx) catch {};
            }
        }
    }

    fn getInfo(self: *BufferPool, handle: rhi.BufferHandle) ?BufferInfo {
        if (handle == 0) return null;
        const idx = handle - 1;
        if (idx < self.buffers.items.len) {
            const entry = self.buffers.items[idx];
            if (entry.alive) {
                return .{
                    .size = entry.size,
                    .usage = entry.usage,
                    .creation_frame = entry.creation_frame,
                    .last_used_frame = entry.last_used_frame,
                };
            }
        }
        return null;
    }

    fn gc(self: *BufferPool) void {
        _ = self;
    }

    fn activeCount(self: *BufferPool) u32 {
        var count: u32 = 0;
        for (self.buffers.items) |entry| {
            if (entry.alive) count += 1;
        }
        return count;
    }

    fn totalMemory(self: *BufferPool) usize {
        var total: usize = 0;
        for (self.buffers.items) |entry| {
            if (entry.alive) total += entry.size;
        }
        return total;
    }
};

const TexturePool = struct {
    allocator: Allocator,
    textures: std.ArrayListUnmanaged(TextureEntry),
    free_indices: std.ArrayListUnmanaged(usize),
    next_handle: rhi.TextureHandle,
    frame: u64,

    const TextureEntry = struct {
        width: u32,
        height: u32,
        format: rhi.TextureFormat,
        mip_levels: u32,
        creation_frame: u64,
        last_used_frame: u64,
        backend_data: ?*anyopaque,
        alive: bool = true,
    };

    fn init(allocator: Allocator) !TexturePool {
        return .{
            .allocator = allocator,
            .textures = .empty,
            .free_indices = .empty,
            .next_handle = 1,
            .frame = 0,
        };
    }

    fn deinit(self: *TexturePool, allocator: Allocator) void {
        self.textures.deinit(allocator);
        self.free_indices.deinit(allocator);
    }

    fn create(
        self: *TexturePool,
        width: u32,
        height: u32,
        format: rhi.TextureFormat,
        config: rhi.TextureConfig,
        data: ?[]const u8,
    ) rhi.TextureHandle {
        _ = data;
        const handle = self.next_handle;
        self.next_handle += 1;

        const mip_levels: u32 = if (config.generate_mipmaps) blk: {
            var levels: u32 = 1;
            var w = width;
            var h = height;
            while (w > 1 and h > 1) : ({
                w >>= 1;
                h >>= 1;
            }) {
                levels += 1;
            }
            break :blk levels;
        } else 1;

        if (self.free_indices.popOrNull()) |idx| {
            self.textures.items[idx] = .{
                .width = width,
                .height = height,
                .format = format,
                .mip_levels = mip_levels,
                .creation_frame = self.frame,
                .last_used_frame = self.frame,
                .backend_data = null,
                .alive = true,
            };
            return handle;
        }

        self.textures.append(self.allocator, .{
            .width = width,
            .height = height,
            .format = format,
            .mip_levels = mip_levels,
            .creation_frame = self.frame,
            .last_used_frame = self.frame,
            .backend_data = null,
            .alive = true,
        }) catch {
            return rhi.InvalidTextureHandle;
        };
        return handle;
    }

    fn destroy(self: *TexturePool, handle: rhi.TextureHandle) void {
        if (handle == 0) return;
        const idx = handle - 1;
        if (idx < self.textures.items.len) {
            const entry = &self.textures.items[idx];
            if (entry.alive) {
                entry.alive = false;
                entry.last_used_frame = self.frame;
                self.free_indices.append(self.allocator, idx) catch {};
            }
        }
    }

    fn getInfo(self: *TexturePool, handle: rhi.TextureHandle) ?TextureInfo {
        if (handle == 0) return null;
        const idx = handle - 1;
        if (idx < self.textures.items.len) {
            const entry = self.textures.items[idx];
            if (entry.alive) {
                return .{
                    .width = entry.width,
                    .height = entry.height,
                    .format = entry.format,
                    .mip_levels = entry.mip_levels,
                    .creation_frame = entry.creation_frame,
                    .last_used_frame = entry.last_used_frame,
                };
            }
        }
        return null;
    }

    fn gc(self: *TexturePool) void {
        _ = self;
    }

    fn activeCount(self: *TexturePool) u32 {
        var count: u32 = 0;
        for (self.textures.items) |entry| {
            if (entry.alive) count += 1;
        }
        return count;
    }

    fn totalMemory(self: *TexturePool) usize {
        var total: usize = 0;
        for (self.textures.items) |entry| {
            if (entry.alive) {
                const bytes_per_pixel = switch (entry.format) {
                    .rgb => 3,
                    .rgba => 4,
                    .red => 1,
                    .depth => 4,
                };
                total += @as(usize, entry.width) * entry.height * bytes_per_pixel;
            }
        }
        return total;
    }
};

const ShaderCache = struct {
    allocator: Allocator,
    shaders: std.ArrayListUnmanaged(ShaderEntry),
    free_indices: std.ArrayListUnmanaged(usize),
    next_handle: rhi.ShaderHandle,

    const ShaderEntry = struct {
        vertex_src: [:0]const u8,
        fragment_src: [:0]const u8,
        backend_data: ?*anyopaque,
        alive: bool = true,
    };

    fn init(allocator: Allocator) !ShaderCache {
        return .{
            .allocator = allocator,
            .shaders = .empty,
            .free_indices = .empty,
            .next_handle = 1,
        };
    }

    fn deinit(self: *ShaderCache, allocator: Allocator) void {
        for (self.shaders.items) |entry| {
            allocator.free(entry.vertex_src);
            allocator.free(entry.fragment_src);
        }
        self.shaders.deinit(allocator);
        self.free_indices.deinit(allocator);
    }

    fn create(self: *ShaderCache, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!rhi.ShaderHandle {
        const handle = self.next_handle;
        self.next_handle += 1;

        const vert_copy = std.mem.span(vertex_src);
        const frag_copy = std.mem.span(fragment_src);

        const vert_alloc = self.allocator.dupeZ(u8, vert_copy) catch return error.OutOfMemory;
        errdefer self.allocator.free(vert_alloc);

        const frag_alloc = self.allocator.dupeZ(u8, frag_copy) catch {
            self.allocator.free(vert_alloc);
            return error.OutOfMemory;
        };

        if (self.free_indices.popOrNull()) |idx| {
            self.shaders.items[idx] = .{
                .vertex_src = vert_alloc,
                .fragment_src = frag_alloc,
                .backend_data = null,
                .alive = true,
            };
            return handle;
        }

        self.shaders.append(self.allocator, .{
            .vertex_src = vert_alloc,
            .fragment_src = frag_alloc,
            .backend_data = null,
            .alive = true,
        }) catch {
            self.allocator.free(vert_alloc);
            self.allocator.free(frag_alloc);
            return error.OutOfMemory;
        };
        return handle;
    }

    fn destroy(self: *ShaderCache, handle: rhi.ShaderHandle) void {
        if (handle == 0) return;
        const idx = handle - 1;
        if (idx < self.shaders.items.len) {
            const entry = &self.shaders.items[idx];
            if (entry.alive) {
                entry.alive = false;
                self.free_indices.append(self.allocator, idx) catch {};
            }
        }
    }

    fn gc(self: *ShaderCache) void {
        _ = self;
    }

    fn activeCount(self: *ShaderCache) u32 {
        var count: u32 = 0;
        for (self.shaders.items) |entry| {
            if (entry.alive) count += 1;
        }
        return count;
    }
};

const RhiError = error{
    OutOfMemory,
    VulkanError,
};
