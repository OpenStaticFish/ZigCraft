const std = @import("std");

pub const AppState = enum {
    home,
    singleplayer,
    world,
    paused,
    settings,
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

        std.log.info("Settings loaded from ~/{s}", .{config_path});
        return parsed.value;
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
