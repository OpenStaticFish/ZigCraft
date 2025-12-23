//! Shadow mapping system.
//! Manages shadow map FBO and light space matrices for CSM.

const std = @import("std");
const c = @import("../../c.zig").c;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

const rhi = @import("rhi.zig");

pub const ShadowMap = struct {
    pub const CASCADE_COUNT = rhi.SHADOW_CASCADE_COUNT;
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

    pub const ShadowCascades = struct {
        light_space_matrices: [CASCADE_COUNT]Mat4,
        cascade_splits: [CASCADE_COUNT]f32,
        texel_sizes: [CASCADE_COUNT]f32,
    };

    pub fn computeCascades(resolution: u32, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_view: Mat4, z_range_01: bool) ShadowCascades {
        const lambda = 0.8;
        const shadow_dist = far;

        var cascades: ShadowCascades = .{
            .light_space_matrices = undefined,
            .cascade_splits = undefined,
            .texel_sizes = undefined,
        };

        // Calculate split distances (linear/log blend)
        for (0..CASCADE_COUNT) |i| {
            const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(CASCADE_COUNT));
            const log_split = near * std.math.pow(f32, shadow_dist / near, p);
            const lin_split = near + (shadow_dist - near) * p;
            cascades.cascade_splits[i] = std.math.lerp(lin_split, log_split, lambda);
        }

        // Calculate matrices for each cascade
        var last_split = near;
        for (0..CASCADE_COUNT) |i| {
            const split = cascades.cascade_splits[i];

            // 1. Compute bounding sphere of frustum slice (STABLE CSM approach)
            const tan_fov_half = std.math.tan(camera_fov / 2.0);
            const tan_fov_h_half = tan_fov_half * aspect;

            const near_v = last_split;
            const far_v = split;
            const center_z = (near_v + far_v) / 2.0;
            const center_view = Vec3.init(0, 0, -center_z);

            const xf = far_v * tan_fov_h_half;
            const yf = far_v * tan_fov_half;
            const zf = -far_v;
            const far_corner = Vec3.init(xf, yf, zf);
            var radius = far_corner.sub(center_view).length();
            radius = @ceil(radius * 16.0) / 16.0;

            // 2. Transform center to World Space
            const inv_cam_view = cam_view.inverse();
            const center_world = inv_cam_view.transformPoint(center_view);

            // 3. Build Light Rotation Matrix (Looking in -sun direction)
            var up = Vec3.init(0, 1, 0);
            if (@abs(sun_dir.y) > 0.99) up = Vec3.init(0, 0, 1);
            const light_rot = Mat4.lookAt(Vec3.zero, sun_dir.scale(-1.0), up);

            // 4. Transform center to Light Space
            const center_ls = light_rot.transformPoint(center_world);

            // 5. Snap center to texel grid in LIGHT SPACE
            const texel_size = (2.0 * radius) / @as(f32, @floatFromInt(resolution));
            cascades.texel_sizes[i] = texel_size;

            const center_snapped = Vec3.init(
                @floor(center_ls.x / texel_size) * texel_size,
                @floor(center_ls.y / texel_size) * texel_size,
                center_ls.z,
            );

            // 6. Build Ortho Projection (Centered around snapped center)
            const minX = center_snapped.x - radius;
            const maxX = center_snapped.x + radius;
            const minY = center_snapped.y - radius;
            const maxY = center_snapped.y + radius;

            const maxZ = center_snapped.z + radius + 300.0;
            const minZ = center_snapped.z - radius - 100.0;

            var light_ortho = Mat4.identity;
            light_ortho.data[0][0] = 2.0 / (maxX - minX);
            light_ortho.data[3][0] = -(maxX + minX) / (maxX - minX);

            light_ortho.data[1][1] = 2.0 / (maxY - minY);
            light_ortho.data[3][1] = -(maxY + minY) / (maxY - minY);

            if (z_range_01) {
                const A = 1.0 / (maxZ - minZ);
                const B = -A * minZ;
                light_ortho.data[2][2] = A;
                light_ortho.data[3][2] = B;
            } else {
                // Standard OpenGL: map closer to -1, further to 1
                // maxZ is closer (less negative), minZ is further (more negative)
                const A = -2.0 / (maxZ - minZ);
                const B = (maxZ + minZ) / (maxZ - minZ);
                light_ortho.data[2][2] = A;
                light_ortho.data[3][2] = B;
            }

            cascades.light_space_matrices[i] = light_ortho.multiply(light_rot);
            last_split = split;
        }

        return cascades;
    }

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
