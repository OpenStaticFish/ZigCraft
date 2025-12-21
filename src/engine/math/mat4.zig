const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;

/// Column-major 4x4 matrix for OpenGL compatibility
pub const Mat4 = struct {
    /// Stored as columns: data[col][row]
    data: [4][4]f32,

    pub const identity = Mat4{
        .data = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
    };

    pub const zero = Mat4{
        .data = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
        },
    };

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var result = Mat4.zero;
        for (0..4) |col| {
            for (0..4) |row| {
                var sum: f32 = 0;
                for (0..4) |k| {
                    sum += a.data[k][row] * b.data[col][k];
                }
                result.data[col][row] = sum;
            }
        }
        return result;
    }

    pub fn perspective(fov_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = std.math.tan(fov_radians / 2.0);
        var result = Mat4.zero;

        result.data[0][0] = 1.0 / (aspect * tan_half_fov);
        result.data[1][1] = 1.0 / tan_half_fov;
        result.data[2][2] = -(far + near) / (far - near);
        result.data[2][3] = -1.0;
        result.data[3][2] = -(2.0 * far * near) / (far - near);

        return result;
    }

    /// Perspective projection with reverse-Z for better depth precision at distance
    /// Maps near plane to z=1 and far plane to z=0 (reversed from standard)
    /// Use with glDepthFunc(GL_GEQUAL) and glClearDepth(0.0)
    pub fn perspectiveReverseZ(fov_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = std.math.tan(fov_radians / 2.0);
        var result = Mat4.zero;

        result.data[0][0] = 1.0 / (aspect * tan_half_fov);
        result.data[1][1] = 1.0 / tan_half_fov;
        // Reverse-Z: swap near and far in depth calculation
        result.data[2][2] = near / (far - near);
        result.data[2][3] = -1.0;
        result.data[3][2] = (far * near) / (far - near);

        return result;
    }

    pub fn orthographic(left: f32, right_val: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
        var result = Mat4.zero;

        result.data[0][0] = 2.0 / (right_val - left);
        result.data[1][1] = 2.0 / (top - bottom);
        result.data[2][2] = -2.0 / (far - near);
        result.data[3][0] = -(right_val + left) / (right_val - left);
        result.data[3][1] = -(top + bottom) / (top - bottom);
        result.data[3][2] = -(far + near) / (far - near);
        result.data[3][3] = 1.0;

        return result;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, world_up: Vec3) Mat4 {
        const f = target.sub(eye).normalize(); // Forward
        const r = f.cross(world_up).normalize(); // Right
        const u = r.cross(f); // Up

        var result = Mat4.identity;

        result.data[0][0] = r.x;
        result.data[1][0] = r.y;
        result.data[2][0] = r.z;

        result.data[0][1] = u.x;
        result.data[1][1] = u.y;
        result.data[2][1] = u.z;

        result.data[0][2] = -f.x;
        result.data[1][2] = -f.y;
        result.data[2][2] = -f.z;

        result.data[3][0] = -r.dot(eye);
        result.data[3][1] = -u.dot(eye);
        result.data[3][2] = f.dot(eye);

        return result;
    }

    pub fn translate(offset: Vec3) Mat4 {
        var result = Mat4.identity;
        result.data[3][0] = offset.x;
        result.data[3][1] = offset.y;
        result.data[3][2] = offset.z;
        return result;
    }

    pub fn scale(s: Vec3) Mat4 {
        var result = Mat4.identity;
        result.data[0][0] = s.x;
        result.data[1][1] = s.y;
        result.data[2][2] = s.z;
        return result;
    }

    pub fn rotateX(angle: f32) Mat4 {
        const c = std.math.cos(angle);
        const s = std.math.sin(angle);
        var result = Mat4.identity;
        result.data[1][1] = c;
        result.data[1][2] = s;
        result.data[2][1] = -s;
        result.data[2][2] = c;
        return result;
    }

    pub fn rotateY(angle: f32) Mat4 {
        const c = std.math.cos(angle);
        const s = std.math.sin(angle);
        var result = Mat4.identity;
        result.data[0][0] = c;
        result.data[0][2] = -s;
        result.data[2][0] = s;
        result.data[2][2] = c;
        return result;
    }

    pub fn rotateZ(angle: f32) Mat4 {
        const c = std.math.cos(angle);
        const s = std.math.sin(angle);
        var result = Mat4.identity;
        result.data[0][0] = c;
        result.data[0][1] = s;
        result.data[1][0] = -s;
        result.data[1][1] = c;
        return result;
    }

    /// Transform a Vec3 point (w=1)
    pub fn transformPoint(self: Mat4, v: Vec3) Vec3 {
        const x = self.data[0][0] * v.x + self.data[1][0] * v.y + self.data[2][0] * v.z + self.data[3][0];
        const y = self.data[0][1] * v.x + self.data[1][1] * v.y + self.data[2][1] * v.z + self.data[3][1];
        const z = self.data[0][2] * v.x + self.data[1][2] * v.y + self.data[2][2] * v.z + self.data[3][2];
        const w = self.data[0][3] * v.x + self.data[1][3] * v.y + self.data[2][3] * v.z + self.data[3][3];

        if (w != 0 and w != 1) {
            return Vec3.init(x / w, y / w, z / w);
        }
        return Vec3.init(x, y, z);
    }

    /// Transform a Vec3 direction (w=0)
    pub fn transformDirection(self: Mat4, v: Vec3) Vec3 {
        return Vec3.init(
            self.data[0][0] * v.x + self.data[1][0] * v.y + self.data[2][0] * v.z,
            self.data[0][1] * v.x + self.data[1][1] * v.y + self.data[2][1] * v.z,
            self.data[0][2] * v.x + self.data[1][2] * v.y + self.data[2][2] * v.z,
        );
    }

    /// Get raw pointer for OpenGL uniform upload
    pub fn ptr(self: *const Mat4) [*]const f32 {
        return @ptrCast(&self.data);
    }

    /// Compute the inverse of this matrix
    /// Returns identity if matrix is singular (determinant near zero)
    pub fn inverse(self: Mat4) Mat4 {
        const m = self.data;

        // Calculate cofactors for first row (used for determinant and first column of adjugate)
        const c00 = m[1][1] * (m[2][2] * m[3][3] - m[3][2] * m[2][3]) -
            m[2][1] * (m[1][2] * m[3][3] - m[3][2] * m[1][3]) +
            m[3][1] * (m[1][2] * m[2][3] - m[2][2] * m[1][3]);

        const c01 = -(m[1][0] * (m[2][2] * m[3][3] - m[3][2] * m[2][3]) -
            m[2][0] * (m[1][2] * m[3][3] - m[3][2] * m[1][3]) +
            m[3][0] * (m[1][2] * m[2][3] - m[2][2] * m[1][3]));

        const c02 = m[1][0] * (m[2][1] * m[3][3] - m[3][1] * m[2][3]) -
            m[2][0] * (m[1][1] * m[3][3] - m[3][1] * m[1][3]) +
            m[3][0] * (m[1][1] * m[2][3] - m[2][1] * m[1][3]);

        const c03 = -(m[1][0] * (m[2][1] * m[3][2] - m[3][1] * m[2][2]) -
            m[2][0] * (m[1][1] * m[3][2] - m[3][1] * m[1][2]) +
            m[3][0] * (m[1][1] * m[2][2] - m[2][1] * m[1][2]));

        // Determinant using first row
        const det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02 + m[0][3] * c03;

        // Check for singular matrix
        if (@abs(det) < 1e-10) {
            return Mat4.identity;
        }

        const inv_det = 1.0 / det;

        // Calculate remaining cofactors and build inverse (transposed adjugate / determinant)
        var result: Mat4 = undefined;

        result.data[0][0] = c00 * inv_det;
        result.data[0][1] = c01 * inv_det;
        result.data[0][2] = c02 * inv_det;
        result.data[0][3] = c03 * inv_det;

        result.data[1][0] = -(m[0][1] * (m[2][2] * m[3][3] - m[3][2] * m[2][3]) -
            m[2][1] * (m[0][2] * m[3][3] - m[3][2] * m[0][3]) +
            m[3][1] * (m[0][2] * m[2][3] - m[2][2] * m[0][3])) * inv_det;

        result.data[1][1] = (m[0][0] * (m[2][2] * m[3][3] - m[3][2] * m[2][3]) -
            m[2][0] * (m[0][2] * m[3][3] - m[3][2] * m[0][3]) +
            m[3][0] * (m[0][2] * m[2][3] - m[2][2] * m[0][3])) * inv_det;

        result.data[1][2] = -(m[0][0] * (m[2][1] * m[3][3] - m[3][1] * m[2][3]) -
            m[2][0] * (m[0][1] * m[3][3] - m[3][1] * m[0][3]) +
            m[3][0] * (m[0][1] * m[2][3] - m[2][1] * m[0][3])) * inv_det;

        result.data[1][3] = (m[0][0] * (m[2][1] * m[3][2] - m[3][1] * m[2][2]) -
            m[2][0] * (m[0][1] * m[3][2] - m[3][1] * m[0][2]) +
            m[3][0] * (m[0][1] * m[2][2] - m[2][1] * m[0][2])) * inv_det;

        result.data[2][0] = (m[0][1] * (m[1][2] * m[3][3] - m[3][2] * m[1][3]) -
            m[1][1] * (m[0][2] * m[3][3] - m[3][2] * m[0][3]) +
            m[3][1] * (m[0][2] * m[1][3] - m[1][2] * m[0][3])) * inv_det;

        result.data[2][1] = -(m[0][0] * (m[1][2] * m[3][3] - m[3][2] * m[1][3]) -
            m[1][0] * (m[0][2] * m[3][3] - m[3][2] * m[0][3]) +
            m[3][0] * (m[0][2] * m[1][3] - m[1][2] * m[0][3])) * inv_det;

        result.data[2][2] = (m[0][0] * (m[1][1] * m[3][3] - m[3][1] * m[1][3]) -
            m[1][0] * (m[0][1] * m[3][3] - m[3][1] * m[0][3]) +
            m[3][0] * (m[0][1] * m[1][3] - m[1][1] * m[0][3])) * inv_det;

        result.data[2][3] = -(m[0][0] * (m[1][1] * m[3][2] - m[3][1] * m[1][2]) -
            m[1][0] * (m[0][1] * m[3][2] - m[3][1] * m[0][2]) +
            m[3][0] * (m[0][1] * m[1][2] - m[1][1] * m[0][2])) * inv_det;

        result.data[3][0] = -(m[0][1] * (m[1][2] * m[2][3] - m[2][2] * m[1][3]) -
            m[1][1] * (m[0][2] * m[2][3] - m[2][2] * m[0][3]) +
            m[2][1] * (m[0][2] * m[1][3] - m[1][2] * m[0][3])) * inv_det;

        result.data[3][1] = (m[0][0] * (m[1][2] * m[2][3] - m[2][2] * m[1][3]) -
            m[1][0] * (m[0][2] * m[2][3] - m[2][2] * m[0][3]) +
            m[2][0] * (m[0][2] * m[1][3] - m[1][2] * m[0][3])) * inv_det;

        result.data[3][2] = -(m[0][0] * (m[1][1] * m[2][3] - m[2][1] * m[1][3]) -
            m[1][0] * (m[0][1] * m[2][3] - m[2][1] * m[0][3]) +
            m[2][0] * (m[0][1] * m[1][3] - m[1][1] * m[0][3])) * inv_det;

        result.data[3][3] = (m[0][0] * (m[1][1] * m[2][2] - m[2][1] * m[1][2]) -
            m[1][0] * (m[0][1] * m[2][2] - m[2][1] * m[0][2]) +
            m[2][0] * (m[0][1] * m[1][2] - m[1][1] * m[0][2])) * inv_det;

        return result;
    }
};
