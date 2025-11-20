const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(a: Vec3) f32 {
        return std.math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        if (len == 0) return a;
        return scale(a, 1.0 / len);
    }
};

pub const Mat4 = struct {
    data: [4][4]f32,

    pub fn identity() Mat4 {
        return .{
            .data = .{
                .{ 1, 0, 0, 0 },
                .{ 0, 1, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ 0, 0, 0, 1 },
            },
        };
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var res = Mat4.identity();
        for (0..4) |r| {
            for (0..4) |c_idx| {
                res.data[r][c_idx] =
                    a.data[r][0] * b.data[0][c_idx] +
                    a.data[r][1] * b.data[1][c_idx] +
                    a.data[r][2] * b.data[2][c_idx] +
                    a.data[r][3] * b.data[3][c_idx];
            }
        }
        return res;
    }

    pub fn perspective(fov_radians: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const tan_half_fov = std.math.tan(fov_radians / 2.0);
        var res = Mat4.identity();

        // Zero out to be safe
        for (0..4) |i| @memset(&res.data[i], 0);

        res.data[0][0] = 1.0 / (aspect * tan_half_fov);
        res.data[1][1] = 1.0 / tan_half_fov;
        res.data[2][2] = -(far + near) / (far - near);
        res.data[2][3] = -(2.0 * far * near) / (far - near);
        res.data[3][2] = -1.0;
        return res;
    }

    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);

        var res = Mat4.identity();
        res.data[0][0] = s.x;
        res.data[0][1] = s.y;
        res.data[0][2] = s.z;
        res.data[1][0] = u.x;
        res.data[1][1] = u.y;
        res.data[1][2] = u.z;
        res.data[2][0] = -f.x;
        res.data[2][1] = -f.y;
        res.data[2][2] = -f.z;

        res.data[0][3] = -s.dot(eye);
        res.data[1][3] = -u.dot(eye);
        res.data[2][3] = f.dot(eye);

        return res;
    }

    pub fn translate(x: f32, y: f32, z: f32) Mat4 {
        var res = Mat4.identity();
        res.data[0][3] = x;
        res.data[1][3] = y;
        res.data[2][3] = z;
        return res;
    }
};
