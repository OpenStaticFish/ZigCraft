const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;
const log = @import("engine-core").log;
const fs = @import("fs");

const CONFIG_DIR = ".config/zigcraft";
const CONFIG_FILE = "settings.json";

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

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
    const home = getenv("HOME") orelse return .{};

    // Open home directory
    var home_dir = fs.openDirAbsolute(home, .{}) catch |err| {
        log.log.warn("Failed to open home directory '{s}': {}", .{ home, err });
        return .{};
    };
    defer home_dir.close();

    // Try to open the config file relative to home
    const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
    const content = home_dir.readFileAlloc(config_path, allocator, 16 * 1024) catch |err| {
        if (err != error.FileNotFound) {
            log.log.warn("Failed to read settings file '{s}': {}", .{ config_path, err });
        }
        return .{};
    };
    defer allocator.free(content);

    const settings = parseSettingsJson(allocator, content) catch |err| {
        log.log.warn("Failed to parse settings JSON: {}. Using defaults.", .{err});
        return .{};
    };

    log.log.info("Settings loaded from ~/{s}", .{config_path});
    return settings;
}

fn parseSettingsJson(allocator: std.mem.Allocator, content: []const u8) !Settings {
    const parsed = try std.json.parseFromSlice(Settings, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var settings = parsed.value;
    settings.texture_pack = try dupStringField(allocator, settings.texture_pack);
    errdefer freeStringField(allocator, settings.texture_pack);
    settings.environment_map = try dupStringField(allocator, settings.environment_map);
    return settings;
}

fn stringifySettings(allocator: std.mem.Allocator, settings: *const Settings) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, settings.*, .{ .whitespace = .indent_2 });
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
///
/// Errors are propagated to the caller so they can be reported to the user.
/// Returns error.NoHomeDir if the HOME environment variable is not set.
pub fn save(settings: *const Settings, allocator: std.mem.Allocator) !void {
    const home = getenv("HOME") orelse return error.NoHomeDir;

    // Open home directory
    var home_dir = try fs.openDirAbsolute(home, .{});
    defer home_dir.close();

    // Create config directory if it doesn't exist (idempotent).
    home_dir.makePath(CONFIG_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open/create the settings file
    const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
    const file = try home_dir.createFile(config_path, .{});
    defer file.close();

    // Serialize settings to JSON and write to file
    const json_str = try stringifySettings(allocator, settings);
    defer allocator.free(json_str);

    try file.writeAll(json_str);

    log.log.info("Settings saved to ~/{s}", .{config_path});
}

test "settings JSON ignores removed LOD fields and omits them when saved" {
    const allocator = std.testing.allocator;
    const legacy_json =
        \\{
        \\  "render_distance": 23,
        \\  "vsync": false,
        \\  "horizon_distance": 512,
        \\  "lod_enabled": true
        \\}
    ;

    var settings = try parseSettingsJson(allocator, legacy_json);
    defer deinit(&settings, allocator);
    try std.testing.expectEqual(@as(i32, 23), settings.render_distance);
    try std.testing.expect(!settings.vsync);

    const saved_json = try stringifySettings(allocator, &settings);
    defer allocator.free(saved_json);
    try std.testing.expect(std.mem.indexOf(u8, saved_json, "render_distance") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved_json, "horizon_distance") == null);
    try std.testing.expect(std.mem.indexOf(u8, saved_json, "lod_enabled") == null);
}
