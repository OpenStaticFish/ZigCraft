const std = @import("std");
const data = @import("data.zig");
const json_presets = @import("json_presets.zig");
const Settings = data.Settings;

pub fn getAnisotropyLabel(level: u8) []const u8 {
    return switch (level) {
        0, 1 => "OFF",
        2 => "2X",
        4 => "4X",
        8 => "8X",
        16 => "16X",
        else => "ON",
    };
}

pub fn cycleAnisotropy(current: u8) u8 {
    return switch (current) {
        0, 1 => 2,
        2 => 4,
        4 => 8,
        8 => 16,
        else => 1,
    };
}

pub fn getMSAALabel(samples: u8) []const u8 {
    return switch (samples) {
        0, 1 => "OFF",
        2 => "2X",
        4 => "4X",
        8 => "8X",
        else => "ON",
    };
}

pub fn cycleMSAA(current: u8) u8 {
    return switch (current) {
        0, 1 => 2,
        2 => 4,
        4 => 8,
        else => 1,
    };
}

pub fn getShadowQualityLabel(quality_idx: u32) []const u8 {
    if (quality_idx < data.SHADOW_QUALITIES.len) {
        return data.SHADOW_QUALITIES[quality_idx].label;
    }
    return data.SHADOW_QUALITIES[2].label;
}

pub fn getPBRQualityLabel(quality: u8) []const u8 {
    return switch (quality) {
        0 => "OFF",
        1 => "LOW",
        2 => "FULL",
        else => "UNKNOWN",
    };
}

pub fn getShadowSamplesLabel(samples: u8, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{} SAMPLES", .{samples}) catch "8 SAMPLES";
}

pub fn getTextureResLabel(res: u32, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{} PX", .{res}) catch "256 PX";
}

pub fn getUIScaleLabel(scale: f32) []const u8 {
    if (scale <= 0.55) return "0.5X";
    if (scale <= 0.8) return "0.75X";
    if (scale <= 1.1) return "1.0X";
    if (scale <= 1.3) return "1.25X";
    if (scale <= 1.6) return "1.5X";
    return "2.0X";
}

pub fn cycleUIScale(current: f32) f32 {
    if (current <= 0.55) return 0.75;
    if (current <= 0.8) return 1.0;
    if (current <= 1.1) return 1.25;
    if (current <= 1.3) return 1.5;
    if (current <= 1.6) return 2.0;
    return 0.5;
}

pub fn getPresetLabel(idx: usize) []const u8 {
    if (idx >= json_presets.graphics_presets.items.len) return "CUSTOM";
    return json_presets.graphics_presets.items[idx].name;
}
