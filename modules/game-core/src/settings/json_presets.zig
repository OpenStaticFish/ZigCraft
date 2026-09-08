const std = @import("std");
const fs = @import("fs");
const data = @import("data.zig");
const Settings = data.Settings;
const log = @import("engine-core").log;
const sync = @import("engine-core").sync;

// Preset config compatible with static presets but with dynamic string name
pub const PresetConfig = struct {
    name: []u8,
    shadow_quality: u32,
    shadow_distance: f32,
    shadow_pcf_samples: u8,
    shadow_cascade_blend: bool,
    shadow_caster_distance: f32 = 250.0,
    shadows_enabled: bool = true,
    pbr_enabled: bool,
    pbr_quality: u8,
    msaa_samples: u8,
    taa_enabled: bool = false,
    taa_blend_factor: f32 = 0.9,
    taa_velocity_rejection: f32 = 0.02,
    anisotropic_filtering: u8,
    max_texture_resolution: u32,
    vsync: ?bool = null,
    exposure: f32,
    saturation: f32,
    volumetric_lighting_enabled: bool,
    volumetric_density: f32,
    volumetric_steps: u32,
    volumetric_scattering: f32,
    ssao_enabled: bool,
    lpv_quality_preset: u32 = 1,
    lpv_enabled: bool = false,
    lpv_intensity: f32 = 0.5,
    lpv_cell_size: f32 = 2.0,
    lpv_grid_size: u32 = 32,
    lpv_propagation_iterations: u32 = 3,
    clouds_enabled: bool = true,
    clouds_3d_enabled: bool = true,
    render_distance: i32,
    fxaa_enabled: bool,
    bloom_enabled: bool,
    bloom_intensity: f32,
};

var graphics_presets: std.ArrayListUnmanaged(PresetConfig) = .empty;
var graphics_presets_mutex: sync.Mutex = .{};

/// Reloads transactionally. Use the same allocator until deinit; borrowed preset
/// names must not outlive a successful reload or deinit.
pub fn initPresets(allocator: std.mem.Allocator) !void {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    // Load from assets/config/presets.json
    const content = fs.cwd().readFileAlloc("assets/config/presets.json", allocator, 1024 * 1024) catch |err| {
        log.log.warn("Failed to open presets.json: {}", .{err});
        return err;
    };
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice([]PresetConfig, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // Keep the previous presets intact if parsing or allocation fails on reload.
    var loaded: std.ArrayListUnmanaged(PresetConfig) = .empty;
    errdefer {
        for (loaded.items) |preset| allocator.free(preset.name);
        loaded.deinit(allocator);
    }

    for (parsed.value) |preset| {
        var p = preset;
        // Validate preset values against metadata constraints
        // Skip invalid presets instead of failing entire load
        if (p.shadow_distance < 100.0 or p.shadow_distance > 1000.0) {
            log.log.warn("Skipping preset '{s}': invalid shadow_distance {}", .{ p.name, p.shadow_distance });
            continue;
        }
        if (p.shadow_caster_distance < 50.0 or p.shadow_caster_distance > 500.0) {
            log.log.warn("Skipping preset '{s}': invalid shadow_caster_distance {}", .{ p.name, p.shadow_caster_distance });
            continue;
        }
        if (p.volumetric_density < 0.0 or p.volumetric_density > 0.5) {
            log.log.warn("Skipping preset '{s}': invalid volumetric_density {}", .{ p.name, p.volumetric_density });
            continue;
        }
        if (p.volumetric_steps < 4 or p.volumetric_steps > 32) {
            log.log.warn("Skipping preset '{s}': invalid volumetric_steps {}", .{ p.name, p.volumetric_steps });
            continue;
        }
        if (p.volumetric_scattering < 0.0 or p.volumetric_scattering > 1.0) {
            log.log.warn("Skipping preset '{s}': invalid volumetric_scattering {}", .{ p.name, p.volumetric_scattering });
            continue;
        }
        if (p.bloom_intensity < 0.0 or p.bloom_intensity > 2.0) {
            log.log.warn("Skipping preset '{s}': invalid bloom_intensity {}", .{ p.name, p.bloom_intensity });
            continue;
        }
        if (p.lpv_intensity < 0.0 or p.lpv_intensity > 2.0) {
            log.log.warn("Skipping preset '{s}': invalid lpv_intensity {}", .{ p.name, p.lpv_intensity });
            continue;
        }
        if (p.lpv_quality_preset > 2) {
            log.log.warn("Skipping preset '{s}': invalid lpv_quality_preset {}", .{ p.name, p.lpv_quality_preset });
            continue;
        }
        if (p.lpv_cell_size < 1.0 or p.lpv_cell_size > 4.0) {
            log.log.warn("Skipping preset '{s}': invalid lpv_cell_size {}", .{ p.name, p.lpv_cell_size });
            continue;
        }
        if (p.lpv_grid_size != 16 and p.lpv_grid_size != 32 and p.lpv_grid_size != 64) {
            log.log.warn("Skipping preset '{s}': invalid lpv_grid_size {}", .{ p.name, p.lpv_grid_size });
            continue;
        }
        if (p.lpv_propagation_iterations < 1 or p.lpv_propagation_iterations > 8) {
            log.log.warn("Skipping preset '{s}': invalid lpv_propagation_iterations {}", .{ p.name, p.lpv_propagation_iterations });
            continue;
        }
        if (p.render_distance < 2) {
            log.log.warn("Skipping preset '{s}': invalid render_distance {}", .{ p.name, p.render_distance });
            continue;
        }
        p.name = try allocator.dupe(u8, preset.name);
        errdefer allocator.free(p.name);
        try loaded.append(allocator, p);
    }
    deinitPresetsLocked(allocator);
    graphics_presets = loaded;
    log.log.info("Loaded {} graphics presets", .{graphics_presets.items.len});
}

pub fn deinitPresets(allocator: std.mem.Allocator) void {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    deinitPresetsLocked(allocator);
}

fn deinitPresetsLocked(allocator: std.mem.Allocator) void {
    for (graphics_presets.items) |preset| {
        allocator.free(preset.name);
    }
    graphics_presets.deinit(allocator);
    graphics_presets = .empty;
}

pub fn apply(settings: *Settings, preset_idx: usize) void {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    if (preset_idx >= graphics_presets.items.len) return;
    const config = graphics_presets.items[preset_idx];
    applyConfig(settings, config);
}

fn applyConfig(settings: *Settings, config: PresetConfig) void {
    settings.shadow_quality = config.shadow_quality;
    settings.shadow_distance = config.shadow_distance;
    settings.shadow_pcf_samples = config.shadow_pcf_samples;
    settings.shadow_cascade_blend = config.shadow_cascade_blend;
    settings.shadow_caster_distance = config.shadow_caster_distance;
    settings.shadow_sandbox_enabled = config.shadows_enabled;
    settings.shadow_beauty_enabled = config.shadows_enabled;
    settings.pbr_enabled = config.pbr_enabled;
    settings.pbr_quality = config.pbr_quality;
    settings.msaa_samples = config.msaa_samples;
    settings.taa_enabled = config.taa_enabled;
    settings.taa_blend_factor = config.taa_blend_factor;
    settings.taa_velocity_rejection = config.taa_velocity_rejection;
    settings.anisotropic_filtering = config.anisotropic_filtering;
    settings.max_texture_resolution = config.max_texture_resolution;
    if (config.vsync) |vsync| settings.vsync = vsync;
    settings.exposure = config.exposure;
    settings.saturation = config.saturation;
    settings.volumetric_lighting_enabled = config.volumetric_lighting_enabled;
    settings.volumetric_density = config.volumetric_density;
    settings.volumetric_steps = config.volumetric_steps;
    settings.volumetric_scattering = config.volumetric_scattering;
    settings.ssao_enabled = config.ssao_enabled;
    settings.lpv_quality_preset = config.lpv_quality_preset;
    settings.lpv_enabled = config.lpv_enabled;
    settings.lpv_intensity = config.lpv_intensity;
    settings.lpv_cell_size = config.lpv_cell_size;
    settings.lpv_grid_size = config.lpv_grid_size;
    settings.lpv_propagation_iterations = config.lpv_propagation_iterations;
    settings.clouds_enabled = config.clouds_enabled;
    settings.clouds_3d_enabled = config.clouds_3d_enabled;
    settings.render_distance = config.render_distance;
    settings.fxaa_enabled = data.resolveFXAAEnabled(config.taa_enabled, config.fxaa_enabled);
    settings.bloom_enabled = config.bloom_enabled;
    settings.bloom_intensity = config.bloom_intensity;
}

pub fn getIndex(settings: *const Settings) usize {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    for (graphics_presets.items, 0..) |preset, i| {
        if (matches(settings, preset)) return i;
    }
    return graphics_presets.items.len; // Custom
}

fn matches(settings: *const Settings, preset: PresetConfig) bool {
    const epsilon = 0.0001;
    return settings.shadow_quality == preset.shadow_quality and
        std.math.approxEqAbs(f32, settings.shadow_distance, preset.shadow_distance, epsilon) and
        settings.shadow_pcf_samples == preset.shadow_pcf_samples and
        settings.shadow_cascade_blend == preset.shadow_cascade_blend and
        std.math.approxEqAbs(f32, settings.shadow_caster_distance, preset.shadow_caster_distance, epsilon) and
        settings.shadow_sandbox_enabled == preset.shadows_enabled and
        settings.shadow_beauty_enabled == preset.shadows_enabled and
        settings.pbr_enabled == preset.pbr_enabled and
        settings.pbr_quality == preset.pbr_quality and
        settings.msaa_samples == preset.msaa_samples and
        settings.taa_enabled == preset.taa_enabled and
        std.math.approxEqAbs(f32, settings.taa_blend_factor, preset.taa_blend_factor, epsilon) and
        std.math.approxEqAbs(f32, settings.taa_velocity_rejection, preset.taa_velocity_rejection, epsilon) and
        settings.anisotropic_filtering == preset.anisotropic_filtering and
        settings.max_texture_resolution == preset.max_texture_resolution and
        (preset.vsync == null or settings.vsync == preset.vsync.?) and
        std.math.approxEqAbs(f32, settings.exposure, preset.exposure, epsilon) and
        std.math.approxEqAbs(f32, settings.saturation, preset.saturation, epsilon) and
        settings.render_distance == preset.render_distance and
        settings.volumetric_lighting_enabled == preset.volumetric_lighting_enabled and
        std.math.approxEqAbs(f32, settings.volumetric_density, preset.volumetric_density, epsilon) and
        settings.volumetric_steps == preset.volumetric_steps and
        std.math.approxEqAbs(f32, settings.volumetric_scattering, preset.volumetric_scattering, epsilon) and
        settings.ssao_enabled == preset.ssao_enabled and
        settings.lpv_quality_preset == preset.lpv_quality_preset and
        settings.lpv_enabled == preset.lpv_enabled and
        std.math.approxEqAbs(f32, settings.lpv_intensity, preset.lpv_intensity, epsilon) and
        std.math.approxEqAbs(f32, settings.lpv_cell_size, preset.lpv_cell_size, epsilon) and
        settings.lpv_grid_size == preset.lpv_grid_size and
        settings.lpv_propagation_iterations == preset.lpv_propagation_iterations and
        settings.clouds_enabled == preset.clouds_enabled and
        settings.clouds_3d_enabled == preset.clouds_3d_enabled and
        settings.fxaa_enabled == data.resolveFXAAEnabled(preset.taa_enabled, preset.fxaa_enabled) and
        settings.bloom_enabled == preset.bloom_enabled and
        std.math.approxEqAbs(f32, settings.bloom_intensity, preset.bloom_intensity, epsilon);
}

pub fn getPresetName(idx: usize) []const u8 {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    if (idx >= graphics_presets.items.len) return "CUSTOM";
    return graphics_presets.items[idx].name;
}

pub fn count() usize {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    return graphics_presets.items.len;
}

pub fn findAndApplyNamed(settings: *Settings, preset_name: []const u8) ?[]const u8 {
    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();

    for (graphics_presets.items) |preset| {
        if (std.ascii.eqlIgnoreCase(preset.name, preset_name)) {
            applyConfig(settings, preset);
            return preset.name;
        }
    }

    return null;
}

test "preset matching uses effective FXAA and detects SSAO edits" {
    try initPresets(std.testing.allocator);
    defer deinitPresets(std.testing.allocator);

    graphics_presets_mutex.lock();
    defer graphics_presets_mutex.unlock();
    var config = graphics_presets.items[1];
    config.taa_enabled = true;
    config.fxaa_enabled = true;
    var settings = Settings{};
    applyConfig(&settings, config);
    try std.testing.expect(!settings.fxaa_enabled);
    try std.testing.expect(matches(&settings, config));
    settings.ssao_enabled = !settings.ssao_enabled;
    try std.testing.expect(!matches(&settings, config));
}
