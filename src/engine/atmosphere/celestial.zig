const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;

pub const CelestialSystem = struct {
    orbit_tilt: f32 = 0.35,
    sun_dir: Vec3 = Vec3.init(0, 1, 0),
    moon_dir: Vec3 = Vec3.init(0, -1, 0),

    pub fn update(self: *CelestialSystem, time_of_day: f32) void {
        const sun_angle = time_of_day * std.math.tau;
        const cos_angle = @cos(sun_angle);
        const sin_angle = @sin(sun_angle);
        const cos_tilt = @cos(self.orbit_tilt);
        const sin_tilt = @sin(self.orbit_tilt);

        self.sun_dir = Vec3.init(
            sin_angle,
            -cos_angle * cos_tilt,
            -cos_angle * sin_tilt,
        ).normalize();
        self.moon_dir = self.sun_dir.scale(-1);
    }
};
