//! Main renderer that manages OpenGL state and rendering pipeline.

const std = @import("std");
const c = @import("../../c.zig").c;

const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Camera = @import("camera.zig").Camera;
const Shader = @import("shader.zig").Shader;
const Mesh = @import("mesh.zig").Mesh;
const log = @import("../core/log.zig");

/// Renderer statistics for the current frame
pub const RenderStats = struct {
    draw_calls: u32 = 0,
    vertices: u64 = 0,
    triangles: u64 = 0,

    pub fn reset(self: *RenderStats) void {
        self.draw_calls = 0;
        self.vertices = 0;
        self.triangles = 0;
    }
};

/// Blend modes for transparency
pub const BlendMode = enum {
    none,
    alpha,
    additive,
    multiply,
};

pub const Renderer = struct {
    clear_color: Vec3,
    wireframe: bool,
    stats: RenderStats,
    vsync: bool,
    cull_face: bool,
    depth_test: bool,

    pub fn init() Renderer {
        // Log OpenGL info
        const vendor = c.glGetString(c.GL_VENDOR);
        const renderer_name = c.glGetString(c.GL_RENDERER);
        const version = c.glGetString(c.GL_VERSION);
        const glsl_version = c.glGetString(c.GL_SHADING_LANGUAGE_VERSION);

        log.log.info("OpenGL Vendor: {s}", .{vendor});
        log.log.info("OpenGL Renderer: {s}", .{renderer_name});
        log.log.info("OpenGL Version: {s}", .{version});
        log.log.info("GLSL Version: {s}", .{glsl_version});

        // Enable depth testing
        c.glEnable(c.GL_DEPTH_TEST);
        c.glDepthFunc(c.GL_LESS);

        // Enable backface culling
        c.glEnable(c.GL_CULL_FACE);
        c.glCullFace(c.GL_BACK);
        c.glFrontFace(c.GL_CCW);

        // Enable blending for transparency
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

        return .{
            .clear_color = Vec3.init(0.5, 0.7, 1.0), // Sky blue
            .wireframe = false,
            .stats = .{},
            .vsync = true,
            .cull_face = true,
            .depth_test = true,
        };
    }

    pub fn beginFrame(self: *Renderer) void {
        self.stats.reset();
        c.glClearColor(self.clear_color.x, self.clear_color.y, self.clear_color.z, 1.0);
        c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);

        if (self.wireframe) {
            c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_LINE);
        } else {
            c.glPolygonMode(c.GL_FRONT_AND_BACK, c.GL_FILL);
        }
    }

    pub fn endFrame(self: *Renderer) void {
        _ = self;
        // Could add end-of-frame operations here
    }

    pub fn setViewport(self: *Renderer, width: u32, height: u32) void {
        _ = self;
        c.glViewport(0, 0, @intCast(width), @intCast(height));
    }

    pub fn toggleWireframe(self: *Renderer) void {
        self.wireframe = !self.wireframe;
        log.log.debug("Wireframe: {}", .{self.wireframe});
    }

    pub fn setWireframe(self: *Renderer, enabled: bool) void {
        self.wireframe = enabled;
    }

    pub fn setClearColor(self: *Renderer, color: Vec3) void {
        self.clear_color = color;
    }

    pub fn setDepthTest(self: *Renderer, enabled: bool) void {
        self.depth_test = enabled;
        if (enabled) {
            c.glEnable(c.GL_DEPTH_TEST);
        } else {
            c.glDisable(c.GL_DEPTH_TEST);
        }
    }

    pub fn setCullFace(self: *Renderer, enabled: bool) void {
        self.cull_face = enabled;
        if (enabled) {
            c.glEnable(c.GL_CULL_FACE);
        } else {
            c.glDisable(c.GL_CULL_FACE);
        }
    }

    pub fn setBlendMode(self: *Renderer, mode: BlendMode) void {
        _ = self;
        switch (mode) {
            .none => c.glDisable(c.GL_BLEND),
            .alpha => {
                c.glEnable(c.GL_BLEND);
                c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
            },
            .additive => {
                c.glEnable(c.GL_BLEND);
                c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE);
            },
            .multiply => {
                c.glEnable(c.GL_BLEND);
                c.glBlendFunc(c.GL_DST_COLOR, c.GL_ZERO);
            },
        }
    }

    /// Draw a mesh with a shader and transform
    pub fn drawMesh(self: *Renderer, mesh: *const Mesh, shader: *const Shader, model: Mat4, view_proj: Mat4) void {
        shader.use();

        const mvp = view_proj.multiply(model);
        shader.setMat4("transform", &mvp.data);

        mesh.draw();

        // Update stats
        self.stats.draw_calls += 1;
        self.stats.vertices += mesh.vertex_count;
        self.stats.triangles += mesh.vertex_count / 3;
    }

    /// Draw arrays directly (for chunk meshes etc)
    pub fn recordDrawCall(self: *Renderer, vertex_count: u32) void {
        self.stats.draw_calls += 1;
        self.stats.vertices += vertex_count;
        self.stats.triangles += vertex_count / 3;
    }

    pub fn getStats(self: *const Renderer) RenderStats {
        return self.stats;
    }
};

/// Set VSync mode (call after creating GL context)
pub fn setVSync(enabled: bool) void {
    _ = c.SDL_GL_SetSwapInterval(if (enabled) 1 else 0);
    log.log.info("VSync: {}", .{enabled});
}

/// Get OpenGL version as integers
pub fn getGLVersion() struct { major: i32, minor: i32 } {
    var major: c.GLint = undefined;
    var minor: c.GLint = undefined;
    c.glGetIntegerv(c.GL_MAJOR_VERSION, &major);
    c.glGetIntegerv(c.GL_MINOR_VERSION, &minor);
    return .{ .major = major, .minor = minor };
}

/// Check if an OpenGL extension is supported
pub fn hasExtension(name: [*c]const u8) bool {
    var num_extensions: c.GLint = undefined;
    c.glGetIntegerv(c.GL_NUM_EXTENSIONS, &num_extensions);

    var i: c.GLuint = 0;
    while (i < @as(c.GLuint, @intCast(num_extensions))) : (i += 1) {
        const ext = c.glGetStringi(c.GL_EXTENSIONS, i);
        if (ext != null and std.mem.eql(u8, std.mem.span(ext), std.mem.span(name))) {
            return true;
        }
    }
    return false;
}
