const std = @import("std");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const rhi = @import("rhi.zig");

pub const CASCADE_COUNT = rhi.SHADOW_CASCADE_COUNT;

pub const ShadowCascades = struct {
    light_space_matrices: [CASCADE_COUNT]Mat4,
    cascade_splits: [CASCADE_COUNT]f32,
    texel_sizes: [CASCADE_COUNT]f32,
};

/// Computes stable cascaded shadow map matrices using texel snapping.
///
/// Parameters:
/// - resolution: shadow map resolution per cascade.
/// - camera_fov: vertical FOV in radians.
/// - aspect: viewport aspect ratio.
/// - near/far: camera depth range for cascade splitting.
/// - sun_dir: normalized direction to the sun (world space).
/// - cam_view: camera view matrix (origin-centered).
/// - z_range_01: map depth to [0,1] for reverse-Z when true.
///
/// Notes:
/// - lambda=0.92 biases the split scheme toward logarithmic distribution.
/// - min/max Z offsets are tuned to avoid clipping during camera motion.
pub fn computeCascades(resolution: u32, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_view: Mat4, z_range_01: bool) ShadowCascades {
    const lambda = 0.92;
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

        // Expand depth bounds to reduce clipping on steep angles and during movement.
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
            // Standard perspective: map closer to -1, further to 1
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

test "computeCascades splits and texel sizes" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    var last_split: f32 = 0.0;
    for (0..CASCADE_COUNT) |i| {
        try std.testing.expect(cascades.cascade_splits[i] > last_split);
        try std.testing.expect(cascades.texel_sizes[i] > 0.0);
        last_split = cascades.cascade_splits[i];
    }
}
