//! Shadow mapping system.
//! Manages shadow map FBO and light space matrices for CSM.

const std = @import("std");
const c = @import("../../c.zig").c;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

const rhi = @import("rhi.zig");

const CSM = @import("csm.zig");

pub const ShadowMap = struct {
    pub const CASCADE_COUNT = CSM.CASCADE_COUNT;
    depth_maps: [CASCADE_COUNT]Texture,
    fbos: [CASCADE_COUNT]c.GLuint,
    resolution: u32,
    shader: Shader,
    light_space_matrices: [CASCADE_COUNT]Mat4,
    cascade_splits: [CASCADE_COUNT]f32,
    texel_sizes: [CASCADE_COUNT]f32,
    rhi_instance: rhi.RHI,

    pub fn init(rhi_instance: rhi.RHI, resolution: u32) !ShadowMap {
        var depth_maps: [CASCADE_COUNT]Texture = undefined;
        var fbos: [CASCADE_COUNT]c.GLuint = undefined;

        // Create FBOs and Textures for each cascade
        for (0..CASCADE_COUNT) |i| {
            depth_maps[i] = Texture.initEmpty(rhi_instance, resolution, resolution, .depth, .{
                .min_filter = .nearest,
                .mag_filter = .nearest,
                .wrap_s = .clamp_to_border,
                .wrap_t = .clamp_to_border,
                .generate_mipmaps = false,
            });

            c.glGenFramebuffers().?(1, &fbos[i]);
            c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, fbos[i]);
            c.glFramebufferTexture2D().?(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, @intCast(depth_maps[i].handle), 0);

            c.glDrawBuffer(c.GL_NONE);
            c.glReadBuffer(c.GL_NONE);

            if (c.glCheckFramebufferStatus().?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
                return error.FramebufferIncomplete;
            }
        }

        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);

        // Create shader
        const shader = try Shader.initSimple(vertex_src, fragment_src);

        return .{
            .depth_maps = depth_maps,
            .fbos = fbos,
            .resolution = resolution,
            .shader = shader,
            .light_space_matrices = undefined,
            .cascade_splits = undefined,
            .texel_sizes = undefined,
            .rhi_instance = rhi_instance,
        };
    }

    pub fn deinit(self: *ShadowMap) void {
        for (0..CASCADE_COUNT) |i| {
            c.glDeleteFramebuffers().?(1, &self.fbos[i]);
            var tex = self.depth_maps[i];
            tex.deinit();
        }
        var sh = self.shader;
        sh.deinit();
    }

    pub const ShadowCascades = CSM.ShadowCascades;
    pub const computeCascades = CSM.computeCascades;

    /// Calculate cascade splits and matrices
    pub fn update(self: *ShadowMap, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_pos: Vec3, cam_view: Mat4) void {
        _ = cam_pos;
        const cascades = computeCascades(self.resolution, camera_fov, aspect, near, far, sun_dir, cam_view, false);
        self.light_space_matrices = cascades.light_space_matrices;
        self.cascade_splits = cascades.cascade_splits;
        self.texel_sizes = cascades.texel_sizes;
    }

    /// Begin shadow pass for specific cascade
    pub fn begin(self: *ShadowMap, cascade_index: usize) void {
        c.glViewport(0, 0, @intCast(self.resolution), @intCast(self.resolution));
        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, self.fbos[cascade_index]);

        // Standard Z clear
        c.glClearDepth(1.0);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);
        // Use GL_LESS for standard depth test
        c.glDepthFunc(c.GL_LESS);
        // Use standard back-face culling for shadows too
        // Front-face culling can cause issues if chunks have holes or are thin
        c.glEnable(c.GL_CULL_FACE);
        c.glCullFace(c.GL_BACK);

        self.shader.use();
        self.shader.setMat4("uLightSpaceMatrix", &self.light_space_matrices[cascade_index].data);
    }

    /// End shadow pass
    pub fn end(self: *ShadowMap, screen_width: u32, screen_height: u32) void {
        _ = self;
        // Restore standard culling (Back faces)
        c.glCullFace(c.GL_BACK);

        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, @intCast(screen_width), @intCast(screen_height));
    }
};

const vertex_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\// Other attributes ignored
    \\
    \\uniform mat4 transform; // MVP matrix (LightProjection * LightView * Model)
    \\// World.render sets 'transform' to (view_proj * model).
    \\// Since we passed 'light_space_matrix' as 'view_proj', 'transform' computes the full transform.
    \\
    \\void main() {
    \\    gl_Position = transform * vec4(aPos, 1.0);
    \\}
;

const fragment_src =
    \\#version 330 core
    \\void main() {
    \\    // Depth written automatically
    \\}
;
