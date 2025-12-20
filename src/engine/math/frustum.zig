//! View Frustum for culling objects outside camera view.

const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;
const Mat4 = @import("mat4.zig").Mat4;
const AABB = @import("aabb.zig").AABB;

/// A plane in 3D space (ax + by + cz + d = 0)
pub const Plane = struct {
    normal: Vec3,
    distance: f32,

    pub fn init(normal: Vec3, distance: f32) Plane {
        return .{ .normal = normal, .distance = distance };
    }

    /// Signed distance from point to plane (positive = in front)
    pub fn signedDistance(self: Plane, point: Vec3) f32 {
        return self.normal.dot(point) + self.distance;
    }

    /// Normalize plane coefficients
    pub fn normalize(self: Plane) Plane {
        const len = self.normal.length();
        if (len < 0.0001) return self;
        return .{
            .normal = self.normal.scale(1.0 / len),
            .distance = self.distance / len,
        };
    }
};

/// View frustum composed of 6 planes
pub const Frustum = struct {
    planes: [6]Plane, // left, right, bottom, top, near, far

    pub const Side = enum(u3) {
        left = 0,
        right = 1,
        bottom = 2,
        top = 3,
        near = 4,
        far = 5,
    };

    /// Extract frustum planes from a view-projection matrix
    /// Uses the Gribb/Hartmann method
    pub fn fromViewProj(vp: Mat4) Frustum {
        const m = vp.data;

        // Each row of the matrix contributes to plane extraction
        // m[row][col] - remember Mat4 is row-major
        var planes: [6]Plane = undefined;

        // Left: row3 + row0
        planes[0] = Plane.init(
            Vec3.init(m[0][3] + m[0][0], m[1][3] + m[1][0], m[2][3] + m[2][0]),
            m[3][3] + m[3][0],
        ).normalize();

        // Right: row3 - row0
        planes[1] = Plane.init(
            Vec3.init(m[0][3] - m[0][0], m[1][3] - m[1][0], m[2][3] - m[2][0]),
            m[3][3] - m[3][0],
        ).normalize();

        // Bottom: row3 + row1
        planes[2] = Plane.init(
            Vec3.init(m[0][3] + m[0][1], m[1][3] + m[1][1], m[2][3] + m[2][1]),
            m[3][3] + m[3][1],
        ).normalize();

        // Top: row3 - row1
        planes[3] = Plane.init(
            Vec3.init(m[0][3] - m[0][1], m[1][3] - m[1][1], m[2][3] - m[2][1]),
            m[3][3] - m[3][1],
        ).normalize();

        // Near: row3 + row2
        planes[4] = Plane.init(
            Vec3.init(m[0][3] + m[0][2], m[1][3] + m[1][2], m[2][3] + m[2][2]),
            m[3][3] + m[3][2],
        ).normalize();

        // Far: row3 - row2
        planes[5] = Plane.init(
            Vec3.init(m[0][3] - m[0][2], m[1][3] - m[1][2], m[2][3] - m[2][2]),
            m[3][3] - m[3][2],
        ).normalize();

        return .{ .planes = planes };
    }

    /// Check if a point is inside the frustum
    pub fn containsPoint(self: Frustum, point: Vec3) bool {
        for (self.planes) |plane| {
            if (plane.signedDistance(point) < 0) {
                return false;
            }
        }
        return true;
    }

    /// Check if a sphere intersects the frustum
    pub fn intersectsSphere(self: Frustum, center: Vec3, radius: f32) bool {
        for (self.planes) |plane| {
            if (plane.signedDistance(center) < -radius) {
                return false;
            }
        }
        return true;
    }

    /// Check if an AABB intersects the frustum
    /// Uses the "get positive vertex" optimization
    pub fn intersectsAABB(self: Frustum, aabb: AABB) bool {
        for (self.planes) |plane| {
            // Get the vertex most in the direction of the plane normal (p-vertex)
            const p = Vec3.init(
                if (plane.normal.x >= 0) aabb.max.x else aabb.min.x,
                if (plane.normal.y >= 0) aabb.max.y else aabb.min.y,
                if (plane.normal.z >= 0) aabb.max.z else aabb.min.z,
            );

            // If p-vertex is outside, the whole box is outside
            if (plane.signedDistance(p) < 0) {
                return false;
            }
        }
        return true;
    }

    /// Check if a chunk (given by chunk coordinates) intersects the frustum
    /// Chunks are 16x256x16 blocks
    pub fn intersectsChunk(self: Frustum, chunk_x: i32, chunk_z: i32) bool {
        const CHUNK_SIZE_X: f32 = 16.0;
        const CHUNK_SIZE_Y: f32 = 256.0;
        const CHUNK_SIZE_Z: f32 = 16.0;

        const world_x: f32 = @floatFromInt(chunk_x * 16);
        const world_z: f32 = @floatFromInt(chunk_z * 16);

        const aabb = AABB.init(
            Vec3.init(world_x, 0, world_z),
            Vec3.init(world_x + CHUNK_SIZE_X, CHUNK_SIZE_Y, world_z + CHUNK_SIZE_Z),
        );

        return self.intersectsAABB(aabb);
    }
};
