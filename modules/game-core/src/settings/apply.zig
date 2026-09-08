const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;
const rhi_pkg = @import("engine-rhi");

/// Startup uses the same settings-only adapter and policy as menus and presets.
pub fn applyToRHI(settings: *const Settings, rhi: *rhi_pkg.RHI) void {
    var adapter = rhi_pkg.RenderSettingsAdapter.init(rhi);
    applyToRenderSettings(settings, adapter.interface());
}

/// Applies every persisted setting with a render-quality setter, once per group.
/// The sink must support the complete IRenderSettings contract; settings are not
/// silently skipped based on which methods a sink happens to expose.
///
/// TAA enablement, shader uniforms (PBR, shadow filtering, SSAO, atmosphere, etc.),
/// and world/camera/asset/window settings remain with their existing consumers.
/// Setters request backend changes; resource recreation can occur on a later frame.
pub fn applyToRenderSettings(settings: *const Settings, rs: anytype) void {
    inline for (.{
        "vsync",
        "wireframe_enabled",
        "textures_enabled",
        "debug_shadows_active",
        "anisotropic_filtering",
        "shadow_quality",
        "msaa_samples",
        "fxaa_enabled",
        "taa_blend_factor",
        "taa_velocity_rejection",
        "dynamic_resolution_enabled",
        "bloom_enabled",
        "bloom_intensity",
        "vignette_enabled",
        "vignette_intensity",
        "film_grain_enabled",
        "film_grain_intensity",
        "volumetric_density",
    }) |name| {
        applyRenderSetting(name, settings, rs);
    }
}

/// Applies a UI edit without resending unrelated resource-recreation requests.
/// Keep the UI's existing behavior of clearing FXAA when TAA takes precedence.
pub fn applyChangedSetting(comptime name: []const u8, settings: *Settings, rs: anytype) void {
    if (comptime std.mem.eql(u8, name, "taa_enabled") or std.mem.eql(u8, name, "fxaa_enabled")) {
        settings.fxaa_enabled = data.resolveFXAAEnabled(settings.taa_enabled, settings.fxaa_enabled);
    }
    applyRenderSetting(name, settings, rs);
}

fn applyRenderSetting(comptime name: []const u8, settings: *const Settings, rs: anytype) void {
    if (comptime !@hasField(Settings, name)) @compileError("Unknown setting: " ++ name);

    if (comptime std.mem.eql(u8, name, "vsync")) {
        rs.setVSync(settings.vsync);
    } else if (comptime std.mem.eql(u8, name, "wireframe_enabled")) {
        rs.setWireframe(settings.wireframe_enabled);
    } else if (comptime std.mem.eql(u8, name, "textures_enabled")) {
        rs.setTexturesEnabled(settings.textures_enabled);
    } else if (comptime std.mem.eql(u8, name, "debug_shadows_active") or
        std.mem.eql(u8, name, "debug_shadow_cascade_index") or
        std.mem.eql(u8, name, "debug_shadow_caster_coverage") or
        std.mem.eql(u8, name, "debug_shadow_seam_diag") or
        std.mem.eql(u8, name, "debug_direct_key_active") or
        std.mem.eql(u8, name, "debug_sky_fill_active") or
        std.mem.eql(u8, name, "debug_block_light_active") or
        std.mem.eql(u8, name, "debug_outdoor_factor_active"))
    {
        const channel = data.resolveShadowDebugChannel(settings);
        rs.setDebugShadowView(channel != .off);
        rs.setShadowDebugChannel(@intFromEnum(channel));
    } else if (comptime std.mem.eql(u8, name, "anisotropic_filtering")) {
        rs.setAnisotropicFiltering(settings.anisotropic_filtering);
    } else if (comptime std.mem.eql(u8, name, "shadow_quality")) {
        rs.setShadowResolution(settings.getShadowResolution());
    } else if (comptime std.mem.eql(u8, name, "msaa_samples")) {
        rs.setMSAA(settings.msaa_samples);
    } else if (comptime std.mem.eql(u8, name, "taa_enabled") or std.mem.eql(u8, name, "fxaa_enabled")) {
        rs.setFXAA(data.resolveFXAAEnabled(settings.taa_enabled, settings.fxaa_enabled));
    } else if (comptime std.mem.eql(u8, name, "taa_blend_factor")) {
        rs.setTAABlendFactor(settings.taa_blend_factor);
    } else if (comptime std.mem.eql(u8, name, "taa_velocity_rejection")) {
        rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
    } else if (comptime std.mem.eql(u8, name, "dynamic_resolution_enabled") or
        std.mem.eql(u8, name, "dynamic_resolution_min_scale") or
        std.mem.eql(u8, name, "dynamic_resolution_max_scale") or
        std.mem.eql(u8, name, "target_fps"))
    {
        rs.setDynamicResolution(settings.dynamic_resolution_enabled, settings.dynamic_resolution_min_scale, settings.dynamic_resolution_max_scale, settings.target_fps);
    } else if (comptime std.mem.eql(u8, name, "bloom_enabled")) {
        rs.setBloom(settings.bloom_enabled);
    } else if (comptime std.mem.eql(u8, name, "bloom_intensity")) {
        rs.setBloomIntensity(settings.bloom_intensity);
    } else if (comptime std.mem.eql(u8, name, "vignette_enabled")) {
        rs.setVignetteEnabled(settings.vignette_enabled);
    } else if (comptime std.mem.eql(u8, name, "vignette_intensity")) {
        rs.setVignetteIntensity(settings.vignette_intensity);
    } else if (comptime std.mem.eql(u8, name, "film_grain_enabled")) {
        rs.setFilmGrainEnabled(settings.film_grain_enabled);
    } else if (comptime std.mem.eql(u8, name, "film_grain_intensity")) {
        rs.setFilmGrainIntensity(settings.film_grain_intensity);
    } else if (comptime std.mem.eql(u8, name, "volumetric_density")) {
        rs.setVolumetricDensity(settings.volumetric_density);
    }
}
