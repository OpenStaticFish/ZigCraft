//! Shadow mapping system.
//! Manages shadow map FBO and light space matrices for CSM.

const std = @import("std");
const c = @import("../../c.zig").c;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Texture = @import("texture.zig").Texture;
const Shader = @import("shader.zig").Shader;

pub const CASCADE_COUNT = 3;

pub const ShadowMap = struct {
    depth_maps: [CASCADE_COUNT]Texture,
    fbos: [CASCADE_COUNT]c.GLuint,
    resolution: u32,
    shader: Shader,
    light_space_matrices: [CASCADE_COUNT]Mat4,
    cascade_splits: [CASCADE_COUNT]f32,

    pub fn init(resolution: u32) !ShadowMap {
        var depth_maps: [CASCADE_COUNT]Texture = undefined;
        var fbos: [CASCADE_COUNT]c.GLuint = undefined;

        // Create FBOs and Textures for each cascade
        for (0..CASCADE_COUNT) |i| {
            depth_maps[i] = Texture.initEmpty(resolution, resolution, .depth, .{
                .min_filter = .nearest,
                .mag_filter = .nearest,
                .wrap_s = .clamp_to_border,
                .wrap_t = .clamp_to_border,
                .generate_mipmaps = false,
            });

            c.glGenFramebuffers().?(1, &fbos[i]);
            c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, fbos[i]);
            c.glFramebufferTexture2D().?(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_TEXTURE_2D, depth_maps[i].id, 0);

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
            .light_space_matrices = [_]Mat4{Mat4.identity} ** CASCADE_COUNT,
            .cascade_splits = [_]f32{0} ** CASCADE_COUNT,
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

    /// Calculate cascade splits and matrices
    pub fn update(self: *ShadowMap, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_pos: Vec3, cam_view: Mat4) void {
        const lambda = 0.8;
        const shadow_dist = far; // Spec says shadow_distance might be different from camera far, but assuming same for now

        // Calculate split distances (linear/log blend)
        for (0..CASCADE_COUNT) |i| {
            const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(CASCADE_COUNT));
            const log_split = near * std.math.pow(f32, shadow_dist / near, p);
            const lin_split = near + (shadow_dist - near) * p;
            self.cascade_splits[i] = std.math.lerp(lin_split, log_split, lambda);
        }

        // Calculate matrices for each cascade
        var last_split = near;
        for (0..CASCADE_COUNT) |i| {
            const split = self.cascade_splits[i];
            self.light_space_matrices[i] = self.computeLightMatrix(last_split, split, camera_fov, aspect, sun_dir, cam_pos, cam_view);
            last_split = split;
        }
    }

    fn computeLightMatrix(self: *ShadowMap, near: f32, far: f32, fov: f32, aspect: f32, sun_dir: Vec3, cam_pos: Vec3, cam_view: Mat4) Mat4 {
        _ = cam_pos;

        // 1. Compute bounding sphere of frustum slice (STABLE CSM approach)
        // A sphere is invariant to rotation, so the shadow map won't jitter when you look around.
        const tan_fov_half = std.math.tan(fov / 2.0);
        const tan_fov_h_half = tan_fov_half * aspect;

        // Optimal bounding sphere for a frustum slice [near, far]
        // Center is along the camera forward axis
        const near_v = near;
        const far_v = far;
        const center_z = (near_v + far_v) / 2.0;
        const center_view = Vec3.init(0, 0, -center_z);

        // Radius is distance from center to a far corner
        const xf = far_v * tan_fov_h_half;
        const yf = far_v * tan_fov_half;
        const zf = -far_v;
        const far_corner = Vec3.init(xf, yf, zf);
        var radius = far_corner.sub(center_view).length();

        // Stabilize radius to prevent precision crawling
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
        // This makes the shadow map "locked" to the world as the camera moves.
        const texel_size = (2.0 * radius) / @as(f32, @floatFromInt(self.resolution));
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

        // Extend Z to include shadow casters towards the sun
        // Large bounds to prevent clipping mountain/tree shadows
        const maxZ = center_snapped.z + radius + 300.0;
        const minZ = center_snapped.z - radius - 100.0;

        // Build ZERO_TO_ONE Orthographic Matrix
        var light_ortho = Mat4.identity;
        light_ortho.data[0][0] = 2.0 / (maxX - minX);
        light_ortho.data[3][0] = -(maxX + minX) / (maxX - minX);

        light_ortho.data[1][1] = 2.0 / (maxY - minY);
        light_ortho.data[3][1] = -(maxY + minY) / (maxY - minY);

        // Z: [minZ, maxZ] -> [0, 1]
        const A = 1.0 / (minZ - maxZ);
        const B = -A * maxZ;
        light_ortho.data[2][2] = A;
        light_ortho.data[3][2] = B;

        return light_ortho.multiply(light_rot);
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
