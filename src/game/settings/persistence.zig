const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;

const CONFIG_DIR = ".config/zigcraft";
const CONFIG_FILE = "settings.json";

/// Duplicates a string field, or returns the static "default" sentinel if source equals "default".
/// Returns error.OutOfMemory if allocation fails for non-default strings.
fn dupStringField(allocator: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.eql(u8, source, "default")) {
        return "default";
    }
    return allocator.dupe(u8, source);
}

/// Frees a string field if it was heap-allocated (not the static "default" sentinel).
fn freeStringField(allocator: std.mem.Allocator, field: []const u8) void {
    if (!std.mem.eql(u8, field, "default")) {
        allocator.free(field);
    }
}

/// Load settings from ~/.config/zigcraft/settings.json
/// Returns default settings if file doesn't exist or is invalid
pub fn load(allocator: std.mem.Allocator) Settings {
    const home = std.posix.getenv("HOME") orelse return .{};

    // Open home directory
    var home_dir = std.fs.openDirAbsolute(home, .{}) catch |err| {
        std.log.warn("Failed to open home directory '{s}': {}", .{ home, err });
        return .{};
    };
    defer home_dir.close();

    // Try to open the config file relative to home
    const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
    const content = home_dir.readFileAlloc(config_path, allocator, @enumFromInt(16 * 1024)) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Failed to read settings file '{s}': {}", .{ config_path, err });
        }
        return .{};
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(Settings, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("Failed to parse settings JSON: {}. Using defaults.", .{err});
        return .{};
    };
    defer parsed.deinit();

    var settings = parsed.value;

    // Deep copy string fields so they survive parsed.deinit()
    const texture_pack = dupStringField(allocator, settings.texture_pack) catch {
        std.log.warn("Failed to allocate texture_pack string, using default", .{});
        settings.texture_pack = "default";
        settings.environment_map = "default";
        return settings;
    };

    const environment_map = dupStringField(allocator, settings.environment_map) catch {
        std.log.warn("Failed to allocate environment_map string, using default", .{});
        freeStringField(allocator, texture_pack); // Clean up successful first allocation
        settings.texture_pack = "default";
        settings.environment_map = "default";
        return settings;
    };

    settings.texture_pack = texture_pack;
    settings.environment_map = environment_map;

    std.log.info("Settings loaded from ~/{s}", .{config_path});
    return settings;
}

pub fn deinit(settings: *Settings, allocator: std.mem.Allocator) void {
    freeStringField(allocator, settings.texture_pack);
    freeStringField(allocator, settings.environment_map);
}

pub fn setTexturePack(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.texture_pack, name)) return;
    const new_value = try dupStringField(allocator, name);
    freeStringField(allocator, settings.texture_pack);
    settings.texture_pack = new_value;
}

pub fn setEnvironmentMap(settings: *Settings, allocator: std.mem.Allocator, name: []const u8) !void {
    if (std.mem.eql(u8, settings.environment_map, name)) return;
    const new_value = try dupStringField(allocator, name);
    freeStringField(allocator, settings.environment_map);
    settings.environment_map = new_value;
}

/// Save settings to ~/.config/zigcraft/settings.json
pub fn save(settings: *const Settings, allocator: std.mem.Allocator) void {
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
    const json_str = std.json.Stringify.valueAlloc(allocator, settings.*, .{ .whitespace = .indent_2 }) catch |err| {
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
