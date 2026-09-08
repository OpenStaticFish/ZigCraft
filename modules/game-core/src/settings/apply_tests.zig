const std = @import("std");
const testing = std.testing;
const fs = @import("fs");
const rhi_pkg = @import("engine-rhi");
const Settings = @import("data.zig").Settings;
const apply = @import("apply.zig");
const persistence = @import("persistence.zig");
const presets = @import("json_presets.zig");

const DynamicResolution = struct {
    enabled: bool,
    min_scale: f32,
    max_scale: f32,
    target_fps: u32,
};

// Null distinguishes an omitted setter from a correctly applied false/zero value.
const Captured = struct {
    vsync: ?bool = null,
    wireframe: ?bool = null,
    textures: ?bool = null,
    debug_view: ?bool = null,
    debug_channel: ?u32 = null,
    anisotropy: ?u8 = null,
    shadow_resolution: ?u32 = null,
    msaa: ?u8 = null,
    fxaa: ?bool = null,
    taa_blend: ?f32 = null,
    taa_rejection: ?f32 = null,
    dynamic_resolution: ?DynamicResolution = null,
    bloom: ?bool = null,
    bloom_intensity: ?f32 = null,
    vignette: ?bool = null,
    vignette_intensity: ?f32 = null,
    film_grain: ?bool = null,
    film_grain_intensity: ?f32 = null,
    volumetric_density: ?f32 = null,
};

const MockQuality = struct {
    captured: Captured = .{},
    calls: usize = 0,

    fn capture(comptime field: []const u8, comptime T: type) *const fn (*anyopaque, T) void {
        return struct {
            fn set(ptr: *anyopaque, value: T) void {
                const self: *MockQuality = @ptrCast(@alignCast(ptr));
                @field(self.captured, field) = value;
                self.calls += 1;
            }
        }.set;
    }

    fn setDynamicResolution(ptr: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        const self: *MockQuality = @ptrCast(@alignCast(ptr));
        self.captured.dynamic_resolution = .{ .enabled = enabled, .min_scale = min_scale, .max_scale = max_scale, .target_fps = target_fps };
        self.calls += 1;
    }

    const quality_vtable = rhi_pkg.IRenderQualityOptions.VTable{
        .setVSync = capture("vsync", bool),
        .setWireframe = capture("wireframe", bool),
        .setTexturesEnabled = capture("textures", bool),
        .setDebugShadowView = capture("debug_view", bool),
        .setShadowDebugChannel = capture("debug_channel", u32),
        .setAnisotropicFiltering = capture("anisotropy", u8),
        .setShadowResolution = capture("shadow_resolution", u32),
        .setMSAA = capture("msaa", u8),
        .setFXAA = capture("fxaa", bool),
        .setTAABlendFactor = capture("taa_blend", f32),
        .setTAAVelocityRejection = capture("taa_rejection", f32),
        .setDynamicResolution = setDynamicResolution,
        .setBloom = capture("bloom", bool),
        .setBloomIntensity = capture("bloom_intensity", f32),
        .setVignetteEnabled = capture("vignette", bool),
        .setVignetteIntensity = capture("vignette_intensity", f32),
        .setFilmGrainEnabled = capture("film_grain", bool),
        .setFilmGrainIntensity = capture("film_grain_intensity", f32),
        .setVolumetricDensity = capture("volumetric_density", f32),
        // These capabilities have no persisted setting and must not be called.
        .setColorGradingEnabled = undefined,
        .setColorGradingIntensity = undefined,
        .getResolutionScale = undefined,
    };

    const rhi_vtable = rhi_pkg.RHI.VTable{
        .init = undefined,
        .deinit = undefined,
        .quality = &quality_vtable,
    };

    fn rhi(self: *MockQuality) rhi_pkg.RHI {
        return .{ .ptr = self, .vtable = &rhi_vtable, .device = null };
    }
};

test "settings apply startup and narrow adapter forward complete persisted quality settings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = fs.Dir{ .inner = tmp.dir };
    const original = Settings{
        .vsync = false,
        .wireframe_enabled = true,
        .textures_enabled = false,
        .debug_shadow_seam_diag = true,
        .debug_direct_key_active = true,
        .shadow_quality = 3,
        .anisotropic_filtering = 8,
        .msaa_samples = 2,
        .taa_enabled = true,
        .fxaa_enabled = true,
        .taa_blend_factor = 0.75,
        .taa_velocity_rejection = 0.125,
        .dynamic_resolution_enabled = true,
        .dynamic_resolution_min_scale = 0.65,
        .dynamic_resolution_max_scale = 0.95,
        .target_fps = 120,
        .bloom_enabled = true,
        .bloom_intensity = 1.25,
        .vignette_enabled = true,
        .vignette_intensity = 0.625,
        .film_grain_enabled = true,
        .film_grain_intensity = 0.25,
        .volumetric_density = 0.125,
    };
    try persistence.saveToDir(&original, testing.allocator, home);
    var settings = try persistence.loadFromDir(home, testing.allocator);
    defer persistence.deinit(&settings, testing.allocator);

    const expected = Captured{
        .vsync = false,
        .wireframe = true,
        .textures = false,
        .debug_view = true,
        .debug_channel = 7,
        .anisotropy = 8,
        .shadow_resolution = 4096,
        .msaa = 2,
        .fxaa = false,
        .taa_blend = 0.75,
        .taa_rejection = 0.125,
        .dynamic_resolution = .{ .enabled = true, .min_scale = 0.65, .max_scale = 0.95, .target_fps = 120 },
        .bloom = true,
        .bloom_intensity = 1.25,
        .vignette = true,
        .vignette_intensity = 0.625,
        .film_grain = true,
        .film_grain_intensity = 0.25,
        .volumetric_density = 0.125,
    };

    var mock = MockQuality{};
    var rhi = mock.rhi();
    apply.applyToRHI(&settings, &rhi);
    try testing.expectEqualDeep(expected, mock.captured);
    try testing.expectEqual(@as(usize, 19), mock.calls);
    try testing.expect(settings.fxaa_enabled); // Applying a snapshot does not rewrite it.

    mock = .{};
    var adapter = rhi_pkg.RenderSettingsAdapter.init(&rhi);
    apply.applyToRenderSettings(&settings, adapter.interface());
    try testing.expectEqualDeep(expected, mock.captured);
    try testing.expectEqual(@as(usize, 19), mock.calls);
}

test "settings apply TAA FXAA policy is consistent for snapshots and UI transitions" {
    var mock = MockQuality{};
    var rhi = mock.rhi();
    var adapter = rhi_pkg.RenderSettingsAdapter.init(&rhi);

    const cases = .{
        .{ false, false, false },
        .{ false, true, true },
        .{ true, false, false },
        .{ true, true, false },
    };
    inline for (cases) |case| {
        var settings = Settings{ .taa_enabled = case[0], .fxaa_enabled = case[1] };
        mock = .{};
        apply.applyToRHI(&settings, &rhi);
        try testing.expectEqual(@as(?bool, case[2]), mock.captured.fxaa);
        try testing.expectEqual(case[1], settings.fxaa_enabled);

        inline for (.{ "taa_enabled", "fxaa_enabled" }) |name| {
            settings.fxaa_enabled = case[1];
            mock = .{};
            apply.applyChangedSetting(name, &settings, adapter.interface());
            try testing.expectEqualDeep(Captured{ .fxaa = case[2] }, mock.captured);
            try testing.expectEqual(case[2], settings.fxaa_enabled);
            try testing.expectEqual(@as(usize, 1), mock.calls);
        }
    }
}

test "settings apply UI quality debug and resolution groups update without unrelated setters" {
    var mock = MockQuality{};
    var rhi = mock.rhi();
    var adapter = rhi_pkg.RenderSettingsAdapter.init(&rhi);
    var settings = Settings{
        .shadow_quality = 99,
        .dynamic_resolution_enabled = false,
        .dynamic_resolution_min_scale = 0.4,
        .dynamic_resolution_max_scale = 0.8,
        .target_fps = 144,
    };
    apply.applyChangedSetting("shadow_quality", &settings, adapter.interface());
    try testing.expectEqualDeep(Captured{ .shadow_resolution = 2048 }, mock.captured);
    try testing.expectEqual(@as(usize, 1), mock.calls);

    inline for (.{ "dynamic_resolution_enabled", "dynamic_resolution_min_scale", "dynamic_resolution_max_scale", "target_fps" }) |name| {
        mock = .{};
        apply.applyChangedSetting(name, &settings, adapter.interface());
        try testing.expectEqualDeep(Captured{ .dynamic_resolution = .{ .enabled = false, .min_scale = 0.4, .max_scale = 0.8, .target_fps = 144 } }, mock.captured);
        try testing.expectEqual(@as(usize, 1), mock.calls);
    }

    mock = .{};
    settings.debug_shadow_seam_diag = true;
    apply.applyChangedSetting("debug_shadow_seam_diag", &settings, adapter.interface());
    try testing.expectEqualDeep(Captured{ .debug_view = true, .debug_channel = 4 }, mock.captured);
    try testing.expectEqual(@as(usize, 2), mock.calls);
    mock = .{};
    settings.debug_shadow_seam_diag = false;
    apply.applyChangedSetting("debug_shadow_seam_diag", &settings, adapter.interface());
    try testing.expectEqualDeep(Captured{ .debug_view = false, .debug_channel = 0 }, mock.captured);
    try testing.expectEqual(@as(usize, 2), mock.calls);
}

test "settings apply preset changes forward quality and post processing through the adapter" {
    try presets.initPresets(testing.allocator);
    defer presets.deinitPresets(testing.allocator);
    var settings = Settings{ .vsync = true, .taa_enabled = true, .fxaa_enabled = false };
    presets.apply(&settings, 0);

    var mock = MockQuality{};
    var rhi = mock.rhi();
    var adapter = rhi_pkg.RenderSettingsAdapter.init(&rhi);
    apply.applyToRenderSettings(&settings, adapter.interface());
    try testing.expectEqualDeep(Captured{
        .vsync = false,
        .wireframe = false,
        .textures = true,
        .debug_view = false,
        .debug_channel = 0,
        .anisotropy = 1,
        .shadow_resolution = 1024,
        .msaa = 1,
        .fxaa = true,
        .taa_blend = 0.85,
        .taa_rejection = 0.03,
        .dynamic_resolution = .{ .enabled = false, .min_scale = 0.5, .max_scale = 1.0, .target_fps = 60 },
        .bloom = false,
        .bloom_intensity = 0.3,
        .vignette = false,
        .vignette_intensity = 0.3,
        .film_grain = false,
        .film_grain_intensity = 0.15,
        .volumetric_density = 0.0,
    }, mock.captured);
    try testing.expectEqual(@as(usize, 19), mock.calls);
}
