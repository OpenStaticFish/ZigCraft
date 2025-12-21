const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");

const BufferResource = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
};

const OpenGLContext = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayListUnmanaged(BufferResource),
    free_indices: std.ArrayListUnmanaged(usize),
    mutex: std.Thread.Mutex,
};

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.buffers = .empty;
    ctx.free_indices = .empty;
    ctx.mutex = .{};
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    for (ctx.buffers.items) |buf| {
        if (buf.vao != 0) c.glDeleteVertexArrays().?(1, &buf.vao);
        if (buf.vbo != 0) c.glDeleteBuffers().?(1, &buf.vbo);
    }
    ctx.buffers.deinit(ctx.allocator);
    ctx.free_indices.deinit(ctx.allocator);
    ctx.allocator.destroy(ctx);
}

fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    // We only support vertex buffers for this refactor as per requirements
    if (usage != .vertex) {
        // Fallback or error
    }

    var vao: c.GLuint = 0;
    var vbo: c.GLuint = 0;

    c.glGenVertexArrays().?(1, &vao);
    c.glGenBuffers().?(1, &vbo);
    c.glBindVertexArray().?(vao);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, vbo);

    // Allocate mutable storage with NULL data
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @intCast(size), null, c.GL_DYNAMIC_DRAW);

    // Stride is 14 floats (matches Vertex struct)
    const stride: c.GLsizei = 14 * @sizeOf(f32);

    // Position (3)
    c.glVertexAttribPointer().?(0, 3, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glEnableVertexAttribArray().?(0);

    // Color (3)
    c.glVertexAttribPointer().?(1, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(3 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(1);

    // Normal (3)
    c.glVertexAttribPointer().?(2, 3, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(6 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(2);

    // UV (2)
    c.glVertexAttribPointer().?(3, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(9 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(3);

    // Tile ID (1)
    c.glVertexAttribPointer().?(4, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(11 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(4);

    // Skylight (1)
    c.glVertexAttribPointer().?(5, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(12 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(5);

    // Blocklight (1)
    c.glVertexAttribPointer().?(6, 1, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(13 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(6);

    c.glBindVertexArray().?(0);

    if (ctx.free_indices.items.len > 0) {
        const new_len = ctx.free_indices.items.len - 1;
        const idx = ctx.free_indices.items[new_len];
        ctx.free_indices.items.len = new_len;

        ctx.buffers.items[idx] = .{ .vao = vao, .vbo = vbo };
        return @intCast(idx + 1);
    } else {
        ctx.buffers.append(ctx.allocator, .{ .vao = vao, .vbo = vbo }) catch {
            c.glDeleteVertexArrays().?(1, &vao);
            c.glDeleteBuffers().?(1, &vbo);
            return rhi.InvalidBufferHandle;
        };
        return @intCast(ctx.buffers.items.len);
    }
}

fn uploadBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (handle == 0) return;
    const idx = handle - 1;
    if (idx < ctx.buffers.items.len) {
        const buf = ctx.buffers.items[idx];
        if (buf.vbo != 0) {
            c.glBindBuffer().?(c.GL_ARRAY_BUFFER, buf.vbo);
            // Replace entire buffer content
            // NOTE: In a real queue we would use glMapBufferRange or just glBufferSubData
            // For now, since we allocate with size in createBuffer, we use glBufferSubData.
            c.glBufferSubData().?(c.GL_ARRAY_BUFFER, 0, @intCast(data.len), data.ptr);
            c.glBindBuffer().?(c.GL_ARRAY_BUFFER, 0);
        }
    }
}

fn destroyBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (handle == 0) return;
    const idx = handle - 1;
    if (idx < ctx.buffers.items.len) {
        const buf = ctx.buffers.items[idx];
        if (buf.vao != 0) {
            var vao = buf.vao;
            var vbo = buf.vbo;
            c.glDeleteVertexArrays().?(1, &vao);
            c.glDeleteBuffers().?(1, &vbo);
            ctx.buffers.items[idx] = .{ .vao = 0, .vbo = 0 };
            ctx.free_indices.append(ctx.allocator, idx) catch {};
        }
    }
}

fn beginFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn endFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (handle == 0) return;
    const idx = handle - 1;
    if (idx < ctx.buffers.items.len) {
        const buf = ctx.buffers.items[idx];
        if (buf.vao != 0) {
            c.glBindVertexArray().?(buf.vao);
            const gl_mode: c.GLenum = switch (mode) {
                .triangles => c.GL_TRIANGLES,
                .lines => c.GL_LINES,
                .points => c.GL_POINTS,
            };
            c.glDrawArrays(gl_mode, 0, @intCast(count));
            c.glBindVertexArray().?(0);
        }
    }
}

const vtable = rhi.RHI.VTable{
    .init = init,
    .deinit = deinit,
    .createBuffer = createBuffer,
    .uploadBuffer = uploadBuffer,
    .destroyBuffer = destroyBuffer,
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .draw = draw,
};

pub fn createRHI(allocator: std.mem.Allocator) !rhi.RHI {
    const ctx = try allocator.create(OpenGLContext);
    ctx.* = .{
        .allocator = allocator,
        .buffers = .empty,
        .free_indices = .empty,
        .mutex = .{},
    };

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &vtable,
    };
}
