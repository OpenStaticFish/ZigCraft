const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;

pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub fn lerpVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return Vec3.init(
        std.math.lerp(a.x, b.x, t),
        std.math.lerp(a.y, b.y, t),
        std.math.lerp(a.z, b.z, t),
    );
}
