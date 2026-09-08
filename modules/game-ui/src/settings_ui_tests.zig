const std = @import("std");
const testing = std.testing;

const settings_ui = @import("settings_ui.zig");
const Settings = @import("game-core").settings.Settings;

const MockRenderSettings = struct {
    anisotropic_filtering: u8 = 0,
    textures_enabled: bool = false,
    vsync: bool = false,
    volumetric_density: f32 = 0.0,
    fxaa_enabled: bool = false,
    taa_blend_factor: f32 = 0.0,
    taa_velocity_rejection: f32 = 0.0,
    bloom_enabled: bool = false,
    bloom_intensity: f32 = 0.0,
    vignette_enabled: bool = false,
    vignette_intensity: f32 = 0.0,
    film_grain_enabled: bool = false,
    film_grain_intensity: f32 = 0.0,
    shadow_resolution: u32 = 0,
    wireframe_enabled: bool = false,
    debug_shadow_view: bool = false,
    shadow_debug_channel: u32 = 0,
    msaa_samples: u8 = 0,
    dynamic_resolution_enabled: bool = false,
    dynamic_resolution_min_scale: f32 = 0.0,
    dynamic_resolution_max_scale: f32 = 0.0,
    target_fps: u32 = 0,

    pub fn setAnisotropicFiltering(self: *@This(), value: u8) void {
        self.anisotropic_filtering = value;
    }

    pub fn setTexturesEnabled(self: *@This(), value: bool) void {
        self.textures_enabled = value;
    }

    pub fn setVSync(self: *@This(), value: bool) void {
        self.vsync = value;
    }

    pub fn setVolumetricDensity(self: *@This(), value: f32) void {
        self.volumetric_density = value;
    }

    pub fn setFXAA(self: *@This(), value: bool) void {
        self.fxaa_enabled = value;
    }

    pub fn setTAABlendFactor(self: *@This(), value: f32) void {
        self.taa_blend_factor = value;
    }

    pub fn setTAAVelocityRejection(self: *@This(), value: f32) void {
        self.taa_velocity_rejection = value;
    }

    pub fn setBloom(self: *@This(), value: bool) void {
        self.bloom_enabled = value;
    }

    pub fn setBloomIntensity(self: *@This(), value: f32) void {
        self.bloom_intensity = value;
    }

    pub fn setVignetteEnabled(self: *@This(), value: bool) void {
        self.vignette_enabled = value;
    }

    pub fn setVignetteIntensity(self: *@This(), value: f32) void {
        self.vignette_intensity = value;
    }

    pub fn setFilmGrainEnabled(self: *@This(), value: bool) void {
        self.film_grain_enabled = value;
    }

    pub fn setFilmGrainIntensity(self: *@This(), value: f32) void {
        self.film_grain_intensity = value;
    }

    pub fn setShadowResolution(self: *@This(), value: u32) void {
        self.shadow_resolution = value;
    }

    pub fn setWireframe(self: *@This(), value: bool) void {
        self.wireframe_enabled = value;
    }

    pub fn setDebugShadowView(self: *@This(), value: bool) void {
        self.debug_shadow_view = value;
    }

    pub fn setShadowDebugChannel(self: *@This(), value: u32) void {
        self.shadow_debug_channel = value;
    }

    pub fn setMSAA(self: *@This(), value: u8) void {
        self.msaa_samples = value;
    }

    pub fn setDynamicResolution(self: *@This(), enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        self.dynamic_resolution_enabled = enabled;
        self.dynamic_resolution_min_scale = min_scale;
        self.dynamic_resolution_max_scale = max_scale;
        self.target_fps = target_fps;
    }
};

test "rowHighlight highlights enabled bool settings" {
    try testing.expect(settings_ui.rowHighlight("textures_enabled", true));
}

test "rowHighlight does not highlight disabled bool settings" {
    try testing.expect(!settings_ui.rowHighlight("textures_enabled", false));
}

test "rowHighlight ignores non-bool values" {
    try testing.expect(!settings_ui.rowHighlight("shadow_quality", @as(u32, 2)));
}

test "getLPVQualityLegend labels fast preset" {
    try testing.expectEqualStrings("GRID16  ITER2  TICK8", settings_ui.getLPVQualityLegend(0));
}

test "getLPVQualityLegend labels balanced preset by default" {
    try testing.expectEqualStrings("GRID32  ITER3  TICK6", settings_ui.getLPVQualityLegend(1));
    try testing.expectEqualStrings("GRID32  ITER3  TICK6", settings_ui.getLPVQualityLegend(99));
}

test "getLPVQualityLegend labels quality preset" {
    try testing.expectEqualStrings("GRID64  ITER5  TICK3", settings_ui.getLPVQualityLegend(2));
}

test "applyChangedSetting forwards anisotropic filtering" {
    var settings = Settings{ .anisotropic_filtering = 8 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("anisotropic_filtering", &settings, &rs);

    try testing.expectEqual(@as(u8, 8), rs.anisotropic_filtering);
}

test "applyChangedSetting forwards texture toggle" {
    var settings = Settings{ .textures_enabled = true };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("textures_enabled", &settings, &rs);

    try testing.expect(rs.textures_enabled);
}

test "applyChangedSetting forwards vsync toggle" {
    var settings = Settings{ .vsync = true };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("vsync", &settings, &rs);

    try testing.expect(rs.vsync);
}

test "applyChangedSetting forwards volumetric density" {
    var settings = Settings{ .volumetric_density = 0.125 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("volumetric_density", &settings, &rs);

    try testing.expectEqual(@as(f32, 0.125), rs.volumetric_density);
}

test "applyChangedSetting disables FXAA when TAA is enabled" {
    var settings = Settings{ .taa_enabled = true, .fxaa_enabled = true };
    var rs = MockRenderSettings{ .fxaa_enabled = true };

    settings_ui.applyChangedSetting("taa_enabled", &settings, &rs);

    try testing.expect(!settings.fxaa_enabled);
    try testing.expect(!rs.fxaa_enabled);
}

test "applyChangedSetting rejects FXAA when TAA remains enabled" {
    var settings = Settings{ .taa_enabled = true, .fxaa_enabled = true };
    var rs = MockRenderSettings{ .fxaa_enabled = true };

    settings_ui.applyChangedSetting("fxaa_enabled", &settings, &rs);

    try testing.expect(!settings.fxaa_enabled);
    try testing.expect(!rs.fxaa_enabled);
}

test "applyChangedSetting allows FXAA when TAA is disabled" {
    var settings = Settings{ .taa_enabled = false, .fxaa_enabled = true };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("fxaa_enabled", &settings, &rs);

    try testing.expect(rs.fxaa_enabled);
}

test "applyChangedSetting forwards TAA tuning values" {
    var settings = Settings{ .taa_blend_factor = 0.75, .taa_velocity_rejection = 0.04 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("taa_blend_factor", &settings, &rs);
    settings_ui.applyChangedSetting("taa_velocity_rejection", &settings, &rs);

    try testing.expectEqual(@as(f32, 0.75), rs.taa_blend_factor);
    try testing.expectEqual(@as(f32, 0.04), rs.taa_velocity_rejection);
}

test "applyChangedSetting forwards bloom settings" {
    var settings = Settings{ .bloom_enabled = true, .bloom_intensity = 0.8 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("bloom_enabled", &settings, &rs);
    settings_ui.applyChangedSetting("bloom_intensity", &settings, &rs);

    try testing.expect(rs.bloom_enabled);
    try testing.expectEqual(@as(f32, 0.8), rs.bloom_intensity);
}

test "applyChangedSetting forwards vignette settings" {
    var settings = Settings{ .vignette_enabled = true, .vignette_intensity = 0.6 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("vignette_enabled", &settings, &rs);
    settings_ui.applyChangedSetting("vignette_intensity", &settings, &rs);

    try testing.expect(rs.vignette_enabled);
    try testing.expectEqual(@as(f32, 0.6), rs.vignette_intensity);
}

test "applyChangedSetting forwards film grain settings" {
    var settings = Settings{ .film_grain_enabled = true, .film_grain_intensity = 0.25 };
    var rs = MockRenderSettings{};

    settings_ui.applyChangedSetting("film_grain_enabled", &settings, &rs);
    settings_ui.applyChangedSetting("film_grain_intensity", &settings, &rs);

    try testing.expect(rs.film_grain_enabled);
    try testing.expectEqual(@as(f32, 0.25), rs.film_grain_intensity);
}

test "applyPresetSideEffects forwards the complete renderer configuration" {
    var settings = Settings{
        .anisotropic_filtering = 4,
        .textures_enabled = true,
        .vsync = true,
        .wireframe_enabled = true,
        .debug_shadow_cascade_index = true,
        .shadow_quality = 3,
        .msaa_samples = 8,
        .taa_enabled = true,
        .fxaa_enabled = true,
        .taa_blend_factor = 0.5,
        .taa_velocity_rejection = 0.03,
        .bloom_enabled = true,
        .bloom_intensity = 0.8,
        .vignette_enabled = true,
        .vignette_intensity = 0.6,
        .film_grain_enabled = true,
        .film_grain_intensity = 0.25,
        .volumetric_density = 0.125,
        .dynamic_resolution_enabled = true,
        .dynamic_resolution_min_scale = 0.6,
        .dynamic_resolution_max_scale = 0.9,
        .target_fps = 144,
    };
    var rs = MockRenderSettings{ .fxaa_enabled = true };

    settings_ui.applyPresetSideEffects(&settings, &rs);

    try testing.expect(!settings.fxaa_enabled);
    try testing.expectEqualDeep(MockRenderSettings{
        .anisotropic_filtering = 4,
        .textures_enabled = true,
        .vsync = true,
        .wireframe_enabled = true,
        .debug_shadow_view = true,
        .shadow_debug_channel = 2,
        .shadow_resolution = 4096,
        .msaa_samples = 8,
        .fxaa_enabled = false,
        .taa_blend_factor = 0.5,
        .taa_velocity_rejection = 0.03,
        .bloom_enabled = true,
        .bloom_intensity = 0.8,
        .vignette_enabled = true,
        .vignette_intensity = 0.6,
        .film_grain_enabled = true,
        .film_grain_intensity = 0.25,
        .volumetric_density = 0.125,
        .dynamic_resolution_enabled = true,
        .dynamic_resolution_min_scale = 0.6,
        .dynamic_resolution_max_scale = 0.9,
        .target_fps = 144,
    }, rs);
}

test "applyChangedSetting forwards quality debug and each dynamic resolution edit" {
    var settings = Settings{
        .wireframe_enabled = true,
        .msaa_samples = 2,
        .shadow_quality = 1,
        .debug_block_light_active = true,
        .dynamic_resolution_enabled = true,
        .dynamic_resolution_min_scale = 0.5,
        .dynamic_resolution_max_scale = 0.8,
        .target_fps = 120,
    };
    var rs = MockRenderSettings{};
    settings_ui.applyChangedSetting("wireframe_enabled", &settings, &rs);
    settings_ui.applyChangedSetting("msaa_samples", &settings, &rs);
    settings_ui.applyChangedSetting("shadow_quality", &settings, &rs);
    settings_ui.applyChangedSetting("debug_block_light_active", &settings, &rs);
    try testing.expectEqualDeep(MockRenderSettings{
        .wireframe_enabled = true,
        .msaa_samples = 2,
        .shadow_resolution = 1536,
        .debug_shadow_view = true,
        .shadow_debug_channel = 9,
    }, rs);

    inline for (.{ "dynamic_resolution_enabled", "dynamic_resolution_min_scale", "dynamic_resolution_max_scale", "target_fps" }) |name| {
        rs = .{};
        settings_ui.applyChangedSetting(name, &settings, &rs);
        try testing.expectEqualDeep(MockRenderSettings{
            .dynamic_resolution_enabled = true,
            .dynamic_resolution_min_scale = 0.5,
            .dynamic_resolution_max_scale = 0.8,
            .target_fps = 120,
        }, rs);
    }
}
