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
        const lambda = 0.6;
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
        _ = cam_pos; // Not used directly, we use cam_view inverse to get world space corners

        // 1. Compute frustum corners in view space
        const tan_half_v = std.math.tan(fov / 2.0);
        const tan_half_h = tan_half_v * aspect;

        const xn = near * tan_half_h;
        const xf = far * tan_half_h;
        const yn = near * tan_half_v;
        const yf = far * tan_half_v;

        // Standard GL view space: Forward is -Z
        const zn = -near;
        const zf = -far;

        const corners_view = [8]Vec3{
            // Near plane
            Vec3.init(-xn, yn, zn), Vec3.init(xn, yn, zn),
            Vec3.init(xn, -yn, zn), Vec3.init(-xn, -yn, zn),
            // Far plane
            Vec3.init(-xf, yf, zf), Vec3.init(xf, yf, zf),
            Vec3.init(xf, -yf, zf), Vec3.init(-xf, -yf, zf),
        };

        // 2. Transform to World Space (Camera Relative)
        const inv_cam_view = cam_view.inverse();

        var center = Vec3.zero;
        var corners_world: [8]Vec3 = undefined;

        for (0..8) |j| {
            corners_world[j] = inv_cam_view.transformPoint(corners_view[j]);
            center = center.add(corners_world[j]);
        }
        center = center.scale(1.0 / 8.0);

        // 3. Build Light View Matrix
        // Position light 'far away' from center in sun direction
        const light_pos = center.add(sun_dir.scale(100.0)); // Arbitrary distance
        const light_view = Mat4.lookAt(light_pos, center, Vec3.init(0, 1, 0));

        // 4. Fit Ortho Projection
        var minX: f32 = std.math.floatMax(f32);
        var maxX: f32 = -std.math.floatMax(f32);
        var minY: f32 = std.math.floatMax(f32);
        var maxY: f32 = -std.math.floatMax(f32);
        var minZ: f32 = std.math.floatMax(f32);
        var maxZ: f32 = -std.math.floatMax(f32);

        for (corners_world) |p| {
            const p_light = light_view.transformPoint(p);
            minX = @min(minX, p_light.x);
            maxX = @max(maxX, p_light.x);
            minY = @min(minY, p_light.y);
            maxY = @max(maxY, p_light.y);
            minZ = @min(minZ, p_light.z);
            maxZ = @max(maxZ, p_light.z);
        }

        // Texel Snapping
        const units_per_texel = (maxX - minX) / @as(f32, @floatFromInt(self.resolution));
        minX = @floor(minX / units_per_texel) * units_per_texel;
        maxX = @floor(maxX / units_per_texel) * units_per_texel;
        minY = @floor(minY / units_per_texel) * units_per_texel;
        maxY = @floor(maxY / units_per_texel) * units_per_texel;

        // Extend Z to include shadow casters in front of the frustum
        const z_mult: f32 = 10.0;
        minZ = if (minZ < 0) minZ * z_mult else minZ / z_mult;
        maxZ = if (maxZ < 0) maxZ / z_mult else maxZ * z_mult;

        const light_ortho = Mat4.orthographic(minX, maxX, minY, maxY, -maxZ, -minZ);
        return light_ortho.multiply(light_view);
    }

    /// Begin shadow pass for specific cascade
    pub fn begin(self: *ShadowMap, cascade_index: usize) void {
        c.glViewport(0, 0, @intCast(self.resolution), @intCast(self.resolution));
        c.glBindFramebuffer().?(c.GL_FRAMEBUFFER, self.fbos[cascade_index]);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);

        // Cull front faces to prevent self-shadowing (peter panning / acne trade-off)
        // This effectively moves the shadow depth to the back of the object
        c.glCullFace(c.GL_FRONT);

        self.shader.use();
        self.shader.setMat4("uLightSpaceMatrix", &self.light_space_matrices[cascade_index].data);
    }

    /// End shadow pass
    pub fn end(self: *ShadowMap, screen_width: u32, screen_height: u32) void {
        _ = self;
        // Restore culling
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
