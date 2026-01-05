//! Ray casting and voxel traversal utilities for block targeting.
//!
//! Provides a Ray struct and DDA (Digital Differential Analyzer) algorithm
//! for efficiently traversing voxels along a ray direction.

const std = @import("std");
const math = @import("zig-math");
const Vec3 = math.Vec3;
const AABB = math.AABB;
const block = @import("../../world/block.zig");
const Face = block.Face;

/// A ray defined by an origin point and direction vector.
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3, // Should be normalized

    pub fn init(origin: Vec3, direction: Vec3) Ray {
        return .{
            .origin = origin,
            .direction = direction.normalize(),
        };
    }

    /// Get a point along the ray at distance t from the origin.
    pub fn at(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.scale(t));
    }
};

/// Result of a ray-AABB intersection test.
pub const RayHit = struct {
    t: f32, // Distance along ray to hit point
    normal: Vec3, // Surface normal at hit point
};

/// Result of a voxel raycast.
pub const VoxelHit = struct {
    x: i32,
    y: i32,
    z: i32,
    face: Face,
    distance: f32,
};

/// Test ray intersection against an axis-aligned bounding box.
/// Uses the slab method for efficient intersection testing.
/// Returns hit info if intersection occurs, null otherwise.
pub fn intersectAABB(ray: Ray, aabb: AABB) ?RayHit {
    var t_min: f32 = 0.0;
    var t_max: f32 = std.math.inf(f32);
    var hit_axis: u2 = 0;
    var hit_sign: f32 = -1.0;

    // Test each axis (X, Y, Z)
    inline for (0..3) |axis| {
        const origin = switch (axis) {
            0 => ray.origin.x,
            1 => ray.origin.y,
            2 => ray.origin.z,
            else => unreachable,
        };
        const dir = switch (axis) {
            0 => ray.direction.x,
            1 => ray.direction.y,
            2 => ray.direction.z,
            else => unreachable,
        };
        const box_min = switch (axis) {
            0 => aabb.min.x,
            1 => aabb.min.y,
            2 => aabb.min.z,
            else => unreachable,
        };
        const box_max = switch (axis) {
            0 => aabb.max.x,
            1 => aabb.max.y,
            2 => aabb.max.z,
            else => unreachable,
        };

        if (@abs(dir) < 1e-8) {
            // Ray is parallel to slab - check if origin is within slab
            if (origin < box_min or origin > box_max) {
                return null;
            }
        } else {
            const inv_d = 1.0 / dir;
            var t1 = (box_min - origin) * inv_d;
            var t2 = (box_max - origin) * inv_d;

            var sign: f32 = -1.0;
            if (t1 > t2) {
                const tmp = t1;
                t1 = t2;
                t2 = tmp;
                sign = 1.0;
            }

            if (t1 > t_min) {
                t_min = t1;
                hit_axis = @intCast(axis);
                hit_sign = sign;
            }
            t_max = @min(t_max, t2);

            if (t_min > t_max or t_max < 0) {
                return null;
            }
        }
    }

    // Calculate normal based on which axis was hit
    const normal = switch (hit_axis) {
        0 => Vec3.init(hit_sign, 0, 0),
        1 => Vec3.init(0, hit_sign, 0),
        2 => Vec3.init(0, 0, hit_sign),
        else => unreachable,
    };

    return RayHit{
        .t = t_min,
        .normal = normal,
    };
}

/// DDA (Digital Differential Analyzer) voxel traversal.
/// Efficiently steps through voxels along a ray, calling the provided
/// function for each voxel until it returns true or max_distance is reached.
///
/// This is the standard algorithm for voxel raycasting, used in games like
/// Minecraft for block selection.
pub fn castThroughVoxels(
    origin: Vec3,
    direction: Vec3,
    max_distance: f32,
    comptime Context: type,
    context: Context,
    comptime isSolid: fn (ctx: Context, x: i32, y: i32, z: i32) bool,
) ?VoxelHit {
    const dir = direction.normalize();

    // Current voxel coordinates
    var x: i32 = @intFromFloat(@floor(origin.x));
    var y: i32 = @intFromFloat(@floor(origin.y));
    var z: i32 = @intFromFloat(@floor(origin.z));

    // Direction to step in each axis (+1 or -1)
    const step_x: i32 = if (dir.x >= 0) 1 else -1;
    const step_y: i32 = if (dir.y >= 0) 1 else -1;
    const step_z: i32 = if (dir.z >= 0) 1 else -1;

    // Distance along ray to next voxel boundary for each axis
    // t_max_* = distance to next boundary
    // t_delta_* = distance between boundaries
    const t_delta_x = if (@abs(dir.x) < 1e-8) std.math.inf(f32) else @abs(1.0 / dir.x);
    const t_delta_y = if (@abs(dir.y) < 1e-8) std.math.inf(f32) else @abs(1.0 / dir.y);
    const t_delta_z = if (@abs(dir.z) < 1e-8) std.math.inf(f32) else @abs(1.0 / dir.z);

    // Calculate initial t_max values
    var t_max_x: f32 = undefined;
    var t_max_y: f32 = undefined;
    var t_max_z: f32 = undefined;

    if (dir.x >= 0) {
        t_max_x = (@as(f32, @floatFromInt(x)) + 1.0 - origin.x) * t_delta_x;
    } else {
        t_max_x = (origin.x - @as(f32, @floatFromInt(x))) * t_delta_x;
    }

    if (dir.y >= 0) {
        t_max_y = (@as(f32, @floatFromInt(y)) + 1.0 - origin.y) * t_delta_y;
    } else {
        t_max_y = (origin.y - @as(f32, @floatFromInt(y))) * t_delta_y;
    }

    if (dir.z >= 0) {
        t_max_z = (@as(f32, @floatFromInt(z)) + 1.0 - origin.z) * t_delta_z;
    } else {
        t_max_z = (origin.z - @as(f32, @floatFromInt(z))) * t_delta_z;
    }

    var distance: f32 = 0.0;
    var last_face: Face = .top;

    // Main DDA loop
    while (distance < max_distance) {
        // Check current voxel
        if (isSolid(context, x, y, z)) {
            return VoxelHit{
                .x = x,
                .y = y,
                .z = z,
                .face = last_face,
                .distance = distance,
            };
        }

        // Step to next voxel boundary
        if (t_max_x < t_max_y) {
            if (t_max_x < t_max_z) {
                x += step_x;
                distance = t_max_x;
                t_max_x += t_delta_x;
                last_face = if (step_x > 0) .west else .east;
            } else {
                z += step_z;
                distance = t_max_z;
                t_max_z += t_delta_z;
                last_face = if (step_z > 0) .north else .south;
            }
        } else {
            if (t_max_y < t_max_z) {
                y += step_y;
                distance = t_max_y;
                t_max_y += t_delta_y;
                last_face = if (step_y > 0) .bottom else .top;
            } else {
                z += step_z;
                distance = t_max_z;
                t_max_z += t_delta_z;
                last_face = if (step_z > 0) .north else .south;
            }
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "Ray initialization" {
    const ray = Ray.init(Vec3.init(0, 0, 0), Vec3.init(1, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), ray.origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), ray.direction.x, 0.001);
}

test "Ray.at returns correct point" {
    const ray = Ray.init(Vec3.init(0, 0, 0), Vec3.init(1, 0, 0));
    const point = ray.at(5.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), point.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), point.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), point.z, 0.001);
}

test "intersectAABB hit" {
    const ray = Ray.init(Vec3.init(-2, 0.5, 0.5), Vec3.init(1, 0, 0));
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(1, 1, 1));

    const hit = intersectAABB(ray, aabb);
    try std.testing.expect(hit != null);
    try std.testing.expectApproxEqAbs(@as(f32, 2), hit.?.t, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), hit.?.normal.x, 0.001);
}

test "intersectAABB miss" {
    const ray = Ray.init(Vec3.init(-2, 5, 0.5), Vec3.init(1, 0, 0));
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(1, 1, 1));

    const hit = intersectAABB(ray, aabb);
    try std.testing.expect(hit == null);
}

test "DDA voxel traversal" {
    // Simple test: raycast through empty space then hit a solid block at (3, 0, 0)
    const Context = struct {
        pub fn isSolid(_: @This(), x: i32, y: i32, z: i32) bool {
            return x == 3 and y == 0 and z == 0;
        }
    };

    const result = castThroughVoxels(
        Vec3.init(0.5, 0.5, 0.5),
        Vec3.init(1, 0, 0),
        10.0,
        Context,
        Context{},
        Context.isSolid,
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 3), result.?.x);
    try std.testing.expectEqual(@as(i32, 0), result.?.y);
    try std.testing.expectEqual(@as(i32, 0), result.?.z);
    try std.testing.expectEqual(Face.west, result.?.face);
}
