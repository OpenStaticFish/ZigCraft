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

/// Loads settings from ~/.config/zigcraft/settings.json, falling back to defaults
/// on missing HOME or any read/parse/allocation failure. Non-missing-file failures
/// are logged. Menu metadata is not a load-time validator: it is narrower than
/// some backend-supported ranges. Existing consumers retain their normalization.
pub fn load(allocator: std.mem.Allocator) Settings {
    const home = getenv("HOME") orelse return .{};

    // Open home directory
    var home_dir = fs.openDirAbsolute(home, .{}) catch |err| {
        log.log.warn("Failed to open home directory '{s}': {}", .{ home, err });
        return .{};
    };
    defer home_dir.close();

    const settings = loadFromDir(home_dir, allocator) catch |err| {
        if (err != error.FileNotFound) {
            log.log.warn("Failed to load settings: {}. Using defaults.", .{err});
        }
        return .{};
    };

    log.log.info("Settings loaded from ~/" ++ CONFIG_DIR ++ "/" ++ CONFIG_FILE, .{});
    return settings;
}

/// Loads relative to a supplied home directory without swallowing I/O or decode
/// errors. The returned strings are owned by the caller; release with deinit.
pub fn loadFromDir(home_dir: fs.Dir, allocator: std.mem.Allocator) !Settings {
    const content = try home_dir.readFileAlloc(CONFIG_DIR ++ "/" ++ CONFIG_FILE, allocator, 16 * 1024);
    defer allocator.free(content);
    return parseSettingsJson(allocator, content);
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

    try saveToDir(settings, allocator, home_dir);
    log.log.info("Settings saved to ~/" ++ CONFIG_DIR ++ "/" ++ CONFIG_FILE, .{});
}

/// Saves using fs.Dir operations, replacing the old file only after writing and
/// syncing its sibling temporary file. Callers must serialize saves to the same
/// directory. A failed save may leave the temporary file for the next attempt.
/// This is failure-atomic replacement, not a directory-fsync durability guarantee.
pub fn saveToDir(settings: *const Settings, allocator: std.mem.Allocator, home_dir: anytype) !void {
    const json_str = try stringifySettings(allocator, settings);
    defer allocator.free(json_str);

    // Create config directory if it doesn't exist (idempotent).
    try home_dir.makePath(CONFIG_DIR);

    const config_path = CONFIG_DIR ++ "/" ++ CONFIG_FILE;
    const temp_path = config_path ++ ".tmp";
    {
        const file = try home_dir.createFile(temp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json_str);
        try file.sync();
    }
    try home_dir.rename(temp_path, config_path);
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
