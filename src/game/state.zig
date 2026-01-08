const std = @import("std");

pub const AppState = enum {
    home,
    singleplayer,
    world,
    paused,
    settings,
    resource_packs,
    environment,
    graphics,
};

pub const Settings = struct {
    render_distance: i32 = 15,
    mouse_sensitivity: f32 = 50.0,
    vsync: bool = true,
    fov: f32 = 45.0,
    textures_enabled: bool = true,
    wireframe_enabled: bool = false,
    shadow_quality: u32 = 2, // 0=Low, 1=Medium, 2=High, 3=Ultra
    shadow_distance: f32 = 250.0,
    anisotropic_filtering: u8 = 16,
    msaa_samples: u8 = 4,
    ui_scale: f32 = 1.0, // Manual UI scale multiplier (0.5 to 2.0)
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    lod_enabled: bool = false, // Disabled by default due to performance issues
    texture_pack: []const u8 = "default",
    environment_map: []const u8 = "default", // "default" or filename.exr/hdr

    // PBR Settings
    pbr_enabled: bool = true,
    pbr_quality: u8 = 2, // 0=Off, 1=Low (no normal maps), 2=Full
    exposure: f32 = 1.0,
    saturation: f32 = 1.1,

    // Shadow Settings
    shadow_pcf_samples: u8 = 12, // 4, 8, 12, 16
    shadow_cascade_blend: bool = true,

    // Cloud Settings
    cloud_shadows_enabled: bool = true,

    // Volumetric Lighting Settings (Phase 4)
    volumetric_lighting_enabled: bool = true,
    volumetric_density: f32 = 0.05, // Fog density
    volumetric_steps: u32 = 24, // Raymarching steps
    volumetric_scattering: f32 = 0.8, // Mie scattering anisotropy (G)

    // Texture Settings
    max_texture_resolution: u32 = 512, // 16, 32, 64, 128, 256, 512

    pub const ShadowQuality = struct {
        resolution: u32,
        label: []const u8,
    };

    pub const SHADOW_QUALITIES = [_]ShadowQuality{
        .{ .resolution = 1024, .label = "LOW" },
        .{ .resolution = 2048, .label = "MEDIUM" },
        .{ .resolution = 4096, .label = "HIGH" },
        .{ .resolution = 8192, .label = "ULTRA" },
    };

    pub fn getShadowResolution(self: *const Settings) u32 {
        if (self.shadow_quality < SHADOW_QUALITIES.len) {
            return SHADOW_QUALITIES[self.shadow_quality].resolution;
        }
        return SHADOW_QUALITIES[2].resolution; // Default to High
    }

    // Common resolution presets
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

    pub const GraphicsPreset = enum {
        low,
        medium,
        high,
        ultra,
        custom,
    };

    pub const PresetConfig = struct {
        preset: GraphicsPreset,
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
    };

    pub const GRAPHICS_PRESETS = [_]PresetConfig{
        // LOW: Prioritize performance
        .{ .preset = .low, .shadow_quality = 0, .shadow_pcf_samples = 4, .shadow_cascade_blend = false, .pbr_enabled = false, .pbr_quality = 0, .msaa_samples = 1, .anisotropic_filtering = 1, .max_texture_resolution = 64, .cloud_shadows_enabled = false, .exposure = 1.0, .saturation = 1.0, .volumetric_lighting_enabled = false, .volumetric_density = 0.0, .volumetric_steps = 4, .volumetric_scattering = 0.5 },

        // MEDIUM: Balanced
        .{ .preset = .medium, .shadow_quality = 1, .shadow_pcf_samples = 8, .shadow_cascade_blend = false, .pbr_enabled = true, .pbr_quality = 1, .msaa_samples = 2, .anisotropic_filtering = 4, .max_texture_resolution = 128, .cloud_shadows_enabled = true, .exposure = 1.0, .saturation = 1.0, .volumetric_lighting_enabled = true, .volumetric_density = 0.00005, .volumetric_steps = 6, .volumetric_scattering = 0.7 },

        // HIGH: Quality focus
        .{ .preset = .high, .shadow_quality = 2, .shadow_pcf_samples = 12, .shadow_cascade_blend = true, .pbr_enabled = true, .pbr_quality = 2, .msaa_samples = 4, .anisotropic_filtering = 8, .max_texture_resolution = 256, .cloud_shadows_enabled = true, .exposure = 1.0, .saturation = 1.0, .volumetric_lighting_enabled = true, .volumetric_density = 0.0001, .volumetric_steps = 8, .volumetric_scattering = 0.75 },

        // ULTRA: Maximum quality
        .{ .preset = .ultra, .shadow_quality = 3, .shadow_pcf_samples = 16, .shadow_cascade_blend = true, .pbr_enabled = true, .pbr_quality = 2, .msaa_samples = 4, .anisotropic_filtering = 16, .max_texture_resolution = 512, .cloud_shadows_enabled = true, .exposure = 1.0, .saturation = 1.0, .volumetric_lighting_enabled = true, .volumetric_density = 0.0002, .volumetric_steps = 12, .volumetric_scattering = 0.8 },
    };

    pub fn applyPreset(self: *Settings, preset_idx: usize) void {
        if (preset_idx >= GRAPHICS_PRESETS.len) return;
        const config = GRAPHICS_PRESETS[preset_idx];
        self.shadow_quality = config.shadow_quality;
        self.shadow_pcf_samples = config.shadow_pcf_samples;
        self.shadow_cascade_blend = config.shadow_cascade_blend;
        self.pbr_enabled = config.pbr_enabled;
        self.pbr_quality = config.pbr_quality;
        self.msaa_samples = config.msaa_samples;
        self.anisotropic_filtering = config.anisotropic_filtering;
        self.max_texture_resolution = config.max_texture_resolution;
        self.cloud_shadows_enabled = config.cloud_shadows_enabled;
        self.exposure = config.exposure;
        self.saturation = config.saturation;
        self.volumetric_lighting_enabled = config.volumetric_lighting_enabled;
        self.volumetric_density = config.volumetric_density;
        self.volumetric_steps = config.volumetric_steps;
        self.volumetric_scattering = config.volumetric_scattering;
    }

    pub fn getPresetIndex(self: *const Settings) usize {
        for (GRAPHICS_PRESETS, 0..) |preset, i| {
            if (self.shadow_quality == preset.shadow_quality and
                self.shadow_pcf_samples == preset.shadow_pcf_samples and
                self.shadow_cascade_blend == preset.shadow_cascade_blend and
                self.pbr_enabled == preset.pbr_enabled and
                self.pbr_quality == preset.pbr_quality and
                self.msaa_samples == preset.msaa_samples and
                self.anisotropic_filtering == preset.anisotropic_filtering and
                self.max_texture_resolution == preset.max_texture_resolution and
                self.cloud_shadows_enabled == preset.cloud_shadows_enabled and
                self.exposure == preset.exposure and
                self.saturation == preset.saturation)
            {
                return i;
            }
        }
        return GRAPHICS_PRESETS.len; // Custom
    }

    const CONFIG_DIR = ".config/zigcraft";
    const CONFIG_FILE = "settings.json";

    /// Load settings from ~/.config/zigcraft/settings.json
    /// Returns default settings if file doesn't exist or is invalid
    pub fn load(allocator: std.mem.Allocator) Settings {
        const home = std.posix.getenv("HOME") orelse return .{};

        // Open home directory
        var home_dir = std.fs.openDirAbsolute(home, .{}) catch return .{};
        defer home_dir.close();

        // Try to open the config file relative to home
        const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
        const content = home_dir.readFileAlloc(config_path, allocator, @enumFromInt(16 * 1024)) catch return .{};
        defer allocator.free(content);

        const parsed = std.json.parseFromSlice(Settings, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return .{};
        defer parsed.deinit();

        var settings = parsed.value;
        // Deep copy the texture pack string so it survives deinit
        if (std.mem.eql(u8, settings.texture_pack, "default")) {
            settings.texture_pack = "default";
        } else {
            settings.texture_pack = allocator.dupe(u8, settings.texture_pack) catch "default";
        }

        if (std.mem.eql(u8, settings.environment_map, "default")) {
            settings.environment_map = "default";
        } else {
            settings.environment_map = allocator.dupe(u8, settings.environment_map) catch "default";
        }

        std.log.info("Settings loaded from ~/{s}", .{config_path});
        return settings;
    }

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (!std.mem.eql(u8, self.texture_pack, "default")) {
            allocator.free(self.texture_pack);
        }
        if (!std.mem.eql(u8, self.environment_map, "default")) {
            allocator.free(self.environment_map);
        }
    }

    pub fn setTexturePack(self: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
        if (std.mem.eql(u8, self.texture_pack, name)) return;
        if (!std.mem.eql(u8, self.texture_pack, "default")) allocator.free(self.texture_pack);
        if (std.mem.eql(u8, name, "default")) {
            self.texture_pack = "default";
        } else {
            self.texture_pack = try allocator.dupe(u8, name);
        }
    }

    pub fn setEnvironmentMap(self: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
        if (std.mem.eql(u8, self.environment_map, name)) return;
        if (!std.mem.eql(u8, self.environment_map, "default")) allocator.free(self.environment_map);
        if (std.mem.eql(u8, name, "default")) {
            self.environment_map = "default";
        } else {
            self.environment_map = try allocator.dupe(u8, name);
        }
    }

    /// Save settings to ~/.config/zigcraft/settings.json
    pub fn save(self: *const Settings, allocator: std.mem.Allocator) void {
        const home = std.posix.getenv("HOME") orelse {
            std.log.warn("Cannot save settings: HOME not set", .{});
            return;
        };

        // Open home directory
        var home_dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
            std.log.warn("Cannot open home directory: {}", .{err});
            return;
        };
        defer home_dir.close();

        // Create config directory if it doesn't exist
        home_dir.makePath(CONFIG_DIR) catch |err| {
            std.log.warn("Failed to create config directory: {}", .{err});
            return;
        };

        // Open/create the settings file
        const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
        const file = home_dir.createFile(config_path, .{}) catch |err| {
            std.log.warn("Failed to create settings file: {}", .{err});
            return;
        };
        defer file.close();

        // Serialize settings to JSON and write to file
        const json_str = std.json.Stringify.valueAlloc(allocator, self.*, .{ .whitespace = .indent_2 }) catch |err| {
            std.log.warn("Failed to serialize settings: {}", .{err});
            return;
        };
        defer allocator.free(json_str);

        // Write to file
        _ = file.writeAll(json_str) catch |err| {
            std.log.warn("Failed to write settings: {}", .{err});
            return;
        };

        std.log.info("Settings saved to ~/{s}", .{config_path});
    }
};
