//! OpenGL Rendering Hardware Interface (RHI) Backend
//!
//! Implements the RHI interface for OpenGL 3.3+. This is the simpler backend
//! compared to Vulkan, using immediate-mode style rendering.
//!
//! ## Key Differences from Vulkan
//! - No explicit synchronization (OpenGL driver handles it)
//! - Simpler resource management (VAO/VBO pairs)
//! - Embedded GLSL shaders for UI and sky rendering
//!
//! ## Thread Safety
//! A mutex protects the buffer list. OpenGL context is NOT thread-safe -
//! all rendering must occur on the main thread with the GL context current.

const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const RenderDevice = @import("render_device.zig").RenderDevice;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Shader = @import("shader.zig").Shader;

/// Compile-time constants for shadow cascade uniform names.
/// Eliminates per-frame string formatting overhead in updateShadowUniforms.
const shadow_uniform_names = struct {
    const light_space_matrices = [_][:0]const u8{
        "uLightSpaceMatrices[0]",
        "uLightSpaceMatrices[1]",
        "uLightSpaceMatrices[2]",
    };
    const cascade_splits = [_][:0]const u8{
        "uCascadeSplits[0]",
        "uCascadeSplits[1]",
        "uCascadeSplits[2]",
    };
    const shadow_texel_sizes = [_][:0]const u8{
        "uShadowTexelSizes[0]",
        "uShadowTexelSizes[1]",
        "uShadowTexelSizes[2]",
    };
};

/// Direct GL uniform setters for fallback path (when no Shader pointer available).
/// These are uncached and should only be used when active_shader is null.
fn setUniformFloatDirect(program: rhi.ShaderHandle, name: [:0]const u8, value: f32) void {
    const loc = c.glGetUniformLocation().?(program, name.ptr);
    c.glUniform1f().?(loc, value);
}

fn setUniformIntDirect(program: rhi.ShaderHandle, name: [:0]const u8, value: i32) void {
    const loc = c.glGetUniformLocation().?(program, name.ptr);
    c.glUniform1i().?(loc, value);
}

fn setUniformVec3Direct(program: rhi.ShaderHandle, name: [:0]const u8, x: f32, y: f32, z: f32) void {
    const loc = c.glGetUniformLocation().?(program, name.ptr);
    c.glUniform3f().?(loc, x, y, z);
}

fn setUniformMat4Direct(program: rhi.ShaderHandle, name: [:0]const u8, matrix: *const [4][4]f32) void {
    const loc = c.glGetUniformLocation().?(program, name.ptr);
    c.glUniformMatrix4fv().?(loc, 1, c.GL_FALSE, @ptrCast(matrix));
}

const BufferResource = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
};

const OpenGLContext = struct {
    allocator: std.mem.Allocator,
    device: ?*RenderDevice,
    buffers: std.ArrayListUnmanaged(BufferResource),
    free_indices: std.ArrayListUnmanaged(usize),
    mutex: std.Thread.Mutex,

    // Shader registry for uniform caching - maps handles to Shader pointers
    shader_registry: std.AutoHashMap(rhi.ShaderHandle, *Shader),

    // UI rendering state
    ui_shader: ?*Shader,
    ui_tex_shader: ?*Shader,
    ui_vao: c.GLuint,
    ui_vbo: c.GLuint,
    ui_screen_width: f32,
    ui_screen_height: f32,

    // Sky rendering state
    sky_shader: ?*Shader,
    sky_vao: c.GLuint,
    sky_vbo: c.GLuint,

    // Cloud rendering state
    cloud_shader: ?*Shader,
    cloud_vao: c.GLuint,
    cloud_vbo: c.GLuint,
    cloud_ebo: c.GLuint,
    cloud_mesh_size: f32,

    // Debug shadow map rendering state
    debug_shadow_shader: ?*Shader,
    debug_shadow_vao: c.GLuint,
    debug_shadow_vbo: c.GLuint,

    // State for setModelMatrix
    current_view_proj: Mat4,

    // Active shader tracking (to avoid glGetIntegerv queries)
    active_shader: ?*Shader,
    active_program: rhi.ShaderHandle,
};

fn checkError(label: []const u8) void {
    const err = c.glGetError();
    if (err != c.GL_NO_ERROR) {
        std.log.err("OpenGL Error in {s}: 0x{X}", .{ label, err });
    }
}

// UI Shaders (loaded from external files for validation)
const shaders = @import("shader_sources");
const ui_vertex_shader = shaders.ui_vert;
const ui_fragment_shader = shaders.ui_frag;
const ui_tex_vertex_shader = shaders.ui_tex_vert;
const ui_tex_fragment_shader = shaders.ui_tex_frag;

// Sky shaders
const sky_vertex_shader = shaders.sky_vert;
const sky_fragment_shader = shaders.sky_frag;

// Debug shadow map visualization shader
const debug_shadow_vertex_shader = shaders.debug_shadow_vert;
const debug_shadow_fragment_shader = shaders.debug_shadow_frag;

// Cloud shaders (2D layered clouds)
const cloud_vertex_shader = shaders.cloud_vert;
const cloud_fragment_shader = shaders.cloud_frag;

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, device: ?*RenderDevice) anyerror!void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.device = device;
    ctx.buffers = .empty;
    ctx.free_indices = .empty;
    ctx.mutex = .{};

    // Initialize UI shaders
    std.log.info("Creating OpenGL UI shaders...", .{});
    const ui_shader_ptr = try allocator.create(Shader);
    ui_shader_ptr.* = try Shader.init(allocator, ui_vertex_shader, ui_fragment_shader);
    ctx.ui_shader = ui_shader_ptr;
    try ctx.shader_registry.put(ui_shader_ptr.handle, ui_shader_ptr);

    const ui_tex_shader_ptr = try allocator.create(Shader);
    ui_tex_shader_ptr.* = try Shader.init(allocator, ui_tex_vertex_shader, ui_tex_fragment_shader);
    ctx.ui_tex_shader = ui_tex_shader_ptr;
    try ctx.shader_registry.put(ui_tex_shader_ptr.handle, ui_tex_shader_ptr);
    std.log.info("OpenGL UI shaders created", .{});

    // Create UI VAO/VBO
    c.glGenVertexArrays().?(1, &ctx.ui_vao);
    c.glGenBuffers().?(1, &ctx.ui_vbo);
    c.glBindVertexArray().?(ctx.ui_vao);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.ui_vbo);

    // Position (2 floats) + Color (4 floats) = 6 floats per vertex
    const stride: c.GLsizei = 6 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glEnableVertexAttribArray().?(0);
    c.glVertexAttribPointer().?(1, 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));
    c.glEnableVertexAttribArray().?(1);

    c.glBindVertexArray().?(0);
    ctx.ui_screen_width = 1280;
    ctx.ui_screen_height = 720;

    // Initialize sky shader and fullscreen triangle
    const sky_shader_ptr = try allocator.create(Shader);
    sky_shader_ptr.* = try Shader.init(allocator, sky_vertex_shader, sky_fragment_shader);
    ctx.sky_shader = sky_shader_ptr;
    try ctx.shader_registry.put(sky_shader_ptr.handle, sky_shader_ptr);

    const sky_vertices = [_]f32{
        -1.0, -1.0,
        3.0,  -1.0,
        -1.0, 3.0,
    };

    c.glGenVertexArrays().?(1, &ctx.sky_vao);
    c.glGenBuffers().?(1, &ctx.sky_vbo);
    c.glBindVertexArray().?(ctx.sky_vao);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.sky_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(sky_vertices)), &sky_vertices, c.GL_STATIC_DRAW);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    c.glEnableVertexAttribArray().?(0);
    c.glBindVertexArray().?(0);

    // Initialize cloud shader and quad
    const cloud_shader_ptr = try allocator.create(Shader);
    cloud_shader_ptr.* = try Shader.init(allocator, cloud_vertex_shader, cloud_fragment_shader);
    ctx.cloud_shader = cloud_shader_ptr;
    try ctx.shader_registry.put(cloud_shader_ptr.handle, cloud_shader_ptr);
    ctx.cloud_mesh_size = 10000.0;

    const cloud_vertices = [_]f32{
        -ctx.cloud_mesh_size, -ctx.cloud_mesh_size,
        ctx.cloud_mesh_size,  -ctx.cloud_mesh_size,
        ctx.cloud_mesh_size,  ctx.cloud_mesh_size,
        -ctx.cloud_mesh_size, ctx.cloud_mesh_size,
    };

    const cloud_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

    c.glGenVertexArrays().?(1, &ctx.cloud_vao);
    c.glGenBuffers().?(1, &ctx.cloud_vbo);
    c.glGenBuffers().?(1, &ctx.cloud_ebo);
    c.glBindVertexArray().?(ctx.cloud_vao);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.cloud_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(cloud_vertices)), &cloud_vertices, c.GL_STATIC_DRAW);
    c.glBindBuffer().?(c.GL_ELEMENT_ARRAY_BUFFER, ctx.cloud_ebo);
    c.glBufferData().?(c.GL_ELEMENT_ARRAY_BUFFER, @sizeOf(@TypeOf(cloud_indices)), &cloud_indices, c.GL_STATIC_DRAW);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    c.glEnableVertexAttribArray().?(0);
    c.glBindVertexArray().?(0);

    // Initialize debug shadow map visualization shader and quad
    const debug_shadow_shader_ptr = try allocator.create(Shader);
    debug_shadow_shader_ptr.* = try Shader.init(allocator, debug_shadow_vertex_shader, debug_shadow_fragment_shader);
    ctx.debug_shadow_shader = debug_shadow_shader_ptr;
    try ctx.shader_registry.put(debug_shadow_shader_ptr.handle, debug_shadow_shader_ptr);

    const debug_quad_vertices = [_]f32{
        -1.0, 1.0,  0.0, 1.0,
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,
        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
    };

    c.glGenVertexArrays().?(1, &ctx.debug_shadow_vao);
    c.glGenBuffers().?(1, &ctx.debug_shadow_vbo);
    c.glBindVertexArray().?(ctx.debug_shadow_vao);
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.debug_shadow_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(debug_quad_vertices)), &debug_quad_vertices, c.GL_STATIC_DRAW);
    c.glEnableVertexAttribArray().?(0);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    c.glEnableVertexAttribArray().?(1);
    c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    c.glBindVertexArray().?(0);

    ctx.current_view_proj = Mat4.identity;
    ctx.active_shader = null;
    ctx.active_program = 0;

    c.glFrontFace(c.GL_CW);
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        for (ctx.buffers.items) |buf| {
            if (buf.vao != 0) c.glDeleteVertexArrays().?(1, &buf.vao);
            if (buf.vbo != 0) c.glDeleteBuffers().?(1, &buf.vbo);
        }
        ctx.buffers.deinit(ctx.allocator);
        ctx.free_indices.deinit(ctx.allocator);
    }

    // Cleanup UI resources
    if (ctx.ui_shader) |s| {
        s.deinit();
        ctx.allocator.destroy(s);
    }
    if (ctx.ui_tex_shader) |s| {
        s.deinit();
        ctx.allocator.destroy(s);
    }
    if (ctx.ui_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.ui_vao);
    if (ctx.ui_vbo != 0) c.glDeleteBuffers().?(1, &ctx.ui_vbo);

    // Cleanup sky resources
    if (ctx.sky_shader) |s| {
        s.deinit();
        ctx.allocator.destroy(s);
    }
    if (ctx.sky_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.sky_vao);
    if (ctx.sky_vbo != 0) c.glDeleteBuffers().?(1, &ctx.sky_vbo);

    // Cleanup cloud resources
    if (ctx.cloud_shader) |s| {
        s.deinit();
        ctx.allocator.destroy(s);
    }
    if (ctx.cloud_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.cloud_vao);
    if (ctx.cloud_vbo != 0) c.glDeleteBuffers().?(1, &ctx.cloud_vbo);
    if (ctx.cloud_ebo != 0) c.glDeleteBuffers().?(1, &ctx.cloud_ebo);

    // Cleanup debug shadow map resources
    if (ctx.debug_shadow_shader) |s| {
        s.deinit();
        ctx.allocator.destroy(s);
    }
    if (ctx.debug_shadow_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.debug_shadow_vao);
    if (ctx.debug_shadow_vbo != 0) c.glDeleteBuffers().?(1, &ctx.debug_shadow_vbo);

    ctx.shader_registry.deinit();
    ctx.allocator.destroy(ctx);
}

fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.BufferHandle {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    // Currently only vertex buffers are fully supported
    // Index and uniform buffers use the same code path for now
    _ = usage;

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
    checkError("createBuffer");

    if (ctx.free_indices.items.len > 0) {
        const new_len = ctx.free_indices.items.len - 1;
        const idx = ctx.free_indices.items[new_len];
        ctx.free_indices.items.len = new_len;

        ctx.buffers.items[idx] = .{ .vao = vao, .vbo = vbo };
        return @intCast(idx + 1);
    } else {
        ctx.buffers.append(ctx.allocator, .{ .vao = vao, .vbo = vbo }) catch |err| {
            std.log.err("OpenGL: Failed to allocate buffer handle: {}", .{err});
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
            checkError("uploadBuffer");
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

fn abortFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn setClearColor(ctx_ptr: *anyopaque, color: Vec3) void {
    _ = ctx_ptr;
    c.glClearColor(color.x, color.y, color.z, 1.0);
}

fn beginMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    _ = ctx;

    // Ensure render state matches what Renderer was doing
    c.glEnable(c.GL_DEPTH_TEST);
    c.glDepthMask(c.GL_TRUE);
    c.glDepthFunc(c.GL_LESS);

    // Disable culling for now to ensure all voxel faces are visible regardless of winding
    c.glDisable(c.GL_CULL_FACE);

    c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
}

fn endMainPass(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn endFrame(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
    c.glFinish();
}

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32) void {
    _ = ctx_ptr;
    _ = cascade_index;
}

fn endShadowPass(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, time: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.current_view_proj = view_proj;

    // Use active shader with caching if available
    if (ctx.active_shader) |shader| {
        shader.use();

        shader.setVec3Cached("uSunDir", sun_dir.x, sun_dir.y, sun_dir.z);
        shader.setFloatCached("uSunIntensity", sun_intensity);
        shader.setFloatCached("uAmbient", ambient);
        shader.setVec3Cached("uFogColor", fog_color.x, fog_color.y, fog_color.z);
        shader.setFloatCached("uFogDensity", fog_density);
        shader.setIntCached("uFogEnabled", if (fog_enabled) 1 else 0);
        shader.setIntCached("uUseTexture", if (use_texture) 1 else 0);

        shader.setFloatCached("uCloudWindOffsetX", cloud_params.wind_offset_x);
        shader.setFloatCached("uCloudWindOffsetZ", cloud_params.wind_offset_z);
        shader.setFloatCached("uCloudScale", cloud_params.cloud_scale);
        shader.setFloatCached("uCloudCoverage", cloud_params.cloud_coverage);
        shader.setFloatCached("uCloudShadowStrength", 0.15);
        shader.setFloatCached("uCloudHeight", cloud_params.cloud_height);
    } else if (ctx.active_program != 0) {
        // Fallback: no shader pointer, use direct GL calls
        c.glUseProgram().?(ctx.active_program);
        setUniformVec3Direct(ctx.active_program, "uSunDir", sun_dir.x, sun_dir.y, sun_dir.z);
        setUniformFloatDirect(ctx.active_program, "uSunIntensity", sun_intensity);
        setUniformFloatDirect(ctx.active_program, "uAmbient", ambient);
        setUniformVec3Direct(ctx.active_program, "uFogColor", fog_color.x, fog_color.y, fog_color.z);
        setUniformFloatDirect(ctx.active_program, "uFogDensity", fog_density);
        setUniformIntDirect(ctx.active_program, "uFogEnabled", if (fog_enabled) 1 else 0);
        setUniformIntDirect(ctx.active_program, "uUseTexture", if (use_texture) 1 else 0);

        setUniformFloatDirect(ctx.active_program, "uCloudWindOffsetX", cloud_params.wind_offset_x);
        setUniformFloatDirect(ctx.active_program, "uCloudWindOffsetZ", cloud_params.wind_offset_z);
        setUniformFloatDirect(ctx.active_program, "uCloudScale", cloud_params.cloud_scale);
        setUniformFloatDirect(ctx.active_program, "uCloudCoverage", cloud_params.cloud_coverage);
        setUniformFloatDirect(ctx.active_program, "uCloudShadowStrength", 0.15);
        setUniformFloatDirect(ctx.active_program, "uCloudHeight", cloud_params.cloud_height);
    }

    _ = cam_pos;
    _ = time;
}

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [3]rhi.TextureHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    const shadow_map_names = [_][:0]const u8{ "uShadowMap0", "uShadowMap1", "uShadowMap2" };

    if (ctx.active_shader) |shader| {
        shader.use();

        shader.setIntCached("uTexture", 0);
        shader.setIntCached("uUseTexture", if (texture_enabled) 1 else 0);

        for (0..3) |i| {
            const slot: i32 = 1 + @as(i32, @intCast(i));
            c.glActiveTexture().?(@as(c.GLenum, @intCast(@as(u32, @intCast(c.GL_TEXTURE0)) + @as(u32, @intCast(slot)))));
            c.glBindTexture(c.GL_TEXTURE_2D, @intCast(shadow_map_handles[i]));
            shader.setIntCached(shadow_map_names[i], slot);
        }
    } else if (ctx.active_program != 0) {
        c.glUseProgram().?(ctx.active_program);

        setUniformIntDirect(ctx.active_program, "uTexture", 0);
        setUniformIntDirect(ctx.active_program, "uUseTexture", if (texture_enabled) 1 else 0);

        for (0..3) |i| {
            const slot: i32 = 1 + @as(i32, @intCast(i));
            c.glActiveTexture().?(@as(c.GLenum, @intCast(@as(u32, @intCast(c.GL_TEXTURE0)) + @as(u32, @intCast(slot)))));
            c.glBindTexture(c.GL_TEXTURE_2D, @intCast(shadow_map_handles[i]));
            setUniformIntDirect(ctx.active_program, shadow_map_names[i], slot);
        }
    }
    c.glActiveTexture().?(c.GL_TEXTURE0);
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    if (ctx.active_shader) |shader| {
        shader.use();

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            shader.setMat4Cached(shadow_uniform_names.light_space_matrices[i], &params.light_space_matrices[i].data);
            shader.setFloatCached(shadow_uniform_names.cascade_splits[i], params.cascade_splits[i]);
            shader.setFloatCached(shadow_uniform_names.shadow_texel_sizes[i], params.shadow_texel_sizes[i]);
        }
    } else if (ctx.active_program != 0) {
        c.glUseProgram().?(ctx.active_program);

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            setUniformMat4Direct(ctx.active_program, shadow_uniform_names.light_space_matrices[i], &params.light_space_matrices[i].data);
            setUniformFloatDirect(ctx.active_program, shadow_uniform_names.cascade_splits[i], params.cascade_splits[i]);
            setUniformFloatDirect(ctx.active_program, shadow_uniform_names.shadow_texel_sizes[i], params.shadow_texel_sizes[i]);
        }
    }
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const mvp = ctx.current_view_proj.multiply(model);

    if (ctx.active_shader) |shader| {
        shader.use();
        shader.setMat4Cached("transform", &mvp.data);
        shader.setMat4Cached("uModel", &model.data);
    } else if (ctx.active_program != 0) {
        c.glUseProgram().?(ctx.active_program);
        setUniformMat4Direct(ctx.active_program, "transform", &mvp.data);
        setUniformMat4Direct(ctx.active_program, "uModel", &model.data);
    }
}

fn compileShaderGL(shader_type: c.GLenum, source: [*c]const u8) Shader.Error!c.GLuint {
    const shader = c.glCreateShader().?(shader_type);
    c.glShaderSource().?(shader, 1, &source, null);
    c.glCompileShader().?(shader);

    var success: c.GLint = undefined;
    c.glGetShaderiv().?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        var length: c.GLsizei = undefined;
        c.glGetShaderInfoLog().?(shader, 512, &length, &info_log);
        std.log.err("Shader compile error: {s}", .{info_log[0..@intCast(length)]});
        c.glDeleteShader().?(shader);
        return if (shader_type == c.GL_VERTEX_SHADER) Shader.Error.VertexCompileFailed else Shader.Error.FragmentCompileFailed;
    }

    return shader;
}

fn createShaderGL(vertex_src: [*c]const u8, fragment_src: [*c]const u8) Shader.Error!c.GLuint {
    const vert = try compileShaderGL(c.GL_VERTEX_SHADER, vertex_src);
    defer c.glDeleteShader().?(vert);

    const frag = try compileShaderGL(c.GL_FRAGMENT_SHADER, fragment_src);
    defer c.glDeleteShader().?(frag);

    const program: c.GLuint = c.glCreateProgram().?();
    c.glAttachShader().?(program, vert);
    c.glAttachShader().?(program, frag);
    c.glLinkProgram().?(program);

    var success: c.GLint = undefined;
    c.glGetProgramiv().?(program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        var length: c.GLsizei = undefined;
        c.glGetProgramInfoLog().?(program, 512, &length, &info_log);
        std.log.err("Shader link failed: {s}", .{info_log[0..@intCast(length)]});
        c.glDeleteProgram().?(program);
        return Shader.Error.LinkFailed;
    }

    return program;
}

fn createShader(ctx_ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    const shader_ptr = ctx.allocator.create(Shader) catch return error.OutOfMemory;
    shader_ptr.* = Shader.init(ctx.allocator, vertex_src, fragment_src) catch |err| {
        ctx.allocator.destroy(shader_ptr);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.OpenGLError;
    };

    ctx.shader_registry.put(shader_ptr.handle, shader_ptr) catch {
        shader_ptr.deinit();
        ctx.allocator.destroy(shader_ptr);
        return error.OutOfMemory;
    };

    return shader_ptr.handle;
}

fn destroyShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    if (handle != 0) {
        if (ctx.shader_registry.fetchRemove(handle)) |entry| {
            const shader_ptr = entry.value;
            shader_ptr.deinit();
            ctx.allocator.destroy(shader_ptr);
        } else {
            // Fallback for shaders not in registry (shouldn't happen with new code, but safe)
            c.glDeleteProgram().?(@intCast(handle));
        }
    }
}

fn bindShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.active_program = handle;
    ctx.active_shader = ctx.shader_registry.get(handle);

    if (handle != 0) {
        c.glUseProgram().?(@intCast(handle));
    } else {
        c.glUseProgram().?(0);
    }
}

fn shaderSetMat4(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, matrix: *const [4][4]f32) void {
    _ = ctx_ptr;
    const program = @as(c.GLuint, @intCast(handle));
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniformMatrix4fv().?(loc, 1, c.GL_FALSE, @ptrCast(matrix));
}

fn shaderSetVec3(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, x: f32, y: f32, z: f32) void {
    _ = ctx_ptr;
    const program = @as(c.GLuint, @intCast(handle));
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform3f().?(loc, x, y, z);
}

fn shaderSetFloat(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, value: f32) void {
    _ = ctx_ptr;
    const program = @as(c.GLuint, @intCast(handle));
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform1f().?(loc, value);
}

fn shaderSetInt(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle, name: [*c]const u8, value: i32) void {
    _ = ctx_ptr;
    const program = @as(c.GLuint, @intCast(handle));
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform1i().?(loc, value);
}

fn drawIndirect(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    _ = ctx_ptr;
    _ = handle;
    _ = command_buffer;
    _ = offset;
    _ = draw_count;
    _ = stride;
    // Not implemented for OpenGL backend yet
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
            checkError("draw");
        }
    }
}

fn drawSky(ctx_ptr: *anyopaque, params: rhi.SkyParams) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const shader = ctx.sky_shader orelse return;

    const prev_shader = ctx.active_shader;
    const prev_program = ctx.active_program;

    ctx.active_shader = shader;
    ctx.active_program = shader.handle;

    // Disable depth write, keep depth test
    c.glDepthMask(c.GL_FALSE);

    shader.use();
    shader.setVec3Cached("uCamForward", params.cam_forward.x, params.cam_forward.y, params.cam_forward.z);
    shader.setVec3Cached("uCamRight", params.cam_right.x, params.cam_right.y, params.cam_right.z);
    shader.setVec3Cached("uCamUp", params.cam_up.x, params.cam_up.y, params.cam_up.z);
    shader.setFloatCached("uAspect", params.aspect);
    shader.setFloatCached("uTanHalfFov", params.tan_half_fov);
    shader.setVec3Cached("uSunDir", params.sun_dir.x, params.sun_dir.y, params.sun_dir.z);
    shader.setVec3Cached("uSkyColor", params.sky_color.x, params.sky_color.y, params.sky_color.z);
    shader.setVec3Cached("uHorizonColor", params.horizon_color.x, params.horizon_color.y, params.horizon_color.z);
    shader.setFloatCached("uSunIntensity", params.sun_intensity);
    shader.setFloatCached("uMoonIntensity", params.moon_intensity);
    shader.setFloatCached("uTime", params.time);

    c.glBindVertexArray().?(ctx.sky_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    c.glBindVertexArray().?(0);

    // Restore state
    c.glDepthMask(c.GL_TRUE);
    if (prev_shader) |s| {
        s.use();
        ctx.active_shader = s;
        ctx.active_program = prev_program;
    } else if (prev_program != 0) {
        c.glUseProgram().?(@intCast(prev_program));
        ctx.active_program = prev_program;
        // Try to restore active_shader from registry if possible
        ctx.active_shader = ctx.shader_registry.get(prev_program);
    } else {
        c.glUseProgram().?(0);
        ctx.active_shader = null;
        ctx.active_program = 0;
    }
}

fn createTexture(ctx_ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data: ?[]const u8) rhi.TextureHandle {
    _ = ctx_ptr;
    var id: c.GLuint = 0;
    c.glGenTextures(1, &id);
    c.glBindTexture(c.GL_TEXTURE_2D, id);

    // Apply config
    const gl_min = switch (config.min_filter) {
        .nearest => c.GL_NEAREST,
        .linear => c.GL_LINEAR,
        .nearest_mipmap_nearest => c.GL_NEAREST_MIPMAP_NEAREST,
        .linear_mipmap_nearest => c.GL_LINEAR_MIPMAP_NEAREST,
        .nearest_mipmap_linear => c.GL_NEAREST_MIPMAP_LINEAR,
        .linear_mipmap_linear => c.GL_LINEAR_MIPMAP_LINEAR,
    };
    const gl_mag = if (config.mag_filter == .nearest) c.GL_NEAREST else c.GL_LINEAR;
    const gl_wrap_s = switch (config.wrap_s) {
        .repeat => c.GL_REPEAT,
        .mirrored_repeat => c.GL_MIRRORED_REPEAT,
        .clamp_to_edge => c.GL_CLAMP_TO_EDGE,
        .clamp_to_border => c.GL_CLAMP_TO_BORDER,
    };
    const gl_wrap_t = switch (config.wrap_t) {
        .repeat => c.GL_REPEAT,
        .mirrored_repeat => c.GL_MIRRORED_REPEAT,
        .clamp_to_edge => c.GL_CLAMP_TO_EDGE,
        .clamp_to_border => c.GL_CLAMP_TO_BORDER,
    };

    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, @intCast(gl_min));
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, @intCast(gl_mag));
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, @intCast(gl_wrap_s));
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, @intCast(gl_wrap_t));

    if (config.wrap_s == .clamp_to_border or config.wrap_t == .clamp_to_border) {
        const border_color = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
        c.glTexParameterfv(c.GL_TEXTURE_2D, c.GL_TEXTURE_BORDER_COLOR, &border_color);
    }

    const internal_format: c.GLint = switch (format) {
        .rgb => c.GL_RGB,
        .rgba => c.GL_RGBA,
        .red => c.GL_RED,
        .depth => c.GL_DEPTH_COMPONENT24,
    };
    const gl_format: c.GLenum = switch (format) {
        .rgb => c.GL_RGB,
        .rgba => c.GL_RGBA,
        .red => c.GL_RED,
        .depth => c.GL_DEPTH_COMPONENT,
    };
    const gl_type: c.GLenum = if (format == .depth) c.GL_FLOAT else c.GL_UNSIGNED_BYTE;

    c.glTexImage2D(c.GL_TEXTURE_2D, 0, internal_format, @intCast(width), @intCast(height), 0, gl_format, gl_type, if (data) |d| d.ptr else null);

    if (config.generate_mipmaps and format != .depth) {
        c.glGenerateMipmap().?(c.GL_TEXTURE_2D);
    }

    // Special hardware shadow mapping support for depth textures
    if (format == .depth) {
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_COMPARE_MODE, c.GL_NONE);
    }

    return @intCast(id);
}

fn destroyTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle) void {
    _ = ctx_ptr;
    if (handle == 0) return;
    var id: c.GLuint = @intCast(handle);
    c.glDeleteTextures(1, &id);
}

fn bindTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
    _ = ctx_ptr;
    c.glActiveTexture().?(@as(c.GLenum, @intCast(@as(u32, @intCast(c.GL_TEXTURE0)) + slot)));
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(handle));
}

fn getAllocator(ctx_ptr: *anyopaque) std.mem.Allocator {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.allocator;
}

fn setViewport(ctx_ptr: *anyopaque, width: u32, height: u32) void {
    _ = ctx_ptr;
    c.glViewport(0, 0, @intCast(width), @intCast(height));
}

fn setWireframe(ctx_ptr: *anyopaque, enabled: bool) void {
    _ = ctx_ptr;
    if (enabled) {
        c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_LINE);
    } else {
        c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_FILL);
    }
}

fn setTexturesEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    _ = ctx_ptr;
    _ = enabled;
}

fn setVSync(ctx_ptr: *anyopaque, enabled: bool) void {
    _ = ctx_ptr;
    _ = c.SDL_GL_SetSwapInterval(if (enabled) 1 else 0);
}

fn updateTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) void {
    _ = ctx_ptr;
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(handle));
    var w: c.GLint = 0;
    var h: c.GLint = 0;
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &w);
    c.glGetTexLevelParameteriv(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_HEIGHT, &h);

    c.glTexSubImage2D(
        c.GL_TEXTURE_2D,
        0,
        0,
        0,
        w,
        h,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        data.ptr,
    );
}

fn beginUI(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;

    c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);

    c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    if (ctx.ui_shader) |shader| {
        ctx.active_shader = shader;
        ctx.active_program = shader.handle;
        shader.use();
        const proj = Mat4.orthographic(0, screen_width, screen_height, 0, -1, 1);
        shader.setMat4Cached("projection", &proj.data);
    }

    c.glBindVertexArray().?(ctx.ui_vao);
}

fn endUI(ctx_ptr: *anyopaque) void {
    _ = ctx_ptr;
    c.glBindVertexArray().?(0);
    c.glDisable(c.GL_BLEND);
    c.glEnable(c.GL_DEPTH_TEST);
    c.glEnable(c.GL_CULL_FACE);
}

fn drawUIQuad(ctx_ptr: *anyopaque, rect: rhi.Rect, color: rhi.Color) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    const vertices = [_]f32{
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y + h, color.r, color.g, color.b, color.a,
    };

    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.ui_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_DYNAMIC_DRAW);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
}

fn drawUITexturedQuad(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    if (ctx.ui_tex_shader) |tex_shader| {
        ctx.active_shader = tex_shader;
        ctx.active_program = tex_shader.handle;
        tex_shader.use();
        const proj = Mat4.orthographic(0, ctx.ui_screen_width, ctx.ui_screen_height, 0, -1, 1);
        tex_shader.setMat4Cached("projection", &proj.data);

        c.glActiveTexture().?(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(texture));
        tex_shader.setIntCached("uTexture", 0);
    }

    const vertices = [_]f32{
        x,     y,     0.0, 0.0,
        x + w, y,     1.0, 0.0,
        x + w, y + h, 1.0, 1.0,
        x,     y,     0.0, 0.0,
        x + w, y + h, 1.0, 1.0,
        x,     y + h, 0.0, 1.0,
    };

    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.ui_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_DYNAMIC_DRAW);

    const stride: c.GLsizei = 4 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));

    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);

    const color_stride: c.GLsizei = 6 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, color_stride, null);
    c.glVertexAttribPointer().?(1, 4, c.GL_FLOAT, c.GL_FALSE, color_stride, @ptrFromInt(2 * @sizeOf(f32)));

    if (ctx.ui_shader) |shader| {
        ctx.active_shader = shader;
        shader.use();
    }
}

fn drawClouds(ctx_ptr: *anyopaque, params: rhi.CloudParams) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const shader = ctx.cloud_shader orelse return;

    const prev_shader = ctx.active_shader;
    const prev_program = ctx.active_program;

    ctx.active_shader = shader;
    ctx.active_program = shader.handle;

    shader.use();
    shader.setMat4Cached("uViewProj", &params.view_proj.data);
    shader.setVec3Cached("uCameraPos", params.cam_pos.x, params.cam_pos.y, params.cam_pos.z);
    shader.setVec3Cached("uSunDir", params.sun_dir.x, params.sun_dir.y, params.sun_dir.z);
    shader.setFloatCached("uSunIntensity", params.sun_intensity);
    shader.setVec3Cached("uFogColor", params.fog_color.x, params.fog_color.y, params.fog_color.z);
    shader.setFloatCached("uFogDensity", params.fog_density);
    shader.setFloatCached("uCloudHeight", params.cloud_height);
    shader.setFloatCached("uCloudCoverage", params.cloud_coverage);
    shader.setFloatCached("uCloudScale", params.cloud_scale);
    shader.setFloatCached("uWindOffsetX", params.wind_offset_x);
    shader.setFloatCached("uWindOffsetZ", params.wind_offset_z);
    shader.setVec3Cached("uBaseColor", params.base_color.x, params.base_color.y, params.base_color.z);

    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glDepthMask(c.GL_FALSE);

    c.glBindVertexArray().?(ctx.cloud_vao);
    c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    c.glBindVertexArray().?(0);

    c.glDisable(c.GL_BLEND);
    c.glDepthMask(c.GL_TRUE);

    if (prev_shader) |s| {
        s.use();
        ctx.active_shader = s;
        ctx.active_program = prev_program;
    } else if (prev_program != 0) {
        c.glUseProgram().?(@intCast(prev_program));
        ctx.active_program = prev_program;
        ctx.active_shader = ctx.shader_registry.get(prev_program);
    } else {
        c.glUseProgram().?(0);
        ctx.active_shader = null;
        ctx.active_program = 0;
    }
}

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const shader = ctx.debug_shadow_shader orelse return;
    if (ctx.debug_shadow_vao == 0) return;
    ctx.active_shader = shader;
    ctx.active_program = shader.handle;

    _ = cascade_index;

    shader.use();
    c.glActiveTexture().?(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(depth_map_handle));
    shader.setIntCached("uDepthMap", 0);
    c.glBindVertexArray().?(ctx.debug_shadow_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    c.glBindVertexArray().?(0);
}

fn setAnisotropicFiltering(ctx_ptr: *anyopaque, level: u8) void {
    _ = ctx_ptr;
    // OpenGL anisotropic filtering is set per-texture at creation time
    // This would require recreating textures, so we log a warning
    if (level > 1) {
        std.log.info("OpenGL: Anisotropic filtering level {} requested (applied on texture creation)", .{level});
    }
}

fn setMSAA(ctx_ptr: *anyopaque, samples: u8) void {
    _ = ctx_ptr;
    // OpenGL MSAA requires window recreation which is not supported at runtime
    std.log.warn("OpenGL: MSAA change not supported at runtime (requires window recreation)", .{});
    _ = samples;
}

fn getMaxAnisotropy(ctx_ptr: *anyopaque) u8 {
    _ = ctx_ptr;
    var max_aniso: c.GLfloat = 1.0;
    c.glGetFloatv(c.GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT, &max_aniso);
    return @intFromFloat(@min(max_aniso, 16.0));
}

fn getMaxMSAASamples(ctx_ptr: *anyopaque) u8 {
    _ = ctx_ptr;
    var max_samples: c.GLint = 1;
    c.glGetIntegerv(c.GL_MAX_SAMPLES, &max_samples);
    return @intCast(@min(max_samples, 16));
}

const vtable = rhi.RHI.VTable{
    .init = init,
    .deinit = deinit,
    .createBuffer = createBuffer,
    .uploadBuffer = uploadBuffer,
    .destroyBuffer = destroyBuffer,
    .createShader = createShader,
    .destroyShader = destroyShader,
    .bindShader = bindShader,
    .shaderSetMat4 = shaderSetMat4,
    .shaderSetVec3 = shaderSetVec3,
    .shaderSetFloat = shaderSetFloat,
    .shaderSetInt = shaderSetInt,
    .beginFrame = beginFrame,
    .abortFrame = abortFrame,
    .setClearColor = setClearColor,
    .beginMainPass = beginMainPass,
    .endMainPass = endMainPass,
    .endFrame = endFrame,
    .waitIdle = waitIdle,
    .beginShadowPass = beginShadowPass,
    .endShadowPass = endShadowPass,
    .updateGlobalUniforms = updateGlobalUniforms,
    .updateShadowUniforms = updateShadowUniforms,
    .setModelMatrix = setModelMatrix,
    .setTextureUniforms = setTextureUniforms,
    .draw = draw,
    .drawIndirect = drawIndirect,
    .drawSky = drawSky,
    .createTexture = createTexture,
    .destroyTexture = destroyTexture,
    .bindTexture = bindTexture,
    .updateTexture = updateTexture,
    .getAllocator = getAllocator,
    .setViewport = setViewport,
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setVSync = setVSync,
    .beginUI = beginUI,
    .endUI = endUI,
    .drawUIQuad = drawUIQuad,
    .drawUITexturedQuad = drawUITexturedQuad,
    .drawClouds = drawClouds,
    .drawDebugShadowMap = drawDebugShadowMap,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setMSAA = setMSAA,
    .getMaxAnisotropy = getMaxAnisotropy,
    .getMaxMSAASamples = getMaxMSAASamples,
};

pub fn createRHI(allocator: std.mem.Allocator, device: ?*RenderDevice) !rhi.RHI {
    const ctx = try allocator.create(OpenGLContext);
    ctx.* = .{
        .allocator = allocator,
        .device = device,
        .buffers = .empty,
        .free_indices = .empty,
        .mutex = .{},
        .shader_registry = std.AutoHashMap(rhi.ShaderHandle, *Shader).init(allocator),
        .ui_shader = null,
        .ui_tex_shader = null,
        .ui_vao = 0,
        .ui_vbo = 0,
        .ui_screen_width = 1280,
        .ui_screen_height = 720,
        .sky_shader = null,
        .sky_vao = 0,
        .sky_vbo = 0,
        .cloud_shader = null,
        .cloud_vao = 0,
        .cloud_vbo = 0,
        .cloud_ebo = 0,
        .cloud_mesh_size = 0,
        .debug_shadow_shader = null,
        .debug_shadow_vao = 0,
        .debug_shadow_vbo = 0,
        .current_view_proj = Mat4.identity,
        .active_shader = null,
        .active_program = 0,
    };

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &vtable,
        .device = device,
    };
}
