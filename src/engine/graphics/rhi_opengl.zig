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
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Shader = @import("shader.zig").Shader;

const BufferResource = struct {
    vao: c.GLuint,
    vbo: c.GLuint,
};

const OpenGLContext = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayListUnmanaged(BufferResource),
    free_indices: std.ArrayListUnmanaged(usize),
    mutex: std.Thread.Mutex,

    // UI rendering state
    ui_shader: ?Shader,
    ui_tex_shader: ?Shader,
    ui_vao: c.GLuint,
    ui_vbo: c.GLuint,
    ui_screen_width: f32,
    ui_screen_height: f32,

    // Sky rendering state
    sky_shader: ?Shader,
    sky_vao: c.GLuint,
    sky_vbo: c.GLuint,

    // Cloud rendering state
    cloud_shader: ?Shader,
    cloud_vao: c.GLuint,
    cloud_vbo: c.GLuint,
    cloud_ebo: c.GLuint,
    cloud_mesh_size: f32,

    // Debug shadow map rendering state
    debug_shadow_shader: ?Shader,
    debug_shadow_vao: c.GLuint,
    debug_shadow_vbo: c.GLuint,

    // State for setModelMatrix
    current_view_proj: Mat4,
};

fn checkError(label: []const u8) void {
    const err = c.glGetError();
    if (err != c.GL_NO_ERROR) {
        std.log.err("OpenGL Error in {s}: {}", .{ label, err });
    }
}

// UI Shaders (embedded GLSL)
const ui_vertex_shader =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec4 aColor;
    \\out vec4 vColor;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(aPos, 0.0, 1.0);
    \\    vColor = aColor;
    \\}
;

const ui_fragment_shader =
    \\#version 330 core
    \\in vec4 vColor;
    \\out vec4 FragColor;
    \\void main() {
    \\    FragColor = vColor;
    \\}
;

const ui_tex_vertex_shader =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

const ui_tex_fragment_shader =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\out vec4 FragColor;
    \\uniform sampler2D uTexture;
    \\void main() {
    \\    FragColor = texture(uTexture, vTexCoord);
    \\}
;

// Sky shaders (shared with Atmosphere)
const sky_vertex_shader =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\out vec3 vWorldDir;
    \\uniform vec3 uCamForward;
    \\uniform vec3 uCamRight;
    \\uniform vec3 uCamUp;
    \\uniform float uAspect;
    \\uniform float uTanHalfFov;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.9999, 1.0);
    \\    vec3 rayDir = uCamForward
    \\                + uCamRight * aPos.x * uAspect * uTanHalfFov
    \\                + uCamUp * aPos.y * uTanHalfFov;
    \\    vWorldDir = rayDir;
    \\}
;

const sky_fragment_shader =
    \\#version 330 core
    \\in vec3 vWorldDir;
    \\out vec4 FragColor;
    \\
    \\uniform vec3 uSunDir;
    \\uniform vec3 uSkyColor;
    \\uniform vec3 uHorizonColor;
    \\uniform float uSunIntensity;
    \\uniform float uMoonIntensity;
    \\uniform float uTime;
    \\
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\vec2 hash22(vec2 p) {
    \\    float n = hash21(p);
    \\    return vec2(n, hash21(p + n));
    \\}
    \\
    \\float stars(vec3 dir) {
    \\    float theta = atan(dir.z, dir.x);
    \\    float phi = asin(clamp(dir.y, -1.0, 1.0));
    \\
    \\    vec2 gridCoord = vec2(theta * 15.0, phi * 30.0);
    \\    vec2 cell = floor(gridCoord);
    \\    vec2 cellFrac = fract(gridCoord);
    \\
    \\    float brightness = 0.0;
    \\
    \\    for (int dy = -1; dy <= 1; dy++) {
    \\        for (int dx = -1; dx <= 1; dx++) {
    \\            vec2 neighbor = cell + vec2(float(dx), float(dy));
    \\
    \\            float starChance = hash21(neighbor);
    \\            if (starChance > 0.92) {
    \\                vec2 starPos = hash22(neighbor * 1.7);
    \\                vec2 offset = vec2(float(dx), float(dy)) + starPos - cellFrac;
    \\                float dist = length(offset);
    \\
    \\                float starBright = smoothstep(0.08, 0.0, dist);
    \\
    \\                starBright *= 0.5 + 0.5 * hash21(neighbor * 3.14);
    \\
    \\                float twinkle = 0.7 + 0.3 * sin(hash21(neighbor) * 50.0 + uTime * 8.0);
    \\                starBright *= twinkle;
    \\
    \\                brightness = max(brightness, starBright);
    \\            }
    \\        }
    \\    }
    \\
    \\    return brightness;
    \\}
    \\
    \\void main() {
    \\    vec3 dir = normalize(vWorldDir);
    \\
    \\    float horizon = 1.0 - abs(dir.y);
    \\    horizon = pow(horizon, 1.5);
    \\    vec3 sky = mix(uSkyColor, uHorizonColor, horizon);
    \\
    \\    float sunDot = dot(dir, uSunDir);
    \\    float sunDisc = smoothstep(0.9995, 0.9999, sunDot);
    \\    vec3 sunColor = vec3(1.0, 0.95, 0.8);
    \\
    \\    float sunGlow = pow(max(sunDot, 0.0), 8.0) * 0.5;
    \\    sunGlow += pow(max(sunDot, 0.0), 64.0) * 0.3;
    \\
    \\    float moonDot = dot(dir, -uSunDir);
    \\    float moonDisc = smoothstep(0.9990, 0.9995, moonDot);
    \\    vec3 moonColor = vec3(0.9, 0.9, 1.0);
    \\
    \\    float starIntensity = 0.0;
    \\    if (uSunIntensity < 0.3 && dir.y > 0.0) {
    \\        float nightFactor = 1.0 - uSunIntensity * 3.33;
    \\        starIntensity = stars(dir) * nightFactor * 1.5;
    \\    }
    \\
    \\    vec3 finalColor = sky;
    \\    finalColor += sunGlow * uSunIntensity * vec3(1.0, 0.8, 0.4);
    \\    finalColor += sunDisc * sunColor * uSunIntensity;
    \\    finalColor += moonDisc * moonColor * uMoonIntensity * 3.0;
    \\    finalColor += vec3(starIntensity);
    \\
    \\    FragColor = vec4(finalColor, 1.0);
    \\}
;

// Debug shadow map visualization shader
const debug_shadow_vertex_shader =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

const debug_shadow_fragment_shader =
    \\#version 330 core
    \\out vec4 FragColor;
    \\in vec2 vTexCoord;
    \\uniform sampler2D uDepthMap;
    \\void main() {
    \\    float depth = texture(uDepthMap, vTexCoord).r;
    \\    FragColor = vec4(vec3(depth), 1.0);
    \\}
;

// Cloud shaders (2D layered clouds)
const cloud_vertex_shader =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\out vec3 vWorldPos;
    \\out float vDistance;
    \\uniform vec3 uCameraPos;
    \\uniform float uCloudHeight;
    \\uniform mat4 uViewProj;
    \\void main() {
    \\    vec3 relPos = vec3(
    \\        aPos.x,
    \\        uCloudHeight - uCameraPos.y,
    \\        aPos.y
    \\    );
    \\    vWorldPos = vec3(aPos.x + uCameraPos.x, uCloudHeight, aPos.y + uCameraPos.z);
    \\    vDistance = length(relPos);
    \\    gl_Position = uViewProj * vec4(relPos, 1.0);
    \\}
;

const cloud_fragment_shader =
    \\#version 330 core
    \\in vec3 vWorldPos;
    \\in float vDistance;
    \\out vec4 FragColor;
    \\uniform vec3 uCameraPos;
    \\uniform float uCloudHeight;
    \\uniform float uCloudCoverage;
    \\uniform float uCloudScale;
    \\uniform float uWindOffsetX;
    \\uniform float uWindOffsetZ;
    \\uniform vec3 uSunDir;
    \\uniform float uSunIntensity;
    \\uniform vec3 uBaseColor;
    \\uniform vec3 uFogColor;
    \\uniform float uFogDensity;
    \\float hash(vec2 p) {
    \\    p = fract(p * vec2(234.34, 435.345));
    \\    p += dot(p, p + 34.23);
    \\    return fract(p.x * p.y);
    \\}
    \\float noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    float a = hash(i);
    \\    float b = hash(i + vec2(1.0, 0.0));
    \\    float c = hash(i + vec2(0.0, 1.0));
    \\    float d = hash(i + vec2(1.0, 1.0));
    \\    vec2 u = f * f * (3.0 - 2.0 * f);
    \\    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    \\}
    \\float fbm(vec2 p, int octaves) {
    \\    float value = 0.0;
    \\    float amplitude = 0.5;
    \\    float frequency = 1.0;
    \\    for (int i = 0; i < octaves; i++) {
    \\        value += amplitude * noise(p * frequency);
    \\        amplitude *= 0.5;
    \\        frequency *= 2.0;
    \\    }
    \\    return value;
    \\}
    \\void main() {
    \\    float cloudBlockSize = 12.0;
    \\    vec2 worldXZ = vWorldPos.xz + vec2(uWindOffsetX, uWindOffsetZ);
    \\    vec2 pixelPos = floor(worldXZ / cloudBlockSize) * cloudBlockSize;
    \\    vec2 samplePos = pixelPos * uCloudScale;
    \\    float cloudValue = fbm(samplePos, 3);
    \\    float threshold = 1.0 - uCloudCoverage;
    \\    if (cloudValue < threshold) discard;
    \\    vec3 nightTint = vec3(0.1, 0.12, 0.2);
    \\    vec3 dayColor = uBaseColor;
    \\    vec3 cloudColor = mix(nightTint, dayColor, uSunIntensity);
    \\    float lightFactor = clamp(uSunDir.y, 0.0, 1.0);
    \\    cloudColor *= (0.7 + 0.3 * lightFactor);
    \\    float fogFactor = 1.0 - exp(-vDistance * uFogDensity * 0.4);
    \\    cloudColor = mix(cloudColor, uFogColor, fogFactor);
    \\    float alpha = 1.0 * (1.0 - fogFactor * 0.8);
    \\    float altitudeDiff = uCameraPos.y - uCloudHeight;
    \\    if (altitudeDiff > 0.0) {
    \\        alpha *= 1.0 - smoothstep(10.0, 400.0, altitudeDiff);
    \\    }
    \\    FragColor = vec4(cloudColor, alpha);
    \\}
;

fn init(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.allocator = allocator;
    ctx.buffers = .empty;
    ctx.free_indices = .empty;
    ctx.mutex = .{};

    // Initialize UI shaders
    std.log.info("Creating OpenGL UI shaders...", .{});
    ctx.ui_shader = try Shader.initSimple(ui_vertex_shader, ui_fragment_shader);
    ctx.ui_tex_shader = try Shader.initSimple(ui_tex_vertex_shader, ui_tex_fragment_shader);
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
    ctx.sky_shader = try Shader.initSimple(sky_vertex_shader, sky_fragment_shader);

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
    ctx.cloud_shader = try Shader.initSimple(cloud_vertex_shader, cloud_fragment_shader);
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
    ctx.debug_shadow_shader = try Shader.initSimple(debug_shadow_vertex_shader, debug_shadow_fragment_shader);

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
    if (ctx.ui_shader) |*s| s.deinit();
    if (ctx.ui_tex_shader) |*s| s.deinit();
    if (ctx.ui_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.ui_vao);
    if (ctx.ui_vbo != 0) c.glDeleteBuffers().?(1, &ctx.ui_vbo);

    // Cleanup sky resources
    if (ctx.sky_shader) |*s| s.deinit();
    if (ctx.sky_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.sky_vao);
    if (ctx.sky_vbo != 0) c.glDeleteBuffers().?(1, &ctx.sky_vbo);

    // Cleanup cloud resources
    if (ctx.cloud_shader) |*s| s.deinit();
    if (ctx.cloud_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.cloud_vao);
    if (ctx.cloud_vbo != 0) c.glDeleteBuffers().?(1, &ctx.cloud_vbo);
    if (ctx.cloud_ebo != 0) c.glDeleteBuffers().?(1, &ctx.cloud_ebo);

    // Cleanup debug shadow map resources
    if (ctx.debug_shadow_shader) |*s| s.deinit();
    if (ctx.debug_shadow_vao != 0) c.glDeleteVertexArrays().?(1, &ctx.debug_shadow_vao);
    if (ctx.debug_shadow_vbo != 0) c.glDeleteBuffers().?(1, &ctx.debug_shadow_vbo);

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

    // We assume the shader is already bound by the caller (main.zig calling shader.use())
    // Note: In a fully abstracted RHI, we would bind the shader here.
    // For now, we just set uniforms on the currently active program.

    var prog: c.GLint = 0;
    c.glGetIntegerv(c.GL_CURRENT_PROGRAM, &prog);
    if (prog == 0) return;
    const program: c.GLuint = @intCast(prog);

    setUniformVec3(program, "uSunDir", sun_dir);
    setUniformFloat(program, "uSunIntensity", sun_intensity);
    setUniformFloat(program, "uAmbient", ambient);
    setUniformVec3(program, "uFogColor", fog_color);
    setUniformFloat(program, "uFogDensity", fog_density);
    setUniformBool(program, "uFogEnabled", fog_enabled);
    setUniformBool(program, "uUseTexture", use_texture);

    // Cloud shadow params
    setUniformFloat(program, "uCloudWindOffsetX", cloud_params.wind_offset_x);
    setUniformFloat(program, "uCloudWindOffsetZ", cloud_params.wind_offset_z);
    setUniformFloat(program, "uCloudScale", cloud_params.cloud_scale);
    setUniformFloat(program, "uCloudCoverage", cloud_params.cloud_coverage);
    setUniformFloat(program, "uCloudShadowStrength", 0.15); // Hardcoded in Vulkan/Shader
    setUniformFloat(program, "uCloudHeight", cloud_params.cloud_height);

    _ = cam_pos;
    _ = time;
}

fn setUniformVec3(program: c.GLuint, name: [:0]const u8, val: Vec3) void {
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform3f().?(loc, val.x, val.y, val.z);
}

fn setUniformFloat(program: c.GLuint, name: [:0]const u8, val: f32) void {
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform1f().?(loc, val);
}

fn setUniformBool(program: c.GLuint, name: [:0]const u8, val: bool) void {
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform1i().?(loc, if (val) 1 else 0);
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
    _ = ctx_ptr;
    const program = createShaderGL(vertex_src, fragment_src) catch {
        return error.VulkanError;
    };
    return @intCast(program);
}

fn destroyShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    _ = ctx_ptr;
    if (handle != 0) {
        c.glDeleteProgram().?(@intCast(handle));
    }
}

fn bindShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    _ = ctx_ptr;
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

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [3]rhi.TextureHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    _ = ctx;

    var prog: c.GLint = 0;
    c.glGetIntegerv(c.GL_CURRENT_PROGRAM, &prog);
    if (prog == 0) return;
    const program: c.GLuint = @intCast(prog);

    setUniformInt(program, "uTexture", 0);
    setUniformBool(program, "uUseTexture", texture_enabled);

    const shadow_map_names = [_][:0]const u8{ "uShadowMap0", "uShadowMap1", "uShadowMap2" };
    for (0..3) |i| {
        const slot = @as(c.GLint, 1 + @as(c_int, @intCast(i)));
        c.glActiveTexture().?(@as(c.GLenum, @intCast(@as(u32, @intCast(c.GL_TEXTURE0)) + @as(u32, @intCast(slot)))));
        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(shadow_map_handles[i]));
        setUniformInt(program, shadow_map_names[i], slot);
    }
    c.glActiveTexture().?(c.GL_TEXTURE0);
}

fn setUniformInt(program: c.GLuint, name: [:0]const u8, val: c.GLint) void {
    const loc = c.glGetUniformLocation().?(program, name);
    if (loc != -1) c.glUniform1i().?(loc, val);
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) void {
    _ = ctx_ptr;
    // For OpenGL, shadow uniforms are arrays.
    var prog: c.GLint = 0;
    c.glGetIntegerv(c.GL_CURRENT_PROGRAM, &prog);
    if (prog == 0) return;
    const program: c.GLuint = @intCast(prog);

    // We only support up to 3 cascades in shader
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        var buf: [64]u8 = undefined;
        // uLightSpaceMatrices[i]
        const name_mat = std.fmt.bufPrintZ(&buf, "uLightSpaceMatrices[{}]", .{i}) catch continue;
        const loc_mat = c.glGetUniformLocation().?(program, name_mat);
        if (loc_mat != -1) c.glUniformMatrix4fv().?(loc_mat, 1, c.GL_FALSE, @ptrCast(&params.light_space_matrices[i].data));

        // uCascadeSplits[i]
        const name_split = std.fmt.bufPrintZ(&buf, "uCascadeSplits[{}]", .{i}) catch continue;
        const loc_split = c.glGetUniformLocation().?(program, name_split);
        if (loc_split != -1) c.glUniform1f().?(loc_split, params.cascade_splits[i]);

        // uShadowTexelSizes[i]
        const name_size = std.fmt.bufPrintZ(&buf, "uShadowTexelSizes[{}]", .{i}) catch continue;
        const loc_size = c.glGetUniformLocation().?(program, name_size);
        if (loc_size != -1) c.glUniform1f().?(loc_size, params.shadow_texel_sizes[i]);
    }
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));

    var prog: c.GLint = 0;
    c.glGetIntegerv(c.GL_CURRENT_PROGRAM, &prog);
    if (prog == 0) return;
    const program: c.GLuint = @intCast(prog);

    const mvp = ctx.current_view_proj.multiply(model);

    const loc_mvp = c.glGetUniformLocation().?(program, "transform");
    if (loc_mvp != -1) c.glUniformMatrix4fv().?(loc_mvp, 1, c.GL_FALSE, @ptrCast(&mvp.data));

    const loc_model = c.glGetUniformLocation().?(program, "uModel");
    if (loc_model != -1) c.glUniformMatrix4fv().?(loc_model, 1, c.GL_FALSE, @ptrCast(&model.data));
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

    // Disable depth write, keep depth test
    c.glDepthMask(c.GL_FALSE);
    defer c.glDepthMask(c.GL_TRUE);

    shader.use();
    shader.setVec3("uCamForward", params.cam_forward.x, params.cam_forward.y, params.cam_forward.z);
    shader.setVec3("uCamRight", params.cam_right.x, params.cam_right.y, params.cam_right.z);
    shader.setVec3("uCamUp", params.cam_up.x, params.cam_up.y, params.cam_up.z);
    shader.setFloat("uAspect", params.aspect);
    shader.setFloat("uTanHalfFov", params.tan_half_fov);
    shader.setVec3("uSunDir", params.sun_dir.x, params.sun_dir.y, params.sun_dir.z);
    shader.setVec3("uSkyColor", params.sky_color.x, params.sky_color.y, params.sky_color.z);
    shader.setVec3("uHorizonColor", params.horizon_color.x, params.horizon_color.y, params.horizon_color.z);
    shader.setFloat("uSunIntensity", params.sun_intensity);
    shader.setFloat("uMoonIntensity", params.moon_intensity);
    shader.setFloat("uTime", params.time);

    c.glBindVertexArray().?(ctx.sky_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    c.glBindVertexArray().?(0);
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
    // OpenGL texture toggle is handled via shader uniform 'uUseTexture' in main.zig.
    // The RHI interface provides this method for consistency with Vulkan or future usage where
    // RHI manages the shader state directly.
}

fn setVSync(ctx_ptr: *anyopaque, enabled: bool) void {
    _ = ctx_ptr;
    _ = c.SDL_GL_SetSwapInterval(if (enabled) 1 else 0);
}

fn updateTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) void {
    _ = ctx_ptr;
    // This assumes the texture is already bound or we bind it temporarily
    // For safety, we should really track width/height or have them passed in.
    // But world_map.zig calls it expecting a specific size.
    // For now, let's assume 256x256 as used in world_map.zig or get from GL.
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

// UI Rendering functions
fn beginUI(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.ui_screen_width = screen_width;
    ctx.ui_screen_height = screen_height;

    // Ensure we're rendering to the default framebuffer
    c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);

    // Disable depth test and culling for UI
    c.glDisable(c.GL_DEPTH_TEST);
    c.glDisable(c.GL_CULL_FACE);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    if (ctx.ui_shader) |*shader| {
        shader.use();
        // Orthographic projection: (0,0) at top-left
        const proj = Mat4.orthographic(0, screen_width, screen_height, 0, -1, 1);
        shader.setMat4("projection", &proj.data);
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

    // Two triangles forming a quad
    // Each vertex: x, y, r, g, b, a
    const vertices = [_]f32{
        // Triangle 1
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        // Triangle 2
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

    if (ctx.ui_tex_shader) |*tex_shader| {
        tex_shader.use();
        const proj = Mat4.orthographic(0, ctx.ui_screen_width, ctx.ui_screen_height, 0, -1, 1);
        tex_shader.setMat4("projection", &proj.data);

        c.glActiveTexture().?(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, @intCast(texture));
        tex_shader.setInt("uTexture", 0);
    }

    // Position (2) + TexCoord (2) = 4 floats per vertex
    const vertices = [_]f32{
        // pos, uv
        x,     y,     0.0, 0.0,
        x + w, y,     1.0, 0.0,
        x + w, y + h, 1.0, 1.0,
        x,     y,     0.0, 0.0,
        x + w, y + h, 1.0, 1.0,
        x,     y + h, 0.0, 1.0,
    };

    // Need different VAO setup for textured quads - use same VBO but different layout
    // For simplicity, we'll just draw with position data and let the shader handle it
    c.glBindBuffer().?(c.GL_ARRAY_BUFFER, ctx.ui_vbo);
    c.glBufferData().?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertices)), &vertices, c.GL_DYNAMIC_DRAW);

    // Temporarily reconfigure vertex attributes for textured quad
    const stride: c.GLsizei = 4 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, stride, null);
    c.glVertexAttribPointer().?(1, 2, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));

    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);

    // Restore colored quad vertex format
    const color_stride: c.GLsizei = 6 * @sizeOf(f32);
    c.glVertexAttribPointer().?(0, 2, c.GL_FLOAT, c.GL_FALSE, color_stride, null);
    c.glVertexAttribPointer().?(1, 4, c.GL_FLOAT, c.GL_FALSE, color_stride, @ptrFromInt(2 * @sizeOf(f32)));

    // Switch back to color shader
    if (ctx.ui_shader) |*shader| {
        shader.use();
    }
}

fn drawClouds(ctx_ptr: *anyopaque, params: rhi.CloudParams) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const shader = ctx.cloud_shader orelse return;
    if (ctx.cloud_vao == 0) return;

    c.glDepthMask(c.GL_FALSE);
    c.glDisable(c.GL_CULL_FACE);
    c.glEnable(c.GL_BLEND);
    c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    c.glDepthFunc(c.GL_LEQUAL);
    defer c.glDepthMask(c.GL_TRUE);
    defer c.glDisable(c.GL_BLEND);
    defer c.glEnable(c.GL_CULL_FACE);
    defer c.glDepthFunc(c.GL_LESS);

    shader.use();
    shader.setVec3("uCameraPos", params.cam_pos.x, params.cam_pos.y, params.cam_pos.z);
    shader.setFloat("uCloudHeight", params.cloud_height);
    shader.setFloat("uCloudCoverage", params.cloud_coverage);
    shader.setFloat("uCloudScale", params.cloud_scale);
    shader.setFloat("uWindOffsetX", params.wind_offset_x);
    shader.setFloat("uWindOffsetZ", params.wind_offset_z);
    shader.setVec3("uSunDir", params.sun_dir.x, params.sun_dir.y, params.sun_dir.z);
    shader.setFloat("uSunIntensity", params.sun_intensity);
    shader.setVec3("uBaseColor", params.base_color.x, params.base_color.y, params.base_color.z);
    shader.setVec3("uFogColor", params.fog_color.x, params.fog_color.y, params.fog_color.z);
    shader.setFloat("uFogDensity", params.fog_density);
    shader.setMat4("uViewProj", &params.view_proj.data);

    c.glBindVertexArray().?(ctx.cloud_vao);
    c.glDrawElements(c.GL_TRIANGLES, 6, c.GL_UNSIGNED_SHORT, null);
    c.glBindVertexArray().?(0);
}

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    const ctx: *OpenGLContext = @ptrCast(@alignCast(ctx_ptr));
    const shader = ctx.debug_shadow_shader orelse return;
    if (ctx.debug_shadow_vao == 0) return;

    _ = cascade_index;

    shader.use();
    c.glActiveTexture().?(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, @intCast(depth_map_handle));
    shader.setInt("uDepthMap", 0);
    c.glBindVertexArray().?(ctx.debug_shadow_vao);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    c.glBindVertexArray().?(0);
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
};

pub fn createRHI(allocator: std.mem.Allocator) !rhi.RHI {
    const ctx = try allocator.create(OpenGLContext);
    ctx.* = .{
        .allocator = allocator,
        .buffers = .empty,
        .free_indices = .empty,
        .mutex = .{},
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
    };

    return rhi.RHI{
        .ptr = ctx,
        .vtable = &vtable,
    };
}
