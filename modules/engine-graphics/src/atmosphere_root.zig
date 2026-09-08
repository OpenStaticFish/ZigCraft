pub const atmosphere = @import("atmosphere/atmosphere.zig");

test {
    _ = @import("atmosphere_test_root.zig");
}
pub const atmosphere_celestial = @import("atmosphere/celestial.zig");
pub const atmosphere_config = @import("atmosphere/config.zig");
pub const atmosphere_sky_palette = @import("atmosphere/sky_palette.zig");
pub const atmosphere_tests = @import("atmosphere/tests.zig");
pub const atmosphere_time = @import("atmosphere/time.zig");
pub const atmosphere_system = @import("atmosphere_system.zig");

pub const Atmosphere = atmosphere.Atmosphere;
pub const AtmosphereSystem = atmosphere_system.AtmosphereSystem;
