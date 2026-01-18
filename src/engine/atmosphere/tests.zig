const std = @import("std");
const testing = std.testing;
const Atmosphere = @import("atmosphere.zig").Atmosphere;
const TimeSystem = @import("time.zig").TimeSystem;
const CelestialSystem = @import("celestial.zig").CelestialSystem;
const SkyColorPalette = @import("sky_palette.zig").SkyColorPalette;
const Config = @import("config.zig").AtmosphereConfig;
const Vec3 = @import("../math/vec3.zig").Vec3;

test "TimeSystem initialization and update" {
    var time = TimeSystem{};

    // Default start time is 0.25 (6 AM)
    try testing.expectEqual(@as(f32, 0.25), time.time_of_day);
    try testing.expectEqual(@as(f32, 6.0), time.getHours());

    // Update time
    // 20 ticks per second * time_scale
    // If we advance by 1.0s, we get 20 ticks
    // 20 ticks / 24000 ticks/day = 0.0008333 day fraction
    time.update(1.0);

    try testing.expect(time.world_ticks > 0);
    try testing.expect(time.time_of_day > 0.25);
}

test "TimeSystem setTimeOfDay" {
    var time = TimeSystem{};
    time.setTimeOfDay(0.5); // Noon

    try testing.expectEqual(@as(f32, 0.5), time.time_of_day);
    try testing.expectEqual(@as(u64, 12000), time.world_ticks); // 24000 * 0.5
}

test "CelestialSystem updates sun direction" {
    var celestial = CelestialSystem{};

    // Noon (0.5) -> Sun should be at zenith (0, 1, 0) roughly (depending on tilt)
    // sun_angle = 0.5 * 2PI = PI
    // cos(PI) = -1, sin(PI) = 0
    // x = 0
    // y = -(-1) * cos(tilt) = cos(tilt)
    // z = -(-1) * sin(tilt) = sin(tilt)
    // It seems the calculation puts sun at +Y roughly.

    celestial.update(0.5);

    const sun_dir = celestial.sun_dir;
    try testing.expectApproxEqAbs(@as(f32, 0), sun_dir.x, 0.001);
    try testing.expect(sun_dir.y > 0); // Should be high up
}

test "Atmosphere initialization" {
    const atmosphere = Atmosphere.init();
    try testing.expectEqual(@as(f32, 0.25), atmosphere.time.time_of_day);
}

test "Atmosphere color interpolation at noon" {
    var atmosphere = Atmosphere.init();
    atmosphere.setTimeOfDay(0.5); // Noon

    // Check sun intensity is 1.0
    try testing.expectEqual(@as(f32, 1.0), atmosphere.sun_intensity);

    // Check colors match day palette
    const day_sky = Vec3.init(0.4, 0.65, 1.0).toLinear();

    try testing.expectApproxEqAbs(day_sky.x, atmosphere.sky_color.x, 0.001);
    try testing.expectApproxEqAbs(day_sky.y, atmosphere.sky_color.y, 0.001);
    try testing.expectApproxEqAbs(day_sky.z, atmosphere.sky_color.z, 0.001);
}

test "Atmosphere color interpolation at midnight" {
    var atmosphere = Atmosphere.init();
    atmosphere.setTimeOfDay(0.0); // Midnight

    // Check sun intensity is 0.0
    try testing.expectEqual(@as(f32, 0.0), atmosphere.sun_intensity);
}
