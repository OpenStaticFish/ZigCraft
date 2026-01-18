const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const utils = @import("../math/utils.zig");
const TimeSystem = @import("time.zig").TimeSystem;
const CelestialSystem = @import("celestial.zig").CelestialSystem;
const SkyColorPalette = @import("sky_palette.zig").SkyColorPalette;
const Config = @import("config.zig").AtmosphereConfig;

pub const Atmosphere = struct {
    time: TimeSystem,
    celestial: CelestialSystem,
    palette: SkyColorPalette,

    // Current State
    sun_intensity: f32 = 1.0,
    moon_intensity: f32 = 0.0,
    ambient_intensity: f32 = 0.3,
    sky_color: Vec3 = Vec3.init(0, 0, 0),
    horizon_color: Vec3 = Vec3.init(0, 0, 0),
    sun_color: Vec3 = Vec3.init(0, 0, 0),
    fog_color: Vec3 = Vec3.init(0, 0, 0),
    fog_density: f32 = Config.FOG_DENSITY_MAX,
    fog_enabled: bool = true,

    pub fn init() Atmosphere {
        return .{
            .time = TimeSystem{},
            .celestial = CelestialSystem{},
            .palette = SkyColorPalette.init(),
        };
    }

    pub fn update(self: *Atmosphere, delta_time: f32) void {
        self.time.update(delta_time);

        const t = self.time.time_of_day;
        self.celestial.update(t);

        // Update intensities
        if (t < Config.DAWN_START) {
            self.sun_intensity = 0;
        } else if (t < Config.DAWN_END) {
            self.sun_intensity = utils.smoothstep(Config.DAWN_START, Config.DAWN_END, t);
        } else if (t < Config.DUSK_START) {
            self.sun_intensity = 1.0;
        } else if (t < Config.DUSK_END) {
            self.sun_intensity = 1.0 - utils.smoothstep(Config.DUSK_START, Config.DUSK_END, t);
        } else {
            self.sun_intensity = 0;
        }

        self.moon_intensity = (1.0 - self.sun_intensity) * Config.MOON_INTENSITY_FACTOR;
        self.ambient_intensity = std.math.lerp(Config.AMBIENT_NIGHT, Config.AMBIENT_DAY, self.sun_intensity);

        // Update colors
        const colors = self.palette.interpolate(t);
        self.sky_color = colors.sky;
        self.horizon_color = colors.horizon;
        self.sun_color = colors.sun;

        self.fog_color = self.horizon_color;
        self.fog_density = std.math.lerp(Config.FOG_DENSITY_MAX, Config.FOG_DENSITY_MIN, self.sun_intensity);
    }

    // API compatibility wrappers - provided to maintain interface with legacy code
    // while forwarding to the new subsystem components.

    /// Returns the current time of day in hours (0.0 - 24.0)
    pub fn getHours(self: *const Atmosphere) f32 {
        return self.time.getHours();
    }

    /// Sets the time of day and immediately updates atmosphere state
    pub fn setTimeOfDay(self: *Atmosphere, t: f32) void {
        self.time.setTimeOfDay(t);
        // Force update to refresh state immediately
        // We pass 0 delta time just to re-run the logic
        self.update(0);
    }

    /// Returns the primary light factor (max of sun or moon intensity) for block lighting
    pub fn getSkyLightFactor(self: *const Atmosphere) f32 {
        return @max(self.sun_intensity, self.moon_intensity);
    }
};
