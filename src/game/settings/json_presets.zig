const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;

// Preset config compatible with static presets but with dynamic string name
pub const PresetConfig = struct {
    name: []u8,
    shadow_quality: u32,
    shadow_pcf_samples: u8,
    shadow_cascade_blend: bool,
    pbr_enabled: bool,
    pbr_quality: u8,
    msaa_samples: u8,
    anisotropic_filtering: u8,
    max_texture_resolution: u32,
    cloud_shadows_enabled: bool,
    exposure: f32,
    saturation: f32,
    volumetric_lighting_enabled: bool,
    volumetric_density: f32,
    volumetric_steps: u32,
    volumetric_scattering: f32,
    ssao_enabled: bool,
    lod_enabled: bool,
    render_distance: i32,
    fxaa_enabled: bool,
    bloom_enabled: bool,
    bloom_intensity: f32,
};

pub var graphics_presets: std.ArrayListUnmanaged(PresetConfig) = .empty;

pub fn initPresets(allocator: std.mem.Allocator) !void {
    graphics_presets = std.ArrayListUnmanaged(PresetConfig){};

    // Load from assets/config/presets.json
    const content = std.fs.cwd().readFileAlloc("assets/config/presets.json", allocator, @enumFromInt(1024 * 1024)) catch |err| {
        std.log.warn("Failed to open presets.json: {}", .{err});
        return err;
    };
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice([]PresetConfig, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Ensure we clean up on error
    errdefer deinitPresets(allocator);

    for (parsed.value) |preset| {
        var p = preset;
        // Validate preset values against metadata constraints
        if (p.volumetric_density < 0.0 or p.volumetric_density > 0.5) {
            return error.InvalidVolumetricDensity;
        }
        if (p.volumetric_steps < 4 or p.volumetric_steps > 32) {
            return error.InvalidVolumetricSteps;
        }
        if (p.volumetric_scattering < 0.0 or p.volumetric_scattering > 1.0) {
            return error.InvalidVolumetricScattering;
        }
        if (p.bloom_intensity < 0.0 or p.bloom_intensity > 2.0) {
            return error.InvalidBloomIntensity;
        }
        // Duplicate name because parsed.deinit() will free strings
        p.name = try allocator.dupe(u8, preset.name);
        errdefer allocator.free(p.name);
        try graphics_presets.append(allocator, p);
    }
    std.log.info("Loaded {} graphics presets", .{graphics_presets.items.len});
}

pub fn deinitPresets(allocator: std.mem.Allocator) void {
    for (graphics_presets.items) |preset| {
        allocator.free(preset.name);
    }
    graphics_presets.deinit(allocator);
}

pub fn apply(settings: *Settings, preset_idx: usize) void {
    if (preset_idx >= graphics_presets.items.len) return;
    const config = graphics_presets.items[preset_idx];
    settings.shadow_quality = config.shadow_quality;
    settings.shadow_pcf_samples = config.shadow_pcf_samples;
    settings.shadow_cascade_blend = config.shadow_cascade_blend;
    settings.pbr_enabled = config.pbr_enabled;
    settings.pbr_quality = config.pbr_quality;
    settings.msaa_samples = config.msaa_samples;
    settings.anisotropic_filtering = config.anisotropic_filtering;
    settings.max_texture_resolution = config.max_texture_resolution;
    settings.cloud_shadows_enabled = config.cloud_shadows_enabled;
    settings.exposure = config.exposure;
    settings.saturation = config.saturation;
    settings.volumetric_lighting_enabled = config.volumetric_lighting_enabled;
    settings.volumetric_density = config.volumetric_density;
    settings.volumetric_steps = config.volumetric_steps;
    settings.volumetric_scattering = config.volumetric_scattering;
    settings.ssao_enabled = config.ssao_enabled;
    settings.lod_enabled = config.lod_enabled;
    settings.render_distance = config.render_distance;
    settings.fxaa_enabled = config.fxaa_enabled;
    settings.bloom_enabled = config.bloom_enabled;
    settings.bloom_intensity = config.bloom_intensity;
}

pub fn getIndex(settings: *const Settings) usize {
    for (graphics_presets.items, 0..) |preset, i| {
        if (matches(settings, preset)) return i;
    }
    return graphics_presets.items.len; // Custom
}

fn matches(settings: *const Settings, preset: PresetConfig) bool {
    const epsilon = 0.0001;
    return settings.shadow_quality == preset.shadow_quality and
        settings.shadow_pcf_samples == preset.shadow_pcf_samples and
        settings.shadow_cascade_blend == preset.shadow_cascade_blend and
        settings.pbr_enabled == preset.pbr_enabled and
        settings.pbr_quality == preset.pbr_quality and
        settings.msaa_samples == preset.msaa_samples and
        settings.anisotropic_filtering == preset.anisotropic_filtering and
        settings.max_texture_resolution == preset.max_texture_resolution and
        settings.cloud_shadows_enabled == preset.cloud_shadows_enabled and
        std.math.approxEqAbs(f32, settings.exposure, preset.exposure, epsilon) and
        std.math.approxEqAbs(f32, settings.saturation, preset.saturation, epsilon) and
        settings.render_distance == preset.render_distance and
        settings.volumetric_lighting_enabled == preset.volumetric_lighting_enabled and
        std.math.approxEqAbs(f32, settings.volumetric_density, preset.volumetric_density, epsilon) and
        settings.volumetric_steps == preset.volumetric_steps and
        std.math.approxEqAbs(f32, settings.volumetric_scattering, preset.volumetric_scattering, epsilon) and
        settings.ssao_enabled == preset.ssao_enabled and
        settings.lod_enabled == preset.lod_enabled and
        settings.fxaa_enabled == preset.fxaa_enabled and
        settings.bloom_enabled == preset.bloom_enabled and
        std.math.approxEqAbs(f32, settings.bloom_intensity, preset.bloom_intensity, epsilon);
}

pub fn getPresetName(idx: usize) []const u8 {
    if (idx >= graphics_presets.items.len) return "CUSTOM";
    return graphics_presets.items[idx].name;
}
