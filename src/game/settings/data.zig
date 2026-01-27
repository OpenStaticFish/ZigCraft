const std = @import("std");

pub const ShadowQuality = struct {
    resolution: u32,
    label: []const u8,
};

pub const SHADOW_QUALITIES = [_]ShadowQuality{
    .{ .resolution = 1024, .label = "LOW" },
    .{ .resolution = 1536, .label = "MEDIUM" },
    .{ .resolution = 2048, .label = "HIGH" },
    .{ .resolution = 4096, .label = "ULTRA" },
};

pub const Resolution = struct {
    width: u32,
    height: u32,
    label: []const u8,
};

pub const RESOLUTIONS = [_]Resolution{
    .{ .width = 1280, .height = 720, .label = "1280X720" },
    .{ .width = 1600, .height = 900, .label = "1600X900" },
    .{ .width = 1920, .height = 1080, .label = "1920X1080" },
    .{ .width = 2560, .height = 1080, .label = "2560X1080" },
    .{ .width = 2560, .height = 1440, .label = "2560X1440" },
    .{ .width = 3440, .height = 1440, .label = "3440X1440" },
    .{ .width = 3840, .height = 2160, .label = "3840X2160" },
};

pub const Settings = struct {
    render_distance: i32 = 15,
    mouse_sensitivity: f32 = 50.0,
    vsync: bool = true,
    fov: f32 = 45.0,
    textures_enabled: bool = true,
    wireframe_enabled: bool = false,
    debug_shadows_active: bool = false, // Reverted to false for normal gameplay
    shadow_quality: u32 = 2, // 0=Low, 1=Medium, 2=High, 3=Ultra
    shadow_distance: f32 = 250.0,
    anisotropic_filtering: u8 = 16,
    msaa_samples: u8 = 2,
    ui_scale: f32 = 1.0, // Manual UI scale multiplier (0.5 to 2.0)
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    lod_enabled: bool = false,
    texture_pack: []const u8 = "default",
    environment_map: []const u8 = "default", // "default" or filename.exr/hdr

    // PBR Settings
    pbr_enabled: bool = true,
    pbr_quality: u8 = 2, // 0=Off, 1=Low (no normal maps), 2=Full
    exposure: f32 = 0.9,
    saturation: f32 = 1.3,

    // Shadow Settings
    shadow_pcf_samples: u8 = 12, // 4, 8, 12, 16
    shadow_cascade_blend: bool = true,

    // Cloud Settings
    cloud_shadows_enabled: bool = true,

    // Volumetric Lighting Settings (Phase 4)
    volumetric_lighting_enabled: bool = true,
    volumetric_density: f32 = 0.05, // Fog density
    volumetric_steps: u32 = 16, // Raymarching steps
    volumetric_scattering: f32 = 0.8, // Mie scattering anisotropy (G)
    ssao_enabled: bool = true,

    // FXAA Settings (Phase 3)
    fxaa_enabled: bool = false, // Disabled by default as TAA provides better AA
    taa_enabled: bool = true,
    smaa_enabled: bool = false,

    // Bloom Settings (Phase 3)
    bloom_enabled: bool = true,
    bloom_intensity: f32 = 0.5,

    // Texture Settings
    max_texture_resolution: u32 = 512, // 16, 32, 64, 128, 256, 512

    pub const SettingMetadata = struct {
        label: []const u8,
        description: []const u8 = "",
        kind: union(enum) {
            toggle: void,
            slider: struct { min: f32, max: f32, step: f32 },
            choice: struct { labels: []const []const u8, values: ?[]const u32 = null },
            int_range: struct { min: i32, max: i32, step: i32 },
        },
    };

    pub const metadata = struct {
        pub const render_distance = SettingMetadata{
            .label = "RENDER DISTANCE",
            .kind = .{ .int_range = .{ .min = 2, .max = 32, .step = 1 } },
        };
        pub const mouse_sensitivity = SettingMetadata{
            .label = "SENSITIVITY",
            .kind = .{ .slider = .{ .min = 1.0, .max = 200.0, .step = 1.0 } },
        };
        pub const fov = SettingMetadata{
            .label = "FOV",
            .kind = .{ .slider = .{ .min = 30.0, .max = 120.0, .step = 1.0 } },
        };
        pub const vsync = SettingMetadata{
            .label = "VSYNC",
            .kind = .toggle,
        };
        pub const textures_enabled = SettingMetadata{
            .label = "TEXTURES",
            .kind = .toggle,
        };
        pub const shadow_quality = SettingMetadata{
            .label = "SHADOW RESOLUTION",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "LOW", "MEDIUM", "HIGH", "ULTRA" },
                .values = &[_]u32{ 0, 1, 2, 3 },
            } },
        };
        pub const shadow_pcf_samples = SettingMetadata{
            .label = "SHADOW SOFTNESS",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "4 SAMPLES", "8 SAMPLES", "12 SAMPLES", "16 SAMPLES" },
                .values = &[_]u32{ 4, 8, 12, 16 },
            } },
        };
        pub const shadow_cascade_blend = SettingMetadata{
            .label = "CASCADE BLENDING",
            .kind = .toggle,
        };
        pub const pbr_enabled = SettingMetadata{
            .label = "PBR RENDERING",
            .kind = .toggle,
        };
        pub const pbr_quality = SettingMetadata{
            .label = "PBR QUALITY",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "LOW", "FULL" },
                .values = &[_]u32{ 0, 1, 2 },
            } },
        };
        pub const anisotropic_filtering = SettingMetadata{
            .label = "ANISOTROPIC FILTER",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "2X", "4X", "8X", "16X" },
                .values = &[_]u32{ 1, 2, 4, 8, 16 },
            } },
        };
        pub const msaa_samples = SettingMetadata{
            .label = "FOLIAGE MSAA",
            .description = "Applies MSAA only to foliage geometry (Future)",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "2X", "4X", "8X" },
                .values = &[_]u32{ 1, 2, 4, 8 },
            } },
        };
        pub const max_texture_resolution = SettingMetadata{
            .label = "MAX TEXTURE RES",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "16 PX", "32 PX", "64 PX", "128 PX", "256 PX", "512 PX" },
                .values = &[_]u32{ 16, 32, 64, 128, 256, 512 },
            } },
        };
        pub const cloud_shadows_enabled = SettingMetadata{
            .label = "CLOUD SHADOWS",
            .kind = .toggle,
        };
        pub const lod_enabled = SettingMetadata{
            .label = "LOD SYSTEM",
            .description = "Enables high-distance simplified terrain rendering",
            .kind = .toggle,
        };
        pub const ssao_enabled = SettingMetadata{
            .label = "SSAO",
            .kind = .toggle,
        };
        pub const fxaa_enabled = SettingMetadata{
            .label = "FXAA",
            .description = "Fast Approximate Anti-Aliasing",
            .kind = .toggle,
        };
        pub const taa_enabled = SettingMetadata{
            .label = "TAA",
            .description = "Temporal Anti-Aliasing (Recommended)",
            .kind = .toggle,
        };
        pub const smaa_enabled = SettingMetadata{
            .label = "SMAA",
            .description = "Subpixel Morphological Anti-Aliasing",
            .kind = .toggle,
        };
        pub const bloom_enabled = SettingMetadata{
            .label = "BLOOM",
            .description = "HDR glow effect",
            .kind = .toggle,
        };
        pub const bloom_intensity = SettingMetadata{
            .label = "BLOOM INTENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 2.0, .step = 0.1 } },
        };
        pub const volumetric_density = SettingMetadata{
            .label = "FOG DENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 0.5, .step = 0.05 } },
        };
        pub const volumetric_steps = SettingMetadata{
            .label = "VOLUMETRIC STEPS",
            .kind = .{ .int_range = .{ .min = 4, .max = 32, .step = 4 } },
        };
        pub const volumetric_scattering = SettingMetadata{
            .label = "VOLUMETRIC SCATTERING",
            .kind = .{ .slider = .{ .min = 0.0, .max = 1.0, .step = 0.05 } },
        };
    };

    pub fn getShadowResolution(self: *const Settings) u32 {
        if (self.shadow_quality < SHADOW_QUALITIES.len) {
            return SHADOW_QUALITIES[self.shadow_quality].resolution;
        }
        return SHADOW_QUALITIES[2].resolution; // Default to High
    }

    pub fn getResolutionIndex(self: *const Settings) usize {
        for (RESOLUTIONS, 0..) |res, i| {
            if (res.width == self.window_width and res.height == self.window_height) {
                return i;
            }
        }
        return 2; // Default to 1920x1080
    }

    pub fn setResolutionByIndex(self: *Settings, idx: usize) void {
        if (idx < RESOLUTIONS.len) {
            self.window_width = RESOLUTIONS[idx].width;
            self.window_height = RESOLUTIONS[idx].height;
        }
    }
};
