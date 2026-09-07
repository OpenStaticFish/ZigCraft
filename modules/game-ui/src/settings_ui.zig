const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Theme = @import("menu_theme.zig");
const Rect = Theme.Rect;
const settings_pkg = @import("game-core").settings;
const Settings = settings_pkg.Settings;

pub const StepResult = enum { none, previous, next };

pub fn drawStepperControl(ui: *UISystem, row: Rect, value: []const u8, value_scale: f32, button_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) StepResult {
    const control_h = row.height - 18.0 * scale;
    const arrow_w = 42.0 * scale;
    const value_w = @min(190.0 * scale, row.width * 0.32);
    const control_y = row.y + 9.0 * scale;
    const right_x = row.x + row.width - arrow_w - 12.0 * scale;
    const value_x = right_x - value_w - 8.0 * scale;
    const left_x = value_x - arrow_w - 8.0 * scale;
    var result: StepResult = .none;
    if (Theme.drawButton(ui, .{ .x = left_x, .y = control_y, .width = arrow_w, .height = control_h }, "-", button_scale, mx, my, clicked, .ghost, scale)) result = .previous;
    Theme.drawValueText(ui, .{ .x = value_x, .y = control_y, .width = value_w, .height = control_h }, value, value_scale, scale);
    if (Theme.drawButton(ui, .{ .x = right_x, .y = control_y, .width = arrow_w, .height = control_h }, "+", button_scale, mx, my, clicked, .ghost, scale)) result = .next;
    return result;
}

pub fn drawToggleControl(ui: *UISystem, row: Rect, enabled: bool, value_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    const toggle_w = 190.0 * scale;
    const toggle_h = row.height - 18.0 * scale;
    const toggle_x = row.x + row.width - toggle_w - 12.0 * scale;
    const toggle_y = row.y + 9.0 * scale;
    return Theme.drawButton(ui, .{ .x = toggle_x, .y = toggle_y, .width = toggle_w, .height = toggle_h }, if (enabled) "ENABLED" else "DISABLED", value_scale, mx, my, clicked, if (enabled) .secondary else .ghost, scale);
}

pub fn rowHighlight(comptime name: []const u8, value: anytype) bool {
    _ = name;
    return switch (@TypeOf(value)) {
        bool => value,
        else => false,
    };
}

pub fn applyChangedSetting(comptime name: []const u8, settings: *Settings, rs: anytype) void {
    if (comptime std.mem.eql(u8, name, "anisotropic_filtering")) {
        rs.setAnisotropicFiltering(settings.anisotropic_filtering);
    } else if (comptime std.mem.eql(u8, name, "textures_enabled")) {
        rs.setTexturesEnabled(settings.textures_enabled);
    } else if (comptime std.mem.eql(u8, name, "vsync")) {
        rs.setVSync(settings.vsync);
    } else if (comptime std.mem.eql(u8, name, "volumetric_density")) {
        rs.setVolumetricDensity(settings.volumetric_density);
    } else if (comptime std.mem.eql(u8, name, "shadow_quality")) {
        rs.setShadowResolution(settings.getShadowResolution());
    } else if (comptime std.mem.eql(u8, name, "taa_enabled")) {
        if (settings.taa_enabled) {
            settings.fxaa_enabled = false;
            rs.setFXAA(false);
        }
    } else if (comptime std.mem.eql(u8, name, "taa_blend_factor")) {
        rs.setTAABlendFactor(settings.taa_blend_factor);
    } else if (comptime std.mem.eql(u8, name, "taa_velocity_rejection")) {
        rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
    } else if (comptime std.mem.eql(u8, name, "fxaa_enabled")) {
        if (settings.taa_enabled and settings.fxaa_enabled) {
            settings.fxaa_enabled = false;
            rs.setFXAA(false);
        } else {
            rs.setFXAA(settings.fxaa_enabled);
        }
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
    }
}

pub fn applyPresetSideEffects(settings: *Settings, rs: anytype) void {
    rs.setAnisotropicFiltering(settings.anisotropic_filtering);
    rs.setTexturesEnabled(settings.textures_enabled);
    rs.setShadowResolution(settings.getShadowResolution());
    rs.setTAABlendFactor(settings.taa_blend_factor);
    rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
    if (settings.taa_enabled) {
        settings.fxaa_enabled = false;
        rs.setFXAA(false);
    } else {
        rs.setFXAA(settings.fxaa_enabled);
    }
}

pub fn getPresetLabel(idx: usize) []const u8 {
    return settings_pkg.json_presets.getPresetName(idx);
}

pub fn getLPVQualityLegend(preset: u32) []const u8 {
    return switch (preset) {
        0 => "GRID16  ITER2  TICK8",
        2 => "GRID64  ITER5  TICK3",
        else => "GRID32  ITER3  TICK6",
    };
}
