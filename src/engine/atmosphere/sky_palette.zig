const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const utils = @import("../math/utils.zig");
const Config = @import("config.zig").AtmosphereConfig;

pub const SkyColorPalette = struct {
    // Linear color storage
    day_sky: Vec3,
    day_horizon: Vec3,
    night_sky: Vec3,
    night_horizon: Vec3,
    dawn_sky: Vec3,
    dawn_horizon: Vec3,
    dusk_sky: Vec3,
    dusk_horizon: Vec3,

    day_sun: Vec3,
    dawn_sun: Vec3,
    dusk_sun: Vec3,
    night_sun: Vec3,

    pub fn init() SkyColorPalette {
        return .{
            .day_sky = Vec3.init(0.4, 0.65, 1.0).toLinear(),
            .day_horizon = Vec3.init(0.7, 0.8, 0.95).toLinear(),
            .night_sky = Vec3.init(0.02, 0.02, 0.08).toLinear(),
            .night_horizon = Vec3.init(0.05, 0.05, 0.12).toLinear(),
            .dawn_sky = Vec3.init(0.25, 0.3, 0.5).toLinear(),
            .dawn_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear(),
            // Dawn and dusk colors are currently symmetric (identical)
            // This is intentional for now but can be split later if needed
            .dusk_sky = Vec3.init(0.25, 0.3, 0.5).toLinear(),
            .dusk_horizon = Vec3.init(0.95, 0.55, 0.2).toLinear(),

            .day_sun = Vec3.init(1.0, 0.95, 0.9).toLinear(),
            .dawn_sun = Vec3.init(1.0, 0.85, 0.6).toLinear(),
            .dusk_sun = Vec3.init(1.0, 0.85, 0.6).toLinear(),
            .night_sun = Vec3.init(0.04, 0.04, 0.1).toLinear(),
        };
    }

    pub const SkyColors = struct {
        sky: Vec3,
        horizon: Vec3,
        sun: Vec3,
    };

    pub fn interpolate(self: *const SkyColorPalette, t: f32) SkyColors {
        var colors: SkyColors = undefined;

        if (t < Config.DAWN_START) {
            colors.sky = self.night_sky;
            colors.horizon = self.night_horizon;
            colors.sun = self.night_sun;
        } else if (t < Config.DAWN_END) {
            const blend = utils.smoothstep(Config.DAWN_START, Config.DAWN_END, t);
            colors.sky = utils.lerpVec3(self.night_sky, self.dawn_sky, blend);
            colors.horizon = utils.lerpVec3(self.night_horizon, self.dawn_horizon, blend);
            colors.sun = utils.lerpVec3(self.night_sun, self.dawn_sun, blend);
        } else if (t < Config.DAY_TRANSITION) {
            const blend = utils.smoothstep(Config.DAWN_END, Config.DAY_TRANSITION, t);
            colors.sky = utils.lerpVec3(self.dawn_sky, self.day_sky, blend);
            colors.horizon = utils.lerpVec3(self.dawn_horizon, self.day_horizon, blend);
            colors.sun = utils.lerpVec3(self.dawn_sun, self.day_sun, blend);
        } else if (t < Config.DUSK_START) {
            colors.sky = self.day_sky;
            colors.horizon = self.day_horizon;
            colors.sun = self.day_sun;
        } else if (t < Config.NIGHT_TRANSITION) {
            const blend = utils.smoothstep(Config.DUSK_START, Config.NIGHT_TRANSITION, t);
            colors.sky = utils.lerpVec3(self.day_sky, self.dusk_sky, blend);
            colors.horizon = utils.lerpVec3(self.day_horizon, self.dusk_horizon, blend);
            colors.sun = utils.lerpVec3(self.day_sun, self.dusk_sun, blend);
        } else if (t < Config.DUSK_END) {
            const blend = utils.smoothstep(Config.NIGHT_TRANSITION, Config.DUSK_END, t);
            colors.sky = utils.lerpVec3(self.dusk_sky, self.night_sky, blend);
            colors.horizon = utils.lerpVec3(self.dusk_horizon, self.night_horizon, blend);
            colors.sun = utils.lerpVec3(self.dusk_sun, self.night_sun, blend);
        } else {
            colors.sky = self.night_sky;
            colors.horizon = self.night_horizon;
            colors.sun = self.night_sun;
        }

        return colors;
    }
};
