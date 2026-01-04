const std = @import("std");
const math = std.math;

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }

    pub fn splat(v: f32) Vec4 {
        return .{ .x = v, .y = v, .z = v, .w = v };
    }

    pub fn zero() Vec4 {
        return .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    }

    pub fn add(self: Vec4, other: Vec4) Vec4 {
        return .{
            .x = self.x + other.x,
            .y = self.y + other.y,
            .z = self.z + other.z,
            .w = self.w + other.w,
        };
    }

    pub fn scale(self: Vec4, scalar: f32) Vec4 {
        return .{
            .x = self.x * scalar,
            .y = self.y * scalar,
            .z = self.z * scalar,
            .w = self.w * scalar,
        };
    }

    pub fn toArray(self: Vec4) [4]f32 {
        return .{ self.x, self.y, self.z, self.w };
    }
};
