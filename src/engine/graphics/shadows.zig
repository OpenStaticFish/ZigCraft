//! Shadow mapping system.
//! Manages shadow map FBO and light space matrices.

const std = @import("std");
const c = @import("../../c.zig").c;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

pub const ShadowMap = struct {
    depth_map: Texture,
    fbo: c.GLuint,
    resolution: u32,
    shader: Shader,
    light_space_matrix: Mat4,

    pub fn init(resolution: u32) !ShadowMap {
        // Create depth texture
        const depth_map = Texture.initEmpty(resolution, resolution, .depth, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_border,
            .wrap_t = .clamp_to_border,
            .generate_mipmaps = false,
        });

        // Create FBO
        var fbo: c.GLuint = 0;
        c.glGenFramebuffers().?(1, &fbo);
        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, fbo);
        c.glFramebufferTexture2D().?(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, depth_map.id, 0);

        // No color buffer needed
        c.glDrawBuffer(c.GL_NONE);
        c.glReadBuffer(c.GL_NONE);

        if (c.glCheckFramebufferStatus().?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
            return error.FramebufferIncomplete;
        }

        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);

        // Create shader
        const shader = try Shader.initSimple(vertex_src, fragment_src);

        return .{
            .depth_map = depth_map,
            .fbo = fbo,
            .resolution = resolution,
            .shader = shader,
            .light_space_matrix = Mat4.identity,
        };
    }

    pub fn deinit(self: *ShadowMap) void {
        var fbo = self.fbo;
        c.glDeleteFramebuffers().?(1, &fbo);
        var tex = self.depth_map;
        tex.deinit();
        var sh = self.shader;
        sh.deinit();
    }

    /// Begin shadow pass
    pub fn begin(self: *ShadowMap, sun_dir: Vec3, cam_pos: Vec3) void {
        // Calculate light space matrix
        // Orthographic projection centered on player
        const near_plane = -200.0;
        const far_plane = 200.0;
        const ortho_size = 120.0; // Half-size of shadow area (covers ~240 blocks)

        const projection = Mat4.orthographic(-ortho_size, ortho_size, -ortho_size, ortho_size, near_plane, far_plane);

        // View matrix: look from sun direction towards camera position
        // Snap camera position to texel grid to prevent shimmering
        const world_units_per_texel = (2.0 * ortho_size) / @as(f32, @floatFromInt(self.resolution));

        // Snap position
        const snapped_pos = Vec3.init(@floor(cam_pos.x / world_units_per_texel) * world_units_per_texel, @floor(cam_pos.y / world_units_per_texel) * world_units_per_texel, @floor(cam_pos.z / world_units_per_texel) * world_units_per_texel);

        // Position light "far away" in sun direction
        const light_pos = snapped_pos.add(sun_dir.scale(100.0));
        const view = Mat4.lookAt(light_pos, snapped_pos, Vec3.init(0, 1, 0));

        self.light_space_matrix = projection.multiply(view);

        c.glViewport(0, 0, @intCast(self.resolution), @intCast(self.resolution));
        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, self.fbo);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);

        // Use shader and set matrix
        self.shader.use();
        self.shader.setMat4("uLightSpaceMatrix", &self.light_space_matrix.data);
    }

    /// End shadow pass
    pub fn end(self: *ShadowMap, screen_width: u32, screen_height: u32) void {
        _ = self;
        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, @intCast(screen_width), @intCast(screen_height));
    }
};

const vertex_src =
    \\#version 330 core
    \\layout (location = 0) in vec3 aPos;
    \\// Other attributes ignored
    \\
    \\uniform mat4 transform; // Chunk Model matrix (passed via World.render, actually MVP? No wait)
    \\// In World.render for shadow pass, we pass 'light_space_matrix' as 'view_proj'.
    \\// So 'transform' uniform set by World.render IS (LightSpace * Model).
    \\// So we just output it.
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
